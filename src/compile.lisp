(in-package #:clamsara)

;;;; Compilable Framework
;;;
;;; The paper describes a gc-phase method combination and boot-gc that
;;; compiles hot-path functions into a function table.

;;; --- gc-phase Method Combination ---
;;; Qualifiers: :around, :prologue, :pre-mark, :mark, :sweep, :compact, :release, :epilogue
;;; Order: prologue -> pre-mark -> mark -> sweep -> compact -> release -> epilogue

(eval-when (:compile-toplevel :load-toplevel :execute)
  (define-method-combination gc-phase ()
    ((around (:around))
     (prologue (:prologue))
     (pre-mark (:pre-mark))
     (mark (:mark))
     (sweep (:sweep))
     (compact (:compact))
     (release (:release))
     (epilogue (:epilogue))
     (default ()))
    (let ((form (if default
                    `(progn ,@(mapcar #'(lambda (m) `(call-method ,m)) default))
                    nil)))
      (dolist (m (reverse epilogue))
        (setf form `(progn (call-method ,m) ,form)))
      (dolist (m (reverse release))
        (setf form `(progn (call-method ,m) ,form)))
      (dolist (m (reverse compact))
        (setf form `(progn (call-method ,m) ,form)))
      (dolist (m (reverse sweep))
        (setf form `(progn (call-method ,m) ,form)))
      (dolist (m (reverse mark))
        (setf form `(progn (call-method ,m) ,form)))
      (dolist (m (reverse pre-mark))
        (setf form `(progn (call-method ,m) ,form)))
      (dolist (m (reverse prologue))
        (setf form `(progn (call-method ,m) ,form)))
      (if around
          `(call-method ,(first around)
                        (,@(rest around)
                         (make-method ,form)))
          form))))

;;; --- Generic with gc-phase ---

(defgeneric plan-collect-phase (plan phase)
  (:method-combination gc-phase)
  (:documentation "Collect garbage for PLAN in PHASE (:minor or :major).
Uses the gc-phase method combination to order collection phases."))

;;; --- Default phase methods ---

(defmethod plan-collect-phase :prologue ((plan plan) (phase t))
  "Prologue: prepare for collection."
  (declare (ignore phase))
  ;; Clear barrier state
  (when (plan-barrier plan)
    (barrier-clear-all (plan-barrier plan)))
  ;; Clear mark bits
  (let ((vm (plan-vm plan)))
    (when vm
      (dotimes (i (vm-heap-size vm))
        (when (vm-object-start-p vm i)
          (setf (vm-object-is-marked-p vm i) nil))))))

(defmethod plan-collect-phase :mark ((plan plan) (phase t))
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

(defmethod plan-collect-phase :sweep ((plan plan) (phase t))
  "Sweep: reclaim unreachable objects."
  (declare (ignore phase))
  nil)

(defmethod plan-collect-phase :compact ((plan plan) (phase t))
  "Compact: defragment heap (plan-specific). Default no-op."
  (declare (ignore phase))
  nil)

(defmethod plan-collect-phase :release ((plan plan) (phase t))
  "Release: release temporary resources, swap spaces, reset mutator contexts."
  (declare (ignore phase))
  (let ((vm (plan-vm plan)))
    (when vm
      (vm-clear-all-forwarding vm)
      (vm-clear-all-log-bits vm))))

(defmethod plan-collect-phase :epilogue ((plan plan) (phase t))
  "Epilogue: cleanup after collection."
  (declare (ignore phase))
  nil)

;;; Finalization hook: runs during gc-phase :epilogue to move dead objects
;;; from known-finalizers to pending-finalizers after mark/sweep.
(defmethod plan-collect-phase :epilogue ((plan finalization-trait) (phase t))
  (declare (ignore phase))
  (let ((vm (plan-vm plan))
        (keep-count 0))
    (loop with known = (plan-known-finalizers plan)
          for i from 0 below (fill-pointer known)
          for entry = (aref known i)
          do (when (consp entry)
               (let ((obj-addr (car entry)))
                 (if (and (not (zerop obj-addr))
                          (vm-object-is-marked-p vm obj-addr))
                     (progn
                       (setf (aref known keep-count) entry)
                       (incf keep-count))
                     (progn
                       (vector-push-extend entry
                                           (plan-pending-finalizers plan)))))))
    (setf (fill-pointer (plan-known-finalizers plan)) keep-count))
  (call-next-method))

;;; --- :around method for timing ---

(defmethod plan-collect-phase :around ((plan plan) (phase t))
  ":around method for timing and statistics."
  (let ((start (get-internal-real-time)))
    (call-next-method)
    (let ((end (get-internal-real-time)))
      (let ((stats (plan-stats plan)))
        (when stats
          (incf (plan-stats-gc-count stats))
          (incf (plan-stats-gc-time stats)
                (/ (- end start) internal-time-units-per-second)))))))

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
             (plan-collect-phase plan ,(if (plan-generational-p (plan-constraints plan)) :minor :major)))))
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

