(in-package #:clamsara)

;;; --- Space Traits ---
;;; Mixin classes providing default implementations of the space protocol.

;;; --- Collectable-Space Mixin ---

(defclass collectable-space ()
  ()
  (:documentation "Base trait: the space participates in collection."))

;;; --- Copying-Space Trait ---

(defclass copying-space-trait (collectable-space)
  ((from-space-p :initform t :accessor copying-from-space-p)
   (partner-space :initform nil :accessor copying-partner-space))
  (:documentation "Semispace copying: evacuate live objects to partner."))

(defmethod space-trace-object ((space copying-space-trait) vm ref tracer
                               &key cycle-kind trace-kind copy-semantics)
  (declare (ignore cycle-kind trace-kind copy-semantics))
  (when (and (copying-from-space-p space)
             (vm-address-in-space-p vm ref space))
    (let ((to (copying-partner-space space)))
      (when to
        (let ((forwarded-p (vm-object-is-forwarded-p vm ref)))
          (unless forwarded-p
            (let* ((n-words (vm-object-total-words vm ref))
                   (alloc (space-allocator to))
                   (dst (alloc alloc n-words)))
              (when (null dst)
                (error 'heap-exhausted :message "To-space exhausted during evacuation"))
              (vm-object-copy vm ref dst)
              (setf (vm-object-forwarding-pointer vm ref) dst)))
          (let ((result (or (vm-object-forwarding-pointer vm ref) ref)))
            (when (and tracer (not forwarded-p))
              (tracer-enqueue tracer result))
            result))))))

(defmethod space-prepare ((space copying-space-trait) vm &key cycle-kind)
  (declare (ignore vm cycle-kind))
  (unless (copying-from-space-p space)
    (let ((alloc (space-allocator space)))
      (when (typep alloc 'bump-allocator)
        (let* ((start (* (space-start-page space) +page-size-words+))
               (end (* (+ (space-start-page space) (space-page-count space))
                       +page-size-words+)))
          (bump-allocator-reset alloc :cursor start :limit end))))))

(defmethod space-release ((space copying-space-trait) vm &key cycle-kind)
  (declare (ignore vm cycle-kind))
  (let ((partner (copying-partner-space space)))
    (when partner
      (rotatef (copying-from-space-p space)
               (copying-from-space-p partner)))))

(defmethod space-sweep ((space copying-space-trait) vm)
  (declare (ignore space vm))
  nil)

;;; --- Copy-Space (concrete class) ---

(defclass copy-space (copying-space-trait space)
  ()
  (:documentation "A copy space with a bump-pointer allocator."))

(defun make-copy-space (plan page-resource &key name size)
  (declare (ignore plan))
  (let* ((start-page (page-resource-get page-resource size :kind :boxed))
         (alloc (make-bump-allocator nil page-resource :alignment 1))
         (space (make-instance 'copy-space
                  :name name :kind :copy
                  :start-page start-page :page-count size
                  :allocator alloc :page-resource page-resource)))
    (bump-allocator-reset alloc
                          :cursor (* start-page +page-size-words+)
                          :limit (* (+ start-page size) +page-size-words+))
    space))

;;; --- Mark-Sweep Space Trait ---

(defclass marksweep-space-trait (collectable-space)
  ()
  (:documentation "Mark-and-sweep: mark live, sweep dead to free-list."))

(defmethod space-trace-object ((space marksweep-space-trait) vm ref tracer
                               &key cycle-kind trace-kind copy-semantics)
  (declare (ignore space cycle-kind trace-kind copy-semantics))
  (unless (vm-object-is-marked-p vm ref)
    (setf (vm-object-is-marked-p vm ref) t)
    (when tracer
      (tracer-enqueue tracer ref))
    ref))

(defmethod space-prepare ((space marksweep-space-trait) vm &key cycle-kind)
  (declare (ignore space vm cycle-kind))
  nil)

(defmethod space-release ((space marksweep-space-trait) vm &key cycle-kind)
  (declare (ignore space vm cycle-kind))
  nil)

(defmethod space-sweep ((space marksweep-space-trait) vm)
  "Walk pages, rebuild free list."
  (let* ((start-page (space-start-page space))
         (n-pages (space-page-count space))
         (alloc (space-allocator space)))
    (free-list-allocator-clear alloc)
    (loop for page-idx from start-page below (+ start-page n-pages)
          for page-addr = (* page-idx +page-size-words+)
          for cursor = page-addr then cursor
          while (< cursor (+ page-addr +page-size-words+))
          do (if (and (vm-object-start-p vm (make-address cursor))
                      (vm-object-is-marked-p vm (make-address cursor)))
                 (let ((obj-size (vm-object-total-words vm (make-address cursor))))
                   (incf cursor obj-size))
                 (let ((free-start cursor)
                       (free-size 0))
                   (loop while (and (< cursor (+ page-addr +page-size-words+))
                                    (not (and (vm-object-start-p vm (make-address cursor))
                                              (vm-object-is-marked-p vm (make-address cursor)))))
                         do (incf cursor) (incf free-size))
                   (when (>= free-size 4)
                     (free alloc (make-address free-start) free-size)))))
    (vm-clear-all-mark-bits vm)))

(defmethod space-sweep-young ((space marksweep-space-trait) vm)
  "Sweep dead young objects. Mature dead objects are deferred to major GC.
Live-young-bytes is accumulated during tracing; this sweep counts
dead-mature-bytes and reclaims dead young objects."
  (let* ((start-page (space-start-page space))
         (n-pages (space-page-count space))
         (alloc (space-allocator space)))
    (free-list-allocator-clear alloc)
    (loop for page-idx from start-page below (+ start-page n-pages)
          for page-addr = (* page-idx +page-size-words+)
          for cursor = page-addr then cursor
          while (< cursor (+ page-addr +page-size-words+))
          do (let ((addr (make-address cursor)))
               (cond
                 ((and (vm-object-start-p vm addr)
                       (vm-object-is-marked-p vm addr))
                  (incf cursor (vm-object-total-words vm addr)))
                 ((vm-object-start-p vm addr)
                  (let ((obj-size (vm-object-total-words vm addr)))
                    (if (vm-object-is-logged-p vm addr)
                        (let ((free-start cursor))
                          (incf cursor obj-size)
                          (when (>= obj-size 4)
                            (free alloc (make-address free-start) obj-size)))
                        (progn
                          (incf cursor obj-size)
                          (incf (plan-dead-mature-bytes *active-plan*) obj-size)))))
                 (t
                  (let ((free-start cursor)
                        (free-size 0))
                    (loop while (and (< cursor (+ page-addr +page-size-words+))
                                     (not (vm-object-start-p vm (make-address cursor))))
                          do (incf cursor) (incf free-size))
                    (when (>= free-size 4)
                      (free alloc (make-address free-start) free-size)))))))
    (vm-clear-all-mark-bits vm)))

;;; --- Mark-Sweep Space (concrete class) ---

(defclass mark-sweep-space (marksweep-space-trait space)
  ()
  (:documentation "Space with mark-sweep trait."))

;;; --- Immix Space Trait ---

(defclass immix-space-trait (collectable-space)
  ()
  (:documentation "Immix mark-region: block and line granularity."))

;;; --- Immix Constants ---

(defconstant +immix-lines-per-block+ +cards-per-page+
  "Number of lines per block (32).")

(defconstant +immix-line-size-words+ +card-size-words+
  "Words per line (128).")

(defconstant +immix-block-size-words+ +page-size-words+
  "Words per block (4096 = page size).")

(defmethod space-trace-object ((space immix-space-trait) vm ref tracer
                               &key cycle-kind trace-kind copy-semantics)
  (declare (ignore cycle-kind trace-kind copy-semantics))
  (unless (vm-object-is-marked-p vm ref)
    (setf (vm-object-is-marked-p vm ref) t)
    (immix-mark-object-lines vm space ref (immix-space-line-mark-state space))
    (when tracer
      (tracer-enqueue tracer ref))
    ref))

(defmethod space-prepare ((space immix-space-trait) vm &key cycle-kind)
  (declare (ignore vm cycle-kind))
  (let ((old-state (immix-space-line-mark-state space)))
    (setf (immix-space-line-mark-state space)
          (if (= old-state 1) 2 1))))

(defmethod space-release ((space immix-space-trait) vm &key cycle-kind)
  (declare (ignore space vm cycle-kind))
  nil)

(defmethod space-sweep ((space immix-space-trait) vm)
  "Recycle empty blocks."
  (let ((mark-state (immix-space-line-mark-state space)))
    (maphash (lambda (page block)
               (declare (ignore page))
               (let ((has-live nil))
                 (loop for line below +immix-lines-per-block+
                       when (= (aref (immix-block-line-marks block) line) mark-state)
                         do (setf has-live t))
                 (unless has-live
                   (setf (immix-block-recycled-p block) t
                         (immix-block-live-lines block) 0)
                   (push (cons page block) (immix-space-recycled-blocks space)))))
             (immix-space-blocks space))
    (let ((curr (immix-space-current-block space)))
      (when (and curr (immix-block-recycled-p curr))
        (setf (immix-space-current-block space) nil)))
    (vm-clear-all-mark-bits vm)))

(defmethod space-sweep-young ((space immix-space-trait) vm)
  "Recycle blocks with no live objects, and count dead mature bytes in
remaining blocks."
  (let ((mark-state (immix-space-line-mark-state space)))
    ;; First pass: identify and recycle completely dead blocks
    (maphash (lambda (page block)
               (declare (ignore page))
               (let ((has-live nil))
                 (loop for line below +immix-lines-per-block+
                       when (= (aref (immix-block-line-marks block) line) mark-state)
                         do (setf has-live t))
                 (unless has-live
                   (setf (immix-block-recycled-p block) t
                         (immix-block-live-lines block) 0)
                   (push (cons page block) (immix-space-recycled-blocks space)))))
             (immix-space-blocks space))
    ;; Second pass: count dead mature bytes in blocks that were NOT recycled
    (maphash (lambda (page block)
               (declare (ignore page))
               (unless (immix-block-recycled-p block)
                 (let* ((block-start (* (immix-block-start-page block)
                                        +immix-block-size-words+))
                        (block-end (+ block-start +immix-block-size-words+))
                        (cursor block-start))
                   (loop while (< cursor block-end)
                         do (let ((addr (make-address cursor)))
                              (cond
                                ((and (vm-object-start-p vm addr)
                                      (not (vm-object-is-marked-p vm addr))
                                      (not (vm-object-is-logged-p vm addr)))
                                 (let ((obj-size (vm-object-total-words vm addr)))
                                   (incf cursor obj-size)
                                   (incf (plan-dead-mature-bytes *active-plan*)
                                         obj-size)))
                                ((vm-object-start-p vm addr)
                                 (incf cursor (vm-object-total-words vm addr)))
                                (t (incf cursor))))))))
             (immix-space-blocks space))
    (let ((curr (immix-space-current-block space)))
      (when (and curr (immix-block-recycled-p curr))
        (setf (immix-space-current-block space) nil)))
    (vm-clear-all-mark-bits vm)))

;;; --- Immix Block ---

(defstruct immix-block
  (start-page 0 :type fixnum)
  (cursor 0 :type fixnum)
  (limit 0 :type fixnum)
  (line-marks (make-array +immix-lines-per-block+
                          :element-type '(unsigned-byte 2)
                          :initial-element 0)
              :type (simple-array (unsigned-byte 2) (*)))
  (live-lines 0 :type fixnum)
  (recycled-p nil :type boolean))

;;; --- Immix Space (concrete) ---

(defclass immix-space (immix-space-trait space)
  ((blocks :initform (make-hash-table :test 'eql)
    :accessor immix-space-blocks)
   (recycled-blocks :initform nil :accessor immix-space-recycled-blocks :type list)
   (current-block :initform nil :accessor immix-space-current-block)
   (line-mark-state :initform 1 :accessor immix-space-line-mark-state :type fixnum)
   (defrag-threshold :initarg :defrag-threshold :initform 0.5
    :accessor immix-space-defrag-threshold :type float))
  (:documentation "Immix space with block/line-granularity marking."))

(defmethod space-contains-p ((space immix-space) addr)
  (let ((page (floor (address-index addr) +page-size-words+)))
    (nth-value 1 (gethash page (immix-space-blocks space)))))

;;; --- Immix Allocator ---

(defclass immix-allocator ()
  ((space :initarg :space :accessor allocator-space)
   (page-resource :initarg :page-resource :accessor allocator-page-resource))
  (:documentation "Immix allocator: bump-pointer within blocks."))

(defun make-immix-allocator (space page-resource)
  (make-instance 'immix-allocator :space space :page-resource page-resource))

(defmethod alloc ((a immix-allocator) size &key)
  (let* ((space (allocator-space a))
         (pr (allocator-page-resource a)))
    (immix-space-ensure-block space pr)
    (let ((block (immix-space-current-block space)))
      (unless block (return-from alloc nil))
      (let* ((cursor (immix-block-cursor block))
             (new-cursor (+ cursor size)))
        (when (> new-cursor (immix-block-limit block))
          (setf (immix-space-current-block space) nil)
          (immix-space-ensure-block space pr)
          (setf block (immix-space-current-block space))
          (unless block (return-from alloc nil))
          (setf cursor (immix-block-cursor block)
                new-cursor (+ cursor size)))
        (setf (immix-block-cursor block) new-cursor)
        (make-address cursor)))))

(defmethod mark-line ((a immix-allocator) addr mark-state)
  "Mark the line containing ADDR with MARK-STATE in the owning block."
  (let* ((space (allocator-space a))
         (page-idx (floor (address-index addr) +page-size-words+))
         (block (gethash page-idx (immix-space-blocks space))))
    (when block
      (let* ((line-idx (floor (mod (address-index addr) +page-size-words+)
                              +immix-line-size-words+))
             (line-marks (immix-block-line-marks block)))
        (when (zerop (aref line-marks line-idx))
          (setf (aref line-marks line-idx) mark-state)
          (incf (immix-block-live-lines block)))))))

(defmethod block-is-recyclable-p ((a immix-allocator) block)
  "Return T if BLOCK has no live lines with the current mark state."
  (declare (ignore a))
  (zerop (immix-block-live-lines block)))

(defun immix-space-ensure-block (space page-resource)
  (unless (immix-space-current-block space)
    (if (immix-space-recycled-blocks space)
        (destructuring-bind (page . block) (pop (immix-space-recycled-blocks space))
          (setf (immix-block-cursor block) (* page +immix-block-size-words+)
                (immix-block-limit block) (+ (* page +immix-block-size-words+)
                                            +immix-block-size-words+)
                (immix-block-recycled-p block) nil
                (immix-block-live-lines block) 0)
          (fill (immix-block-line-marks block) 0)
          (setf (immix-space-current-block space) block))
        (let ((new-page (page-resource-get page-resource 1 :kind :boxed)))
          (when new-page
            (incf (space-page-count space))
            (let ((block (make-immix-block
                          :start-page new-page
                          :cursor (* new-page +immix-block-size-words+)
                          :limit (+ (* new-page +immix-block-size-words+)
                                    +immix-block-size-words+))))
              (setf (gethash new-page (immix-space-blocks space)) block)
              (setf (immix-space-current-block space) block)))))))

(defun make-immix-space (plan page-resource &key name size)
  (declare (ignore plan size))
  (let* ((space (make-instance 'immix-space
                  :name name :kind :immix
                  :start-page 0 :page-count 0
                  :allocator nil :page-resource page-resource)))
    (immix-space-ensure-block space page-resource)
    space))

(defun immix-mark-object-lines (vm space addr mark-state)
  "Mark all lines that overlap with the object at ADDR."
  (let* ((start (address-index addr))
         (obj-size (vm-object-total-words vm addr))
         (end (+ start obj-size))
         (start-line (floor start +immix-line-size-words+))
         (end-line (ceiling end +immix-line-size-words+)))
    (loop for line from start-line below end-line
          for line-addr = (* line +immix-line-size-words+)
          for page-idx = (floor line-addr +page-size-words+)
          for block = (gethash page-idx (immix-space-blocks space))
          when block do
            (let* ((block-start-addr (* page-idx +page-size-words+))
                   (line-idx (floor (- line-addr block-start-addr) +immix-line-size-words+)))
              (when (zerop (aref (immix-block-line-marks block) line-idx))
                (setf (aref (immix-block-line-marks block) line-idx) mark-state)
                (incf (immix-block-live-lines block)))))))
