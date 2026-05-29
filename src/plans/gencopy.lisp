(in-package #:clamsara)

;;; --- Generational Plan Trait ---

(defclass generational-plan-trait ()
  ((survivor-threshold :initarg :survivor-threshold :initform 4
    :accessor plan-survivor-threshold :type fixnum)
   (minor-gc-count :initform 0 :accessor plan-minor-gc-count :type fixnum)
   (major-gc-count :initform 0 :accessor plan-major-gc-count :type fixnum)
   (last-major-gc-minor-count :initform 0
    :accessor plan-last-major-gc-minor-count :type fixnum)
   (current-gc-is-nursery :initform nil :accessor plan-current-gc-is-nursery-p)
   (nursery :initarg :nursery :accessor plan-nursery)
   (nursery-from :initform nil :accessor plan-nursery-from)
   (nursery-to :initform nil :accessor plan-nursery-to)
   (mature-from :initform nil :accessor plan-mature-from)
   (mature-to :initform nil :accessor plan-mature-to))
  (:documentation "Mixin that adds generational behavior to a plan."))

(defmethod should-minor-gc-p ((plan generational-plan-trait))
  (and (not (plan-gc-requested plan))
       (< (plan-minor-gc-count plan)
          (+ (plan-last-major-gc-minor-count plan)
             (plan-max-minor-gcs-before-major plan)))
       (not (nursery-exhausted-p plan))
       (not (mature-dead-ratio-exceeded-p plan))))

(defmethod nursery-exhausted-p ((plan generational-plan-trait))
  (let ((nursery (plan-nursery-from plan)))
    (and nursery
         (> (bump-allocator-occupancy (space-allocator nursery)) 3/4))))

(defmethod plan-collect ((plan generational-plan-trait) &key (cycle-kind :minor))
  (if (eq cycle-kind :major)
      (gen-major-collect plan)
      (if (should-minor-gc-p plan)
          (gen-minor-collect plan)
          (progn
            (setf (plan-last-major-gc-minor-count plan)
                  (plan-minor-gc-count plan))
            (gen-major-collect plan)))))

(defmethod plan-handle-allocation-failure ((plan generational-plan-trait) size space-designator)
  (flet ((try-alloc ()
           (let* ((space (plan-get-space plan space-designator))
                  (alloc (space-allocator space)))
             (alloc alloc size))))
    (or (try-alloc)
        (progn
          (plan-collect plan :cycle-kind :minor)
          (or (try-alloc)
              (progn
                (plan-collect plan :cycle-kind :major)
                (or (try-alloc)
                    (error 'heap-exhausted :plan plan))))))))

(defgeneric gen-minor-collect (plan)
  (:documentation "Execute a minor (nursery) GC cycle."))

(defgeneric gen-major-collect (plan)
  (:documentation "Execute a major (full heap) GC cycle."))

(defun gen-plan-init-nursery (plan heap-size)
  "Initialize two semispaces for the nursery."
  (let* ((nursery-size (floor heap-size 8))
         (pr (plan-page-resource plan))
         (pages-per-nursery (max 1 (floor (ceiling nursery-size +page-size-words+) 1)))
         (n0 (make-copy-space plan pr :name :nursery0 :size pages-per-nursery))
         (n1 (make-copy-space plan pr :name :nursery1 :size pages-per-nursery)))
    (setf (copying-partner-space n0) n1
          (copying-partner-space n1) n0
          (copying-from-space-p n0) t
          (copying-from-space-p n1) nil)
    (setf (plan-nursery-from plan) n0
          (plan-nursery-to plan) n1
          (plan-nursery plan) n0)
    (plan-add-space plan n0)
    (plan-add-space plan n1)))

(defun gen-mature-space (plan)
  "Return the mature space for generational plans."
  (or (plan-mature-from plan)
      (find-if (lambda (s) (member (space-name s) '(:ms-mature :immix-mature)))
               (plan-spaces plan))))

(defun gen-promote-object (plan vm src-addr space)
  "Promote an object to SPACE."
  (let* ((alloc (space-allocator space))
         (n-words (vm-object-total-words vm src-addr))
         (dst (alloc alloc n-words)))
    (when (null dst)
      (error 'heap-exhausted :plan plan :message "Mature space exhausted"))
    (vm-object-copy vm src-addr dst)
    (setf (vm-object-generation vm dst) 1)
    dst))

(defun gen-promote-to-mature (plan vm src-addr)
  (gen-promote-object plan vm src-addr (gen-mature-space plan)))

(defun gen-promote-to-mature-destination (plan vm src-addr)
  (gen-promote-object plan vm src-addr
                      (or (plan-mature-to plan) (gen-mature-space plan))))

;;; --- GenCopy Plan ---

(defclass gencopy-plan (generational-plan-trait plan) ()
  (:documentation "Generational copying collector."))

(defmethod gen-minor-collect ((plan gencopy-plan))
  (let* ((vm (plan-vm plan))
         (n-from (plan-nursery-from plan))
         (n-to (plan-nursery-to plan))
         (barrier (plan-barrier plan))
         (tracer nil))
    (vm-stop-mutators vm)
    (space-prepare n-to vm :cycle-kind :minor)
    (labels ((promote-or-copy (ref)
               (when (and (vm-address-in-space-p vm ref n-from)
                          (not (vm-object-is-forwarded-p vm ref)))
                 (let ((age (vm-object-age vm ref)))
                   (if (>= age (plan-survivor-threshold plan))
                       (gen-promote-to-mature plan vm ref)
                       (let* ((n-words (vm-object-total-words vm ref))
                              (nursery-alloc (space-allocator n-to))
                              (dst (alloc nursery-alloc n-words)))
                         (when (null dst)
                           (error 'heap-exhausted :plan plan))
                         (vm-object-copy vm ref dst)
                         (setf (vm-object-age vm dst) (1+ age))
                         dst)))))
             (trace-ref (ref)
               (let ((already-fwd (vm-object-is-forwarded-p vm ref)))
                 (when already-fwd
                   (let ((fwd-addr (vm-object-forwarding-pointer vm ref)))
                     (when tracer (tracer-enqueue tracer fwd-addr))
                     (return-from trace-ref fwd-addr))))
               (let ((new-addr (promote-or-copy ref)))
                 (when new-addr
                   (setf (vm-object-forwarding-pointer vm ref) new-addr)
                   (when tracer (tracer-enqueue tracer new-addr))
                   new-addr))))
      (setf tracer (make-tracer vm #'trace-ref :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)))
            (let ((result (trace-ref root)))
              (when result
                (unless (tracer-trace-fn-enqueues-p tracer)
                  (tracer-enqueue tracer result)))))))
      (when barrier
        (barrier-card-scan barrier vm
          (lambda (ref slot-idx)
            (declare (ignore slot-idx))
            (let ((result (trace-ref ref)))
              (when result
                (unless (tracer-trace-fn-enqueues-p tracer)
                  (tracer-enqueue tracer result)))))))
      (tracer-process-queue tracer))
    (rotatef (copying-from-space-p n-from) (copying-from-space-p n-to))
    (setf (plan-nursery-from plan) n-to
          (plan-nursery-to plan) n-from
          (plan-nursery plan) n-to)
    (vm-update-roots-forwarded vm)
    (when barrier (barrier-clear-all barrier))
    (vm-clear-all-forwarding vm)
    (incf (plan-minor-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod gen-major-collect ((plan gencopy-plan))
  (let* ((vm (plan-vm plan))
         (n-from (plan-nursery-from plan))
         (n-to (plan-nursery-to plan))
         (m-from (plan-mature-from plan))
         (m-to (plan-mature-to plan))
         (tracer nil))
    (vm-stop-mutators vm)
    (space-prepare n-to vm :cycle-kind :major)
    (when m-to (space-prepare m-to vm :cycle-kind :major))
    (flet ((trace-fn (ref)
             (let ((space (plan-space-for-address plan ref)))
               (when (and space (typep space 'collectable-space))
                 (space-trace-object space vm ref tracer
                                     :cycle-kind :major)))))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
       (vm-scan-roots vm plan
         (lambda (root)
           (when (and root (not (zerop root)))
             (let ((result (funcall #'trace-fn root)))
               (if result
                   (unless (tracer-trace-fn-enqueues-p tracer)
                     (tracer-enqueue tracer result))
                   (unless (tracer-trace-fn-enqueues-p tracer)
                     (tracer-enqueue tracer root)))))))
       (tracer-process-queue tracer))
     ;; Swap nursery
     (when (and n-from n-to)
      (rotatef (copying-from-space-p n-from) (copying-from-space-p n-to))
      (setf (plan-nursery-from plan) n-to
            (plan-nursery-to plan) n-from
            (plan-nursery plan) n-to))
    ;; Swap mature copy spaces
    (when (and m-from m-to)
      (rotatef (copying-from-space-p m-from) (copying-from-space-p m-to))
      (setf (plan-mature-from plan) m-to
            (plan-mature-to plan) m-from))
    (vm-update-roots-forwarded vm)
    (let ((barrier (plan-barrier plan)))
      (when barrier (barrier-clear-all barrier)))
    (vm-clear-all-forwarding vm)
    (vm-clear-all-mark-bits vm)
    (incf (plan-major-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod plan-get-space ((plan gencopy-plan) (designator (eql :default)))
  (plan-nursery plan))

(defmethod plan-allocate ((plan gencopy-plan) size (designator (eql :default)))
  (let* ((space (plan-nursery plan))
         (alloc (space-allocator space)))
    (or (alloc alloc size)
        (plan-handle-allocation-failure plan size designator))))

(defmethod plan-handle-allocation-failure ((plan gencopy-plan) size space-designator)
  (flet ((try-alloc ()
           (let* ((space (plan-nursery plan))
                  (alloc (space-allocator space)))
             (alloc alloc size))))
    (plan-request-gc plan)
    ;; Try minor GC first
    (gen-minor-collect plan)
    (or (try-alloc)
        ;; Then major GC
        (progn
          (gen-major-collect plan)
          (or (try-alloc)
              (error 'heap-exhausted :plan plan))))))

(defun make-gencopy-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'gencopy-plan
                  :name "GenCopy" :vm vm
                  :constraints (make-instance 'plan-constraints
                                 :moves-objects t :generational t
                                 :needs-log-bit t :barrier :object
                                 :needs-forwarding t))))
    (initialize-plan-heap plan heap-size)
    (let* ((pr (plan-page-resource plan))
           (mature-size (floor heap-size 4))
           (mature-pages (max 1 (floor (ceiling mature-size +page-size-words+) 1)))
           (m0 (make-copy-space plan pr :name :mature0 :size mature-pages))
           (m1 (make-copy-space plan pr :name :mature1 :size mature-pages)))
      (gen-plan-init-nursery plan heap-size)
      (setf (copying-partner-space m0) m1
            (copying-partner-space m1) m0
            (copying-from-space-p m0) t
            (copying-from-space-p m1) nil)
      (bump-allocator-reset (space-allocator m0)
                            :cursor (* (space-start-page m0) +page-size-words+)
                            :limit (* (+ (space-start-page m0) (space-page-count m0)) +page-size-words+))
      (bump-allocator-reset (space-allocator m1)
                            :cursor (* (space-start-page m1) +page-size-words+)
                            :limit (* (+ (space-start-page m1) (space-page-count m1)) +page-size-words+))
      (setf (plan-mature-from plan) m0
            (plan-mature-to plan) m1)
      (plan-add-space plan m0)
      (plan-add-space plan m1)
      (setf (plan-default-space plan) (plan-nursery-from plan))
      (let* ((nursery (plan-nursery plan))
             (nursery-start (* (space-start-page nursery) +page-size-words+))
             (nursery-end (+ nursery-start (* (space-page-count nursery) +page-size-words+)))
             (barrier (make-object-barrier (plan-card-table plan) nursery-start nursery-end)))
        (setf (plan-barrier plan) barrier
              (vm-barrier vm) barrier))
      plan)))

(register-plan-selector :gencopy #'make-gencopy-plan)
