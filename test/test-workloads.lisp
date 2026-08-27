;;;; test/test-workloads.lisp -- bounded paper-v8 workload/model checks.
;;;;
;;;; This is deliberately a small, host-driven model checker rather than a
;;;; benchmark.  The only objects it creates in the simulated heap are the
;;;; fixed-size objects below; the model keeps object identities separately so
;;;; moving collectors can be checked without assuming stable addresses.

(in-package #:clamsara)

(defparameter *paper-v8-workload-plans*
  '(:semispace :marksweep :immix :gencopy :genms :genimmix
    :stickyimmix :stickyms :iso :zgcish :claimore))
(defparameter *paper-v8-workload-seeds* '(13579 24680))
(defparameter *paper-v8-workload-steps* 72)

;; A failure is retained as data (rather than only printed), making a failing
;; CI run reproducible from the seed and the concrete action trace.
(defvar *paper-v8-last-failure* nil)

(defstruct (paper-v8-rng (:constructor make-paper-v8-rng (state)))
  (state 1 :type fixnum))

(defun paper-v8-random (rng)
  ;; A tiny xorshift with a deliberately small state.  Keeping the state below
  ;; 2^24 avoids implementation-dependent bignums in the test driver.
  (let ((x (logand (paper-v8-rng-state rng) #xffffff)))
    (setf x (logand (logxor x (ash x 13)) #xffffff))
    (setf x (logand (logxor x (ash x -7)) #xffffff))
    (setf x (logand (logxor x (ash x 17)) #xffffff))
    (when (zerop x) (setf x #x13579))
    (setf (paper-v8-rng-state rng) x)))

(defstruct (paper-v8-node (:constructor make-paper-v8-node (id address slots)))
  (id 0 :type fixnum)
  (address 0 :type fixnum)
  slots)

(defun paper-v8-node-by-id (nodes)
  (let ((result (make-hash-table :test #'eql)))
    (dolist (node nodes result)
      (setf (gethash (paper-v8-node-id node) result) node))))

(defun paper-v8-live-nodes (nodes roots)
  "Return model nodes reachable from ROOTS, in deterministic ID order."
  (let ((by-id (paper-v8-node-by-id nodes))
        (seen (make-hash-table :test #'eql))
        (stack (copy-list roots))
        result)
    (loop while stack
          for id = (pop stack)
          unless (gethash id seen)
            do (setf (gethash id seen) t)
               (let ((node (gethash id by-id)))
                 (when node
                   (push node result)
                   (dotimes (i (length (paper-v8-node-slots node)))
                     (let ((child (aref (paper-v8-node-slots node) i)))
                       (when child (push child stack)))))))
    (sort result #'< :key #'paper-v8-node-id)))

(defun paper-v8-failure (plan seed trace message)
  (let ((chronological (reverse trace)))
    (setf *paper-v8-last-failure*
          (list :plan plan :seed seed :trace chronological :message message))
    (values nil
            (format nil "~a [plan=~a seed=~d trace=~s]"
                    message plan seed chronological))))

(defun paper-v8-check-graph (nodes roots vm)
  "Check the concrete graph against NODES and ROOTS after a collection.
Returns NIL plus a short explanation on the first mismatch."
  (let ((by-id (paper-v8-node-by-id nodes))
        (seen (make-hash-table :test #'eql))
        (addresses (make-hash-table :test #'eql))
        (error-message nil))
    (labels ((bad (format-control &rest args)
               (unless error-message
                 (setf error-message (apply #'format nil format-control args)))
               nil)
             (visit (id reference)
               (let* ((node (gethash id by-id))
                      (address (ref-strip vm reference)))
                 (unless node (return-from visit (bad "unknown node ~a" id)))
                 (when (gethash id seen)
                   (let ((old (gethash id addresses)))
                     (unless (= old address)
                       (return-from visit
                         (bad "node ~a has two addresses (~a and ~a)"
                              id old address))))
                   (return-from visit t))
                 (unless (and (plusp address)
                              (vm-valid-reference-p vm address)
                              (vm-object-start-p vm address))
                   (return-from visit
                     (bad "node ~a points at invalid address ~a" id address)))
                 (setf (gethash id seen) t
                       (gethash id addresses) address
                       (paper-v8-node-address node) address)
                 (let ((count (vm-object-reference-count vm address))
                       (slots (paper-v8-node-slots node)))
                   (unless (= count (length slots))
                     (return-from visit
                       (bad "node ~a has ~a slots, expected ~a"
                            id count (length slots))))
                   (dotimes (slot count)
                     (let* ((expected (aref slots slot))
                            (actual (ref-strip
                                     vm (vm-object-reference vm address slot))))
                       (if expected
                           (unless (visit expected actual)
                             (return-from visit nil))
                           (unless (zerop actual)
                             (return-from visit
                               (bad "node ~a slot ~a unexpectedly points to ~a"
                                    id slot actual)))))))
                 t)))
      (unless (= (length roots) (length (vm-root-vector vm)))
        (bad "model has ~a roots, VM has ~a"
             (length roots) (length (vm-root-vector vm))))
      (unless error-message
        (loop for id in roots
              for index from 0
              do (unless (visit id (aref (vm-root-vector vm) index))
                   (return))))
      (if error-message
          (values nil error-message)
          (progn
            ;; Forget unreachable model objects before the next mutator step;
            ;; their old addresses are no longer legal mutator references.
            (setf nodes
                  (delete-if-not
                   (lambda (node) (gethash (paper-v8-node-id node) seen))
                   nodes))
            (values t "ok" nodes))))))

(defun paper-v8-gc-kind (plan step)
  (if (member plan '(:gencopy :genms :genimmix))
      (if (zerop (mod step 4)) :major :minor)
      :full))

(defun paper-v8-run (plan-type seed)
  (let ((trace nil))
    (labels ((record (event) (push event trace))
             (fail (message) (paper-v8-failure plan-type seed trace message)))
      (handler-case
          (with-clamsara (:plan-type plan-type :heap-size 65536)
            (let ((rng (make-paper-v8-rng seed))
                  (nodes nil)
                  (roots nil)
                  (next-id 0))
              (labels ((allocate-root (slots)
                         (let ((address (clamsara-allocate-object slots))
                               (id next-id))
                           (incf next-id)
                           (unless (plusp address)
                             (return-from paper-v8-run
                               (fail (format nil
                                             "allocation failed for ~a slots"
                                             slots))))
                             (let ((node (make-paper-v8-node
                                        id address (make-array slots
                                                                :initial-element nil))))
                               (push node nodes)
                               (let ((index (clamsara-register-root address)))
                                 (unless (= index (length roots))
                                   (return-from paper-v8-run
                                     (fail (format nil "root index ~a, expected ~a"
                                                   index (length roots)))))
                                 ;; Publication collectors may replace an
                                 ;; object while registering an external root.
                                 ;; The root index is the stable handle;
                                 ;; retaining ADDRESS here would make the model
                                 ;; report a simulator failure against the
                                 ;; private pre-publication incarnation.
                                 (setf (paper-v8-node-address node)
                                       (clamsara-root index))
                                 (setf roots (append roots (list id)))))))
                       (drop-root (index)
                         (let* ((last-index (1- (length roots)))
                                (dropped (nth index roots))
                                (last-id (nth last-index roots)))
                           (clamsara-remove-root index)
                           (setf roots
                                 (if (= index last-index)
                                     (butlast roots)
                                     (let ((copy (copy-list roots)))
                                       (setf (nth index copy) last-id)
                                       (butlast copy))))
                           (record (list :root-drop index dropped))))
                       (collect (step)
                         (let ((kind (paper-v8-gc-kind plan-type step)))
                           (record (list :gc kind))
                           (clamsara-gc :cycle-kind kind)
                           (multiple-value-bind (ok message pruned)
                               (paper-v8-check-graph nodes roots *clamsara-vm*)
                             (unless ok (return-from paper-v8-run (fail message)))
                             (setf nodes pruned))))
                       (mutate ()
                         (let ((live (paper-v8-live-nodes nodes roots)))
                           (when live
                             (let* ((source (nth (mod (paper-v8-random rng)
                                                       (length live)) live))
                                    (slots (paper-v8-node-slots source))
                                    (slot (mod (paper-v8-random rng)
                                               (length slots)))
                                    (target (and (not (zerop (mod
                                                              (paper-v8-random rng)
                                                              5)))
                                                 (nth (mod (paper-v8-random rng)
                                                           (length live)) live)))
                                    (target-id (and target
                                                    (paper-v8-node-id target))))
                               (record (list :mutate (paper-v8-node-id source)
                                             slot target-id))
                               (setf (aref slots slot) target-id)
                               (clamsara-write (paper-v8-node-address source) slot
                                               (if target
                                                   (paper-v8-node-address target)
                                                   0)))))))
                ;; Seed each trace with one rooted object.  Every allocation is
                ;; rooted until an explicit root-drop action, so no stale raw
                ;; address can be used by a later mutator operation.
                (allocate-root 3)
                (dotimes (step *paper-v8-workload-steps*)
                  (let ((choice (mod (paper-v8-random rng) 100)))
                    (cond
                      ((< choice 38)
                       (allocate-root (1+ (mod (paper-v8-random rng) 3)))
                       (record (list :allocate (1- next-id)
                                     (paper-v8-node-id (car nodes)))))
                      ((< choice 70) (mutate))
                      ((< choice 82)
                       (when roots
                         (drop-root (mod (paper-v8-random rng)
                                         (length roots)))))
                      ((< choice 89)
                       ;; Keep one root slot per model identity.  Besides making
                       ;; the trace easier to replay, this avoids asking a
                       ;; copying collector to process duplicate root slots
                       ;; while the model is updating its address map.
                       (let ((live (remove-if
                                    (lambda (node)
                                      (member (paper-v8-node-id node) roots
                                              :test #'eql))
                                    (paper-v8-live-nodes nodes roots))))
                         (when live
                           (let* ((node (nth (mod (paper-v8-random rng)
                                                 (length live)) live))
                                  (index (clamsara-register-root
                                          (paper-v8-node-address node))))
                             (setf (paper-v8-node-address node)
                                   (clamsara-root index))
                             (setf roots (append roots
                                                  (list (paper-v8-node-id node))))
                             (record (list :root-add index
                                           (paper-v8-node-id node)))))))
                      (t (collect step)))
                    ;; Frequent fixed fences keep the trace small and bound
                    ;; both simulated allocation and model state.
                    (when (= (mod step 9) 8)
                      (collect step))))
                ;; Always exercise a final fence, including the empty-root
                ;; state reached by a root-drop-heavy trace.
                (collect *paper-v8-workload-steps*)
                (values t "ok"))))
        (error (condition)
          (fail (format nil "condition ~a" condition)))))))

;; Register one bounded deterministic test per plan/seed.  This keeps a test
;; failure attributable while using the same model and action generator for
;; every collector coordinate we currently support.
(dolist (plan *paper-v8-workload-plans*)
  (dolist (seed *paper-v8-workload-seeds*)
    (let ((name (intern (format nil "PAPER-V8-WORKLOAD-~A-~D" plan seed))))
      (push (cons name
                  (let ((p plan) (s seed))
                    (lambda () (paper-v8-run p s))))
            *clamsara-tests*))))

(deftest paper-v8-persistence-checkpoint-replay-workload ()
  ;; Exercise the complete fence path with real simulated objects and the
  ;; generational card barrier: base image, post-fence write, delta segment,
  ;; then replay into a fresh heap image.
  (handler-case
      (with-clamsara (:plan-type :genms :heap-size 65536)
        (let* ((vm *clamsara-vm*)
               (plan *clamsara-plan*)
               (parent (clamsara-allocate-object 1))
               (child-a (clamsara-allocate-object 0))
               (child-b (clamsara-allocate-object 0))
               (marker (+ (page-start-address 3) 11)))
          (clamsara-register-root parent)
          (clamsara-write parent 0 child-a)
          (setf (ref-u64 vm marker) 31337)
          (checkpoint-heap plan :timestamp 101)
          ;; The MMU is armed by the first fence.  This write is both a card
          ;; event and a simulator write fault, and must become the second
          ;; segment's replayed value.
          (clamsara-write parent 0 child-b)
          (checkpoint-heap plan :timestamp 202)
          (let* ((log (vm-persistence-log vm))
                 (heap (replay-persistence-log log vm))
                 (segments (persistence-log-segments log))
                 (slot (+ parent 1)))
            (if (and heap (= (length segments) 2)
                     (every (lambda (segment) (verify-segment segment vm)) segments)
                     (= (aref heap marker) 31337)
                     (= (aref heap slot) child-b))
                (values t "ok")
                (values nil
                        (format nil "replay mismatch: segments=~a marker=~a slot=~a"
                                (length segments) (aref heap marker)
                                (aref heap slot)))))))
    (error (condition)
      (values nil (format nil "persistence workload condition ~a" condition)))))
