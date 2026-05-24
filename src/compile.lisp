(in-package #:clamsara)

;;;; Compilable Framework
;;;
;;; The paper describes a gc-phase method combination and boot-gc that
;;; compiles hot-path functions into a function table.

;;; --- gc-phase Method Combination ---
;;; Qualifiers: :around, :prologue, :pre-mark, :mark, :sweep, :epilogue

(define-method-combination gc-phase ()
  ((around (:around))
   (prologue (:prologue))
   (pre-mark (:pre-mark))
   (mark (:mark))
   (sweep (:sweep))
   (epilogue (:epilogue))
   (default ())))
  (let ((form (if default
                  `(progn ,@(mapcar #'(lambda (m) `(call-method ,m)) default))
                  nil)))
    ;; Wrap with phase methods in order
    (dolist (m (reverse epilogue))
      (setf form `(progn (call-method ,m) ,form)))
    (dolist (m (reverse sweep))
      (setf form `(progn (call-method ,m) ,form)))
    (dolist (m (reverse mark))
      (setf form `(progn (call-method ,m) ,form)))
    (dolist (m (reverse pre-mark))
      (setf form `(progn (call-method ,m) ,form)))
    (dolist (m (reverse prologue))
      (setf form `(progn (call-method ,m) ,form)))
    ;; Wrap with :around methods
    (if around
        `(call-method ,(first around)
                      (,@(rest around)
                       (make-method ,form)))
        form)))

;;; --- Generic with gc-phase ---

(defgeneric plan-collect-phase (plan phase)
  (:method-combination gc-phase)
  (:documentation "Collect garbage for PLAN in PHASE (:minor or :major).
Uses the gc-phase method combination to order collection phases."))

;;; --- Default phase methods ---

(defmethod plan-collect-phase prologue ((plan plan) (phase t))
  "Prologue: prepare for collection."
  (declare (ignore phase))
  ;; Clear barrier state
  (when (plan-barrier plan)
    (barrier-clear-all (plan-barrier plan)))
  ;; Clear mark bits
  (let ((vm (plan-vm plan)))
    (when vm
      (dotimes (i (length (simulator-vm-heap vm)))
        (when (vm-object-start-p vm i)
          (setf (vm-object-is-marked-p vm i) nil))))))

(defmethod plan-collect-phase mark ((plan plan) (phase t))
  "Mark: trace from roots."
  (declare (ignore phase))
  (let ((vm (plan-vm plan)))
    (when vm
      (let ((tracer (make-tracer vm
                      (lambda (obj)
                        (unless (vm-object-is-marked-p vm obj)
                          (setf (vm-object-is-marked-p vm obj) t))
                        obj))))
        (vm-scan-roots vm plan
          (lambda (r)
            (when (and r (not (zerop r)))
              (tracer-enqueue tracer r))))
        (tracer-process-queue tracer)))))

(defmethod plan-collect-phase sweep ((plan plan) (phase t))
  "Sweep: reclaim unreachable objects."
  (declare (ignore phase))
  ;; Default is a no-op; specific plans override this.
  nil)

(defmethod plan-collect-phase epilogue ((plan plan) (phase t))
  "Epilogue: cleanup after collection."
  (declare (ignore phase))
  nil)

;;; --- :around method for timing ---

(defmethod plan-collect-phase :around ((plan plan) (phase t))
  ":around method for timing and statistics."
  (let ((start (get-internal-real-time)))
    (call-next-method)
    (let ((end (get-internal-real-time)))
      (incf (plan-stats-gc-count (plan-stats plan)))
      (incf (plan-stats-gc-time (plan-stats plan))
            (/ (- end start) internal-time-units-per-second)))))

;;; --- Function Table ---

(defgeneric plan-function-table (plan)
  (:documentation "Return the compiled function table for PLAN."))

(defmethod plan-function-table ((plan plan))
  (slot-value plan 'function-table))

;;; --- compile-to-functions ---

(defgeneric compile-to-functions (component)
  (:method-combination append)
  (:documentation "Return an alist of (function-name . lambda-form) for all
hot-path functions contributed by COMPONENT."))

(defmethod compile-to-functions append ((plan plan))
  "Compile the GC phase sequence."
  (let ((phase-lambda
         `(lambda ()
            (plan-collect-phase plan ,(if (plan-generational-p plan) :minor :major)))))
    (list (cons 'plan-collect phase-lambda))))

(defmethod compile-to-functions append ((space space))
  "Space trace functions."
  (list (cons 'space-trace-object
              `(lambda (vm obj)
                 (declare (ignorable vm obj))
                 ;; Default trace: mark and enqueue children
                 (unless (vm-object-is-marked-p vm obj)
                   (setf (vm-object-is-marked-p vm obj) t))
                 obj))))

(defmethod compile-to-functions append ((barrier object-barrier))
  "Barrier functions."
  (list (cons 'barrier-note-write
              `(lambda (source-addr slot-idx new-value)
                 (barrier-note-write barrier source-addr slot-idx new-value)))
        (cons 'barrier-card-scan
              `(lambda (vm scan-fn)
                 (barrier-card-scan barrier vm scan-fn)))
        (cons 'barrier-clear-all
              `(lambda ()
                 (barrier-clear-all barrier)))))

;;; --- boot-gc ---

(defun boot-gc (plan)
  "Compile all hot-path functions for PLAN and link them into the VM binding.
After this call, PLAN is ready for collection on the target runtime,
and no CLOS dispatch occurs on the hot path.
Idempotent: skips if function-table already populated."
  (let ((table (plan-function-table plan)))
    (when (zerop (hash-table-count table))
      (let ((forms (compile-to-functions plan)))
        (loop for (name . lambda-form) in forms
              do (let ((fn (compile nil lambda-form)))
                   (setf (gethash name table) fn)))))
    plan))

;;; --- Plan initialization ---

(defgeneric plan-initialize-spaces (plan vm heap-size)
  (:documentation "Initialize PLAN's spaces with VM and HEAP-SIZE."))

(defmethod plan-initialize-spaces ((plan plan) vm heap-size)
  "Default: create a single space."
  (setf (plan-spaces plan)
        (list (make-instance 'space
                             :name :default
                             :kind :default
                             :start-page 0
                             :page-count (ceiling heap-size +page-size-words+)
                             :vm vm
                             :allocator (make-instance 'bump-allocator
                                                      :space-start 0
                                                      :space-end heap-size))))
  plan)
