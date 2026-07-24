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
(defmethod allocator-reset ((a bump-allocator)) (setf (ba-cursor a) (ba-start a)))

;; ---- cons allocator (2-word bump) -----------------------------------------

(defclass cons-allocator (bump-allocator) ())

;; ---- monotone allocator (immortal, never releases) -----------------------

(defclass monotone-allocator (bump-allocator) ())

;; ---- free-list allocator (segregated fit, word granularity) -------------

(defclass free-list-allocator ()
  ((start :initarg :start :accessor fl-start)
   (limit :initarg :limit :accessor fl-limit)
   (free :accessor free-runs :initform nil)        ; (addr . len) sorted by addr
   (vm :initarg :vm :accessor fl-vm)
   (space :initarg :space :accessor fl-space)))

(defmethod shared-initialize :after ((a free-list-allocator) slot-names &key)
  (declare (ignore slot-names))
  (when (and (slot-boundp a 'start) (slot-boundp a 'limit))
    (setf (free-runs a) (list (cons (fl-start a) (- (fl-limit a) (fl-start a)))))))

(defmethod alloc ((a free-list-allocator) size &key &allow-other-keys)
  (loop for cell on (free-runs a)
        for run = (car cell)
        for addr = (car run)
        for len = (cdr run)
        when (>= len size)
        do (if (= len size)
               (setf (free-runs a) (delete run (free-runs a)))
               (progn (incf (car run) size)
                      (decf (cdr run) size)))
           (return addr)))

(defmethod free ((a free-list-allocator) addr size)
  (let* ((new (cons addr size))
         (merged (merge 'list (list new) (free-runs a)
                        (lambda (x y) (< (car x) (car y))))))
    (setf (free-runs a)
          (loop with result = nil
                for (s . l) in merged
                if (null result) do (push (cons s l) result)
                else if (= s (+ (car (first result)) (cdr (first result))))
                do (incf (cdr (first result)) l)
                else do (push (cons s l) result)
                finally (return (nreverse result)))))
  nil)

(defmethod coalesce ((a free-list-allocator)) nil) ; free already coalesces
(defmethod allocator-reset ((a free-list-allocator)) nil)

;; ---- large-object allocator (whole pages) --------------------------------

