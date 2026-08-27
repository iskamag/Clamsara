;;;; plans/gencopy.lisp -- generational: copying nursery + copying mature,
;;;; card barrier, minor/major cycles.  The generational machinery is shared by
;;;; genms/genimmix (different mature space).

(in-package #:clamsara)

;; ---- generational base --------------------------------------------------

(defclass generational-plan (plan)
  ((nursery :accessor gen-nursery :initform nil)
   (nursery-to :accessor gen-nursery-to :initform nil)
   (mature :accessor gen-mature :initform nil)
   (mature-to :accessor gen-mature-to :initform nil)  ; set for copying mature
   (promotion-age :initarg :promotion-age :initform 2
                  :reader gen-promotion-age)
   (minor-count :accessor gen-minor-count :initform 0))
  (:metaclass plan-metaclass))

(defclass nursery-copy-space (copy-space) ()
  (:metaclass space-metaclass))

(defmethod plan-nursery ((p generational-plan))
  (gen-nursery p))

(defmethod boot-cycle-kinds ((p generational-plan))
  (declare (ignore p))
  '(:minor :major))

(defmethod boot-reset-state ((p generational-plan))
  (call-next-method)
  (setf (gen-minor-count p) 0)
  p)

(defmethod plan-install-strata ((p generational-plan) vm)
  (vm-set-location vm :mark :side)
  (vm-set-location vm :forwarding :in-header)
  (vm-register-stratum vm :mark
    (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :card
    (make-stratum :card (g-card) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :age
    (make-stratum :age (vm-min-alignment-words vm) :u4 (vm-heap-size vm))))

(defmethod plan-allocate ((p generational-plan) size space-designator)
  (let ((explicit (plan-explicit-space p space-designator)))
    (if explicit
        ;; Explicit names (for example :mature or :los) bypass the nursery
        ;; and automatic LOS policy.
        (or (plan-allocate-in p size explicit)
            (plan-handle-allocation-failure p size explicit))
        (progn
          ;; LOS objects (heap.tex §2) bypass the nursery: whole-page
          ;; allocations in the large-object space.  This is only an automatic
          ;; policy for the default request; explicit names are authoritative.
          (let ((los (plan-los p)))
            (when (and (or (eq space-designator :default)
                           (null space-designator))
                       los (> (* size +word-bytes+)
                              (constraints-max-non-los-bytes
                               (plan-constraints p))))
              (return-from plan-allocate
                (or (plan-allocate-in p size los)
                    (plan-handle-allocation-failure p size los)))))
          (or (plan-allocate-in p size (gen-nursery p))
              (plan-handle-allocation-failure p size (gen-nursery p)))))))

(defmethod plan-handle-allocation-failure ((p generational-plan) size space)
  ;; After a minor the failed NURSERY object is the cleared nursery-to.  A retry
  ;; must allocate into the CURRENT nursery: allocating into the old space
  ;; object would place a fresh, live cons in a region the next minor's
  ;; prologue clears before tracing it, stranding the mutator's reference.
  (plan-collect p :cycle-kind :minor)
  (or (plan-allocate-in p size (plan-current-space p space))
      (plan-retry-after p size space :major)))

(defmethod plan-current-space ((p generational-plan) space)
  ;; Resolve a stale space object to the space currently playing its role.
  ;; The nursery pair swaps on every minor; the mature pair (copying plans)
  ;; swaps on every major.  A space object handed to the failure handler
  ;; belongs to the generation BEFORE the last collection.
  (cond
    ((eq space (gen-nursery-to p)) (gen-nursery p))
    ((eq space (gen-nursery p)) (gen-nursery p))
    ((and (gen-mature-to p) (eq space (gen-mature-to p))) (gen-mature p))
    ((and (gen-mature-to p) (eq space (gen-mature p))) (gen-mature p))
    (t space)))

;; ---- phases -------------------------------------------------------------

(defmethod gc-phase :prologue ((p generational-plan) k)
  (let ((vm (plan-vm p)))
    (vm-direct-stop-mutators vm)
    ;; A minor traces the allocating nursery into its empty partner.  A major
    ;; additionally prepares the mature policy, but the nursery is still a
    ;; semispace collection rather than an in-place mark.
    (s-clear (vm-direct-stratum vm :mark))
    (space-direct-reset (gen-nursery-to p))
    (unless (eq k :minor)
      (space-direct-prepare (gen-mature p) vm k)
      (when (gen-mature-to p)
        (space-direct-reset (gen-mature-to p))))))

(defmethod gc-phase :mark ((p generational-plan) k)
  (if (eq k :minor)
      (minor-mark p)
      (mark-roots p (plan-tracer p) :trace-kind :major)))

(defmethod gc-phase :reclaim ((p generational-plan) k)
  (unless (eq k :minor)
    (space-direct-reclaim (gen-mature p) (plan-vm p) k)))

(defmethod gc-phase :release ((p generational-plan) k)
  (let ((vm (plan-vm p)))
    ;; The old nursery contains forwarding headers.  Forget it only after all
    ;; roots and slots have been healed by the trace.
    (rotatef (gen-nursery p) (gen-nursery-to p))
    (setf (space-default-p (gen-nursery p)) t
          (space-default-p (gen-nursery-to p)) nil)
    (space-direct-reset (gen-nursery-to p))
    (when (and (gen-mature-to p) (eq k :major))
      (rotatef (gen-mature p) (gen-mature-to p))
      (setf (space-default-p (gen-mature p)) t
            (space-default-p (gen-mature-to p)) nil)
      (space-direct-reset (gen-mature-to p)))
    ;; Forwarding can leave an old object pointing at a nursery survivor.
    ;; Rebuild against the post-swap graph; merely clearing the cards loses
    ;; that edge at the next minor, while retaining old card addresses is
    ;; wrong after a copying mature major.
    (rebuild-remset p)
    (let ((mark (vm-direct-stratum vm :mark))) (when mark (s-clear mark)))
    (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1))
    (when (eq k :minor) (incf (gen-minor-count p)))))

;; ---- nursery evacuation and age-based promotion -------------------------

(defun %nursery-copy-space-trace-object (s vm ref tracer trace-kind)
  (let* ((addr (ref-strip-or-self vm ref))
         (plan (vm-plan vm)))
    (cond
      ((vm-direct-object-forwarded-p vm addr)
       (vm-direct-object-forwarding-pointer vm addr))
      ;; A second root can already name the to-space copy installed while
      ;; processing the first root.
      ((vm-direct-object-marked-p vm addr) addr)
      (t
       (let* ((next-age (min 15 (1+ (vm-direct-object-age vm addr))))
              (promote-p (>= next-age (gen-promotion-age plan)))
              (destination
                (if promote-p
                    (if (and (eq trace-kind :major) (gen-mature-to plan))
                        (gen-mature-to plan)
                        (gen-mature plan))
                    (gen-nursery-to plan)))
              (words (vm-direct-object-total-words vm addr))
              (dst (space-direct-alloc destination words)))
         (unless dst
           (error 'heap-exhausted :requested-size words
                                  :space (space-name destination)))
         (vm-direct-object-copy vm addr dst)
         (vm-direct-set-object-age vm dst next-age)
         (vm-direct-set-object-marked-p vm dst t)
         (vm-direct-set-object-forwarding-pointer vm addr dst)
         (tracer-enqueue tracer dst)
         dst)))))

(defmethod space-trace-object ((s nursery-copy-space) vm ref tracer trace-kind)
  (%nursery-copy-space-trace-object s vm ref tracer trace-kind))

;; ---- minor marking: nursery only, seeded from roots + remembered set ----

(defun minor-root-reference (plan ref)
  ;; A minor's root set must cover BOTH the allocating nursery and the
  ;; previous nursery (now `gen-nursery-to`).  Between two flips the mutator
  ;; can keep a reference that points into either space: a freshly allocated
  ;; cons sits in the current nursery, while a survivor of the previous minor
  ;; whose addressing the rotate left in the other half must still be traced.
  ;; TRACE-ROOT-IN re-validates object starts, so scanning the superset is
  ;; safe: a space that is about to be cleared holds no live objects reachable
  ;; from roots, and those roots simply resolve to the rotated survivor.
  (let ((resolved (trace-root-in plan ref (gen-nursery plan) :trace-kind :minor)))
    (if (eql resolved ref)
        (trace-root-in plan ref (gen-nursery-to plan) :trace-kind :minor)
        resolved)))

(defun minor-grey-reference (plan ref)
  (trace-object-children plan ref
                         :target-space (gen-nursery plan)
                         :trace-kind :minor))

(defun minor-mark (plan)
  (let* ((vm (plan-vm plan))
         (tr (plan-tracer plan))
         (nursery (gen-nursery plan)))
    (tracer-reset tr)
    ;; seed roots that point into the nursery
    (vm-direct-scan-roots vm plan #'minor-root-reference)
    ;; seed remembered set: dirty mature cards -> nursery refs
    (scan-remset plan vm nursery tr)
    ;; drain: trace nursery children only (mature refs are external roots)
    (tracer-drain tr #'minor-grey-reference plan)))

(defun scan-remset (plan vm nursery tr)
  "For each dirty mature card, seed the tracer with its nursery references.
LOS objects are card-tracked too, but live at page granularity (their cards
are outside the mature space), so they are scanned alongside the mature
space."
  (let ((card (vm-direct-stratum vm :card))
        (os (vm-object-start vm))
        (mature (gen-mature plan))
        (los (plan-los plan)))
    (when (and card os mature)
      (flet ((scan-range (base end)
               (loop for card-address from base below end by (g-card)
                     when (s-test-bit card card-address)
                       do (loop for object-address from card-address
                                below (min (+ card-address (g-card)) end)
                                when (s-test-bit os object-address)
                                  do (trace-object-children
                                      plan object-address
                                      :target-space nursery
                                      :trace-kind :minor
                                      ;; The weak referent is not a strong
                                      ;; remembered edge.  It is handled by
                                      ;; the weak phase after tracing.
                                      :exclude-weak-referent t)))))
        (scan-range (space-base-address mature) (space-end-address mature))
        (when los
          (scan-range (space-base-address los) (space-end-address los)))))))

(defun rebuild-remset (plan)
  "Recompute out-of-nursery -> nursery cards after evacuation and space
rotation.  LOS objects are included: their edges into the nursery are what
the next minor's scan-remset re-checks."
  (let* ((vm (plan-vm plan))
         (card (vm-direct-stratum vm :card))
         (os (vm-object-start vm))
         (nursery (gen-nursery plan))
         (mature (gen-mature plan))
         (los (plan-los plan)))
    (when card
      (s-clear card)
      (when (and os nursery mature)
        (labels ((scan (space)
                   (loop for object-address from (space-base-address space)
                         below (space-end-address space)
                         when (s-test-bit os object-address)
                           do (when (object-has-nursery-ref-p
                                     vm object-address nursery)
                                (s-set-bit card object-address)))))
          (scan mature)
          (when los (scan los))))))
  plan)

(defun object-has-nursery-ref-p (vm address nursery)
  "True if a strong reference slot of ADDRESS points into NURSERY.
Weak referents do not make a remembered edge: the weak phase owns their
liveness decision."
  (let ((slots (vm-reference-slots vm address))
        (weak-p (weak-pointer-p vm address)))
    (flet ((slot-p (i)
             (when (or (not weak-p) (not (zerop i)))
               (let ((child (vm-direct-object-reference vm address i)))
                 (and (vm-reference-p vm child)
                      (space-direct-contains-p nursery
                                        (ref-strip-or-self vm child)))))))
      (if slots
          (loop for i across slots thereis (slot-p i))
          (dotimes (i (vm-direct-object-reference-count vm address))
            (when (slot-p i) (return t)))))))

;; ---- construction -------------------------------------------------------

(defun %make-generational (name vm mature-class copy-mature-p)
  (multiple-value-bind (nursery-spec nursery-to-spec mature-spec mto-spec)
      (if copy-mature-p
          (values-list (partition-pages (vm-page-count vm) '(1/8 1/8 3/8 3/8)))
          (values-list (append (partition-pages (vm-page-count vm) '(1/8 1/8 3/4))
                               (list nil))))
    (let* ((nursery (make-instance 'nursery-copy-space :vm vm
                                    :start-page (car nursery-spec) :page-count (cdr nursery-spec)
                                    :name :nursery :default-space t))
           (nursery-to (make-instance 'nursery-copy-space :vm vm
                                       :start-page (car nursery-to-spec)
                                       :page-count (cdr nursery-to-spec)
                                       :name :nursery-to :default-space nil))
           (mature (make-instance mature-class :vm vm
                                   :start-page (car mature-spec) :page-count (cdr mature-spec)
                                   :name :mature :default-space nil))
           (barrier (make-instance 'barrier :rules (list (card-barrier-rule))))
           (p (make-instance 'generational-plan
                            :name name :vm vm
                            :spaces (list nursery nursery-to mature)
                            :barrier barrier
                            :constraints (make-instance 'plan-constraints
                                         :generational t :write-barrier :card))))
      (setf (gen-nursery p) nursery
            (gen-nursery-to p) nursery-to
            (gen-mature p) mature
            (space-partner nursery) nursery-to
            (space-partner nursery-to) nursery)
      (setf (barrier-plan barrier) p)
      (when (and copy-mature-p mto-spec)
        (let ((mto-space (make-instance 'copy-space :vm vm
                                        :start-page (car mto-spec) :page-count (cdr mto-spec)
                                        :name :mature-to :default-space nil)))
          (setf (gen-mature-to p) mto-space
                (space-partner mature) mto-space
                (space-partner mto-space) mature)
          (setf (plan-spaces p)
                (list nursery nursery-to mature mto-space))))
      ;; The mature pair is a Cheney space set just like the nursery pair:
      ;; carve the LOS from its joint extent so the two halves stay equal.
      (add-los-space p 1/16 :balanced t)
      (finalize-plan p) p)))

(defun make-gencopy-plan (vm heap-size)
  (declare (ignore heap-size))
  (%make-generational :gencopy vm 'copy-space t))