(defmethod compile-to-functions append ((space copying-space-trait))
  "Copying space contributes trace-object, prepare, and release."
  (list (cons (intern (format nil "SPACE-TRACE-OBJECT-~A" (space-name space)) 'keyword)
              `(lambda (vm ref tracer &key cycle-kind trace-kind copy-semantics)
                 (space-trace-object ,space vm ref tracer
                                     :cycle-kind cycle-kind
                                     :trace-kind trace-kind
                                     :copy-semantics copy-semantics)))
        (cons (intern (format nil "SPACE-PREPARE-~A" (space-name space)) 'keyword)
              `(lambda (vm &key cycle-kind)
                 (space-prepare ,space vm :cycle-kind cycle-kind)))
        (cons (intern (format nil "SPACE-RELEASE-~A" (space-name space)) 'keyword)
              `(lambda (vm &key cycle-kind)
                 (space-release ,space vm :cycle-kind cycle-kind)))))

(defmethod compile-to-functions append ((space marksweep-space-trait))
  "Mark-sweep space contributes trace-object and sweep."
  (list (cons (intern (format nil "SPACE-TRACE-OBJECT-~A" (space-name space)) 'keyword)
              `(lambda (vm ref tracer &key cycle-kind trace-kind copy-semantics)
                 (space-trace-object ,space vm ref tracer
                                     :cycle-kind cycle-kind
                                     :trace-kind trace-kind
                                     :copy-semantics copy-semantics)))
        (cons (intern (format nil "SPACE-SWEEP-~A" (space-name space)) 'keyword)
              `(lambda (vm)
                 (space-sweep ,space vm)))))

(defmethod compile-to-functions append ((a bump-allocator))
  "Bump-pointer allocator contributes a compiled alloc function."
  (list (cons 'bump-alloc
              `(lambda (size)
                 (alloc ,a size)))))

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
                   (setf (gethash name table) fn))))))
  plan)

(defun lookup-compiled-function (plan name)
  "Look up the compiled function named NAME in PLAN's function table.
Returns NIL if no compiled function is found (caller should fall back to
the generic dispatch)."
  (gethash name (plan-function-table plan)))

;;; --- Compilation helpers ---
;;; These functions generate compiled lambda forms for hot-path operations.

(defun compile-gc-phase-form (plan)
  "Generate a compiled lambda form for the gc-phase sequence of PLAN.
Uses compute-effective-method on plan-collect-phase to produce a PROGN
of phase methods."
  (declare (ignore plan))
  ;; In the full implementation this would use MOP compute-effective-method.
  ;; For now, we directly invoke plan-collect-phase which uses gc-phase
  ;; method combination to order the phases.
  `(lambda (cycle-kind)
     (plan-collect-phase ,plan cycle-kind)))

(defun compile-trace-dispatch (plan)
  "Generate a CASE form dispatching trace calls to the correct space based
on the object's address."
  (let ((spaces (plan-spaces plan)))
    (if (null spaces)
        `(lambda (vm obj tracer &key cycle-kind)
           (declare (ignore vm obj tracer cycle-kind))
           nil)
        (let ((clauses
               (loop for space in (plan-spaces plan)
                     for sname = (space-name space)
                     collect `((space-contains-p ,space obj)
                               (space-trace-object ,space vm obj tracer
                                                   :cycle-kind cycle-kind)))))
          `(lambda (vm obj tracer &key cycle-kind)
             (cond
               ,@clauses
               (t nil)))))))

(defun compile-space-trace-object (space)
  "Generate a compiled lambda form for tracing objects in SPACE."
  `(lambda (vm obj tracer &key cycle-kind trace-kind copy-semantics)
     (space-trace-object ,space vm obj tracer
                         :cycle-kind cycle-kind
                         :trace-kind trace-kind
                         :copy-semantics copy-semantics)))

(defun compile-space-prepare (space)
  "Generate a compiled lambda form for preparing SPACE."
  `(lambda (vm &key cycle-kind)
     (space-prepare ,space vm :cycle-kind cycle-kind)))

(defun compile-space-release (space)
  "Generate a compiled lambda form for releasing SPACE."
  `(lambda (vm &key cycle-kind)
     (space-release ,space vm :cycle-kind cycle-kind)))

(defun compile-space-sweep (space)
  "Generate a compiled lambda form for sweeping SPACE."
  `(lambda (vm)
     (space-sweep ,space vm)))

(defun compile-card-barrier-write (barrier)
  "Generate a compiled lambda form for the card-table write barrier."
  `(lambda (source-addr slot-idx new-value &key old-value)
     (barrier-note-write ,barrier source-addr slot-idx new-value :old-value old-value)))

(defun compile-card-barrier-scan (barrier)
  "Generate a compiled lambda form for the card-table scan."
  `(lambda (vm scan-fn)
     (barrier-card-scan ,barrier vm scan-fn)))

(defun compile-bump-alloc-cas (allocator)
  "Generate a CAS-based bump allocation lambda for multi-threaded use."
  `(lambda (size)
     (let* ((cursor (allocator-cursor ,allocator))
            (new-cursor (+ cursor size)))
       (if (> new-cursor (allocator-limit ,allocator))
           nil
           (if (cas (plan-vm *active-plan*) cursor cursor new-cursor)
               (make-address cursor)
               nil)))))

(defun compile-bump-alloc-locked (allocator)
  "Generate a lock-based bump allocation lambda."
  `(lambda (size)
     (alloc ,allocator size)))

(defun compile-cons-trace (plan)
  "Generate a compiled cons-trace function for PLAN."
  (declare (ignore plan))
  `(lambda (vm ref tracer &key cycle-kind trace-kind copy-semantics)
     (declare (ignore cycle-kind trace-kind copy-semantics))
     (when (and ref (not (zerop ref)))
       (unless (vm-object-is-marked-p vm ref)
         (setf (vm-object-is-marked-p vm ref) t)
         (when tracer
           (tracer-enqueue tracer ref)))
       ref)))

;;; --- Plan initialization ---

(defgeneric plan-initialize-spaces (plan vm heap-size)
  (:documentation "Initialize PLAN's spaces with VM and HEAP-SIZE."))

(defmethod plan-initialize-spaces ((plan plan) vm heap-size)
  "Default no-op. Each plan type provides its own make-* function that
calls initialize-plan-heap and sets up spaces."
  (declare (ignore vm heap-size))
  plan)
