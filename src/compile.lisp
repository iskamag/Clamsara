(in-package #:clamsara)

;;;; Compilable Framework
;;;
;;; The paper describes a gc-phase method combination and boot-gc that
;;; compiles hot-path functions into a function table.

;;; --- gc-phase Method Combination ---
;;; Qualifiers: :around, :prologue, :pre-mark, :mark, :sweep, :compact, :release, :epilogue
;;; Order: prologue -> pre-mark -> mark -> sweep -> compact -> release -> epilogue
;;; Only the most-specific method in each phase runs (standard dispatch semantics).
;;; Methods without a recognized qualifier fall into the default group and all run.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (define-method-combination gc-phase ()
    ((around (:around))
     (prologue (:prologue))
     (mark (:mark))
     (sweep (:sweep))
     (compact (:compact))
     (release (:release))
     (epilogue (:epilogue))
     (default ()))
    (flet ((call-primary (method-group)
              (let ((m (first method-group)))
                (when m
                  `(call-method ,m)))))
      (let ((form (if default
                      `(progn ,@(mapcar #'(lambda (m) `(call-method ,m)) default))
                      nil)))
        (let ((m (call-primary epilogue)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary release)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary compact)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary sweep)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary mark)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary prologue)))
          (when m (setf form `(progn ,m ,form))))
        (if around
            `(call-method ,(first around)
                          (,@(rest around)
                           (make-method ,form)))
            form)))))

;;; --- Generic with gc-phase ---

