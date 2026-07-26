;;;; heap.lisp -- spaces, allocators, page wiring (paper-v8 ch. heap).
;;;;
;;;; A space is a region with one allocation policy and one collection
;;;; behaviour (Axes 1, 3, 4).  Each space owns its allocator; the reclamation
;;;; policy dispatches in space-reclaim so the plan loop is policy-agnostic.

(in-package #:clamsara)

;; ---- space constraints ---------------------------------------------------

(defclass space-constraints ()
  ((accepts-copies :initarg :accepts-copies :initform nil :accessor accepts-copies)
   (mixed-age      :initarg :mixed-age      :initform nil :accessor mixed-age)
   (scope          :initarg :scope          :initform :global :accessor scope)
   (immortal       :initarg :immortal       :initform nil :accessor immortal)))

;; ---- space base class ----------------------------------------------------

(defclass space ()
  ((name         :initarg :name :initform nil :reader space-name)
   (start-page   :initarg :start-page :reader space-start-page)
   (page-count   :initarg :page-count :reader space-page-count)
   (allocator    :initarg :allocator :accessor space-allocator)
   (page-resource :initarg :page-resource :initform nil :reader space-page-resource)
   (policy       :initarg :policy :initform :trace :reader space-policy)
   (moving       :initarg :moving :initform :none :reader space-moving)
   (constraints  :initarg :constraints :initform (make-instance 'space-constraints)
                 :reader space-constraints)
   (vm           :initarg :vm :accessor space-vm :initform nil)
   (partner      :initarg :partner :initform nil :accessor space-partner)
   (default-space-p :initarg :default-space :initform nil :accessor space-default-p))
  (:metaclass space-metaclass))

(defmethod shared-initialize :after ((s space) slot-names &key)
  (declare (ignore slot-names))
  (component-validate s))

(declaim (inline space-base-address space-end-address))
(defun space-base-address (s) (ash (space-start-page s) +log-page-words+))
(defun space-end-address (s) (ash (+ (space-start-page s) (space-page-count s)) +log-page-words+))

(defmethod space-contains-p ((s space) address)
  (let ((start (space-base-address s)) (end (space-end-address s)))
    (and (>= address start) (< address end))))

(defmethod component-validate ((s space))
  ;; coherence checks (heap.tex §7); relaxed for the simulator's small heaps.
  (when (and (eq (space-moving s) :concurrent-relocate)
             (not (eq (vm-location (space-vm s) :forwarding) :off-heap)))
    (error 'plan-incompatible :plan s
           :message "concurrent-relocate space needs off-heap forwarding"))
  s)

;; ---- space protocol (heap.tex) -------------------------------------------

(defgeneric space-trace-object (space vm ref tracer &key trace-kind)
  (:method ((s space) vm ref tracer &key trace-kind)
    (declare (ignore tracer trace-kind))
    ref))
(defgeneric space-prepare (space vm &key cycle-kind)
  (:method ((s space) vm &key cycle-kind) (declare (ignore cycle-kind)) s))
(defgeneric space-release (space vm &key cycle-kind)
  (:method ((s space) vm &key cycle-kind) (declare (ignore cycle-kind)) s))
(defgeneric space-reclaim (space vm &key cycle-kind)
  (:method ((s space) vm &key cycle-kind) (declare (ignore cycle-kind)) s))
(defgeneric space-occupancy (space)
  (:method ((s space)) 0))

;; ---- allocator protocol --------------------------------------------------

(defgeneric alloc (allocator size &key &allow-other-keys))
(defgeneric free (allocator addr size))
(defgeneric coalesce (allocator))
(defgeneric allocator-reset (allocator)
  (:method (a) (declare (ignore a)) nil))

;; ---- bump allocator (contiguous) -----------------------------------------

(defclass bump-allocator ()
  ((start :initarg :start :accessor ba-start)
   (limit :initarg :limit :accessor ba-limit)
   (cursor :accessor ba-cursor)
   (vm :initarg :vm :accessor ba-vm)
   (space :initarg :space :accessor ba-space)))

(defmethod shared-initialize :after ((a bump-allocator) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp a 'cursor) (setf (ba-cursor a) (ba-start a))))

(defmethod alloc ((a bump-allocator) size &key &allow-other-keys)
  (let ((c (ba-cursor a)))
    (if (<= (+ c size) (ba-limit a))
        (prog1 c (setf (ba-cursor a) (+ c size)))
        nil)))
(defmethod free ((a bump-allocator) addr size) (declare (ignore addr size)) nil)
(defmethod coalesce ((a bump-allocator)) nil)
(defmethod allocator-reset ((a bump-allocator))
  (when (slot-boundp a 'vm)
    (vm-clear-metadata-range (ba-vm a) (ba-start a) (ba-limit a)))
  (setf (ba-cursor a) (ba-start a)))

;; ---- cons allocator (2-word bump) -----------------------------------------

(defclass cons-allocator (bump-allocator) ())

;; ---- monotone allocator (immortal, never releases) -----------------------

(defclass monotone-allocator (bump-allocator) ())

;; ---- free-list allocator (segregated fit, word granularity) -------------

(defclass free-list-allocator ()
  ((start :initarg :start :accessor fl-start)
   (limit :initarg :limit :accessor fl-limit)
   ;; Parallel boot-allocated arrays. A maximally fragmented word-addressed
   ;; region cannot need more descriptors than it has words, so FREE never
   ;; needs the host allocator.
   (run-starts :accessor fl-run-starts)
   (run-lengths :accessor fl-run-lengths)
   (run-count :accessor fl-run-count :initform 0)
   (vm :initarg :vm :accessor fl-vm)
   (space :initarg :space :accessor fl-space)))

(defmethod shared-initialize :after ((a free-list-allocator) slot-names &key)
  (declare (ignore slot-names))
  (when (and (slot-boundp a 'start) (slot-boundp a 'limit))
    (let ((capacity (max 1 (- (fl-limit a) (fl-start a)))))
      (setf (fl-run-starts a)
            (make-array capacity :element-type 'fixnum :initial-element 0)
            (fl-run-lengths a)
            (make-array capacity :element-type 'fixnum :initial-element 0)
            (fl-run-count a) 1
            (aref (fl-run-starts a) 0) (fl-start a)
            (aref (fl-run-lengths a) 0) (- (fl-limit a) (fl-start a))))))

(declaim (inline %fl-remove-run))
(defun %fl-remove-run (a index)
  (let ((last (1- (fl-run-count a))))
    (loop for i from index below last
          do (setf (aref (fl-run-starts a) i)
                   (aref (fl-run-starts a) (1+ i))
                   (aref (fl-run-lengths a) i)
                   (aref (fl-run-lengths a) (1+ i))))
    (decf (fl-run-count a))))

(defmethod alloc ((a free-list-allocator) size &key &allow-other-keys)
  (dotimes (i (fl-run-count a))
    (let ((addr (aref (fl-run-starts a) i))
          (len (aref (fl-run-lengths a) i)))
      (when (>= len size)
        (if (= len size)
            (%fl-remove-run a i)
            (setf (aref (fl-run-starts a) i) (+ addr size)
                  (aref (fl-run-lengths a) i) (- len size)))
        (return-from alloc addr)))))

(defmethod free ((a free-list-allocator) addr size)
  (when (slot-boundp a 'vm)
    (vm-forget-object (fl-vm a) addr))
  (let* ((count (fl-run-count a))
         (starts (fl-run-starts a))
         (lengths (fl-run-lengths a))
         (pos (loop for i below count
                    when (> (aref starts i) addr) return i
                    finally (return count))))
    (when (>= count (length starts))
      (error 'heap-exhausted :requested-size 1
             :space :free-list-descriptors))
    (when (and (plusp pos)
               (> (+ (aref starts (1- pos)) (aref lengths (1- pos))) addr))
      (error 'clamsara-error :message "overlapping or duplicate free"))
    (when (and (< pos count)
               (> (+ addr size) (aref starts pos)))
      (error 'clamsara-error :message "overlapping or duplicate free"))
    (loop for i downfrom count above pos
          do (setf (aref starts i) (aref starts (1- i))
                   (aref lengths i) (aref lengths (1- i))))
    (setf (aref starts pos) addr
          (aref lengths pos) size)
    (incf (fl-run-count a))
    ;; Merge predecessor, then successor, without manufacturing descriptors.
    (when (and (plusp pos)
               (= (+ (aref starts (1- pos)) (aref lengths (1- pos)))
                  (aref starts pos)))
      (incf (aref lengths (1- pos)) (aref lengths pos))
      (%fl-remove-run a pos)
      (decf pos))
    (when (and (< (1+ pos) (fl-run-count a))
               (= (+ (aref starts pos) (aref lengths pos))
                  (aref starts (1+ pos))))
      (incf (aref lengths pos) (aref lengths (1+ pos)))
      (%fl-remove-run a (1+ pos))))
  nil)

(defmethod coalesce ((a free-list-allocator)) nil) ; free already coalesces
(defmethod allocator-reset ((a free-list-allocator)) nil)

(defun free-runs (a)
  "Diagnostic snapshot of A's runs. Not used by collection."
  (loop for i below (fl-run-count a)
        collect (cons (aref (fl-run-starts a) i)
                      (aref (fl-run-lengths a) i))))

(defun fl-free-words (a)
  (loop for i below (fl-run-count a)
        sum (aref (fl-run-lengths a) i)))

;; ---- large-object allocator (whole pages) --------------------------------

(defclass los-allocator ()
  ((page-resource :initarg :page-resource :accessor los-pr)
   (vm :initarg :vm :accessor los-vm)
   (space :initarg :space :accessor los-space)
   ;; The page-resource hands out *relative* page indices (starting at 1);
   ;; base-page is the absolute page offset of this space so that the
   ;; allocator returns addresses inside the space's own range.
   (base-page :initarg :base-page :accessor los-base-page :initform 0)
   (allocated :accessor los-allocated :initform (make-hash-table :test 'eql))))

(defmethod alloc ((a los-allocator) size &key &allow-other-keys)
  (let* ((pages (ceiling size +page-words+))
         (p (page-resource-get (los-pr a) pages)))
    (when p
      (let ((abs-page (+ p (los-base-page a))))
        (setf (gethash (ash abs-page +log-page-words+) (los-allocated a)) pages)
        (ash abs-page +log-page-words+)))))
(defmethod free ((a los-allocator) addr size)
  (declare (ignore size))
  (let ((pages (gethash addr (los-allocated a))))
    (when pages
      (let ((abs-page (address-page addr)))
        (page-resource-release (los-pr a) (- abs-page (los-base-page a)) pages))
      (remhash addr (los-allocated a)))))
(defmethod allocator-reset ((a los-allocator))
  ;; release every allocated page back to the resource, then forget them
  (maphash (lambda (addr pages)
             (let ((abs-page (address-page addr)))
               (page-resource-release (los-pr a)
                                      (- abs-page (los-base-page a)) pages)))
           (los-allocated a))
  (clrhash (los-allocated a)))

;; ---- Immix allocator (mark-region, block granular) -----------------------
;; Blocks are pages (512 words), carved from a fixed word range.  Bump within
;; a block; on sweep, fully-dead blocks are recycled (cursor reset); a defrag
;; cycle may later compact survivors (opportunistic copy).

(defstruct immix-block base cursor live)

(defclass immix-allocator ()
  ((vm :initarg :vm :accessor ix-vm)
   (space :initarg :space :accessor ix-space)
   (start :initarg :start :accessor ix-start)
   (limit :initarg :limit :accessor ix-limit)
   (block-words :initarg :block-words :initform +g-block+ :accessor ix-block-words)
   (blocks :accessor ix-blocks)
   (block-count :accessor ix-block-count :initform 0)
   (current :accessor ix-current :initform nil)
   (next-base :accessor ix-next-base :initform 0)))

(defmethod shared-initialize :after ((a immix-allocator) slot-names &key)
  (declare (ignore slot-names))
  (when (slot-boundp a 'start)
    (let* ((count (floor (- (ix-limit a) (ix-start a))
                         (ix-block-words a)))
           (blocks (make-array count)))
      (dotimes (i count)
        (let ((base (+ (ix-start a) (* i (ix-block-words a)))))
          (setf (aref blocks i)
                (make-immix-block :base base :cursor base :live 0))))
      (setf (ix-blocks a) blocks
            (ix-block-count a) 0
            (ix-next-base a) (ix-start a)))))

(defmacro do-immix-blocks ((block allocator &optional result) &body body)
  `(loop for %block-index fixnum below (ix-block-count ,allocator)
         for ,block = (aref (ix-blocks ,allocator) %block-index)
         do (progn ,@body)
         finally (return ,result)))

(defun ix-first-block (a)
  (when (plusp (ix-block-count a))
    (aref (ix-blocks a) 0)))

(defun ix-block-end (b block-words) (+ (immix-block-base b) block-words))

(defmethod alloc ((a immix-allocator) size &key &allow-other-keys)
  (flet ((try-block (b)
           (let ((c (immix-block-cursor b)))
             (when (<= (+ c size) (ix-block-end b (ix-block-words a)))
               (setf (immix-block-cursor b) (+ c size))
               c))))
    (or (and (ix-current a) (try-block (ix-current a)))
        (loop for i below (ix-block-count a)
              for b = (aref (ix-blocks a) i)
              thereis (try-block b))
        (let ((b (ix-new-block a))) (when b (try-block b))))))

(defmethod ix-new-block ((a immix-allocator))
  "Carve the next block from the space's word range."
  (when (< (ix-block-count a) (length (ix-blocks a)))
    (let ((b (aref (ix-blocks a) (ix-block-count a))))
      (setf (immix-block-cursor b) (immix-block-base b)
            (immix-block-live b) 0)
      (incf (ix-block-count a))
      (incf (ix-next-base a) (ix-block-words a))
      (setf (ix-current a) b)
      b)))

(defmethod free ((a immix-allocator) addr size) (declare (ignore addr size)) nil)
(defmethod coalesce ((a immix-allocator)) nil)
(defmethod allocator-reset ((a immix-allocator))
  (vm-clear-metadata-range (ix-vm a) (ix-start a) (ix-limit a))
  (setf (ix-block-count a) 0
        (ix-current a) nil
        (ix-next-base a) (ix-start a)))

(defun immix-block-live-count (a vm b)
  "Number of marked object starts in block B."
  (let ((mark (vm-stratum vm :mark)))
    (if mark
        (loop for address from (immix-block-base b)
              below (+ (immix-block-base b) (ix-block-words a))
              count (s-test-bit mark address))
        0)))

(defun immix-forget-dead-objects (a vm b)
  "Clear object-start and per-object metadata for dead objects in B.
Line reuse is a separate allocator concern; stale object identity is never
retained merely because another object keeps the block live."
  (let ((mark (vm-stratum vm :mark))
        (os (vm-object-start vm))
        (start (immix-block-base b))
        (end (+ (immix-block-base b) (ix-block-words a))))
    (when (and mark os)
      (loop for address from start below end
            when (and (s-test-bit os address)
                      (not (s-test-bit mark address)))
              do (vm-forget-object vm address)))))

(defun immix-defrag (s vm)
  "Evacuate one fragmented block into one fresh block.
The old implementation appended a destination block to the same collection it
was iterating, allocated through the ordinary allocator (which could select a
source block), and finally reset every block including the destination.  This
bounded implementation only compacts when an out-of-place block is available."
  (let* ((a (space-allocator s))
         (mark (vm-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm)))
    (when (and mark os
               (plusp (ix-block-count a))
               (< (ix-block-count a) (length (ix-blocks a))))
      (let ((source nil))
        ;; A source is fragmented iff its live payload occupies fewer words
        ;; than its bump extent. Fully-live blocks gain nothing from moving.
        (loop for i below (ix-block-count a)
              for block = (aref (ix-blocks a) i)
              for used = (- (immix-block-cursor block)
                            (immix-block-base block))
              when (plusp used)
              do (let ((live-words 0))
                   (loop for address from (immix-block-base block)
                         below (+ (immix-block-base block)
                                  (ix-block-words a))
                         when (and (s-test-bit os address)
                                   (s-test-bit mark address))
                           do (incf live-words
                                    (vm-object-total-words vm address)))
                   (when (and (plusp live-words) (< live-words used))
                     (setf source block)
                     (return))))
        (when source
          (fill fwd 0)
          (let* ((destination (ix-new-block a))
                 (cursor (immix-block-base destination))
                 (limit (+ cursor (ix-block-words a))))
            ;; The live words came from one block and therefore fit in one
            ;; equally-sized destination block.
            (loop for address from (immix-block-base source)
                  below (+ (immix-block-base source) (ix-block-words a))
                  when (and (s-test-bit os address)
                            (s-test-bit mark address))
                    do (let ((words (vm-object-total-words vm address)))
                         (when (> (+ cursor words) limit)
                           (error 'clamsara-error
                                  :message
                                  "Immix defrag live set exceeds one block"))
                         (let ((destination-address cursor))
                           (incf cursor words)
                           (vm-object-copy
                            vm address destination-address)
                           (setf (vm-object-is-marked-p
                                  vm destination-address)
                                 t
                                 (aref fwd address)
                                 destination-address))))
            (setf (immix-block-cursor destination) cursor)
            (immix-heal-references s vm fwd)
            (vm-clear-metadata-range
             vm (immix-block-base source)
             (+ (immix-block-base source) (ix-block-words a)))
            (setf (immix-block-cursor source) (immix-block-base source)
                  (immix-block-live source) 0
                  (ix-current a) destination)
            (fill fwd 0)))))))

(defun immix-heal-references (s vm fwd)
  "Update root + slot references that point at forwarded objects."
  (when (notany #'plusp fwd) (return-from immix-heal-references))
  (vm-scan-roots vm (vm-plan vm) #'heal-forwarded-root)
  (let ((allocator (space-allocator s))
        (object-start (vm-object-start vm)))
    (do-immix-blocks (block allocator)
      (loop for address from (immix-block-base block)
            below (+ (immix-block-base block)
                     (ix-block-words allocator))
            when (s-test-bit object-start address)
              do (dotimes (slot (vm-object-reference-count vm address))
                   (let ((child (vm-object-reference vm address slot)))
                     (when (vm-reference-p vm child)
                       (let* ((bare (ref-strip-or-self vm child))
                              (destination (aref fwd bare)))
                         (when (plusp destination)
                           (setf (vm-object-reference vm address slot)
                                 destination))))))))))

(defun heal-forwarded-root (plan ref)
  (let ((vm (plan-vm plan)))
    (if (vm-reference-p vm ref)
        (let* ((address (ref-strip-or-self vm ref))
               (destination (aref (vm-fwd-table vm) address)))
          (if (plusp destination)
              ;; Preserve the pointer colour so a self-healing LVB sees the
              ;; relocated reference as "good" rather than a bare address.
              (if (typep vm 'coloured-pointer-mixin)
                  (ref-set-colour vm destination (vm-good-colour vm))
                  destination)
              ref))
        ref)))

;; ---- concrete spaces -----------------------------------------------------

(defclass copy-space (space) ()
  (:default-initargs :policy :trace :moving :stw-copy)
  (:metaclass space-metaclass))
(defclass mark-sweep-space (space) ()
  (:default-initargs :policy :trace :moving :none)
  (:metaclass space-metaclass))
(defclass immix-space (space) ()
  (:default-initargs :policy :trace :moving :opportunistic)
  (:metaclass space-metaclass))
(defclass private-immix-space (immix-space) ()
  (:default-initargs :policy :trace :moving :opportunistic)
  (:metaclass space-metaclass))
(defclass los-space (space) ()
  (:default-initargs :policy :trace :moving :none)
  (:metaclass space-metaclass))
(defclass cons-space (space) ()
  (:default-initargs :policy :trace :moving :stw-copy)
  (:metaclass space-metaclass))
(defclass immortal-space (space) ()
  (:default-initargs :policy nil :moving :none)
  (:metaclass space-metaclass))
(defclass superblock-space (space) ()
  (:default-initargs :policy :hierarchical :moving :none)
  (:metaclass space-metaclass))

;; ---- space instantiation helper -----------------------------------------

(defun %ensure-allocator (space vm)
  "Build the default allocator for SPACE if none was supplied."
  (unless (slot-boundp space 'allocator)
    (let ((start (space-base-address space))
          (end (space-end-address space)))
      (setf (space-allocator space)
            (typecase space
              ((or cons-space)        (make-instance 'cons-allocator :start start :limit end :vm vm :space space))
              (immortal-space         (make-instance 'monotone-allocator :start start :limit end :vm vm :space space))
              (mark-sweep-space       (make-instance 'free-list-allocator :start start :limit end :vm vm :space space))
               (los-space              (make-instance 'los-allocator
                                           :page-resource
                                           (make-instance 'bitmap-page-resource
                                             :total-pages (space-page-count space)
                                             :heap (vm-heap vm))
                                           :base-page (space-start-page space)
                                           :vm vm :space space))
              (immix-space            (make-instance 'immix-allocator :vm vm :space space
                                                     :start start :limit end))
              (superblock-space       (make-instance 'hierarchical-allocator :vm vm :space space
                                                     :start start :limit end))
              (otherwise               (make-instance 'bump-allocator :start start :limit end :vm vm :space space)))))))

(defmethod shared-initialize :after ((s space) slot-names &rest keys &key vm)
  (declare (ignore slot-names keys))
  (when (and vm (slot-boundp s 'start-page) (not (slot-boundp s 'allocator)))
    (%ensure-allocator s vm)))

;; ---- copy-space (SemiSpace / nurseries): Cheney --------------------------

(defmethod space-trace-object ((s copy-space) vm ref tracer &key trace-kind)
  (declare (ignore trace-kind))
  (let* ((addr (ref-strip-or-self vm ref))
         (to (space-partner s)))
    (cond
      ((vm-object-is-forwarded-p vm addr) (vm-object-forwarding-pointer vm addr))
      ((vm-object-is-marked-p vm addr) addr)   ; already a to-space copy
      (t
       (let ((dst (alloc (space-allocator to) (vm-object-total-words vm addr))))
         (vm-object-copy vm addr dst)
         (setf (vm-object-is-marked-p vm dst) t)
         (setf (vm-object-forwarding-pointer vm addr) dst)
         (tracer-enqueue tracer dst)
         dst)))))

(defmethod space-prepare ((s copy-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-stratum vm :mark))
  s)

(defmethod space-reclaim ((s copy-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  ;; forwarding state is in-header and is gone once roots point at to-space;
  ;; mark bits cleared in prepare of next cycle.  Nothing to sweep here.
  s)

(defmethod space-occupancy ((s copy-space))
  (let ((a (space-allocator s)))
    (if (typep a 'bump-allocator) (- (ba-cursor a) (ba-start a)) 0)))

;; ---- cons-space: headerless, off-heap forwarding -------------------------

(defmethod vm-address-cons-p ((vm vm-binding) address)
  (let ((plan (vm-plan vm)))
    (and plan (plan-cons-space plan)
         (space-contains-p (plan-cons-space plan) address))))

(defmethod space-trace-object ((s cons-space) vm ref tracer &key trace-kind)
  (declare (ignore trace-kind))
  (let* ((addr (ref-strip-or-self vm ref))
         (to (space-partner s)))
    (cond
      ((vm-object-is-forwarded-p vm addr) (vm-object-forwarding-pointer vm addr))
      (t (let ((dst (alloc (space-allocator to) 2)))
           (setf (ref-u64 vm dst) (ref-u64 vm addr))
           (setf (ref-u64 vm (+ dst 1)) (ref-u64 vm (+ addr 1)))
           (setf (vm-object-forwarding-pointer vm addr) dst)
           (tracer-enqueue tracer dst)
           dst)))))

;; ---- mark-sweep-space ----------------------------------------------------

(defmethod space-trace-object ((s mark-sweep-space) vm ref tracer &key trace-kind)
  (declare (ignore trace-kind))
  (let ((addr (ref-strip-or-self vm ref)))
    (unless (vm-object-is-marked-p vm addr)
      (setf (vm-object-is-marked-p vm addr) t)
      (tracer-enqueue tracer addr))
    addr))

(defmethod space-prepare ((s mark-sweep-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-stratum vm :mark))
  s)

(defmethod space-reclaim ((s mark-sweep-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (let ((a (space-allocator s))
        (os (vm-object-start vm))
        (mark (vm-stratum vm :mark))
        (start (space-base-address s))
        (end (space-end-address s)))
    (when (and a os mark)
      (loop for address from start below end
            when (and (s-test-bit os address)
                      (not (s-test-bit mark address)))
              do (free a address (vm-object-total-words vm address)))
      (s-clear mark))
    s))

(defmethod space-occupancy ((s mark-sweep-space))
  (let ((a (space-allocator s)))
    (if (typep a 'free-list-allocator)
        (- (fl-limit a) (fl-start a)
           (fl-free-words a))
        0)))

;; ---- immix-space ---------------------------------------------------------

(defmethod space-trace-object ((s immix-space) vm ref tracer &key trace-kind)
  (let ((addr (ref-strip-or-self vm ref)))
    (cond
      ((and (eq trace-kind :defrag) (not (vm-object-is-marked-p vm addr)))
       ;; opportunistic copy: move into a compacted block if a target exists
       (setf (vm-object-is-marked-p vm addr) t)
       (tracer-enqueue tracer addr)
       addr)
      (t
       (unless (vm-object-is-marked-p vm addr)
         (setf (vm-object-is-marked-p vm addr) t)
         (tracer-enqueue tracer addr))
       addr))))

(defmethod space-prepare ((s immix-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-stratum vm :mark))
  s)

(defmethod space-reclaim ((s immix-space) vm &key cycle-kind)
  (let ((a (space-allocator s)))
    (when (and (plusp (ix-block-count a)) (vm-stratum vm :mark))
      (do-immix-blocks (b a)
        (let ((live (immix-block-live-count a vm b)))
          (setf (immix-block-live b) live)
          (immix-forget-dead-objects a vm b)
          (when (zerop live)
            ;; fully dead: recycle the whole block for reuse
            (vm-clear-metadata-range vm
                                     (immix-block-base b)
                                     (+ (immix-block-base b)
                                        (ix-block-words a)))
            (setf (immix-block-cursor b) (immix-block-base b)))))
      (setf (ix-current a) (ix-first-block a)))
    (when (eq cycle-kind :major)
      (immix-defrag s vm))
    (s-clear (vm-stratum vm :mark))
    s))

(defmethod space-occupancy ((s immix-space))
  (let ((a (space-allocator s)))
    (if (typep a 'immix-allocator)
        (loop for i below (ix-block-count a)
              for b = (aref (ix-blocks a) i)
              sum (- (immix-block-cursor b) (immix-block-base b)))
        0)))

;; ---- LOS -----------------------------------------------------------------

(defmethod space-trace-object ((s los-space) vm ref tracer &key trace-kind)
  (declare (ignore trace-kind))
  (let ((addr (ref-strip-or-self vm ref)))
    (unless (vm-object-is-marked-p vm addr)
      (setf (vm-object-is-marked-p vm addr) t)
      (tracer-enqueue tracer addr))
    addr))

(defmethod space-reclaim ((s los-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (let ((a (space-allocator s)) (os (vm-object-start vm)) (mark (vm-stratum vm :mark)))
    (when (and a os mark)
      (loop for address from (space-base-address s)
            below (space-end-address s)
            when (and (s-test-bit os address)
                      (not (s-test-bit mark address)))
              do (free a address (vm-object-total-words vm address)))
      (s-clear mark))
    s))

;; ---- immortal-space ------------------------------------------------------

(defmethod space-reclaim ((s immortal-space) vm &key cycle-kind)
  (declare (ignore vm cycle-kind)) s)

;; ---- hierarchical allocator (Claimore superblock hierarchy) --------------
;; Simplified: allocates objects into blocks of the active superblock; the
;; per-superblock refcount and metablock/block matrices live on the space.

(defclass hierarchical-allocator ()
  ((vm :initarg :vm :accessor ha-vm)
   (space :initarg :space :accessor ha-space)
   (start :initarg :start :accessor ha-start)
   (limit :initarg :limit :accessor ha-limit)
   (cursor :accessor ha-cursor)))

(defmethod shared-initialize :after ((a hierarchical-allocator) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp a 'cursor) (setf (ha-cursor a) (ha-start a))))

(defmethod alloc ((a hierarchical-allocator) size &key &allow-other-keys)
  (when (<= (+ (ha-cursor a) size) (ha-limit a))
    (prog1 (ha-cursor a) (setf (ha-cursor a) (+ (ha-cursor a) size)))))
(defmethod free ((a hierarchical-allocator) addr size) (declare (ignore addr size)) nil)
(defmethod coalesce ((a hierarchical-allocator)) nil)
(defmethod allocator-reset ((a hierarchical-allocator)) nil)
