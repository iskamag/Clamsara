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
   (default-space-p :initarg :default-space :initform nil :accessor space-default-p)
   ;; Filled by the boot compiler.  These slots hold effective protocol
   ;; functions for this exact space/allocator pair; collection never asks the
   ;; generic function dispatcher to rediscover them.
   (collection-trace :accessor space-collection-trace :initform nil)
   (collection-prepare :accessor space-collection-prepare :initform nil)
   (collection-release :accessor space-collection-release :initform nil)
   (collection-reclaim :accessor space-collection-reclaim :initform nil)
   (collection-contains :accessor space-collection-contains :initform nil)
   (collection-occupancy :accessor space-collection-occupancy :initform nil)
   (collection-alloc :accessor space-collection-alloc :initform nil)
   (collection-free :accessor space-collection-free :initform nil)
   (collection-reset :accessor space-collection-reset :initform nil))
  (:metaclass space-metaclass))

(defun space-p (object)
  "True when OBJECT is a Clamsara space instance."
  (typep object 'space))

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
    (unless (member (scope constraints) '(:global :thread :request))
      (error 'plan-incompatible :plan s
             :message (format nil "invalid space scope ~a" (scope constraints))))
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

(defgeneric space-trace-object (space vm ref tracer trace-kind)
  (:method ((s space) vm ref tracer trace-kind)
    (declare (ignore tracer trace-kind))
    ref))
(defgeneric space-prepare (space vm cycle-kind)
  (:method ((s space) vm cycle-kind) (declare (ignore vm cycle-kind)) s))
(defgeneric space-release (space vm cycle-kind)
  (:method ((s space) vm cycle-kind) (declare (ignore vm cycle-kind)) s))
(defgeneric space-reclaim (space vm cycle-kind)
  (:method ((s space) vm cycle-kind) (declare (ignore vm cycle-kind)) s))
(defgeneric space-occupancy (space)
  (:method ((s space)) 0))

;; ---- allocator protocol --------------------------------------------------

(defgeneric alloc (allocator size))
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
   (space :initarg :space :accessor ba-space))
  (:metaclass allocator-metaclass))

(defmethod shared-initialize :after ((a bump-allocator) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp a 'cursor) (setf (ba-cursor a) (ba-start a))))

(defmethod component-validate ((a bump-allocator))
  (unless (and (integerp (ba-start a)) (integerp (ba-limit a))
               (<= 0 (ba-start a)) (<= (ba-start a) (ba-limit a))
               (<= (ba-start a) (ba-cursor a))
               (<= (ba-cursor a) (ba-limit a)))
    (error 'plan-incompatible :plan a
           :message "bump allocator has an invalid cursor range"))
  a)

(defmethod alloc ((a bump-allocator) size)
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

(defclass cons-allocator (bump-allocator) ()
  (:metaclass allocator-metaclass))

;; ---- monotone allocator (immortal, never releases) -----------------------

(defclass monotone-allocator (bump-allocator) ()
  (:metaclass allocator-metaclass))

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
   (space :initarg :space :accessor fl-space))
  (:metaclass allocator-metaclass))

(defmethod component-validate ((a free-list-allocator))
  (unless (and (integerp (fl-start a)) (integerp (fl-limit a))
               (<= 0 (fl-start a)) (<= (fl-start a) (fl-limit a)))
    (error 'plan-incompatible :plan a
           :message "free-list allocator has an invalid range"))
  a)

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

(defmethod alloc ((a free-list-allocator) size)
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

(defstruct (los-hot-arena
            (:constructor %make-los-hot-arena
                (bitmap total-pages first-page extents base-page)))
  "Boot-owned raw LOS state.  It is deliberately a structure rather than a
CLOS component: the measured allocator body touches only arrays and fixnums;
component dispatch and slot extraction stay in the outer ALLOC method."
  (bitmap #* :type simple-bit-vector)
  (total-pages 0 :type fixnum)
  (first-page 0 :type fixnum)
  (extents #() :type (simple-array fixnum (*)))
  (base-page 0 :type fixnum))

(defclass los-allocator ()
  ((page-resource :initarg :page-resource :accessor los-pr)
   (vm :initarg :vm :accessor los-vm)
   (space :initarg :space :accessor los-space)
   (base-page :initarg :base-page :accessor los-base-page :initform 0)
   ;; Dense page-indexed extent storage is retained as the diagnostic view.
   ;; HOT-ARENA holds this exact same vector plus raw bitmap geometry.
   (extents :accessor los-extents :initform nil)
   (hot-arena :reader los-hot-arena :initform nil))
  (:metaclass allocator-metaclass))

(defmethod shared-initialize :after ((a los-allocator) slot-names &key)
  (declare (ignore slot-names))
  (when (and (slot-boundp a 'page-resource) (los-pr a))
    (let* ((pr (los-pr a))
           (extents (make-array (pr-total-pages pr)
                                :element-type 'fixnum :initial-element 0)))
      (setf (slot-value a 'extents) extents
            (slot-value a 'hot-arena)
            (%make-los-hot-arena
             (pr-bitmap pr) (pr-total-pages pr) (pr-first-page pr)
             extents (los-base-page a))))))

(defmethod component-validate ((a los-allocator))
  (let ((arena (los-hot-arena a)))
    (unless (and (typep (los-pr a) 'bitmap-page-resource)
                 (los-vm a) (los-space a) arena
                 (eq (los-hot-arena-extents arena) (los-extents a))
                 (= (length (los-extents a)) (pr-total-pages (los-pr a))))
      (error 'plan-incompatible :plan a
             :message "large-object allocator is not wired to one bitmap arena, VM, and space")))
  a)

(declaim (inline %los-alloc %los-free %los-reset))
(defun %los-alloc (arena size)
  "Allocate SIZE words in raw boot arena ARENA and return an address or NIL."
  (declare (type los-hot-arena arena) (type fixnum size)
           (optimize (speed 3) (safety 0)))
  (let* ((pages (ceiling size +page-words+))
         (p (%bitmap-pages-get
             (los-hot-arena-bitmap arena)
             (los-hot-arena-total-pages arena)
             (los-hot-arena-first-page arena) pages)))
    (when p
      (setf (aref (los-hot-arena-extents arena) p) pages)
      (ash (+ p (los-hot-arena-base-page arena)) +log-page-words+))))

(defun %los-free (arena addr)
  "Release only the exact recorded run beginning at page-aligned ADDR."
  (declare (type los-hot-arena arena) (type fixnum addr)
           (optimize (speed 3) (safety 0)))
  (let* ((extents (los-hot-arena-extents arena))
         (rel (- (ash addr (- +log-page-words+))
                 (los-hot-arena-base-page arena)))
         (pages (and (>= rel 0) (< rel (length extents))
                     (aref extents rel))))
    (when (plusp pages)
      (setf (aref extents rel) 0)
      (%bitmap-pages-release (los-hot-arena-bitmap arena) rel pages))))

(defun %los-reset (arena)
  "Release every exact run in raw boot arena ARENA."
  (declare (type los-hot-arena arena) (optimize (speed 3) (safety 0)))
  (let ((extents (los-hot-arena-extents arena))
        (bitmap (los-hot-arena-bitmap arena)))
    (loop for rel fixnum below (length extents)
          for pages fixnum = (aref extents rel)
          when (plusp pages)
            do (setf (aref extents rel) 0)
               (%bitmap-pages-release bitmap rel pages)))
  arena)

(defmethod alloc ((a los-allocator) size)
  (%los-alloc (slot-value a 'hot-arena) size))
(defmethod free ((a los-allocator) addr size)
  (declare (ignore size))
  (%los-free (slot-value a 'hot-arena) addr))
(defmethod allocator-reset ((a los-allocator))
  (%los-reset (slot-value a 'hot-arena))
  a)

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
   (next-base :accessor ix-next-base :initform 0)
   ;; Medium-object spans: span-root[i] = the root block index of the
   ;; contiguous run block i belongs to, or -1.  Span blocks are reclaimed
   ;; atomically (only when the root object dies); the block-level sweep
   ;; must never recycle a span block while its root object is live.
   (span-root :accessor ix-span-root :initform nil)
   ;; preallocated per-block live counts (the sweep's two-pass span logic)
   (block-live :accessor ix-block-live :initform nil))
  (:metaclass allocator-metaclass))

(defmethod component-validate ((a immix-allocator))
  (unless (and (integerp (ix-start a)) (integerp (ix-limit a))
               (<= 0 (ix-start a)) (<= (ix-start a) (ix-limit a))
               (plusp (ix-block-words a)))
    (error 'plan-incompatible :plan a
           :message "Immix allocator has an invalid range or block size"))
  a)

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
            (ix-next-base a) (ix-start a)
            (ix-span-root a)
            (make-array count :element-type 'fixnum
                        :initial-element -1)
            (ix-block-live a)
            (make-array count :element-type 'fixnum
                        :initial-element 0)))))

(defmacro do-immix-blocks ((block allocator &optional result) &body body)
  `(loop for %block-index fixnum below (ix-block-count ,allocator)
         for ,block = (aref (ix-blocks ,allocator) %block-index)
         do (progn ,@body)
         finally (return ,result)))

(defun ix-first-block (a)
  (when (plusp (ix-block-count a))
    (aref (ix-blocks a) 0)))

(defun ix-block-end (b block-words) (+ (immix-block-base b) block-words))

(defmethod alloc ((a immix-allocator) size)
  ;; Medium objects (heap.tex §2: below the LOS threshold but above one
  ;; block) get a contiguous multi-block run carved from the never-used
  ;; region; the span is tracked so the block-level sweep reclaims it
  ;; atomically, never block-by-block while the root object is live.
  (if (> size (ix-block-words a))
      (let ((pages (ceiling size (ix-block-words a))))
        (when (<= (+ (ix-next-base a) (* pages (ix-block-words a)))
                  (ix-limit a))
          (let ((base (ix-next-base a))
                (first-block (ix-block-count a))
                (remaining size))
            (dotimes (k pages)
              (let ((bi (+ (ix-block-count a) k)))
                (when (< bi (length (ix-blocks a)))
                  (let ((b (aref (ix-blocks a) bi)))
                    (setf (immix-block-cursor b)
                          (+ (immix-block-base b)
                             (min remaining (ix-block-words a))))
                    (decf remaining (ix-block-words a)))
                  (setf (aref (ix-span-root a) bi) first-block))))
            (incf (ix-block-count a) pages)
            (incf (ix-next-base a) (* pages (ix-block-words a)))
            (setf (ix-current a) (aref (ix-blocks a) (1- (ix-block-count a))))
            base)))
      (flet ((try-block (b)
               (let ((c (immix-block-cursor b)))
                 (when (<= (+ c size) (ix-block-end b (ix-block-words a)))
                   (setf (immix-block-cursor b) (+ c size))
                   c))))
        (or (and (ix-current a)
                 (minusp (aref (ix-span-root a)
                               (floor (- (immix-block-base (ix-current a))
                                         (ix-start a))
                                      (ix-block-words a))))
                 (try-block (ix-current a)))
            (loop for i below (ix-block-count a)
                  for b = (aref (ix-blocks a) i)
                  ;; span runs are EXCLUSIVE: a medium-object span's blocks
                  ;; are reclaimed atomically, so small objects never share
                  ;; a span block (its tail may look free but dies with the
                  ;; root object).
                  thereis (and (minusp (aref (ix-span-root a) i))
                               (try-block b)))
            (let ((b (ix-new-block a))) (when b (try-block b)))))))

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
        (ix-next-base a) (ix-start a))
  (when (ix-span-root a)
    (fill (ix-span-root a) -1)))

(defun immix-block-live-count (a vm b)
  "Number of marked object starts in block B."
  (let ((mark (vm-direct-stratum vm :mark)))
    (if mark
        (loop for address from (immix-block-base b)
              below (+ (immix-block-base b) (ix-block-words a))
              count (s-test-bit mark address))
        0)))

(defun immix-forget-dead-objects (a vm b)
  "Clear object-start and per-object metadata for dead objects in B.
Line reuse is a separate allocator concern; stale object identity is never
retained merely because another object keeps the block live."
  (let ((mark (vm-direct-stratum vm :mark))
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
         (mark (vm-direct-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm)))
    (when (and mark os
               (plusp (ix-block-count a))
               (< (ix-block-count a) (length (ix-blocks a))))
      (let ((source nil))
        ;; A source is fragmented iff its live payload occupies fewer words
        ;; than its bump extent. Fully-live blocks gain nothing from moving.
        ;; Span (multi-block) objects are never defrag sources: their live
        ;; set cannot fit one destination block.
        (loop for i below (ix-block-count a)
              for block = (aref (ix-blocks a) i)
              for used = (- (immix-block-cursor block)
                            (immix-block-base block))
              when (and (plusp used)
                        (minusp (aref (ix-span-root a) i)))
              do (let ((live-words 0))
                   (loop for address from (immix-block-base block)
                         below (+ (immix-block-base block)
                                  (ix-block-words a))
                         when (and (s-test-bit os address)
                                   (s-test-bit mark address))
                           do (incf live-words
                                    (vm-direct-object-total-words vm address)))
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
                    do (let ((words (vm-direct-object-total-words vm address)))
                         (when (> (+ cursor words) limit)
                           (error 'clamsara-error
                                  :message
                                  "Immix defrag live set exceeds one block"))
                         (let ((destination-address cursor))
                           (incf cursor words)
                           (vm-direct-object-copy
                            vm address destination-address)
                           (vm-direct-set-object-marked-p vm destination-address t)
                           (setf (aref fwd address) destination-address))))
            (setf (immix-block-cursor destination) cursor)
            (immix-heal-references s vm fwd)
            ;; Forwarding is a grace-period resource.  The source cannot be
            ;; forgotten or reused until every root and slot has observed the
            ;; correction.
            (vm-direct-memory-fence vm)
            (vm-clear-metadata-range
             vm (immix-block-base source)
             (+ (immix-block-base source) (ix-block-words a)))
            (setf (immix-block-cursor source) (immix-block-base source)
                  (immix-block-live source) 0
                  (ix-current a) destination)
            (fill fwd 0)))))))

(defun heal-forwarded-root (plan ref)
  (let ((vm (plan-vm plan)))
    (let* ((address (ref-strip-or-self vm ref))
           (fwd (vm-fwd-table vm))
           (destination
             (and (vm-valid-reference-p vm ref)
                  (< address (length fwd))
                  (aref fwd address))))
      (if (plusp destination)
          ;; Preserve the pointer colour so a self-healing LVB sees the
          ;; relocated reference as "good" rather than a bare address.
          (if (typep vm 'coloured-pointer-mixin)
              (ref-set-colour vm destination (vm-good-colour vm))
              destination)
          ref))))

(defun heal-every-space (plan fwd)
  "Heal root references plus the reference slots of every live object in
every plan space.  Used by defrag/compaction paths: an object in ANY space --
including a LOS object -- may hold a reference into a block that just moved,
and every such edge must be rewritten."
  (let* ((vm (plan-vm plan))
         (object-start (vm-object-start vm)))
    (vm-direct-scan-roots vm plan #'heal-forwarded-root)
    (dolist (space (plan-spaces plan))
      (let ((allocator (space-allocator space)))
        ;; immix allocators bound their walk to used blocks; every other
        ;; allocator heals over the space's full word range (object-start
        ;; bits tell live from stale).
        (etypecase allocator
          (immix-allocator
           (do-immix-blocks (block allocator)
             (loop for address from (immix-block-base block)
                   below (ix-block-end block (ix-block-words allocator))
                   when (s-test-bit object-start address)
                     do (vm-heal-reference-slots vm address fwd))))
          ((or bump-allocator free-list-allocator los-allocator
               hierarchical-allocator null)
           (loop for address from (space-base-address space)
                 below (space-end-address space)
                 when (s-test-bit object-start address)
                   do (vm-heal-reference-slots vm address fwd))))))
    plan))

(defun immix-heal-references (s vm fwd)
  "Update root + slot references that point at forwarded objects.
Healing covers EVERY plan space: a LOS (or any other) object may hold an edge
into the evacuated blocks and must be rewritten too."
  (declare (ignore s))
  (when (notany #'plusp fwd) (return-from immix-heal-references))
  (heal-every-space (vm-plan vm) fwd))

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
  ;; Private regions are request-owned by default.  Callers may override the
  ;; constraints explicitly (Claimore's nursery is thread-owned).
  (:default-initargs :policy :trace :moving :opportunistic
                     :constraints (make-instance 'space-constraints
                                                 :scope :request))
  (:metaclass space-metaclass))

;; Claimore's nursery uses Immix's fixed block allocator only as its physical
;; substrate.  Its collection protocol is the paper's owner-local matrix probe
;; followed by precise offset-vector compaction (OVC), not ordinary Immix
;; opportunistic defragmentation.
(defclass claimore-nursery-space (private-immix-space)
  ((nursery-granule :initarg :nursery-granule :initform +g-block+
                    :accessor claimore-nursery-granule)
   (nursery-node-count :accessor claimore-nursery-node-count :initform 0)
   (nursery-matrix :accessor claimore-nursery-matrix :initform nil)
   (nursery-occupied :accessor claimore-nursery-occupied :initform nil)
   (nursery-dirty :accessor claimore-nursery-dirty :initform nil)
   (nursery-probe-roots :accessor claimore-nursery-probe-roots :initform nil)
   (nursery-probe-live :accessor claimore-nursery-probe-live :initform nil)
   ;; Keep the policy threshold as an integer percentage.  A rational ratio
   ;; here would allocate a temporary ratio in SBCL's generic arithmetic on
   ;; every probe, which is forbidden once the collector is booted.
   (nursery-mgc-threshold :initarg :nursery-mgc-threshold :initform 25
                          :accessor claimore-nursery-mgc-threshold)
   (nursery-recognised-dead :accessor claimore-nursery-recognised-dead
                            :initform 0)
   (nursery-last-action :accessor claimore-nursery-last-action :initform nil)
   ;; OVC scratch is boot-owned.  It prevents overlapping source/destination
   ;; objects from corrupting one another and keeps the collection path fixed
   ;; capacity.  The parallel metadata arrays preserve source state before a
   ;; packed destination can overlap an old source address.
   (ovc-scratch :accessor claimore-nursery-ovc-scratch :initform nil)
   (ovc-source-starts :accessor claimore-nursery-ovc-source-starts
                      :initform nil)
   (ovc-sizes :accessor claimore-nursery-ovc-sizes :initform nil)
   (ovc-age :accessor claimore-nursery-ovc-age :initform nil)
   (ovc-public :accessor claimore-nursery-ovc-public :initform nil)
   (ovc-log :accessor claimore-nursery-ovc-log :initform nil)
   (ovc-weak :accessor claimore-nursery-ovc-weak :initform nil)
   (ovc-mark :accessor claimore-nursery-ovc-mark :initform nil))
  (:default-initargs :moving :sliding-ovc
                     :constraints (make-instance 'space-constraints
                                                 :scope :thread))
  (:metaclass space-metaclass))

(defmethod shared-initialize :after ((s claimore-nursery-space) slot-names
                                     &key vm)
  (declare (ignore slot-names))
  (when (and vm (slot-boundp s 'start-page) (slot-boundp s 'page-count))
    (let* ((words (- (space-end-address s) (space-base-address s)))
           (granule (claimore-nursery-granule s))
           (nodes (max 1 (ceiling words granule))))
      (setf (claimore-nursery-node-count s) nodes
            (claimore-nursery-matrix s)
            (make-matrix-stratum granule nodes)
            (claimore-nursery-occupied s)
            (make-array nodes :element-type 'bit :initial-element 0)
            (claimore-nursery-dirty s)
            (make-array nodes :element-type 'bit :initial-element 0)
            (claimore-nursery-probe-roots s)
            (make-array nodes :element-type 'bit :initial-element 0)
            (claimore-nursery-probe-live s)
            (make-array nodes :element-type 'bit :initial-element 0)
            (claimore-nursery-ovc-scratch s)
            (make-array words :element-type '(unsigned-byte 64)
                        :initial-element 0)
            (claimore-nursery-ovc-source-starts s)
            (make-array words :element-type 'bit :initial-element 0)
            (claimore-nursery-ovc-sizes s)
            (make-array words :element-type 'fixnum :initial-element 0)
            (claimore-nursery-ovc-age s)
            (make-array words :element-type 'fixnum :initial-element 0)
            (claimore-nursery-ovc-public s)
            (make-array words :element-type 'bit :initial-element 0)
            (claimore-nursery-ovc-log s)
            (make-array words :element-type 'bit :initial-element 0)
            (claimore-nursery-ovc-weak s)
            (make-array words :element-type 'bit :initial-element 0)
            (claimore-nursery-ovc-mark s)
            (make-array words :element-type 'bit :initial-element 0)))))

(defun claimore-nursery-node (s address)
  (let ((node (floor (- (ref-strip-or-self (space-vm s) address)
                        (space-base-address s))
                     (claimore-nursery-granule s))))
    (max 0 (min (1- (claimore-nursery-node-count s)) node))))

(defun claimore-nursery-note-write (s vm source old new)
  "Record a nursery relation before SOURCE's store is exposed.
Overwrites conservatively dirty the source node; OVC later rebuilds those rows
from the precise post-collection payloads."
  (when (space-direct-contains-p s (ref-strip-or-self vm source))
    (let ((src-node (claimore-nursery-node s source))
          (matrix (claimore-nursery-matrix s))
          (dirty (claimore-nursery-dirty s)))
      (when dirty (setf (sbit dirty src-node) 1))
      (when (and matrix (vm-reference-p vm new)
                 (space-direct-contains-p s (ref-strip-or-self vm new)))
        (let ((dst-node (claimore-nursery-node s new)))
          (unless (= src-node dst-node)
            (matrix-set matrix src-node dst-node))))))
  new)

(defun claimore-nursery-seed-probe-root (s ref)
  (let ((vm (space-vm s)))
    (when (and (vm-reference-p vm ref)
               (space-direct-contains-p s (ref-strip-or-self vm ref)))
      (setf (sbit (claimore-nursery-probe-roots s)
                  (claimore-nursery-node s ref)) 1)))
  ref)

(defun claimore-nursery-probe (s vm)
  "Run the conservative matrix probe before exact OVC marking.
The probe only chooses/report a physical policy; exact marks remain the
liveness authority in all cases."
  (let* ((roots (claimore-nursery-probe-roots s))
         (live (claimore-nursery-probe-live s))
         (occupied (claimore-nursery-occupied s))
         (matrix (claimore-nursery-matrix s))
         (nodes (claimore-nursery-node-count s))
         (recognized 0))
    (fill roots 0)
    (vm-direct-scan-roots vm s #'claimore-nursery-seed-probe-root)
    (replace live (matrix-closure matrix roots))
    (dotimes (node nodes)
      (when (and (= 1 (sbit occupied node))
                 (= 0 (sbit live node)))
        (incf recognized)))
    (setf (claimore-nursery-recognised-dead s) recognized
          (claimore-nursery-last-action s)
          (if (>= recognized
                  (ceiling (* nodes
                               (claimore-nursery-mgc-threshold s))
                           100))
              :mgc
              :ovc)))
  s)

(defun claimore-nursery-rebuild-metadata (s vm)
  "Rebuild occupancy and relation rows after OVC has installed destinations."
  (let ((matrix (claimore-nursery-matrix s))
        (occupied (claimore-nursery-occupied s))
        (dirty (claimore-nursery-dirty s))
        (os (vm-object-start vm))
        (base (space-base-address s))
        (end (space-end-address s))
        (stats (%stats-for-vm vm)))
    (matrix-clear-all matrix)
    ;; Clearing then reconstructing the matrix defines every logical row,
    ;; including rows that remain empty.  Count matrix rows, not source
    ;; objects (several objects can contribute to the same row).
    (when stats
      (stats-event stats :relation-rows-rebuilt (matrix-regions matrix)))
    (fill occupied 0)
    (fill dirty 0)
    (loop for address from base below end
          when (s-test-bit os address)
            do (let ((src-node (claimore-nursery-node s address))
                     (slots (vm-reference-slots vm address))
                     (count (vm-direct-object-reference-count vm address))
                     (weak-p (weak-pointer-p vm address)))
                 (setf (sbit occupied src-node) 1)
                 (if slots
                     (loop for slot across slots
                           when (or (not weak-p) (not (zerop slot)))
                             do (let ((child (vm-direct-object-reference vm address slot)))
                                  (when (and (vm-reference-p vm child)
                                             (space-direct-contains-p
                                              s (ref-strip-or-self vm child)))
                                    (let ((dst-node
                                            (claimore-nursery-node s child)))
                                      (unless (= src-node dst-node)
                                        (matrix-set matrix src-node dst-node))))))
                     (dotimes (slot count)
                       (when (or (not weak-p) (not (zerop slot)))
                         (let ((child (vm-direct-object-reference vm address slot)))
                           (when (and (vm-reference-p vm child)
                                      (space-direct-contains-p
                                       s (ref-strip-or-self vm child)))
                             (let ((dst-node
                                     (claimore-nursery-node s child)))
                               (unless (= src-node dst-node)
                                 (matrix-set matrix src-node dst-node)))))))))))
  s)

(defun claimore-nursery-clear-source-metadata (vm address)
  "Clear source identity while retaining the OVC forwarding table."
  (let ((os (vm-object-start vm)))
    (when os (s-clear-bit os address)))
  (dolist (name '(:mark :log :public :age :weak))
    (let ((stratum (vm-direct-stratum vm name)))
      (when stratum (s-set stratum address (stratum-default stratum)))))
  (when (and (vm-rc-table vm) (< address (length (vm-rc-table vm))))
    (setf (aref (vm-rc-table vm) address) 0))
  address)

(defun claimore-nursery-copy-metadata (s vm source destination)
  (let ((age (vm-direct-stratum vm :age))
        (public (vm-direct-stratum vm :public))
        (log (vm-direct-stratum vm :log))
        (weak (vm-direct-stratum vm :weak))
        (mark (vm-direct-stratum vm :mark))
        (os (vm-object-start vm)))
    (when os (s-set-bit os destination))
    (when mark
      (if (= 1 (sbit (claimore-nursery-ovc-mark s) source))
          (s-set-bit mark destination)
          (s-clear-bit mark destination)))
    (when age (s-set age destination (aref (claimore-nursery-ovc-age s) source)))
    (when public
      (if (= 1 (sbit (claimore-nursery-ovc-public s) source))
          (s-set-bit public destination)
          (s-clear-bit public destination)))
    (when log
      (if (= 1 (sbit (claimore-nursery-ovc-log s) source))
          (s-set-bit log destination)
          (s-clear-bit log destination)))
    (when weak
      (if (= 1 (sbit (claimore-nursery-ovc-weak s) source))
          (s-set-bit weak destination)
          (s-clear-bit weak destination))))
  destination)

(defun claimore-nursery-rebuild-allocator (s vm cursor)
  (let* ((a (space-allocator s))
         (base (space-base-address s))
         (bw (ix-block-words a))
         (end (space-end-address s))
         (block-count (min (length (ix-blocks a))
                           (ceiling (max 0 (- cursor base)) bw))))
    (dotimes (i (length (ix-blocks a)))
      (let ((block (aref (ix-blocks a) i)))
        (setf (immix-block-cursor block) (immix-block-base block)
              (immix-block-live block) 0)))
    (fill (ix-span-root a) -1)
    (setf (ix-block-count a) block-count
          (ix-next-base a) (+ base (* block-count bw))
          (ix-current a) (and (plusp block-count)
                              (aref (ix-blocks a) (1- block-count))))
    (loop for address from base below cursor
          when (s-test-bit (vm-object-start vm) address)
                      do (let* ((words (vm-direct-object-total-words vm address))
                      (first (floor (- address base) bw))
                      (last (floor (- (+ address words -1) base) bw)))
                 (when (< first block-count)
                   (loop for bi from first to (min last (1- block-count))
                         for block = (aref (ix-blocks a) bi)
                         do (setf (immix-block-cursor block)
                                  (max (immix-block-cursor block)
                                       (min (+ (immix-block-base block) bw)
                                            (+ address words)))))
                 (when (> words bw)
                   (loop for bi from first to (min last (1- block-count))
                         do (setf (aref (ix-span-root a) bi) first)))))
    (when (and (plusp block-count) (> (ix-next-base a) end))
      (setf (ix-next-base a) end)))
  s))

(defmethod space-prepare ((s claimore-nursery-space) vm cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear-range (vm-direct-stratum vm :mark)
                 (space-base-address s) (space-end-address s))
  s)

(defun claimore-nursery-ovc (s vm)
  "Precise offset-vector compaction for the owner-local nursery.
All source words and metadata are snapshotted into boot-owned buffers before
packed destinations are installed, so overlapping objects cannot corrupt the
source scan."
  (let* ((a (space-allocator s))
         (base (space-base-address s))
         (source-end (ix-next-base a))
         (end (space-end-address s))
         (bw (ix-block-words a))
         (os (vm-object-start vm))
         (mark (vm-direct-stratum vm :mark))
         (scratch (claimore-nursery-ovc-scratch s))
         (source-starts (claimore-nursery-ovc-source-starts s))
         (sizes (claimore-nursery-ovc-sizes s))
         (ages (claimore-nursery-ovc-age s))
         (public-stratum (vm-direct-stratum vm :public))
         (public-save (claimore-nursery-ovc-public s))
         (log-stratum (vm-direct-stratum vm :log))
         (log-save (claimore-nursery-ovc-log s))
         (weak-stratum (vm-direct-stratum vm :weak))
         (weak-save (claimore-nursery-ovc-weak s))
         (saved-mark (claimore-nursery-ovc-mark s))
         (dest-starts (vm-direct-stratum vm :claimore-ovc-destination))
         (cursor base))
    (fill source-starts 0)
    (fill sizes 0)
    (fill saved-mark 0)
    (fill public-save 0)
    (fill log-save 0)
    (fill weak-save 0)
    (when (vm-direct-stratum vm :age) (fill ages 0))
    (s-clear dest-starts)
    (fwd-clear vm)
    ;; Snapshot source object boundaries, metadata, and live payload words.
    (loop for address from base below source-end
          when (s-test-bit os address)
            do (let* ((words (vm-direct-object-total-words vm address))
                      (live (and mark (s-test-bit mark address))))
                 (setf (sbit source-starts (- address base)) 1)
                 (setf (aref sizes address) words)
                 (setf (sbit saved-mark address) (if live 1 0))
                 (when (vm-direct-stratum vm :age)
                   (setf (aref ages address)
                         (s-get (vm-direct-stratum vm :age) address)))
                 (when public-stratum
                   (setf (sbit public-save address)
                         (if (s-test-bit public-stratum address) 1 0)))
                 (when log-stratum
                   (setf (sbit log-save address)
                         (if (s-test-bit log-stratum address) 1 0)))
                 (when weak-stratum
                   (setf (sbit weak-save address)
                         (if (s-test-bit weak-stratum address) 1 0)))
                 (when live
                   ;; Keep small objects within a block and start spans at a
                   ;; block boundary, matching the allocator's geometry.
                   (let ((block-end
                           (+ base (* (1+ (floor (- cursor base) bw)) bw))))
                     (cond
                       ((> words bw)
                        (setf cursor
                              (+ base (* (ceiling (- cursor base) bw) bw))))
                       ((> (+ cursor words) block-end)
                        (setf cursor block-end))))
                   (when (> (+ cursor words) end)
                     (error 'heap-exhausted :requested-size words
                            :space :claimore-nursery-ovc))
                   (setf (aref (vm-fwd-table vm) address) cursor)
                   (s-set-bit dest-starts cursor)
                   (dotimes (k words)
                     (setf (aref scratch (+ (- cursor base) k))
                           (vm-direct-ref-u64 vm (+ address k))))
                   (let ((stats (%stats-for-vm vm)))
                     (when stats
                       (stats-event stats :objects-copied 1)
                       (stats-event stats :words-copied words)))
                   (incf cursor words))))
    ;; Install all packed raw objects only after the source snapshot is done.
    (loop for address from base below cursor
          do (vm-direct-set-ref-u64 vm address
                                    (aref scratch (- address base))))
    ;; Drop every old identity, including dead objects, while preserving the
    ;; forwarding table until every destination reference has been healed.
    (loop for address from base below source-end
          when (= 1 (sbit source-starts (- address base)))
            do (claimore-nursery-clear-source-metadata vm address))
    ;; Recreate destination side metadata from the source snapshot.
    (loop for address from base below source-end
          when (and (= 1 (sbit source-starts (- address base)))
                    (= 1 (sbit saved-mark address)))
            do (claimore-nursery-copy-metadata
                s vm address (aref (vm-fwd-table vm) address)))
    ;; All plan spaces and roots may point into the nursery.
    (heal-every-space (vm-plan vm) (vm-fwd-table vm))
    (vm-direct-memory-fence vm)
    (claimore-nursery-rebuild-allocator s vm cursor)
    (claimore-nursery-rebuild-metadata s vm)
    (fwd-clear vm)
    (fill source-starts 0)
    (s-clear dest-starts)
    (when mark (s-clear-range mark base end)))
  s)

(defun %claimore-nursery-reclaim (s vm cycle-kind)
  (declare (ignore cycle-kind))
  (claimore-nursery-probe s vm)
  ;; The exact OVC is the liveness authority for both probe outcomes.  The
  ;; :mgc outcome records the coarse policy choice without allowing coarse
  ;; metadata to reclaim an object independently of the precise trace.
  (claimore-nursery-ovc s vm)
  s)

(defmethod space-reclaim ((s claimore-nursery-space) vm cycle-kind)
  (%claimore-nursery-reclaim s vm cycle-kind))
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
                                             :first-page 0
                                             :heap (vm-heap vm))
                                           :base-page (space-start-page space)
                                           :vm vm :space space))
              (immix-space            (make-instance 'immix-allocator :vm vm :space space
                                                     :start start :limit end))
              (superblock-space       (make-hierarchical-allocator vm space))
              (otherwise               (make-instance 'bump-allocator :start start :limit end :vm vm :space space)))))))

(defmethod shared-initialize :after ((s space) slot-names &rest keys &key vm)
  (declare (ignore slot-names keys))
  (when (and vm (slot-boundp s 'start-page) (not (slot-boundp s 'allocator)))
    (%ensure-allocator s vm)))

;; ---- copy-space (SemiSpace / nurseries): Cheney --------------------------

(defun %copy-space-trace-object (s vm ref tracer trace-kind)
  (declare (ignore trace-kind))
  (let* ((addr (ref-strip-or-self vm ref))
         (to (space-partner s)))
    (cond
      ((vm-direct-object-forwarded-p vm addr)
       (vm-direct-object-forwarding-pointer vm addr))
      ((vm-direct-object-marked-p vm addr) addr)   ; already a to-space copy
      (t
       (let ((dst (space-direct-alloc to
                                      (vm-direct-object-total-words vm addr))))
         (unless dst
           ;; The live set does not fit the destination space.  There is no
           ;; way to complete a Cheney flip with an object that cannot be
           ;; copied, so report the exhaustion instead of passing NIL to the
           ;; copy loop (which would clobber slot arithmetic with a type
           ;; error and leave the heap corrupt).
           (error 'heap-exhausted
                  :requested-size (vm-direct-object-total-words vm addr)
                  :space (space-name to)))
         (vm-direct-object-copy vm addr dst)
         (vm-direct-set-object-marked-p vm dst t)
         (vm-direct-set-object-forwarding-pointer vm addr dst)
         (tracer-enqueue tracer dst)
         dst)))))

(defmethod space-trace-object ((s copy-space) vm ref tracer trace-kind)
  (%copy-space-trace-object s vm ref tracer trace-kind))

(defmethod space-prepare ((s copy-space) vm cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-direct-stratum vm :mark))
  s)

(defmethod space-reclaim ((s copy-space) vm cycle-kind)
  (declare (ignore cycle-kind))
  ;; forwarding state is in-header and is gone once roots point at to-space;
  ;; mark bits cleared in prepare of next cycle.  Nothing to sweep here.
  s)

(defmethod space-occupancy ((s copy-space))
  (let ((a (space-allocator s)))
    (if (typep a 'bump-allocator) (- (ba-cursor a) (ba-start a)) 0)))

;; ---- cons-space: headerless, off-heap forwarding -------------------------

(defun %cons-space-trace-object (s vm ref tracer trace-kind)
  (declare (ignore trace-kind))
  (let* ((addr (ref-strip-or-self vm ref))
         (to (space-partner s)))
    (cond
      ((vm-direct-object-forwarded-p vm addr)
       (vm-direct-object-forwarding-pointer vm addr))
      (t (let ((dst (space-direct-alloc to 2)))
           (unless dst
             (error 'heap-exhausted :requested-size 2 :space (space-name to)))
           (vm-direct-object-copy vm addr dst)
           (vm-direct-set-object-forwarding-pointer vm addr dst)
           (tracer-enqueue tracer dst)
           dst)))))

(defmethod space-trace-object ((s cons-space) vm ref tracer trace-kind)
  (%cons-space-trace-object s vm ref tracer trace-kind))

;; ---- mark-sweep-space ----------------------------------------------------

(defun %mark-sweep-space-trace-object (s vm ref tracer trace-kind)
  (declare (ignore trace-kind))
  (let ((addr (ref-strip-or-self vm ref)))
    (unless (vm-direct-object-marked-p vm addr)
      (vm-direct-set-object-marked-p vm addr t)
      (tracer-enqueue tracer addr))
    addr))

(defmethod space-trace-object ((s mark-sweep-space) vm ref tracer trace-kind)
  (%mark-sweep-space-trace-object s vm ref tracer trace-kind))

(defmethod space-prepare ((s mark-sweep-space) vm cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-direct-stratum vm :mark))
  s)

(defun %mark-sweep-space-reclaim (s vm cycle-kind)
  (declare (ignore cycle-kind))
  (let ((a (space-allocator s))
        (os (vm-object-start vm))
        (mark (vm-direct-stratum vm :mark))
        (start (space-base-address s))
        (end (space-end-address s)))
    (when (and a os mark)
      (loop for address from start below end
            when (and (s-test-bit os address)
                      (not (s-test-bit mark address)))
              do (space-direct-free s address
                                    (vm-direct-object-total-words vm address)))
      ;; Range-clear: the mark stratum is heap-wide; other spaces (LOS,
      ;; sticky partners) own their marks and reclaim after this space.
      (s-clear-range mark start end))
    s))

(defmethod space-reclaim ((s mark-sweep-space) vm cycle-kind)
  (%mark-sweep-space-reclaim s vm cycle-kind))

(defmethod space-occupancy ((s mark-sweep-space))
  (let ((a (space-allocator s)))
    (if (typep a 'free-list-allocator)
        (- (fl-limit a) (fl-start a)
           (fl-free-words a))
        0)))

;; ---- immix-space ---------------------------------------------------------

(defun %immix-space-trace-object (s vm ref tracer trace-kind)
  (let ((addr (ref-strip-or-self vm ref)))
    (cond
      ((and (eq trace-kind :defrag)
            (not (vm-direct-object-marked-p vm addr)))
       ;; opportunistic copy: move into a compacted block if a target exists
       (vm-direct-set-object-marked-p vm addr t)
       (tracer-enqueue tracer addr)
       addr)
      (t
       (unless (vm-direct-object-marked-p vm addr)
         (vm-direct-set-object-marked-p vm addr t)
         (tracer-enqueue tracer addr))
       addr))))

(defmethod space-trace-object ((s immix-space) vm ref tracer trace-kind)
  (%immix-space-trace-object s vm ref tracer trace-kind))

(defmethod space-prepare ((s immix-space) vm cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-direct-stratum vm :mark))
  s)

(defun %immix-sweep-blocks (s vm)
  "Span-aware block sweep shared by immix and sticky-immix reclamation.

First pass: decide each block's live count, but a span block is
reclaimed atomically with its root object: the whole span lives or
dies together (heap.tex §2 medium objects).  The per-block counts
live in a boot-allocated vector, never a host allocation.  Second
pass: forget dead objects and recycle fully-dead blocks, clearing the
recycled span's flags so its blocks return to the allocator.

The mark stratum is never cleared here: callers decide mark policy,
which is what lets the sticky variant keep marks across minors while
the ordinary immix space clears its own range after the sweep."
  (let ((a (space-allocator s)))
    (when (and (plusp (ix-block-count a)) (vm-direct-stratum vm :mark))
      (let ((block-live (ix-block-live a)))
        (do-immix-blocks (b a)
          (let ((bi (floor (- (immix-block-base b) (ix-start a))
                           (ix-block-words a))))
            (setf (aref block-live bi)
                  (immix-block-live-count a vm b))))
        ;; A span block inherits the live count of its ROOT block (the
        ;; block holding the object's header); non-root blocks have no
        ;; object starts so their own count would be zero.
        (dotimes (bi (ix-block-count a))
          (let ((root (aref (ix-span-root a) bi)))
            (when (and (>= root 0) (/= root bi))
              (setf (aref block-live bi) (aref block-live root)))))
        (do-immix-blocks (b a)
          (let* ((bi (floor (- (immix-block-base b) (ix-start a))
                            (ix-block-words a)))
                 (live (aref block-live bi)))
            (setf (immix-block-live b) live)
            (immix-forget-dead-objects a vm b)
            (when (zerop live)
              ;; fully dead: recycle the whole block for reuse
              (vm-clear-metadata-range vm
                                       (immix-block-base b)
                                       (+ (immix-block-base b)
                                          (ix-block-words a)))
              (setf (immix-block-cursor b) (immix-block-base b))
              ;; a recycled span block leaves its span
              (when (>= (aref (ix-span-root a) bi) 0)
                (setf (aref (ix-span-root a) bi) -1))))))
      (setf (ix-current a) (ix-first-block a))))
  s)

(defun %immix-space-reclaim (s vm cycle-kind)
  (let ((a (space-allocator s)))
    (%immix-sweep-blocks s vm)
    (when (eq cycle-kind :major)
      (immix-defrag s vm))
    ;; Range-clear: the mark stratum is heap-wide; other spaces (LOS,
    ;; sticky partners) own their marks and reclaim after this space.
    (let ((mark (vm-direct-stratum vm :mark)))
      (when mark (s-clear-range mark (ix-start a) (ix-limit a))))
    s))

(defmethod space-reclaim ((s immix-space) vm cycle-kind)
  (%immix-space-reclaim s vm cycle-kind))

(defmethod space-occupancy ((s immix-space))
  (let ((a (space-allocator s)))
    (if (typep a 'immix-allocator)
        (loop for i below (ix-block-count a)
              for b = (aref (ix-blocks a) i)
              sum (- (immix-block-cursor b) (immix-block-base b)))
        0)))

;; ---- LOS -----------------------------------------------------------------

(defun %los-space-trace-object (s vm ref tracer trace-kind)
  (declare (ignore trace-kind))
  (let ((addr (ref-strip-or-self vm ref)))
    (unless (vm-direct-object-marked-p vm addr)
      (vm-direct-set-object-marked-p vm addr t)
      (tracer-enqueue tracer addr))
    addr))

(defmethod space-trace-object ((s los-space) vm ref tracer trace-kind)
  (%los-space-trace-object s vm ref tracer trace-kind))

(defun %los-space-reclaim (s vm cycle-kind)
  (declare (ignore cycle-kind))
  (let ((a (space-allocator s)) (os (vm-object-start vm))
        (mark (vm-direct-stratum vm :mark)))
    (when (and a os mark)
      (loop for address from (space-base-address s)
            below (space-end-address s)
            when (and (s-test-bit os address)
                      (not (s-test-bit mark address)))
              do (space-direct-free s address
                                    (vm-direct-object-total-words vm address)))
      ;; Clear marks only within this space's range: the mark stratum is
      ;; heap-wide and other spaces (notably sticky plans) own their marks.
      (s-clear-range mark (space-base-address s) (space-end-address s)))
    s))

(defmethod space-reclaim ((s los-space) vm cycle-kind)
  (%los-space-reclaim s vm cycle-kind))

(defmethod space-occupancy ((s los-space))
  ;; Occupied LOS words for the :retained-bytes-sample gauge: the dense
  ;; extent table records every live run's page length.  Read-only over the
  ;; boot-allocated table; no allocation.
  (let ((a (space-allocator s)))
    (if (typep a 'los-allocator)
        (let ((extents (los-extents a)))
          (if extents
              (* +page-words+ (loop for pages across extents sum pages))
              0))
        0)))

;; ---- immortal-space ------------------------------------------------------

(defmethod space-reclaim ((s immortal-space) vm cycle-kind)
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
  ((sb-refcounts :reader sb-refcounts :initarg :sb-refcounts :initform nil
                 :type (or (simple-array fixnum (*)) null))
   (block-words :reader sb-block-words :initarg :block-words
                :initform +g-block+ :type fixnum)
   (blocks-per-metablock :reader sb-blocks-per-metablock
                         :initarg :blocks-per-metablock :initform 256
                         :type fixnum)
   (metablocks-per-superblock :reader sb-mbs-per-superblock
                              :initarg :metablocks-per-superblock
                              :initform 256 :type fixnum)
   ;; per-SB metablock points-to matrices (heap.tex §6, strata.tex §5)
   (mb-matrices :accessor sb-mb-matrices :initform nil
                :type (or (simple-array (or matrix-stratum null) (*)) null))
   ;; per-MB block points-to matrices (indexed by global metablock index)
   (block-matrices :accessor sb-block-matrices :initform nil
                   :type (or (simple-array (or matrix-stratum null) (*)) null))
   ;; preallocated closure scratch: root/reached bit-vectors per SB
   (mb-root-bits :accessor sb-mb-root-bits :initform nil)
   (reached-mbs :accessor sb-reached-mbs :initform nil)
   ;; SBs that must not be released wholesale this cycle
   (pinned :accessor sb-pinned :initform nil
           :type (or (simple-array bit (*)) null))
   ;; One Fine/Mature bit per metablock.  Fine is sealed state; a mutator
   ;; store demotes it before the new value becomes visible.
   (fine-metablocks :accessor sb-fine-metablocks :initform nil
                    :type (or (simple-array bit (*)) null))
   ;; One-block scratch for the copy-free map tier.  The simulator's physical
   ;; heap is identity mapped until this tier is first used; after that the
   ;; software MMU swaps a live source page with a free destination page and
   ;; the same virtual-address correction path used by move heals references.
   (map-source-starts :accessor sb-map-source-starts :initform nil)
   (map-source-sizes :accessor sb-map-source-sizes :initform nil)
   (map-source-mark :accessor sb-map-source-mark :initform nil)
   (map-source-age :accessor sb-map-source-age :initform nil)
   (map-source-public :accessor sb-map-source-public :initform nil)
   (map-source-log :accessor sb-map-source-log :initform nil)
   (map-source-weak :accessor sb-map-source-weak :initform nil)
   (map-source-rc :accessor sb-map-source-rc :initform nil)
   (map-pages :accessor sb-map-pages :initform 0)
   ;; the block-granularity 3-bit escape stratum (registered on the VM)
   (escape :accessor sb-escape :initform nil
           :type (or stratum null)))
  (:default-initargs :policy :hierarchical :moving :none)
  (:metaclass space-metaclass))

;; ---- collection-path slot access (no CLOS dispatch) ----------------------
;; The superblock collection path must not dispatch through CLOS slot
;; accessors: SBCL allocates an effective method on the first dynamically
;; typed access.  These wrappers read slots via (STRUCTURE-CLASS . SLOT) 
;; slot-value with fixnum/vector type propagation, compiled to direct slot
;; offsets under (SPEED 3) (SAFETY 0).

(declaim (inline %sb-block-words %sb-bpm %sb-mps %sb-block-count
                 %sb-mb-count %sb-count %sb-block-matrices
                 %sb-mb-matrices %sb-refcounts %sb-pinned
                 %sb-reached-mbs %sb-mb-root-bits %sb-escape %sb-fine
                 %sb-map-source-starts %sb-map-source-sizes %sb-map-source-mark
                 %sb-map-source-age %sb-map-source-public %sb-map-source-log
                 %sb-map-source-weak %sb-map-source-rc))
(defun %sb-block-words (s)
  (declare (optimize (speed 3) (safety 0)))
  (the fixnum (slot-value s 'block-words)))
(defun %sb-bpm (s)
  (declare (optimize (speed 3) (safety 0)))
  (the fixnum (slot-value s 'blocks-per-metablock)))
(defun %sb-mps (s)
  (declare (optimize (speed 3) (safety 0)))
  (the fixnum (slot-value s 'metablocks-per-superblock)))
(defun %sb-block-count (s)
  (declare (optimize (speed 3) (safety 0)))
  (the fixnum (floor (- (space-end-address s) (space-base-address s))
                     (%sb-block-words s))))
(defun %sb-mb-count (s)
  (declare (optimize (speed 3) (safety 0)))
  (the fixnum (ceiling (%sb-block-count s) (%sb-bpm s))))
(defun %sb-count (s)
  (declare (optimize (speed 3) (safety 0)))
  (the fixnum (ceiling (%sb-mb-count s) (%sb-mps s))))
(defun %sb-block-matrices (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'block-matrices))
(defun %sb-mb-matrices (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'mb-matrices))
(defun %sb-refcounts (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'sb-refcounts))
(defun %sb-pinned (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'pinned))
(defun %sb-reached-mbs (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'reached-mbs))
(defun %sb-mb-root-bits (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'mb-root-bits))
(defun %sb-escape (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'escape))
(defun %sb-fine (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'fine-metablocks))
(defun %sb-map-source-starts (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-starts))
(defun %sb-map-source-sizes (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-sizes))
(defun %sb-map-source-mark (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-mark))
(defun %sb-map-source-age (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-age))
(defun %sb-map-source-public (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-public))
(defun %sb-map-source-log (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-log))
(defun %sb-map-source-weak (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-weak))
(defun %sb-map-source-rc (s)
  (declare (optimize (speed 3) (safety 0)))
  (slot-value s 'map-source-rc))

;; ---- region geometry -----------------------------------------------------

(declaim (inline sb-words-per-block sb-words-per-mb sb-words-per-superblock))
(defun sb-words-per-block (s) (%sb-block-words s))
(defun sb-words-per-mb (s)
  (* (%sb-block-words s) (%sb-bpm s)))
(defun sb-words-per-superblock (s)
  (* (sb-words-per-mb s) (%sb-mps s)))

(defun sb-block-count (s)
  (floor (- (space-end-address s) (space-base-address s)) (%sb-block-words s)))
(defun sb-mb-count (s)
  (ceiling (%sb-block-count s) (%sb-bpm s)))
(defun sb-count (s)
  (ceiling (%sb-mb-count s) (%sb-mps s)))

(defun sb-index (s address)
  "Which superblock ADDRESS belongs to (superblock 0 is the first in the
  space's address range; it holds the persistent root set and is never freed)."
  (floor (- address (space-base-address s)) (sb-words-per-superblock s)))
(defun sb-block-index (s address)
  (floor (- address (space-base-address s)) (%sb-block-words s)))
(defun sb-mb-index (s address)
  (floor (sb-block-index s address) (%sb-bpm s)))
(defun sb-local-block (s block-index)
  (mod block-index (%sb-bpm s)))
(defun sb-local-mb (s mb-index)
  (mod mb-index (%sb-mps s)))
(defun sb-block-base (s block-index)
  (+ (space-base-address s) (* block-index (%sb-block-words s))))

(declaim (inline sb-fine-metablock-p sb-clear-fine-for-address))
(defun sb-fine-metablock-p (s mb)
  (let ((fine (%sb-fine s)))
    (and fine (< mb (length fine)) (eql 1 (sbit fine mb)))))
(defun sb-clear-fine-for-address (s address)
  (let ((fine (%sb-fine s)))
    (when (and fine (space-direct-contains-p s address))
      (setf (sbit fine (sb-mb-index s address)) 0)))
  address)
(defun superblock-seal-fine (s)
  "Mark every currently occupied metablock Fine after a collection/checkpoint.
The vector is summary state only; object liveness remains the trace's job."
  (let ((fine (%sb-fine s))
        (a (space-allocator s))
        (bpm (%sb-bpm s))
        (nmb (%sb-mb-count s)))
    (when fine
      (fill fine 0)
      (dotimes (mb nmb)
        (dotimes (b bpm)
          (let ((bi (+ (* mb bpm) b)))
            (when (and (< bi (%sb-block-count s))
                       (hierarchical-block-in-use-p a bi))
              (setf (sbit fine mb) 1)
              (return))))))
  s))

(defmethod shared-initialize :after ((s superblock-space) slot-names &key)
  (declare (ignore slot-names))
  (let ((nsb (%sb-count s))
        (nmbs (%sb-mb-count s))
        (mps (%sb-mps s))
        (bpm (%sb-bpm s)))
    (unless (%sb-refcounts s)
      (setf (slot-value s 'sb-refcounts)
            (make-array nsb :element-type 'fixnum :initial-element 0)))
    (unless (%sb-fine s)
      (setf (slot-value s 'fine-metablocks)
            (make-array nmbs :element-type 'bit :initial-element 0)))
    (unless (slot-value s 'map-source-starts)
      (setf (slot-value s 'map-source-starts)
            (make-array (sb-block-words s) :element-type 'bit
                        :initial-element 0)
            (slot-value s 'map-source-sizes)
            (make-array (sb-block-words s) :element-type 'fixnum
                        :initial-element 0)
            (slot-value s 'map-source-mark)
            (make-array (sb-block-words s) :element-type 'bit
                        :initial-element 0)
            (slot-value s 'map-source-age)
            (make-array (sb-block-words s) :element-type 'fixnum
                        :initial-element 0)
            (slot-value s 'map-source-public)
            (make-array (sb-block-words s) :element-type 'bit
                        :initial-element 0)
            (slot-value s 'map-source-log)
            (make-array (sb-block-words s) :element-type 'bit
                        :initial-element 0)
            (slot-value s 'map-source-weak)
            (make-array (sb-block-words s) :element-type 'bit
                        :initial-element 0)
            (slot-value s 'map-source-rc)
            (make-array (sb-block-words s) :element-type 'fixnum
                        :initial-element 0)))
    (unless (%sb-mb-matrices s)
      (setf (slot-value s (quote clamsara::mb-matrices))
            (make-array nsb :initial-element nil))
      (dotimes (i nsb)
        (setf (aref (%sb-mb-matrices s) i)
              (make-matrix-stratum (sb-words-per-mb s) mps)))
      (setf (slot-value s (quote clamsara::block-matrices))
            (make-array nmbs :initial-element nil))
      (dotimes (i nmbs)
        (setf (aref (%sb-block-matrices s) i)
              (make-matrix-stratum (%sb-block-words s) bpm)))
      (setf (slot-value s (quote clamsara::mb-root-bits))
            (make-array nsb :initial-element nil)
            (slot-value s (quote clamsara::reached-mbs))
            (make-array nsb :initial-element nil)
            (slot-value s (quote clamsara::pinned))
            (make-array nsb :element-type 'bit :initial-element 0))
      (dotimes (i nsb)
        (setf (aref (%sb-mb-root-bits s) i)
              (make-array mps :element-type 'bit :initial-element 0)
              (aref (%sb-reached-mbs s) i)
              (make-array mps :element-type 'bit :initial-element 0))))
    ;; The escape stratum is VM-registered; register once per VM.
    (let ((vm (space-vm s)))
      (when (and vm (not (vm-direct-stratum vm :block-escape)))
        (setf (slot-value s (quote clamsara::escape))
              (vm-register-stratum
               vm :block-escape
               (make-stratum :block-escape (%sb-block-words s) :u4
                             (vm-heap-size vm))))))))

(defun superblock-trace-object (s vm ref tracer trace-kind)
  (declare (ignore trace-kind))
  (let ((addr (ref-strip-or-self vm ref)))
    (unless (vm-direct-object-marked-p vm addr)
      (vm-direct-set-object-marked-p vm addr t)
      (tracer-enqueue tracer addr))
    addr))

(defmethod space-trace-object ((s superblock-space) vm ref tracer trace-kind)
  (superblock-trace-object s vm ref tracer trace-kind))

(defmethod space-prepare ((s superblock-space) vm cycle-kind)
  (declare (ignore cycle-kind))
  (s-clear (vm-direct-stratum vm :mark))
  s)

;; ---- escape bits (block-granularity stratum) -----------------------------

(defun sb-escape-value (s vm block-index)
  (declare (optimize (speed 3) (safety 0)))
  (let ((escape (or (%sb-escape s) (vm-direct-stratum vm :block-escape))))
    (if escape (s-get escape (sb-block-base s block-index)) 0)))
(defun (setf sb-escape-value) (bits s vm block-index)
  (declare (optimize (speed 3) (safety 0)))
  (let ((escape (or (%sb-escape s) (vm-direct-stratum vm :block-escape))))
    (when escape (s-set escape (sb-block-base s block-index) bits))
    bits))

;; ---- barrier maintenance of the hierarchy relations ----------------------
;; strata.tex §5.1: the write barrier sets M[block(src), block(dst)] on a
;; cross-region store; newgc.txt §3/§6: per-block direction bits, and the
;; pointed-to-by-older bit when the source metablock is older.

(defun superblock-rebuild-relations (s vm)
  "Rebuild hierarchy matrices after relocation copied object payloads.
VM-OBJECT-COPY moves slots without invoking the mutator write barrier, so a
compaction destination can otherwise have stale/empty block and metablock
relations.  This boot-warmed direct walk is allocation-free and uses declared
layout maps; weak referent slot zero is not a strong hierarchy edge."
  (let ((mb-matrices (%sb-mb-matrices s))
        (block-matrices (%sb-block-matrices s))
        (escape (or (%sb-escape s) (vm-direct-stratum vm :block-escape)))
        (os (vm-object-start vm))
        (stats (%stats-for-vm vm))
        (rows 0))
    (when mb-matrices
      (dotimes (i (length mb-matrices))
        (let ((matrix (aref mb-matrices i)))
          (when matrix
            (matrix-clear-all matrix)
            (incf rows (matrix-regions matrix))))))
    (when block-matrices
      (dotimes (i (length block-matrices))
        (let ((matrix (aref block-matrices i)))
          (when matrix
            (matrix-clear-all matrix)
            (incf rows (matrix-regions matrix))))))
    ;; A clear-and-reconstruct pass defines every matrix row, including empty
    ;; rows.  Count those actual rows once, not the number of source objects.
    (when stats (stats-event stats :relation-rows-rebuilt rows))
    (when escape (s-clear escape))
    (when os
      (loop for address from (space-base-address s)
            below (space-end-address s)
            when (s-test-bit os address)
              do (let ((slots (vm-reference-slots vm address))
                       (weak-p (weak-pointer-p vm address)))
                   (if slots
                       (loop for slot across slots
                             when (or (not weak-p) (not (zerop slot)))
                               do (superblock-note-write
                                   s vm address
                                   (ref-strip-or-self
                                    vm (vm-direct-object-reference vm address slot))))
                       (dotimes (slot (vm-direct-object-reference-count vm address))
                         (when (or (not weak-p) (not (zerop slot)))
                           (superblock-note-write
                            s vm address
                            (ref-strip-or-self
                             vm (vm-direct-object-reference vm address slot))))))))))
  s)

(defun superblock-note-write (s vm src new)
  "Maintain hierarchy relations for a mature-space store SRC<-NEW.
   Both endpoints must belong to S: a mature source can point to a nursery
   or LOS object, but that edge has no mature block-matrix representation."
  (sb-clear-fine-for-address s src)
  (when (and (space-direct-contains-p s src)
             (space-direct-contains-p s new))
    (let* ((src-block (sb-block-index s src))
           (dst-block (sb-block-index s new))
           (src-mb (floor src-block (%sb-bpm s)))
           (dst-mb (floor dst-block (%sb-bpm s)))
           (src-sb (floor src-mb (%sb-mps s)))
           (dst-sb (floor dst-mb (%sb-mps s))))
      (when (/= src-sb dst-sb)
        ;; to-foreign on the source block, from-foreign on the target block
        (setf (sb-escape-value s vm src-block)
              (logior (sb-escape-value s vm src-block) +escape-to-foreign+)
              (sb-escape-value s vm dst-block)
              (logior (sb-escape-value s vm dst-block) +escape-from-foreign+)))
      (cond
        ((/= src-mb dst-mb)
         (matrix-set (aref (%sb-mb-matrices s) src-sb)
                     (sb-local-mb s src-mb) (sb-local-mb s dst-mb)))
        ((/= src-block dst-block)
         (matrix-set (aref (%sb-block-matrices s) src-mb)
                     (sb-local-block s src-block) (sb-local-block s dst-block))))
      (when (and (= src-sb dst-sb) (< src-mb dst-mb))
        (setf (sb-escape-value s vm dst-block)
              (logior (sb-escape-value s vm dst-block)
                      +escape-pointed-to-by-older+)))
      nil)))
;; ---- reclamation: RC release -> search -> precise-trace sweep ------------

(defun superblock-pinned (s vm)
  "SBs that must survive RC release this cycle: superblock 0 (persistent root
  set) plus every SB containing a marked (live) object.  The precise trace is
  the authority; the count table only releases SBs the trace agrees are dead."
  (declare (optimize (speed 3) (safety 0)))
  (let ((pinned (%sb-pinned s))
        (mark (vm-direct-stratum vm :mark))
        (os (vm-object-start vm))
        (base (space-base-address s))
        (end (space-end-address s)))
    (declare (type fixnum base end))
    (fill pinned 0)
    (setf (sbit pinned 0) 1)
    (when (and mark os)
      (loop for address fixnum from base below end
            when (and (s-test-bit os address) (s-test-bit mark address))
              do (setf (sbit pinned (sb-index s address)) 1)))
    pinned))

(defun superblock-release-zero-count (s vm)
  "Stage 1 (cheapest, largest gain): a superblock whose count reached zero is
  released wholesale — every block returned to the free list, object identity
  forgotten.  Pinned superblocks (root set, live objects) are excluded."
  (declare (optimize (speed 3) (safety 0)))
  (let ((counts (%sb-refcounts s))
        (pinned (superblock-pinned s vm))
        (a (space-allocator s)))
    (let ((nsb (%sb-count s))
          (bpm (%sb-bpm s))
          (mps (%sb-mps s))
          (nblocks (%sb-block-count s)))
      (declare (type fixnum nsb bpm mps nblocks))
      (dotimes (i nsb)
        (when (and (plusp i) (zerop (aref counts i)) (zerop (sbit pinned i)))
          (dotimes (mb mps)
            (let ((mb-base (the fixnum (+ (the fixnum (* i mps bpm))
                                           (the fixnum (* mb bpm))))))
              (dotimes (b bpm)
                (let ((bi (the fixnum (+ mb-base b))))
                  (when (< bi nblocks)
                    (hierarchical-free-block a vm bi)))))))))
    s))

(defun superblock-seed-root-reference (s ref)
  "Seed the hierarchy for one root and return it unchanged.
Explicit root regions are already filtered by VM-SCAN-ROOTS, so this helper
also keeps the hierarchy's root set consistent with the tracing root set."
  (let ((vm (space-vm s)))
    (when (and (integerp ref) (plusp ref)
               (space-direct-contains-p s (ref-strip-or-self vm ref)))
      (let* ((address (ref-strip-or-self vm ref))
             (mi (sb-mb-index s address))
             (sb (floor mi (%sb-mps s))))
        (when (< sb (%sb-count s))
          (setf (sbit (aref (%sb-mb-root-bits s) sb)
                      (sb-local-mb s mi)) 1))))
  ref))

(defun superblock-root-mbs (s vm)
  "Seed bits per SB: metablocks containing root references or nursery-edge
  targets.  A superset of the trace seeds keeps the closure a valid bound."
  (let* ((plan (vm-plan vm))
         (nursery (and plan (plan-nursery plan)))
         (nsb (%sb-count s)))
    (dotimes (i nsb) (fill (aref (%sb-mb-root-bits s) i) 0))
    ;; This includes the legacy root vector and every explicit
    ;; simulator/backend root region, applying each region's map.
    (vm-direct-scan-roots vm s #'superblock-seed-root-reference)
    (when (and nursery (vm-object-start vm))
      (let ((os (vm-object-start vm)))
        (loop for address from (space-base-address nursery)
              below (space-end-address nursery)
              when (s-test-bit os address)
                do (superblock-seed-nursery-object s vm address))))
    s))

(defun superblock-seed-nursery-object (s vm address)
  "Seed the per-SB metablock root bits with every mature reference held by
  the nursery object at ADDRESS.  Top-level: no host closure per object."
  (let ((slots (vm-reference-slots vm address)))
    (flet ((seed (ref)
            (when (and (plusp ref) (space-direct-contains-p s ref))
               (let* ((mi (sb-mb-index s ref))
                      (sb (floor mi (%sb-mps s))))
                 (when (< sb (%sb-count s))
                   (setf (sbit (aref (%sb-mb-root-bits s) sb)
                               (sb-local-mb s mi)) 1))))))
      (if slots
          (loop for i across slots
                do (seed (vm-direct-object-reference vm address i)))
          (dotimes (i (vm-direct-object-reference-count vm address))
            (seed (vm-direct-object-reference vm address i))))))
  address)

(defun superblock-search (s vm)
  "Stage 2: metablock-granularity search.  Close each live superblock's
  local matrix from its roots, adding metablocks marked as targets of
  cross-superblock edges until a fixed point."
  (let* ((nsb (%sb-count s))
         (mps (%sb-mps s))
         (bpm (%sb-bpm s))
         (nmb (%sb-mb-count s))
         (nblocks (%sb-block-count s))
         (a (space-allocator s)))
    (superblock-root-mbs s vm)
    (dotimes (sb nsb)
      (let ((reached (aref (%sb-reached-mbs s) sb))
            (roots (aref (%sb-mb-root-bits s) sb)))
        (fill reached 0)
        (when (hierarchical-sb-in-use-p a sb)
          ;; Iterate closure and foreign-target seeding to a fixed point.
          ;; MB-MATRICES are per-SB and use local indices, while block and
          ;; escape strata use global indices.  Keep those coordinate systems
          ;; explicit; using MI directly skips every nonzero superblock.
          (loop repeat mps
                for added-p = nil
                do (let ((closure
                           (matrix-closure
                            (aref (%sb-mb-matrices s) sb) roots)))
                     (replace reached closure))
                   (dotimes (local-mi mps)
                     (let ((global-mi (+ (* sb mps) local-mi)))
                       (when (and (< global-mi nmb)
                                  (zerop (sbit reached local-mi)))
                         ;; A from-foreign target is a root for this SB's
                         ;; closure.  Its source is in another SB, so no local
                         ;; matrix row can describe that edge.
                         (let ((foreign-p nil))
                           (dotimes (b bpm)
                             (let ((bi (+ (* global-mi bpm) b)))
                               (when (and (< bi nblocks)
                                          (logtest (sb-escape-value s vm bi)
                                                   +escape-from-foreign+))
                                 (setf foreign-p t)
                                 (return))))
                           (when foreign-p
                             (setf (sbit roots local-mi) 1
                                   added-p t))))))
                unless added-p return nil))))
    s))
(defun superblock-sweep (s vm)
  "Stage 3: after the precise trace (marks set), free every dead block.
  Non-root superblocks are bounded by the search results: only metablocks
  reached by the closure are examined.  Superblock 0 is never released
  wholesale, but its individual dead blocks are swept too; otherwise an
  unreachable cycle allocated beside the persistent root set would survive
  forever.  This block-level sweep is the periodic full-trace backup that
  reclaims cycle garbage inside a still-counted superblock."
  (let* ((a (space-allocator s))
         (mark (vm-direct-stratum vm :mark))
         (os (vm-object-start vm))
         (nsb (%sb-count s))
         (bpm (%sb-bpm s))
         (mps (%sb-mps s)))
    (when (and mark os)
      (dotimes (sb nsb)
        ;; SB0 is protected from whole-superblock RC release, not from
        ;; precise block sweep.  For it, inspect every metablock so cycles
        ;; with no root-seeded closure are reclaimable.
        (let ((reached (aref (%sb-reached-mbs s) sb)))
          (dotimes (m mps)
            (when (or (zerop sb)
                      (and reached (eql 1 (sbit reached m))))
                ;; within a reached metablock the mark stratum is the
                ;; authority for liveness, but a span (multi-block) run is
                ;; reclaimed atomically: tail blocks inherit their root
                ;; block's live count, never judged independently
                (dotimes (b bpm)
                  (let ((bi (+ (* sb mps bpm) (* m bpm) b)))
                    (when (and (< bi (%sb-block-count s))
                               (hierarchical-block-in-use-p a bi))
                      (let ((root (aref (hierarchical-allocator-span-root a) bi)))
                        (unless (and (>= root 0) (/= root bi))
                          ;; root or single block: judge liveness.  Tail
                          ;; blocks are skipped (the root's pass reclaims
                          ;; the whole run), but iteration CONTINUES so a
                          ;; later dead span in the same metablock is still
                          ;; swept.
                          (let ((live-p nil))
                            (loop for address from (sb-block-base s bi)
                                  below (+ (sb-block-base s bi)
                                           (%sb-block-words s))
                                  when (and (s-test-bit os address)
                                            (s-test-bit mark address))
                                    do (setf live-p t) (return))
                            (unless live-p
                              (hierarchical-free-block
                              a vm bi)))))))))))))))

(defun superblock-map (s vm)
  "Map one fragmented mature block into a free virtual block without copying.

The simulator uses the software MMU's physical-page table for the same
copy-free operation a target VM performs with page-table remapping.  The
source and destination virtual pages swap physical backing; object metadata
is moved in the side tables, and the ordinary forwarding/healing path repairs
all references before the source block is recycled.  A span and superblock 0
are excluded because their ownership/grace rules are different."
  (let* ((a (space-allocator s))
         (mark (vm-direct-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm))
         (bw (%sb-block-words s))
         (source nil)
         (source-fragmentation 0))
    (when (and (typep a 'hierarchical-allocator)
               mark os
               (typep vm 'ring0-mixin))
      ;; T0 direct accesses do not observe a page-table change.  The simulator
      ;; therefore arms its software MMU at the first map; real VMs provide
      ;; the same virtual-address semantics through their binding.
      (when (typep vm 'virtual-memory-mixin)
        (mmu-arm vm :clear-dirty nil))
      (loop for bi from 1 below (%sb-block-count s)
            when (and (hierarchical-block-in-use-p a bi)
                      (minusp (aref (hierarchical-allocator-span-root a) bi)))
              do (let* ((base (sb-block-base s bi))
                        (limit (+ base bw))
                        (cursor (hierarchical-block-cursor a bi))
                        (live-words 0))
                   (loop for address from base below limit
                         when (and (s-test-bit os address)
                                   (s-test-bit mark address))
                           do (incf live-words
                                    (vm-direct-object-total-words vm address)))
                   (let ((fragmentation (- (- cursor base) live-words)))
                     (when (and (plusp live-words)
                                (> fragmentation source-fragmentation))
                       (setf source bi
                             source-fragmentation fragmentation)))))
      (when source
        (let ((destination (hierarchical-acquire-block a)))
          (when destination
            (let* ((source-base (sb-block-base s source))
                   (destination-base (sb-block-base s destination))
                   (source-page (address-page source-base))
                   (destination-page (address-page destination-base))
                   (source-physical (vm-direct-page-physical vm source-page))
                   (destination-physical
                     (vm-direct-page-physical vm destination-page))
                   (starts (%sb-map-source-starts s))
                   (sizes (%sb-map-source-sizes s))
                   (saved-mark (%sb-map-source-mark s))
                   (ages (%sb-map-source-age s))
                   (public (%sb-map-source-public s))
                   (log (%sb-map-source-log s))
                   (weak (%sb-map-source-weak s))
                   (rc (%sb-map-source-rc s))
                   (age-stratum (vm-direct-stratum vm :age))
                   (public-stratum (vm-direct-stratum vm :public))
                   (log-stratum (vm-direct-stratum vm :log))
                   (weak-stratum (vm-direct-stratum vm :weak))
                   (source-end (+ source-base bw))
                   (destination-cursor destination-base))
              ;; Snapshot all source boundaries and side metadata while the
              ;; source virtual page still names its original physical page.
              (fill starts 0)
              (fill sizes 0)
              (fill saved-mark 0)
              (fill ages 0)
              (fill public 0)
              (fill log 0)
              (fill weak 0)
              (fill rc 0)
              (loop for address from source-base below source-end
                    when (s-test-bit os address)
                      do (let ((offset (- address source-base)))
                           (setf (sbit starts offset) 1
                                 (aref sizes offset)
                                 (vm-direct-object-total-words vm address)
                                 (sbit saved-mark offset)
                                 (if (s-test-bit mark address) 1 0)
                                 (aref rc offset) (vm-direct-object-rc vm address))
                           (when age-stratum
                             (setf (aref ages offset)
                                   (s-get age-stratum address)))
                           (when public-stratum
                             (setf (sbit public offset)
                                   (if (s-test-bit public-stratum address)
                                       1 0)))
                           (when log-stratum
                             (setf (sbit log offset)
                                   (if (s-test-bit log-stratum address)
                                       1 0)))
                           (when weak-stratum
                             (setf (sbit weak offset)
                                   (if (s-test-bit weak-stratum address)
                                       1 0)))))
              ;; Swap page backing.  No payload word is copied.
              (fwd-clear vm)
              (vm-remap vm destination-page source-physical 1)
              (vm-remap vm source-page destination-physical 1)
              (vm-flush-tlb vm source-page 2)
              ;; The source virtual range now names the old destination page,
              ;; so remove its logical object identity before healing.  The
              ;; forwarding table is populated afterwards and is the sole
              ;; stale-reference witness during the correction window.
              (vm-clear-metadata-range vm source-base source-end)
              (loop for offset fixnum below bw
                    when (= 1 (sbit starts offset))
                      do (let* ((old (+ source-base offset))
                                (new (+ destination-base offset))
                                (words (aref sizes offset))
                                (live (= 1 (sbit saved-mark offset))))
                           (when live
                             (setf (aref fwd old) new
                                   destination-cursor
                                   (max destination-cursor (+ new words)))
                             (s-set-bit os new)
                             (s-set-bit mark new)
                             (when age-stratum
                               (s-set age-stratum new (aref ages offset)))
                             (when public-stratum
                               (if (= 1 (sbit public offset))
                                   (s-set-bit public-stratum new)
                                   (s-clear-bit public-stratum new)))
                             (when log-stratum
                               (if (= 1 (sbit log offset))
                                   (s-set-bit log-stratum new)
                                   (s-clear-bit log-stratum new)))
                             (when weak-stratum
                               (if (= 1 (sbit weak offset))
                                   (s-set-bit weak-stratum new)
                                   (s-clear-bit weak-stratum new)))
                             (vm-direct-set-object-rc vm new (aref rc offset)))))
              (setf (hierarchical-block-cursor a destination)
                    destination-cursor)
              (heal-every-space (vm-plan vm) fwd)
              (vm-direct-memory-fence vm)
              (hierarchical-free-block a vm source)
              (superblock-rebuild-relations s vm)
              (incf (slot-value s 'map-pages))
              (let ((stats (%stats-for-vm vm)))
                (when stats (stats-event stats :pages-mapped 1)))
              (fill fwd 0)
              t))))))
  s)

(defun superblock-compact (s vm)
  "Block compaction (heap.tex §6, the expensive last resort): move the live
  objects of the most fragmented in-use block into a fresh block, recording
  old->new in the off-heap forwarding table, then heal every reference
  (roots, nursery slots, mature slots) before releasing the source block."
  (let* ((a (space-allocator s))
         (mark (vm-direct-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm)))
    (when (and mark os (hierarchical-fresh-available-p a))
      (let ((source nil) (source-frag 0))
        (dotimes (bi (%sb-block-count s))
          (when (and (hierarchical-block-in-use-p a bi)
                     (plusp (sb-index s (sb-block-base s bi)))) ; SB0 pinned
            (let* ((base (sb-block-base s bi))
                   (limit (+ base (%sb-block-words s)))
                   (cursor (hierarchical-block-cursor a bi))
                   (live-words 0))
              (loop for address from base below limit
                    when (and (s-test-bit os address) (s-test-bit mark address))
                      do (incf live-words
                               (vm-direct-object-total-words vm address)))
              (let ((frag (- (- cursor base) live-words)))
                (when (and (plusp live-words) (> frag source-frag))
                  (setf source bi source-frag frag))))))
        (when (and source (>= source-frag (ash (%sb-block-words s) -1)))
          ;; copy survivors into a fresh destination block
          (let* ((dest (hierarchical-acquire-block a))
                 (dcur (sb-block-base s dest))
                 (dlim (+ dcur (%sb-block-words s))))
            (loop for address from (sb-block-base s source)
                  below (+ (sb-block-base s source) (%sb-block-words s))
                  when (and (s-test-bit os address) (s-test-bit mark address))
                    do (let ((words (vm-direct-object-total-words vm address)))
                         (when (> (+ dcur words) dlim)
                           (error 'clamsara-error
                                  :message "superblock compaction overflow"))
                         (vm-direct-object-copy vm address dcur)
                         (vm-direct-set-object-marked-p vm dcur t)
                         (setf
                               (aref fwd address) dcur)
                         (incf dcur words)))
            (setf (hierarchical-block-cursor a dest) dcur)
            ;; heal all live references through the forwarding table --
            ;; INCLUDING the destination block: vm-object-copy reproduced
            ;; the source payloads, so destination slots still hold the old
            ;; source addresses and must be healed before the source dies.
            ;; Healing covers every plan space: nursery, LOS, and mature.
            (heal-every-space (vm-plan vm) fwd)
            (vm-direct-memory-fence vm)
            (hierarchical-free-block a vm source)
            ;; Recompute relations after source metadata is cleared and all
            ;; destination payloads have been healed.
            (superblock-rebuild-relations s vm)
            (fill fwd 0))))))
  s)

(defun %superblock-space-reclaim (s vm cycle-kind)
  ;; heap.tex §6: run the hierarchy in cost order -- refcount release first
  ;; (cheapest, largest gain), then search closure over reached metablocks,
  ;; then block compaction (the expensive last resort, run rarely).
  (superblock-release-zero-count s vm)
  (superblock-search s vm)
  (superblock-sweep s vm)
  ;; Map is the copy-free middle tier; only the rare residual fragmentation
  ;; reaches block move below it.
  (superblock-map s vm)
  (when (eq cycle-kind :major)
    (superblock-compact s vm))
  s)

(defmethod space-reclaim ((s superblock-space) vm cycle-kind)
  (%superblock-space-reclaim s vm cycle-kind))

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
;;
;; DEFSTRUCT, not DEFCLASS: struct accessors compile to raw memory reads, so
;; the collection path never pays PCL slot-accessor dispatch (the same reason
;; IMMIX-BLOCK is a struct).  The generic ALLOC/FREE/COALESCE/ALLOCATOR-RESET
;; methods dispatch on the struct type name instead.

(defstruct (hierarchical-allocator
             (:constructor %make-hierarchical-allocator
                           (vm space start limit)))
  (vm nil :type (or vm-binding null) :read-only t)
  (space nil :read-only t)
  (start 0 :type word-address :read-only t)
  (limit 0 :type word-address :read-only t)
  (block-words 0 :type fixnum)
  (block-count 0 :type fixnum)
  ;; per-block bump cursor; -1 means the block is on the free list
  (cursors nil :type (or (simple-array fixnum (*)) null))
  (free-blocks nil :type (or (and (vector fixnum) (not simple-array)) null))
  (next-fresh 0 :type fixnum)
  (current nil)
  ;; span-root[i] = root block index of the multi-block run block i
  ;; belongs to, or -1 (mirrors the immix allocator's span tracking)
  (span-root nil :type (or (simple-array fixnum (*)) null)))

(defmethod component-validate ((a hierarchical-allocator))
  (unless (and (<= 0 (hierarchical-allocator-start a))
               (<= (hierarchical-allocator-start a)
                   (hierarchical-allocator-limit a))
               (plusp (hierarchical-allocator-block-words a))
               (arrayp (hierarchical-allocator-cursors a)))
    (error 'plan-incompatible :plan a
           :message "hierarchical allocator has invalid geometry"))
  a)

(defun make-hierarchical-allocator (vm space)
  "Build the hierarchical allocator for SPACE, wiring the block geometry."
  (let* ((count (floor (- (space-end-address space)
                          (space-base-address space))
                       (sb-block-words space)))
         (a (%make-hierarchical-allocator
             vm space (space-base-address space)
             (space-end-address space))))
    (setf (hierarchical-allocator-block-words a) (sb-block-words space)
          (hierarchical-allocator-block-count a) count
          (hierarchical-allocator-cursors a)
          (make-array count :element-type 'fixnum :initial-element -1)
          (hierarchical-allocator-free-blocks a)
          (make-array count :element-type 'fixnum
                      :initial-element 0 :fill-pointer 0)
          (hierarchical-allocator-span-root a)
          (make-array count :element-type 'fixnum :initial-element -1))
    a))

(declaim (inline hierarchical-block-in-use-p hierarchical-block-cursor
                 hierarchical-block-base hierarchical-fresh-available-p
                 hierarchical-clear-relations
                 hierarchical-clear-empty-metablock-relations))

(defun hierarchical-block-in-use-p (a block-index)
  (and (< block-index (hierarchical-allocator-block-count a))
       (>= (aref (hierarchical-allocator-cursors a) block-index) 0)))
(defun hierarchical-block-cursor (a block-index)
  (aref (hierarchical-allocator-cursors a) block-index))
(defun (setf hierarchical-block-cursor) (cursor a block-index)
  (setf (aref (hierarchical-allocator-cursors a) block-index) cursor))
(defun hierarchical-fresh-available-p (a)
  (< (hierarchical-allocator-next-fresh a)
     (hierarchical-allocator-block-count a)))

(defun hierarchical-block-base (a block-index)
  (declare (type hierarchical-allocator a) (type fixnum block-index)
           (optimize (speed 3) (safety 0)))
  (let ((start (hierarchical-allocator-start a))
        (log-bw (1- (integer-length
                     (hierarchical-allocator-block-words a)))))
    (declare (type fixnum start log-bw))
    (the fixnum (+ start (ash block-index log-bw)))))

(defun hierarchical-acquire-block (a)
  "Pop a recycled block, else carve the next never-used block."
  (let ((free (hierarchical-allocator-free-blocks a)))
    (cond
      ((plusp (fill-pointer free))
       (decf (fill-pointer free))
       (aref free (fill-pointer free)))
      ((hierarchical-fresh-available-p a)
       (prog1 (hierarchical-allocator-next-fresh a) (incf (hierarchical-allocator-next-fresh a)))))))

(defun hierarchical-free-block (a vm block-index)
  "Return an in-use block to the free list, forget its object identity, and
  clear its hierarchy relations: the block's row/column in the points-to
  matrices and its escape bits (strata.tex §5: a stale M[i,j] no longer means
  'region i may reference region j')."
  (declare (type hierarchical-allocator a) (type fixnum block-index)
           (optimize (speed 3) (safety 0)))
  (when (hierarchical-block-in-use-p a block-index)
    (let ((root (aref (hierarchical-allocator-span-root a) block-index))
          (bw (hierarchical-allocator-block-words a)))
      (declare (type fixnum root bw))
      (cond
        ;; a tail block is never freed individually; the run is reclaimed
        ;; atomically when its root block dies: do nothing
        ((and (>= root 0) (/= root block-index))
         nil)
        ;; freeing a run's root releases the whole contiguous run, with the
        ;; same hierarchy-relation cleanup as a single block
        ((and (>= root 0) (= root block-index))
         (loop for bi fixnum from root below (hierarchical-allocator-block-count a)
               do (let ((r2 (aref (hierarchical-allocator-span-root a) bi)))
                    (unless (and (>= r2 0) (= r2 root)) (return))
                    (vm-clear-metadata-range
                     vm (hierarchical-block-base a bi)
                     (the fixnum (+ (hierarchical-block-base a bi) bw)))
                    (hierarchical-clear-relations a vm bi)
                    (setf (aref (hierarchical-allocator-cursors a) bi) -1
                          (aref (hierarchical-allocator-span-root a) bi) -1)
                    ;; A metablock relation remains valid while another
                    ;; block in the MB is in use.  Once this block was the
                    ;; last one, remove the parent SB's MB row/column too.
                    (hierarchical-clear-empty-metablock-relations a bi)
                    (unless (vector-push bi (hierarchical-allocator-free-blocks a))
                      (error 'heap-exhausted :requested-size 1
                             :space :block-free-list))
                    (when (eql (hierarchical-allocator-current a) bi)
                      (setf (hierarchical-allocator-current a) nil)))))
        ;; ordinary single-block free
        (t
         (vm-clear-metadata-range
          vm (hierarchical-block-base a block-index)
          (the fixnum (+ (hierarchical-block-base a block-index) bw)))
         (hierarchical-clear-relations a vm block-index)
         (setf (aref (hierarchical-allocator-cursors a) block-index) -1)
         ;; Keep the MB-level remembered set until its final block dies.
         (hierarchical-clear-empty-metablock-relations a block-index)
         (unless (vector-push block-index (hierarchical-allocator-free-blocks a))
           (error 'heap-exhausted :requested-size 1 :space :block-free-list))
         (when (eql (hierarchical-allocator-current a) block-index)
           (setf (hierarchical-allocator-current a) nil))))))
  block-index)


(defun hierarchical-clear-relations (a vm block-index)
  "Clear BLOCK-INDEX's hierarchy relations: its block points-to matrix
  row/column and its escape bits (strata.tex §5)."
  (let ((s (hierarchical-allocator-space a)))
    (when (typep s 'superblock-space)
      (let* ((src-mb (floor block-index (%sb-bpm s)))
             (local-block (sb-local-block s block-index)))
        (let ((bm (and (%sb-block-matrices s)
                       (< src-mb (length (%sb-block-matrices s)))
                       (aref (%sb-block-matrices s) src-mb))))
          (when bm
            (dotimes (j (%sb-bpm s))
              (matrix-clear bm local-block j)
              (matrix-clear bm j local-block)))
          (setf (sb-escape-value s vm block-index) 0)))))
  block-index)

(defun hierarchical-clear-empty-metablock-relations (a block-index)
  "Clear the parent SB MB row/column when BLOCK-INDEX emptied its MB.

The final MB in a space can be partial, so only blocks below the allocator's
actual block count participate in the emptiness check.  MB matrices are local
to their parent SB; the matrix for that SB is therefore the only one that can
contain this MB's same-SB relations."
  (declare (type hierarchical-allocator a) (type fixnum block-index)
           (optimize (speed 3) (safety 0)))
  (let ((s (hierarchical-allocator-space a)))
    (when (typep s 'superblock-space)
      (let* ((bpm (%sb-bpm s))
             (mb (floor block-index bpm))
             (base (* mb bpm))
             (nblocks (%sb-block-count s))
             (empty-p t))
        ;; Do not treat the unused tail of a partial final MB as live.
        (dotimes (b bpm)
          (let ((bi (+ base b)))
            (when (and (< bi nblocks)
                       (hierarchical-block-in-use-p a bi))
              (setf empty-p nil)
              (return))))
        (when empty-p
          (let* ((mps (%sb-mps s))
                 (sb (floor mb mps))
                 (local-mb (mod mb mps))
                 (matrices (%sb-mb-matrices s)))
            (when (and matrices (< sb (length matrices)))
              (let ((matrix (aref matrices sb)))
                (when matrix
                  (dotimes (j mps)
                    (matrix-clear matrix local-mb j)
                    (matrix-clear matrix j local-mb))))))))))
  block-index)

(defun hierarchical-sb-in-use-p (a sb)
  (let* ((s (hierarchical-allocator-space a))
         (bpm (%sb-bpm s))
         (mps (%sb-mps s)))
    (loop for m below mps
          thereis (loop for b below bpm
                        for bi = (+ (* sb mps bpm) (* m bpm) b)
                        when (and (< bi (hierarchical-allocator-block-count a))
                                  (hierarchical-block-in-use-p a bi))
                          return t))))

(defun hierarchical-bump (a block-index size)
  (let ((base (hierarchical-block-base a block-index))
        (cursor (aref (hierarchical-allocator-cursors a) block-index)))
    (when (and (>= cursor 0)
               (<= (+ cursor size) (+ base (hierarchical-allocator-block-words a))))
      (setf (aref (hierarchical-allocator-cursors a) block-index) (+ cursor size))
      cursor)))

(defmethod alloc ((a hierarchical-allocator) size)
  (if (<= size (hierarchical-allocator-block-words a))
      ;; small object: never bump into a span block — span runs are
      ;; exclusive and reclaimed atomically with their root
      (let ((candidate
              (or (and (hierarchical-allocator-current a)
                       (minusp (aref (hierarchical-allocator-span-root a) (hierarchical-allocator-current a)))
                       (hierarchical-allocator-current a))
                  (loop for bi below (hierarchical-allocator-block-count a)
                        when (and (hierarchical-block-in-use-p a bi)
                                  (minusp (aref (hierarchical-allocator-span-root a) bi)))
                          return bi))))
        (or (and candidate (hierarchical-bump a candidate size))
            (let ((block (hierarchical-acquire-block a)))
              (when block
                (setf (aref (hierarchical-allocator-cursors a) block)
                      (hierarchical-block-base a block)
                      (hierarchical-allocator-current a) block)
                (hierarchical-bump a block size)))))
      ;; Large object: carve contiguous never-used blocks (no recycled runs);
      ;; the run is span-tracked so the sweep reclaims it atomically.
      (let ((pages (ceiling size (hierarchical-allocator-block-words a))))
        (when (<= (+ (hierarchical-allocator-next-fresh a) pages) (hierarchical-allocator-block-count a))
          (let ((base (hierarchical-block-base a (hierarchical-allocator-next-fresh a)))
                (first-block (hierarchical-allocator-next-fresh a))
                (remaining size))
            (dotimes (k pages)
              (let ((bi (+ (hierarchical-allocator-next-fresh a) k)))
                (setf (aref (hierarchical-allocator-cursors a) bi)
                      (+ (hierarchical-block-base a bi)
                         (if (< remaining (hierarchical-allocator-block-words a))
                             remaining
                             (hierarchical-allocator-block-words a))))
                (setf (aref (hierarchical-allocator-span-root a) bi) first-block)
                (decf remaining (hierarchical-allocator-block-words a))))
            (incf (hierarchical-allocator-next-fresh a) pages)
            base)))))

(defmethod free ((a hierarchical-allocator) addr size) (declare (ignore addr size)) nil)
(defmethod coalesce ((a hierarchical-allocator)) nil)

(defmethod allocator-reset ((a hierarchical-allocator))
  (vm-clear-metadata-range (hierarchical-allocator-vm a)
                           (hierarchical-allocator-start a)
                           (hierarchical-allocator-limit a))
  (fill (hierarchical-allocator-cursors a) -1)
  (when (hierarchical-allocator-span-root a)
    (fill (hierarchical-allocator-span-root a) -1))
  (setf (fill-pointer (hierarchical-allocator-free-blocks a)) 0
        (hierarchical-allocator-next-fresh a) 0
        (hierarchical-allocator-current a) nil))

(defun hierarchical-occupied-words (a)
  (loop for bi below (hierarchical-allocator-block-count a)
        when (hierarchical-block-in-use-p a bi)
          sum (- (aref (hierarchical-allocator-cursors a) bi)
                 (hierarchical-block-base a bi))))