(defclass los-allocator ()
  ((page-resource :initarg :page-resource :accessor los-pr)
   (vm :initarg :vm :accessor los-vm)
   (space :initarg :space :accessor los-space)
   (allocated :accessor los-allocated :initform (make-hash-table :test 'eql))))

(defmethod alloc ((a los-allocator) size &key &allow-other-keys)
  (let* ((pages (ceiling size +page-words+))
         (p (page-resource-get (los-pr a) pages)))
    (when p
      (setf (gethash (ash p +log-page-words+) (los-allocated a)) pages)
      (ash p +log-page-words+))))
(defmethod free ((a los-allocator) addr size)
  (declare (ignore size))
  (let ((pages (gethash addr (los-allocated a))))
    (when pages (page-resource-release (los-pr a) (address-page addr) pages)
      (remhash addr (los-allocated a)))))
(defmethod allocator-reset ((a los-allocator)) nil)

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
   (blocks :accessor ix-blocks :initform nil)
   (current :accessor ix-current :initform nil)
   (next-base :accessor ix-next-base :initform 0)))

(defmethod shared-initialize :after ((a immix-allocator) slot-names &key)
  (declare (ignore slot-names))
  (when (slot-boundp a 'start)
    (setf (ix-next-base a) (ix-start a))))

(defun ix-block-end (b block-words) (+ (immix-block-base b) block-words))

(defmethod alloc ((a immix-allocator) size &key &allow-other-keys)
  (flet ((try-block (b)
           (let ((c (immix-block-cursor b)))
             (when (<= (+ c size) (ix-block-end b (ix-block-words a)))
               (setf (immix-block-cursor b) (+ c size))
               c))))
    (or (and (ix-current a) (try-block (ix-current a)))
        (loop for b in (ix-blocks a) thereis (try-block b))
        (let ((b (ix-new-block a))) (when b (try-block b))))))

(defmethod ix-new-block ((a immix-allocator))
  "Carve the next block from the space's word range."
  (when (<= (+ (ix-next-base a) (ix-block-words a)) (ix-limit a))
    (let ((b (make-immix-block :base (ix-next-base a)
                              :cursor (ix-next-base a) :live 0)))
      (incf (ix-next-base a) (ix-block-words a))
      (push b (ix-blocks a))
      (setf (ix-current a) b)
      b)))

(defmethod free ((a immix-allocator) addr size) (declare (ignore addr size)) nil)
(defmethod coalesce ((a immix-allocator)) nil)
(defmethod allocator-reset ((a immix-allocator))
  ;; empty the allocator: blocks discarded, carving restarts at the space base.
  (setf (ix-blocks a) nil (ix-current a) nil (ix-next-base a) (ix-start a)))

(defun immix-block-live-count (a vm b)
  "Number of marked words in block B (mark stratum popcount over the block)."
  (let ((mark (vm-stratum vm :mark)))
    (if mark
        (s-popcount mark (cons (immix-block-base b)
                               (+ (immix-block-base b) (ix-block-words a))))
        0)))

(defun immix-defrag (s vm)
  "Opportunistic compaction: copy live objects into fresh compacted blocks,
  updating references via the off-heap forwarding table, then recycle sources."
  (let* ((a (space-allocator s))
         (mark (vm-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm)))
    (when (and mark os (ix-blocks a))
      (clrhash fwd)
      (let ((dst-block (ix-new-block a)))
        (when dst-block
          (dolist (src (ix-blocks a))
            (when (plusp (immix-block-live-count a vm src))
              (s-for-set-cells os
                (cons (immix-block-base src)
                      (+ (immix-block-base src) (ix-block-words a)))
                (lambda (addr)
                  (when (s-test-bit mark addr)
                    (let ((n (vm-object-total-words vm addr)))
                      (let ((dst (alloc a n)))
                        (when (and dst (not (eql dst addr)))
                          (vm-object-copy vm addr dst)
                          (setf (gethash addr fwd) dst))))))))
            (setf (immix-block-cursor src) (immix-block-base src)))
          (immix-heal-references s vm fwd)
          (setf (ix-current a) dst-block))))))

(defun immix-heal-references (s vm fwd)
  "Update root + slot references that point at forwarded objects."
  (when (zerop (hash-table-count fwd)) (return-from immix-heal-references))
  (labels ((translate (r) (let ((a (ref-strip-or-self vm r)))
                            (or (gethash a fwd) r))))
    (let ((roots (vm-root-vector vm)))
      (dotimes (i (length roots))
        (let ((r (aref roots i)))
          (when (vm-reference-p vm r) (setf (aref roots i) (translate r))))))
    (dolist (b (ix-blocks (space-allocator s)))
      (s-for-set-cells (vm-object-start vm)
        (cons (immix-block-base b) (+ (immix-block-base b) (ix-block-words (space-allocator s))))
        (lambda (addr)
          (dotimes (k (vm-object-reference-count vm addr))
            (let ((c (vm-object-reference vm addr k)))
              (when (vm-reference-p vm c)
                (let ((nw (translate c)))
                  (unless (eql nw c)
                    (setf (vm-object-reference vm addr k) nw)))))))))))

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
              (los-space              (make-instance 'free-list-allocator :start start :limit end :vm vm :space space))
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
      (s-for-set-cells os (cons start end)
        (lambda (addr)
          (unless (s-test-bit mark addr)
            (free a addr (vm-object-total-words vm addr)))))
      (s-clear mark))
    s))

(defmethod space-occupancy ((s mark-sweep-space))
  (let ((a (space-allocator s)))
    (if (typep a 'free-list-allocator)
        (- (fl-limit a) (fl-start a)
           (loop for (nil . l) in (free-runs a) sum l))
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
    (when (and (ix-blocks a) (vm-stratum vm :mark))
      (dolist (b (ix-blocks a))
        (let ((live (immix-block-live-count a vm b)))
          (setf (immix-block-live b) live)
          (when (zerop live)
            ;; fully dead: recycle the whole block for reuse
            (setf (immix-block-cursor b) (immix-block-base b)))))
      (setf (ix-current a) (first (ix-blocks a))))
    (when (eq cycle-kind :major)
      (immix-defrag s vm))
    (s-clear (vm-stratum vm :mark))
    s))

(defmethod space-occupancy ((s immix-space))
  (let ((a (space-allocator s)))
    (if (typep a 'immix-allocator)
        (loop for b in (ix-blocks a) sum (- (immix-block-cursor b) (immix-block-base b)))
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
      (s-for-set-cells os (cons (space-base-address s) (space-end-address s))
        (lambda (addr)
          (unless (s-test-bit mark addr)
            (free a addr (vm-object-total-words vm addr))))
      (s-clear mark)))
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
