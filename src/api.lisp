;;;; api.lisp -- the public surface (README entry points).

(in-package #:clamsara)

(defvar *clamsara-plan* nil)
(defvar *clamsara-vm* nil)

(defvar *clamsara-tests* nil)
(defun list-tests () (nreverse *clamsara-tests*))
(defmacro deftest (name () &body body)
  `(push (cons ',name (lambda () (block ,name ,@body))) *clamsara-tests*))

(defun make-collector (plan-type vm heap-size &key)
  "Dispatch to the per-plan constructor."
  (ecase plan-type
    (:nogc        (make-nogc-plan vm heap-size))
    (:semispace   (make-semispace-plan vm heap-size))
    (:marksweep   (make-marksweep-plan vm heap-size))
    (:immix       (make-immix-plan vm heap-size))
    (:gencopy     (make-gencopy-plan vm heap-size))
    (:genms       (make-genms-plan vm heap-size))
    (:genimmix    (make-genimmix-plan vm heap-size))
    (:stickyimmix (make-stickyimmix-plan vm heap-size))
    (:stickyms    (make-stickyms-plan vm heap-size))
    (:iso         (make-iso-plan vm heap-size))
    (:zgcish      (make-zgcish-plan vm heap-size))
    (:claimore    (make-claimore-plan vm heap-size))))

(defmacro with-clamsara ((&key (plan-type :semispace) (heap-size 65536)) &body body)
  "Build a collector over a fresh simulator heap, boot it, and run BODY with
*clamsara-plan* / *clamsara-vm* bound."
  `(let* ((vm (make-simulator-vm ,heap-size))
          (plan (make-collector ,plan-type vm ,heap-size)))
     (boot-gc plan)
     (let ((*clamsara-plan* plan) (*clamsara-vm* vm))
       ,@body)))

(defun clamsara-allocate-object (slot-count &key (type-tag +tag-object+)
                                             (layout-id 0))
  (allocate-object *clamsara-plan* slot-count
                   :type-tag type-tag :layout-id layout-id))

(defun clamsara-register-root (address)
  "Register ADDRESS as a root; return its index in the root vector (a copying
GC may update the entry in place, so callers track the INDEX, not the address)."
  (vm-add-root *clamsara-vm* address)
  (1- (length (vm-root-vector *clamsara-vm*))))

(defun clamsara-root (index)
  "Current address of root slot INDEX (updated across copying collections)."
  (aref (vm-root-vector *clamsara-vm*) index))

(defun clamsara-remove-root (index)
  "Remove root slot INDEX.  Returns the address that was at INDEX, or NIL.
Removing is by index (not address), so a duplicate address in another slot is
left untouched.  Note: removal uses swap-remove, so the root formerly at the
last index moves into INDEX — callers must refresh any indices they hold."
  (vm-remove-root-at-index *clamsara-vm* index))

(defun clamsara-gc (&key cycle-kind)
  (plan-collect *clamsara-plan* :cycle-kind (or cycle-kind :full))
  (let ((errs   (sanity-check *clamsara-plan* :check-mark (not (plan-sticky-p *clamsara-plan*)))))
    (when errs
      (error 'clamsara-error
             :message (format nil "sanity check failed:~%~{  ~a~%~}" errs))))
  *clamsara-plan*)

;; ---- barrier-aware mutator accessors ------------------------------------

(defun clamsara-write (object slot value)
  "Mutator store: apply the write barrier, then store the (possibly replaced)
  value.  A publication barrier may replace VALUE with the public copy."
  (let ((barrier (plan-barrier *clamsara-plan*)))
    (when barrier
      (setf value (barrier-note-write *clamsara-vm* barrier object slot value)))
    (setf (vm-object-reference *clamsara-vm* object slot) value)
    value))

(defun clamsara-read (object slot)
  "Mutator load: read, then apply the read barrier (may heal)."
  (let* ((vm *clamsara-vm*)
         (raw (vm-object-reference vm object slot))
         (barrier (plan-barrier *clamsara-plan*)))
    (if barrier
        (let* ((slot-addr (if (vm-address-cons-p vm object)
                              (+ object slot)
                              (+ object 1 slot)))
               (healed (barrier-note-read vm barrier slot-addr raw)))
          (setf (vm-object-reference vm object slot) healed)
          healed)
        raw)))

;; ---- event-count snapshot -----------------------------------------------

(defun clamsara-plan () *clamsara-plan*)

(defun run-test-suite (&key (verbose t))
  "Run the built-in self-tests; return (passed . failed) counts."
  (let ((tests (list-tests)) (pass 0) (fail 0))
    (dolist (test tests)
      (multiple-value-bind (ok msg) (funcall (cdr test))
        (if ok
            (progn (incf pass) (when verbose (format t "ok   ~a~%" (car test))))
            (progn (incf fail) (format t "FAIL ~a: ~a~%" (car test) msg)))))
    (cons pass fail)))
