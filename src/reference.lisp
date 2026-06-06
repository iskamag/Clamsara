(in-package #:clamsara)

;;; --- Weak References ---

(defclass weak-reference-trait ()
  ((weak-pointer-list :accessor plan-weak-pointers
    :initform (make-array 256 :adjustable t
                          :initial-element 0 :fill-pointer 0)))
  (:documentation "Mixin that adds weak reference processing."))

(defun make-weak-pointer (referent)
  "Create a weak pointer to REFERENT in the active plan's heap."
  (let ((plan *active-plan*))
    (unless plan (error 'no-active-plan))
    (let ((vm (plan-vm plan)))
      (let ((addr (plan-allocate plan 3 :default)))
        (when addr
          (setf (vm-object-header vm addr)
                (make-object-header 2 :type-tag +type-tag-object+))
          (setf (vm-object-reference vm addr 0) referent)
          (setf (vm-object-reference vm addr 1) 0)
          (when (typep plan 'weak-reference-trait)
            (vector-push-extend addr (plan-weak-pointers plan)))
          addr)))))

(defun process-weak-references (plan)
  "Update forwarded referents and clear weak pointers whose referents are dead.
Runs during the :sweep phase (after marking, before sweeping/bit-clearing)
so mark bits and forwarding pointers are still valid."
  (let* ((vm (plan-vm plan))
         (live-count 0))
    (loop with wp-vec = (plan-weak-pointers plan)
          for i from 0 below (fill-pointer wp-vec)
          do (let* ((wp (aref wp-vec i))
                    (ref (vm-object-reference vm wp 0))
                    (alive-p nil))
               ;; Resolve forwarding first (for copying collectors)
               (when (and (not (zerop ref))
                          (vm-object-is-forwarded-p vm ref))
                 (let ((new-ref (vm-object-forwarding-pointer vm ref)))
                   (setf (vm-object-reference vm wp 0) new-ref)
                   (setf ref new-ref)))
               ;; Check if referent survived GC
               ;; For copying collectors: forwarded ⇒ alive
               ;; For mark-sweep/immix: marked ⇒ alive
               (setf alive-p (and (not (zerop ref))
                                  (or (vm-object-is-forwarded-p vm ref)
                                      (vm-object-is-marked-p vm ref))))
               (if alive-p
                   (progn
                     (setf (aref wp-vec live-count) wp)
                     (incf live-count))
                   (setf (vm-object-reference vm wp 0) 0))))
    (setf (fill-pointer (plan-weak-pointers plan)) live-count)))

(defmethod plan-collect-phase gc-phase ((plan weak-reference-trait) (cycle-kind t))
  "Process weak references during the sweep phase, after marking but
before mark bits are cleared and dead objects are swept."
  (:sweep
    (process-weak-references plan)))