(defgeneric plan-collect-phase (plan cycle-kind)
  (:method-combination gc-phase)
  (:documentation "Collect garbage for PLAN in CYCLE-KIND (:minor or :major).
Uses the gc-phase method combination to order collection phases."))

;;; --- Default phase methods ---
;;; These are fallbacks for plans that don't provide their own.
;;; All 9 concrete plans override the relevant phases, so these
;;; methods only apply to bare plan instances or as secondary
;;; methods in the gc-phase combination (which calls all applicable
;;; methods in a phase, not just the most-specific).

(defmethod plan-collect-phase :prologue ((plan plan) (cycle-kind t))
  "Prologue: clear barrier state."
       (declare (ignore cycle-kind))
  (when (plan-barrier plan)
    (barrier-clear-all (plan-barrier plan))))

(defmethod plan-collect-phase :mark ((plan plan) (cycle-kind t))
  "Mark: no-op default. Concrete plans override this."
       (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :sweep ((plan plan) (cycle-kind t))
  "Sweep: no-op default."
       (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :compact ((plan plan) (cycle-kind t))
  "Compact: no-op default."
       (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :release ((plan plan) (cycle-kind t))
  "Release: no-op default."
       (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :epilogue ((plan plan) (cycle-kind t))
  "Epilogue: no-op default."
       (declare (ignore cycle-kind))
  nil)

;;; Finalization hook: runs during gc-phase :epilogue to move dead objects
;;; from known-finalizers to pending-finalizers after mark/sweep.
(defmethod plan-collect-phase :epilogue ((plan finalization-trait) (cycle-kind t))
       (declare (ignore cycle-kind))
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
    (setf (fill-pointer (plan-known-finalizers plan)) keep-count)))

;;; --- :around method for timing ---

(defmethod plan-collect-phase :around ((plan plan) (cycle-kind t))
  ":around method for timing and statistics."
  (let ((start (get-internal-run-time)))
    (call-next-method)
    (let ((end (get-internal-run-time))
          (stats (plan-stats plan)))
      (incf (plan-stats-gc-count stats))
      (incf (plan-stats-gc-time stats)
            (/ (- end start) internal-time-units-per-second)))))

;;; --- Function Table ---

(defgeneric plan-function-table (plan)
  (:documentation "Return the compiled function table for PLAN."))

(defmethod plan-function-table ((plan plan))
  (slot-value plan 'function-table))

;;; --- compile-to-functions ---

(defgeneric compile-to-functions (component)
  (:method-combination append)
  (:documentation "Return an alist of (function-name . closure) for all
hot-path functions contributed by COMPONENT. Each closure captures
its lexical environment so boot-gc can store them directly."))

(defmethod compile-to-functions append ((plan plan))
  "Compiled plan-collect closure: calls plan-collect-phase with cycle-kind dispatch."
  (let ((default-phase (if (plan-generational-p (plan-constraints plan)) :minor :major)))
    (list (cons 'plan-collect
                (lambda (&key (cycle-kind default-phase))
                  (plan-collect-phase plan cycle-kind))))))

(defmethod compile-to-functions append ((space space))
  "Space trace functions."
  (list (cons 'space-trace-object
              (lambda (vm obj)
                (declare (ignorable vm obj))
                (unless (vm-object-is-marked-p vm obj)
                  (setf (vm-object-is-marked-p vm obj) t))
                obj))))

(defmethod compile-to-functions append ((barrier object-barrier))
  "Barrier functions."
  (list (cons 'barrier-note-write
              (lambda (source-addr slot-idx new-value &key old-value)
                (barrier-note-write barrier source-addr slot-idx new-value
                                    :old-value old-value)))
        (cons 'barrier-card-scan
              (lambda (vm scan-fn)
                (barrier-card-scan barrier vm scan-fn)))
        (cons 'barrier-clear-all
              (lambda ()
                (barrier-clear-all barrier)))))

(defmethod compile-to-functions append ((space copying-space-trait))
  "Copying space contributes trace-object, prepare, and release."
  (list (cons (intern (format nil "SPACE-TRACE-OBJECT-~A" (space-name space)) 'keyword)
              (lambda (vm ref tracer &key cycle-kind trace-kind copy-semantics)
                (space-trace-object space vm ref tracer
                                    :cycle-kind cycle-kind
                                    :trace-kind trace-kind
                                    :copy-semantics copy-semantics)))
        (cons (intern (format nil "SPACE-PREPARE-~A" (space-name space)) 'keyword)
              (lambda (vm &key cycle-kind)
                (space-prepare space vm :cycle-kind cycle-kind)))
        (cons (intern (format nil "SPACE-RELEASE-~A" (space-name space)) 'keyword)
              (lambda (vm &key cycle-kind)
                (space-release space vm :cycle-kind cycle-kind)))))

(defmethod compile-to-functions append ((space marksweep-space-trait))
  "Mark-sweep space contributes trace-object and sweep."
  (list (cons (intern (format nil "SPACE-TRACE-OBJECT-~A" (space-name space)) 'keyword)
              (lambda (vm ref tracer &key cycle-kind trace-kind copy-semantics)
                (space-trace-object space vm ref tracer
                                    :cycle-kind cycle-kind
                                    :trace-kind trace-kind
                                    :copy-semantics copy-semantics)))
        (cons (intern (format nil "SPACE-SWEEP-~A" (space-name space)) 'keyword)
              (lambda (vm)
                (space-sweep space vm)))))

(defmethod compile-to-functions append ((a bump-allocator))
  "Bump-pointer allocator contributes a compiled alloc function."
  (list (cons 'bump-alloc
              (lambda (size)
                (alloc a size)))))

;;; --- boot-gc ---

(defun boot-gc (plan)
  "Compile all hot-path functions for PLAN and link them into the VM binding.
Processes forms in reverse so most-specific plan-type entries override
less-specific base-class entries for duplicate keys.
Idempotent: skips if function-table already populated."
  (let ((table (plan-function-table plan)))
    (unless (plusp (hash-table-count table))
      (let ((forms (compile-to-functions plan)))
        (loop for (name . fn) in (reverse forms)
              do (setf (gethash name table) fn)))))
  plan)

(defun lookup-compiled-function (plan name)
  "Look up the compiled function named NAME in PLAN's function table.
Returns NIL if no compiled function is found (caller should fall back to
the generic dispatch)."
  (gethash name (plan-function-table plan)))

;;; --- plan-collect dispatch ---

(defmethod plan-collect :around ((plan plan) &key cycle-kind)
  ":around method that tries the compiled function table first.
When boot-gc has populated the table, this avoids CLOS dispatch entirely."
  (let ((fn (lookup-compiled-function plan 'plan-collect)))
    (if fn
        (if cycle-kind
            (funcall fn :cycle-kind cycle-kind)
            (funcall fn))
        (call-next-method))))

(defmethod plan-collect ((plan plan) &key (cycle-kind :major))
  "Default plan-collect: delegates to plan-collect-phase via gc-phase method combination.
Used when no compiled function exists and no plan-specific primary method applies."
  (plan-collect-phase plan cycle-kind))

;;; --- Plan initialization ---

(defgeneric plan-initialize-spaces (plan vm heap-size)
  (:documentation "Initialize PLAN's spaces with VM and HEAP-SIZE."))

(defmethod plan-initialize-spaces ((plan plan) vm heap-size)
  "Default no-op. Each plan type provides its own make-* function that
calls initialize-plan-heap and sets up spaces."
  (declare (ignore vm heap-size))
  plan)
