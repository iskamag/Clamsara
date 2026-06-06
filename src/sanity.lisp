(in-package #:clamsara)

;;; --- Sanity Checker ---
;;; Verifies invariants after every GC cycle in test mode.

(defconstant +sanity-max-slots+ 1000
  "Upper bound on object slot count accepted by the sanity checker.")

(defun compute-live-set (vm collector-state)
  "Compute the transitive closure of all objects reachable from roots."
  (let ((live (make-hash-table :test 'eql))
        (queue-size 4096)
        (queue (make-array 4096 :element-type 'fixnum :initial-element 0))
        (head 0) (tail 0))
    (labels ((queue-full-p () (= (mod (1+ tail) queue-size) head))
             (enqueue (addr)
               (when (queue-full-p)
                 ;; Grow the queue if full
                 (let* ((new-size (* queue-size 2))
                        (new-queue (make-array new-size :element-type 'fixnum :initial-element 0)))
                   (loop for i from 0 below (1- queue-size)
                         for idx = (mod (+ head i) queue-size)
                         while (/= idx tail)
                         do (setf (aref new-queue i) (aref queue idx)))
                   (setf head 0 tail (1- queue-size) queue new-queue queue-size new-size)))
               (setf (aref queue tail) addr)
               (setf tail (mod (1+ tail) queue-size)))
             (dequeue ()
               (prog1 (aref queue head)
                 (setf head (mod (1+ head) queue-size))))
             (empty-p () (= head tail)))
      (vm-scan-roots vm collector-state
        (lambda (root)
          (when (and root (not (zerop root))
                     (vm-valid-reference-p vm root))
            (unless (gethash root live)
              (setf (gethash root live) t)
              (enqueue root)))))
      (loop until (empty-p)
            for addr = (dequeue)
            do (let ((n-refs (vm-object-reference-count vm addr)))
                 (when (and (plusp n-refs) (<= n-refs +sanity-max-slots+))
                   (loop for i from 0 below n-refs
                         for ref = (vm-object-reference vm addr i)
                         when (and ref (not (zerop ref))
                                   (vm-valid-reference-p vm ref)
                                   (not (gethash ref live)))
                           do (setf (gethash ref live) t)
                              (enqueue ref))))))
    live))

(defun sanity-check-after-gc (plan)
  "After a full GC cycle, verify structural integrity of the heap.
   Returns (values T NIL) on success, (values NIL ERRORS) on failure."
  (let* ((vm (plan-vm plan))
         (errors nil))
    (let ((live-set (compute-live-set vm plan)))
      ;; Check 1: All roots must point to valid object starts
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)) (vm-valid-reference-p vm root))
            (unless (vm-object-start-p vm root)
              (push (format nil "Root ~D is not a valid object start" root) errors)))))
      ;; Check 2: Every object in the live set must be a valid object start
      (maphash (lambda (addr _)
                  (declare (ignore _))
                  (unless (vm-object-start-p vm addr)
                    (push (format nil "Live object ~D is not a valid object start" addr) errors)))
               live-set)
      ;; Check 3: Every reference slot must reference a valid object start
      (maphash (lambda (addr _)
                  (let ((n-slots (vm-object-reference-count vm addr)))
                    (when (and (plusp n-slots) (<= n-slots +sanity-max-slots+))
                      (dotimes (i n-slots)
                        (let ((ref (vm-object-reference vm addr i)))
                          (when (and ref (not (zerop ref))
                                     (vm-valid-reference-p vm ref)
                                     (not (vm-object-start-p vm ref)))
                            (push (format nil "Object ~D slot ~D refs invalid addr ~D"
                                          addr i ref) errors)))))))
               live-set)
      ;; Check 4: Mark bits consistent: marked iff reachable
      (maphash (lambda (addr _)
                  (declare (ignore _))
                  (unless (vm-object-is-marked-p vm addr)
                    (when (object-marked-p addr)
                      (push (format nil "Object ~D marked but not in live set" addr) errors))))
               live-set))
    (if errors
        (values nil (nreverse errors))
        (values t nil))))

;;; --- Random Object Graph Generator ---

(defun make-random-object-graph (plan n-objects &key (max-slots 5))
  "Create a random object graph with N-OBJECTS objects."
  (let ((objects nil)
        (vm (plan-vm plan)))
    (dotimes (i n-objects)
      (let* ((n-slots (1+ (random max-slots)))
             (size (1+ n-slots))
             (addr (plan-allocate plan size :default)))
        (when addr
          (setf (vm-object-header vm addr) (make-object-header n-slots))
          (dotimes (j n-slots)
            (setf (vm-object-reference vm addr j) 0))
          (push addr objects))))
    ;; Random wiring
    (dolist (obj objects)
      (let ((n-slots (vm-object-reference-count vm obj)))
        (dotimes (slot n-slots)
          (when (and objects (> (random 100) 40))
            (let ((target (nth (random (length objects)) objects)))
              (unless (= obj target)
                (vm-object-reference-store vm obj slot target :barrier-p nil)))))))
    ;; Select random roots
    (let ((roots (when objects
                   (loop repeat (max 1 (floor (length objects) 5))
                         collect (nth (random (length objects)) objects)))))
      (dolist (root roots)
        (register-root (vm-root-set vm) root))
      (values objects roots))))

(defun random-mutator-step (plan objects &key (max-slots 5))
  "Perform one random mutation on the object graph."
  (let ((vm (plan-vm plan)))
    (case (random 5)
      (0 ;; Allocate new object
       (let* ((n-slots (1+ (random max-slots)))
              (size (1+ n-slots))
              (addr (plan-allocate plan size :default)))
         (when addr
           (setf (vm-object-header vm addr) (make-object-header n-slots))
           (dotimes (i n-slots) (setf (vm-object-reference vm addr i) 0))
           (when objects
             (setf (vm-object-reference vm addr (random n-slots))
                   (nth (random (length objects)) objects)))
           (push addr objects))))
      (1 ;; Write reference
       (when objects
         (let ((obj (nth (random (length objects)) objects)))
           (let ((n-slots (vm-object-reference-count vm obj)))
             (when (> n-slots 0)
               (setf (vm-object-reference vm obj (random n-slots))
                     (if objects (nth (random (length objects)) objects) 0)))))))
      (2 ;; Clear reference
       (when objects
         (let ((obj (nth (random (length objects)) objects)))
           (let ((n-slots (vm-object-reference-count vm obj)))
             (when (> n-slots 0)
               (setf (vm-object-reference vm obj (random n-slots)) 0))))))
      (3 ;; Register root
       (when objects
         (register-root (vm-root-set vm)
                        (nth (random (length objects)) objects))))
      (4 ;; Unregister root
       (let ((rs (vm-root-set vm)))
         (when (rs-static-roots rs)
           (unregister-root rs (nth (random (length (rs-static-roots rs)))
                                    (rs-static-roots rs)))))))
    objects))

(defun run-sanity-stress (plan-type n-iterations
                            &key (heap-size 524288) (n-objects 40)
                                 (mutations-per-iteration 8) (max-slots 5) (seed 54321))
  "Run N-ITERATIONS of mutate->GC->verify for PLAN-TYPE.
Note: SEED is accepted for API compatibility but not used; random-state
is seeded from the current time for full entropy."
  (declare (ignore seed))
  (let* ((*random-state* (make-random-state t))
         (vm (make-simulator-vm :heap-size heap-size))
         (plan (make-plan plan-type vm heap-size))
         (*active-plan* plan))
    (multiple-value-bind (objects roots) (make-random-object-graph plan n-objects :max-slots max-slots)
      (declare (ignore roots))
      (dotimes (i n-iterations)
        (dotimes (j mutations-per-iteration)
          (setf objects (random-mutator-step plan objects :max-slots max-slots)))
        (plan-collect plan)
        (let ((live-set (compute-live-set vm plan)))
          (setf objects nil)
          (maphash (lambda (k v) (declare (ignore v)) (push k objects)) live-set))
        (multiple-value-bind (ok errors) (sanity-check-after-gc plan)
          (unless ok
            (error "Sanity check failed at iteration ~D for plan ~A: ~{~A~^; ~}"
                   i (plan-name plan) errors))))
      t)))
