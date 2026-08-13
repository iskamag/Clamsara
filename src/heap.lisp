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

;; ---- space-metaclass coherence checks (heap.tex §7) ----------------------

(defmethod component-validate ((s space))
  ;; Guard: shared-initialize runs before :vm lands; the full check happens
  ;; again at plan finalization when slots are populated.
  (when (and (slot-boundp s 'vm) (space-vm s))
    (when (and (eq (space-moving s) :concurrent-relocate)
               (not (eq (vm-location (space-vm s) :forwarding) :off-heap)))
      (error 'plan-incompatible :plan s
             :message "concurrent-relocate space needs off-heap forwarding")))
  (let ((constraints (space-constraints s)))
    (when (slot-boundp s 'allocator)
      (let ((a (space-allocator s)))
        (when (and (typep s 'immix-space)
                   a
                   (not (typep a 'immix-allocator)))
          (error 'plan-incompatible :plan s
                 :message "immix-space needs an immix-allocator"))
        (when (and (typep s 'mark-sweep-space)
                   a
                   (not (typep a 'free-list-allocator)))
          (error 'plan-incompatible :plan s
                 :message "mark-sweep-space needs a free-list allocator"))))
    ;; moving /= :none implies mixed-age = nil, unless hierarchical
    (when (and (not (eq (space-moving s) :none))
               (mixed-age constraints)
               (not (eq (space-policy s) :hierarchical)))
      (error 'plan-incompatible :plan s
             :message "moving spaces cannot be mixed-age"))
    s))

(declaim (inline space-base-address space-end-address))
(defun space-base-address (s) (ash (space-start-page s) +log-page-words+))
(defun space-end-address (s) (ash (+ (space-start-page s) (space-page-count s)) +log-page-words+))

(defmethod space-contains-p ((s space) address)
  (let ((start (space-base-address s)) (end (space-end-address s)))
    (and (>= address start) (< address end))))

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
              do (vm-heal-reference-slots vm address fwd)))))

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
;; superblock-space is defined in its own section below (heap.tex §6).

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
      ;; Range-clear: the mark stratum is heap-wide; other spaces (LOS,
      ;; sticky partners) own their marks and reclaim after this space.
      (s-clear-range mark start end))
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
    (let ((mark (vm-stratum vm :mark)))
      (when mark (s-clear-range mark (ix-start a) (ix-limit a))))
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
      ;; Clear marks only within this space's range: the mark stratum is
      ;; heap-wide and other spaces (notably sticky plans) own their marks.
      (s-clear-range mark (space-base-address s) (space-end-address s)))
    s))

;; ---- immortal-space ------------------------------------------------------

(defmethod space-reclaim ((s immortal-space) vm &key cycle-kind)
  (declare (ignore vm cycle-kind)) s)

;; ---- superblock-space (Claimore hierarchical space) ----------------------
;; Paper-v8 heap.tex §6: three reclamation primitives at three region
;; granularities.  Superblock: off-heap per-SB reference counts; superblock 0
;; holds the persistent root set and is never freed.  Metablock: per-SB
;; points-to matrices over which a bounded closure runs (search).  Block:
;; compaction via the off-heap forwarding table, run rarely.  Region sizes
;; are declared by the space (the paper's 4 KiB / 1 MiB / 256 MiB values are
;; the defaults), so the simulator can exercise the same hierarchy at small
;; scale.

(defconstant +escape-from-foreign+       1)
(defconstant +escape-to-foreign+         2)
(defconstant +escape-pointed-to-by-older+ 4)

(defclass superblock-space (space)
  ((sb-refcounts :reader sb-refcounts :initarg :sb-refcounts :initform nil)
   (block-words :reader sb-block-words :initarg :block-words
                :initform +g-block+)
   (blocks-per-metablock :reader sb-blocks-per-metablock
                         :initarg :blocks-per-metablock :initform 256)
   (metablocks-per-superblock :reader sb-mbs-per-superblock
                              :initarg :metablocks-per-superblock :initform 256)
   ;; per-SB metablock points-to matrices (heap.tex §6, strata.tex §5)
   (mb-matrices :accessor sb-mb-matrices :initform nil)
   ;; per-MB block points-to matrices (indexed by global metablock index)
   (block-matrices :accessor sb-block-matrices :initform nil)
   ;; preallocated closure scratch: root/reached bit-vectors per SB
   (mb-root-bits :accessor sb-mb-root-bits :initform nil)
   (reached-mbs :accessor sb-reached-mbs :initform nil)
   ;; SBs that must not be released wholesale this cycle
   (pinned :accessor sb-pinned :initform nil)
   ;; the block-granularity 3-bit escape stratum (registered on the VM)
   (escape :accessor sb-escape :initform nil))
  (:default-initargs :policy :hierarchical :moving :none)
  (:metaclass space-metaclass))

;; ---- region geometry -----------------------------------------------------

(declaim (inline sb-words-per-block sb-words-per-mb sb-words-per-superblock))
(defun sb-words-per-block (s) (sb-block-words s))
(defun sb-words-per-mb (s)
  (* (sb-block-words s) (sb-blocks-per-metablock s)))
(defun sb-words-per-superblock (s)
  (* (sb-words-per-mb s) (sb-mbs-per-superblock s)))

(defun sb-block-count (s)
  (floor (- (space-end-address s) (space-base-address s)) (sb-block-words s)))
(defun sb-mb-count (s)
  (ceiling (sb-block-count s) (sb-blocks-per-metablock s)))
(defun sb-count (s)
  (ceiling (sb-mb-count s) (sb-mbs-per-superblock s)))

(defun sb-index (s address)
  "Which superblock ADDRESS belongs to (superblock 0 is the first in the
  space's address range; it holds the persistent root set and is never freed)."
  (floor (- address (space-base-address s)) (sb-words-per-superblock s)))
(defun sb-block-index (s address)
  (floor (- address (space-base-address s)) (sb-block-words s)))
(defun sb-mb-index (s address)
  (floor (sb-block-index s address) (sb-blocks-per-metablock s)))
(defun sb-local-block (s block-index)
  (mod block-index (sb-blocks-per-metablock s)))
(defun sb-local-mb (s mb-index)
  (mod mb-index (sb-mbs-per-superblock s)))
(defun sb-block-base (s block-index)
  (+ (space-base-address s) (* block-index (sb-block-words s))))

(defmethod shared-initialize :after ((s superblock-space) slot-names &key)
  (declare (ignore slot-names))
  (let ((nsb (sb-count s))
        (nmbs (sb-mb-count s))
        (mps (sb-mbs-per-superblock s))
        (bpm (sb-blocks-per-metablock s)))
    (unless (sb-refcounts s)
      (setf (slot-value s 'sb-refcounts)
            (make-array nsb :element-type 'fixnum :initial-element 0)))
    (unless (sb-mb-matrices s)
      (setf (sb-mb-matrices s)
            (make-array nsb :initial-element nil))
      (dotimes (i nsb)
        (setf (aref (sb-mb-matrices s) i)
              (make-matrix-stratum (sb-words-per-mb s) mps)))
      (setf (sb-block-matrices s)
            (make-array nmbs :initial-element nil))
      (dotimes (i nmbs)
        (setf (aref (sb-block-matrices s) i)
              (make-matrix-stratum (sb-block-words s) bpm)))
      (setf (sb-mb-root-bits s)
            (make-array nsb :initial-element nil)
            (sb-reached-mbs s)
            (make-array nsb :initial-element nil)
            (sb-pinned s)
            (make-array nsb :element-type 'bit :initial-element 0))
      (dotimes (i nsb)
        (setf (aref (sb-mb-root-bits s) i)
              (make-array mps :element-type 'bit :initial-element 0)
              (aref (sb-reached-mbs s) i)
              (make-array mps :element-type 'bit :initial-element 0))))
    ;; The escape stratum is VM-registered; register once per VM.
    (let ((vm (space-vm s)))
      (when (and vm (not (vm-stratum vm :block-escape)))
        (setf (sb-escape s)
              (vm-register-stratum
               vm :block-escape
               (make-stratum :block-escape (sb-block-words s) :u4
                             (vm-heap-size vm))))))))

(defun superblock-trace-object (s vm ref tracer &key trace-kind)
  (declare (ignore trace-kind))
  (let ((addr (ref-strip-or-self vm ref)))
    (unless (vm-object-is-marked-p vm addr)
      (setf (vm-object-is-marked-p vm addr) t)
      (tracer-enqueue tracer addr))
    addr))

(defmethod space-trace-object ((s superblock-space) vm ref tracer &key trace-kind)
  (superblock-trace-object s vm ref tracer :trace-kind trace-kind))

(defmethod space-prepare ((s superblock-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-stratum vm :mark))
  s)

;; ---- escape bits (block-granularity stratum) -----------------------------

(defun sb-escape-value (s vm block-index)
  (let ((escape (or (sb-escape s) (vm-stratum vm :block-escape))))
    (if escape (s-get escape (sb-block-base s block-index)) 0)))
(defun (setf sb-escape-value) (bits s vm block-index)
  (let ((escape (or (sb-escape s) (vm-stratum vm :block-escape))))
    (when escape (s-set escape (sb-block-base s block-index) bits))
    bits))

;; ---- barrier maintenance of the hierarchy relations ----------------------
;; strata.tex §5.1: the write barrier sets M[block(src), block(dst)] on a
;; cross-region store; newgc.txt §3/§6: per-block direction bits, and the
;; pointed-to-by-older bit when the source metablock is older.

(defun superblock-note-write (s vm src new)
  "Maintain the hierarchy relations for a mature-space store SRC<-NEW
  (called from the RC write-barrier rule, which runs after publication)."
  (let* ((src-block (sb-block-index s src))
         (dst-block (sb-block-index s new))
         (src-mb (floor src-block (sb-blocks-per-metablock s)))
         (dst-mb (floor dst-block (sb-blocks-per-metablock s)))
         (src-sb (floor src-mb (sb-mbs-per-superblock s)))
         (dst-sb (floor dst-mb (sb-mbs-per-superblock s))))
    (when (/= src-sb dst-sb)
      ;; to-foreign on the source block, from-foreign on the target block
      (setf (sb-escape-value s vm src-block)
            (logior (sb-escape-value s vm src-block) +escape-to-foreign+)
            (sb-escape-value s vm dst-block)
            (logior (sb-escape-value s vm dst-block) +escape-from-foreign+)))
    (cond
      ((/= src-mb dst-mb)
       (matrix-set (aref (sb-mb-matrices s) src-sb)
                   (sb-local-mb s src-mb) (sb-local-mb s dst-mb)))
      ((/= src-block dst-block)
       (matrix-set (aref (sb-block-matrices s) src-mb)
                   (sb-local-block s src-block) (sb-local-block s dst-block))))
    (when (and (= src-sb dst-sb) (< src-mb dst-mb))
      (setf (sb-escape-value s vm dst-block)
            (logior (sb-escape-value s vm dst-block)
                    +escape-pointed-to-by-older+)))
    nil))

;; ---- reclamation: RC release -> search -> precise-trace sweep ------------

(defun superblock-pinned (s vm)
  "SBs that must survive RC release this cycle: superblock 0 (persistent root
  set) plus every SB containing a marked (live) object.  The precise trace is
  the authority; the count table only releases SBs the trace agrees are dead."
  (let ((pinned (sb-pinned s))
        (mark (vm-stratum vm :mark))
        (os (vm-object-start vm))
        (base (space-base-address s))
        (end (space-end-address s)))
    (fill pinned 0)
    (setf (sbit pinned 0) 1)
    (when (and mark os)
      (loop for address from base below end
            when (and (s-test-bit os address) (s-test-bit mark address))
              do (setf (sbit pinned (sb-index s address)) 1)))
    pinned))

(defun superblock-release-zero-count (s vm)
  "Stage 1 (cheapest, largest gain): a superblock whose count reached zero is
  released wholesale — every block returned to the free list, object identity
  forgotten.  Pinned superblocks (root set, live objects) are excluded."
  (let ((counts (sb-refcounts s))
        (pinned (superblock-pinned s vm))
        (a (space-allocator s)))
    (dotimes (i (sb-count s))
      (when (and (plusp i) (zerop (aref counts i)) (zerop (sbit pinned i)))
        (dotimes (b (sb-blocks-per-metablock s))
          (let ((bi (+ (* i (sb-mbs-per-superblock s)
                          (sb-blocks-per-metablock s))
                       b)))
            (when (< bi (sb-block-count s))
              (hierarchical-free-block a vm bi)))))))
  s)

(defun superblock-root-mbs (s vm)
  "Seed bits per SB: metablocks containing root references or nursery-edge
  targets.  A superset of the trace seeds keeps the closure a valid bound."
  (let* ((plan (vm-plan vm))
         (nursery (and plan (plan-nursery plan)))
         (nsb (sb-count s)))
    (dotimes (i nsb) (fill (aref (sb-mb-root-bits s) i) 0))
    (flet ((seed (ref)
             (when (and (plusp ref) (space-contains-p s ref))
               (let* ((mi (sb-mb-index s ref))
                      (sb (floor mi (sb-mbs-per-superblock s))))
                 (when (< sb nsb)
                   (setf (sbit (aref (sb-mb-root-bits s) sb)
                               (sb-local-mb s mi)) 1))))))
      (let ((roots (vm-root-vector vm)))
        (dotimes (i (length roots)) (seed (aref roots i))))
      (when (and nursery (vm-object-start vm))
        (let ((os (vm-object-start vm)))
          (loop for address from (space-base-address nursery)
                below (space-end-address nursery)
                when (s-test-bit os address)
                  do (superblock-seed-nursery-object s vm address)))))
    s))

(defun superblock-seed-nursery-object (s vm address)
  "Seed the per-SB metablock root bits with every mature reference held by
  the nursery object at ADDRESS.  Top-level: no host closure per object."
  (let ((slots (vm-reference-slots vm address)))
    (flet ((seed (ref)
             (when (and (plusp ref) (space-contains-p s ref))
               (let* ((mi (sb-mb-index s ref))
                      (sb (floor mi (sb-mbs-per-superblock s))))
                 (when (< sb (sb-count s))
                   (setf (sbit (aref (sb-mb-root-bits s) sb)
                               (sb-local-mb s mi)) 1))))))
      (if slots
          (loop for i across slots
                do (seed (vm-object-reference vm address i)))
          (dotimes (i (vm-object-reference-count vm address))
            (seed (vm-object-reference vm address i))))))
  address)

(defun superblock-search (s vm)
  "Stage 2: metablock-granularity search.  For each live superblock, close
  the MB points-to matrix from the seed bits.  An unreached metablock that a
  from-foreign escape bit flags as the target of a foreign-superblock edge is
  added to the seeds and the closure re-run (heap.tex: trusted only where the
  RC table and escape bits rule out incoming edges from reached regions).
  The reached sets are retained for the post-collection sanity check: the
  precise trace's marked set must lie within them."
  (let* ((nsb (sb-count s))
         (mps (sb-mbs-per-superblock s))
         (a (space-allocator s)))
    (superblock-root-mbs s vm)
    (dotimes (sb nsb)
      (let ((reached (aref (sb-reached-mbs s) sb))
            (roots (aref (sb-mb-root-bits s) sb)))
        (when (hierarchical-sb-in-use-p a sb)
          ;; iterate to fixpoint: closure, then fold in from-foreign targets
          (loop repeat mps
                for added-p = nil
                do (let ((closure
                           (matrix-closure
                            (aref (sb-mb-matrices s) sb) roots)))
                     (replace reached closure))
                   (dotimes (mi (min mps (sb-mb-count s)))
                     (when (and (= (floor mi mps) sb)  ; local to this SB
                                (zerop (sbit reached (sb-local-mb s mi))))
                       ;; unreached: keep only if a from-foreign block exists
                       (let ((foreign-p nil))
                         (dotimes (b (sb-blocks-per-metablock s))
                           (let ((bi (+ (* mi (sb-blocks-per-metablock s))
                                        b)))
                             (when (and (< bi (sb-block-count s))
                                        (logtest (sb-escape-value s vm bi)
                                                 +escape-from-foreign+))
                               (setf foreign-p t) (return))))
                         (when foreign-p
                           (setf (sbit roots (sb-local-mb s mi)) 1
                                 added-p t)))))
                unless added-p return nil))))
    s))

(defun superblock-sweep (s vm)
  "Stage 3: after the precise trace (marks set), free every block in a live
  superblock with zero marked objects.  Superblock 0 is the persistent root
  set and is never swept.  This block-level sweep is the periodic full-trace
  backup that reclaims cycle garbage inside a still-counted superblock."
  (let* ((a (space-allocator s))
         (mark (vm-stratum vm :mark))
         (os (vm-object-start vm))
         (nsb (sb-count s))
         (bpm (sb-blocks-per-metablock s))
         (mps (sb-mbs-per-superblock s)))
    (when (and mark os)
      (dotimes (sb nsb)
        (unless (zerop sb)
          (dotimes (m mps)
            (dotimes (b bpm)
              (let ((bi (+ (* sb mps bpm) (* m bpm) b)))
                (when (and (< bi (sb-block-count s))
                           (hierarchical-block-in-use-p a bi))
                  (let ((live-p nil))
                    (loop for address from (sb-block-base s bi)
                          below (+ (sb-block-base s bi) (sb-block-words s))
                          when (and (s-test-bit os address)
                                    (s-test-bit mark address))
                            do (setf live-p t) (return))
                    (unless live-p
                      (hierarchical-free-block a vm bi)))))))))))
  s)

(defun superblock-compact (s vm)
  "Block compaction (heap.tex §6, the expensive last resort): move the live
  objects of the most fragmented in-use block into a fresh block, recording
  old->new in the off-heap forwarding table, then heal every reference
  (roots, nursery slots, mature slots) before releasing the source block."
  (let* ((a (space-allocator s))
         (mark (vm-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm)))
    (when (and mark os (hierarchical-fresh-available-p a))
      (let ((source nil) (source-frag 0))
        (dotimes (bi (sb-block-count s))
          (when (and (hierarchical-block-in-use-p a bi)
                     (plusp (sb-index s (sb-block-base s bi)))) ; SB0 pinned
            (let* ((base (sb-block-base s bi))
                   (limit (+ base (sb-block-words s)))
                   (cursor (hierarchical-block-cursor a bi))
                   (live-words 0))
              (loop for address from base below limit
                    when (and (s-test-bit os address) (s-test-bit mark address))
                      do (incf live-words (vm-object-total-words vm address)))
              (let ((frag (- (- cursor base) live-words)))
                (when (and (plusp live-words) (> frag source-frag))
                  (setf source bi source-frag frag))))))
        (when (and source (>= source-frag (ash (sb-block-words s) -1)))
          ;; copy survivors into a fresh destination block
          (let* ((dest (hierarchical-acquire-block a))
                 (dcur (sb-block-base s dest))
                 (dlim (+ dcur (sb-block-words s))))
            (loop for address from (sb-block-base s source)
                  below (+ (sb-block-base s source) (sb-block-words s))
                  when (and (s-test-bit os address) (s-test-bit mark address))
                    do (let ((words (vm-object-total-words vm address)))
                         (when (> (+ dcur words) dlim)
                           (error 'clamsara-error
                                  :message "superblock compaction overflow"))
                         (vm-object-copy vm address dcur)
                         (setf (vm-object-is-marked-p vm dcur) t
                               (aref fwd address) dcur)
                         (incf dcur words)))
            (setf (hierarchical-block-cursor a dest) dcur)
            ;; heal all live references through the forwarding table
            (vm-scan-roots vm (vm-plan vm) #'heal-forwarded-root)
            (let ((plan (vm-plan vm)))
              (when (and plan (plan-nursery plan))
                (let ((nursery (plan-nursery plan)))
                  (loop for address from (space-base-address nursery)
                        below (space-end-address nursery)
                        when (s-test-bit os address)
                          do (vm-heal-reference-slots vm address fwd)))))
            (dotimes (bi (sb-block-count s))
              (when (and (hierarchical-block-in-use-p a bi) (/= bi dest))
                (loop for address from (sb-block-base s bi)
                      below (+ (sb-block-base s bi) (sb-block-words s))
                      when (s-test-bit os address)
                        do (vm-heal-reference-slots vm address fwd))))
            (hierarchical-free-block a vm source)
            (fill fwd 0))))))
  s)

(defmethod space-reclaim ((s superblock-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (superblock-release-zero-count s vm)
  (superblock-search s vm)
  (superblock-sweep s vm)
  s)

(defmethod space-occupancy ((s superblock-space))
  (let ((a (space-allocator s)))
    (if (typep a 'hierarchical-allocator)
        (hierarchical-occupied-words a)
        0)))

;; ---- hierarchical allocator (Claimore superblock hierarchy) --------------
;; Block-granular bump with a recycled-block list.  A released superblock (or
;; swept block) returns its blocks to the free list, so released memory is
;; reused rather than left as a hole.  Objects larger than one block are
;; carved from the never-used region as contiguous block runs.

(defclass hierarchical-allocator ()
  ((vm :initarg :vm :accessor ha-vm)
   (space :initarg :space :accessor ha-space)
   (start :initarg :start :accessor ha-start)
   (limit :initarg :limit :accessor ha-limit)
   (block-words :accessor ha-block-words)
   (block-count :accessor ha-block-count)
   ;; per-block bump cursor; -1 means the block is on the free list
   (cursors :accessor ha-cursors)
   (free-blocks :accessor ha-free-blocks)   ; fixnum vector + fill pointer
   (next-fresh :accessor ha-next-fresh :initform 0)
   (current :accessor ha-current :initform nil)))

(defmethod shared-initialize :after ((a hierarchical-allocator) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp a 'block-words)
    (let* ((s (ha-space a))
           (count (floor (- (ha-limit a) (ha-start a)) (sb-block-words s))))
      (setf (ha-block-words a) (sb-block-words s)
            (ha-block-count a) count
            (ha-cursors a) (make-array count :element-type 'fixnum
                                       :initial-element -1)
            (ha-free-blocks a) (make-array count :element-type 'fixnum
                                           :initial-element 0
                                           :fill-pointer 0)))))

(declaim (inline hierarchical-block-in-use-p hierarchical-block-cursor))
(defun hierarchical-block-in-use-p (a block-index)
  (and (< block-index (ha-block-count a))
       (>= (aref (ha-cursors a) block-index) 0)))
(defun hierarchical-block-cursor (a block-index)
  (aref (ha-cursors a) block-index))
(defun (setf hierarchical-block-cursor) (cursor a block-index)
  (setf (aref (ha-cursors a) block-index) cursor))
(defun hierarchical-fresh-available-p (a)
  (< (ha-next-fresh a) (ha-block-count a)))

(defun hierarchical-block-base (a block-index)
  (+ (ha-start a) (* block-index (ha-block-words a))))

(defun hierarchical-acquire-block (a)
  "Pop a recycled block, else carve the next never-used block."
  (let ((free (ha-free-blocks a)))
    (cond
      ((plusp (fill-pointer free))
       (decf (fill-pointer free))
       (aref free (fill-pointer free)))
      ((hierarchical-fresh-available-p a)
       (prog1 (ha-next-fresh a) (incf (ha-next-fresh a)))))))

(defun hierarchical-free-block (a vm block-index)
  "Return an in-use block to the free list and forget its object identity."
  (when (hierarchical-block-in-use-p a block-index)
    (vm-clear-metadata-range
     vm (hierarchical-block-base a block-index)
     (+ (hierarchical-block-base a block-index) (ha-block-words a)))
    (setf (aref (ha-cursors a) block-index) -1)
    (unless (vector-push block-index (ha-free-blocks a))
      (error 'heap-exhausted :requested-size 1 :space :block-free-list))
    (when (eql (ha-current a) block-index)
      (setf (ha-current a) nil)))
  block-index)

(defun hierarchical-sb-in-use-p (a sb)
  (let* ((s (ha-space a))
         (bpm (sb-blocks-per-metablock s))
         (mps (sb-mbs-per-superblock s)))
    (loop for m below mps
          thereis (loop for b below bpm
                        for bi = (+ (* sb mps bpm) (* m bpm) b)
                        when (and (< bi (ha-block-count a))
                                  (hierarchical-block-in-use-p a bi))
                          return t))))

(defun hierarchical-bump (a block-index size)
  (let ((base (hierarchical-block-base a block-index))
        (cursor (aref (ha-cursors a) block-index)))
    (when (and (>= cursor 0)
               (<= (+ cursor size) (+ base (ha-block-words a))))
      (setf (aref (ha-cursors a) block-index) (+ cursor size))
      cursor)))

(defmethod alloc ((a hierarchical-allocator) size &key &allow-other-keys)
  (if (<= size (ha-block-words a))
      (or (and (ha-current a) (hierarchical-bump a (ha-current a) size))
          (let ((block (hierarchical-acquire-block a)))
            (when block
              (setf (aref (ha-cursors a) block)
                    (hierarchical-block-base a block)
                    (ha-current a) block)
              (hierarchical-bump a block size))))
      ;; Large object: carve contiguous never-used blocks (no recycled runs).
      (let ((pages (ceiling size (ha-block-words a))))
        (when (<= (+ (ha-next-fresh a) pages) (ha-block-count a))
          (let ((base (hierarchical-block-base a (ha-next-fresh a)))
                (remaining size))
            (dotimes (k pages)
              (let ((bi (+ (ha-next-fresh a) k)))
                (setf (aref (ha-cursors a) bi)
                      (+ (hierarchical-block-base a bi)
                         (if (< remaining (ha-block-words a))
                             remaining
                             (ha-block-words a))))
                (decf remaining (ha-block-words a))))
            (incf (ha-next-fresh a) pages)
            base)))))

(defmethod free ((a hierarchical-allocator) addr size) (declare (ignore addr size)) nil)
(defmethod coalesce ((a hierarchical-allocator)) nil)

(defmethod allocator-reset ((a hierarchical-allocator))
  (vm-clear-metadata-range (ha-vm a) (ha-start a) (ha-limit a))
  (fill (ha-cursors a) -1)
  (setf (fill-pointer (ha-free-blocks a)) 0
        (ha-next-fresh a) 0
        (ha-current a) nil))

(defun hierarchical-occupied-words (a)
  (loop for bi below (ha-block-count a)
        when (hierarchical-block-in-use-p a bi)
          sum (- (aref (ha-cursors a) bi)
                 (hierarchical-block-base a bi))))
