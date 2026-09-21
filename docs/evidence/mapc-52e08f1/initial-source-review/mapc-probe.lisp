;;;; SOURCE ONLY. Not executed in the bounded investigation.
;;;; Load only after the parent grants a native slot and CLAMSARA/WORKLOAD
;;;; is loaded normally. No bootstrap, dependency patch, or fixture change.
;;;; Calling RUN-MAPC-NEXT-PROBE is an adapter regression, not Gabriel acceptance.
(defpackage #:clamsara.workload.mapc.next-probe
  (:use #:cl #:clamsara)
  (:export #:run-mapc-next-probe))
(in-package #:clamsara.workload.mapc.next-probe)

(defparameter *semantic-form*
  '(let ((first (cons 1 (cons 2 (cons 3 nil))))
         (second (cons 10 (cons 20 nil)))
         (total 0))
     (values
      (eq first
          (funcall #'mapc (lambda (x y) (incf total (+ x y))) first second))
      total)))

(defparameter *moving-form*
  ;; No outer alias keeps either input graph alive. MAPC must retain the
  ;; original first list while its cursors and the callback args move.
  ;; CONS is explicit: no guest LIST/&REST or quoted compound literal needed.
  '(funcall #'mapc
     (lambda (x y)
       (dotimes (i 600) (cons nil nil))
       ;; Read both arguments AFTER allocation, not saved integer copies.
       (rplaca x (+ (car x) (car y))))
     (cons (cons 1 nil) (cons (cons 2 nil) (cons (cons 3 nil) nil)))
     (cons (cons 10 nil) (cons (cons 20 nil) nil))))

(defun full-cycle (runtime)
  (let ((record (make-cycle-result-record
                 (clamsara::workload-runtime-plan runtime))))
    (collect (clamsara::workload-runtime-configuration runtime)
             :all :explicit record)
    (assert (eq :complete (cycle-result-status record)))
    record))

(defun run-mapc-next-probe ()
  ;; Native semantic oracles are evaluated only when this function is called.
  (let ((semantic-oracle (multiple-value-list (eval *semantic-form*)))
        (moving-oracle (mapcar #'car (eval *moving-form*))))
    (assert (equal '(t 33) semantic-oracle))
    (assert (equal '(11 22 3) moving-oracle))
    (let* ((rt (make-workload-runtime :extent 16384 :max-object-bytes 8192
                                      :root-capacity 512))
           (env (clamsara::workload-runtime-environment rt))
           (client (clamsara::workload-maclina-client env))
           (compiler-env (clamsara::workload-maclina-environment env)))
      (unwind-protect
           (progn
             ;; Isolate the installed function's arity with NO managed
             ;; allocation or compiler-macro dependence. Baseline prediction:
             ;; WRONG-NUMBER-OF-ARGUMENTS, given 3, expected exactly 2.
             (let ((calls 0))
               (assert
                (null (funcall (clostrum:fdefinition client compiler-env 'cl:mapc)
                               (lambda (a b)
                                 (declare (ignore a b)) (incf calls))
                               nil nil)))
               (assert (zerop calls)))
             (assert (equal semantic-oracle
                            (multiple-value-list
                             (workload-eval env *semantic-form*))))
             (workload-eval env nil) ; owner consumes the scalar result
             ;; Deliberately do not retain the host return-reference snapshot.
             (workload-eval env *moving-form*)
             (let ((automatic (clamsara::%plan-automatic-result
                               (clamsara::workload-runtime-plan rt))))
               (assert (eq :complete (cycle-result-status automatic)))
               (assert (plusp (cycle-result-count automatic :objects-moved))))
             ;; Only VM-VALUES owns the completed graph now. Reacquire its
             ;; corrected physical value AFTER collection. No hidden root.
             (let ((record (full-cycle rt)))
               (assert (= 6 (cycle-result-count record :objects-discovered)))
               (assert (= 6 (cycle-result-count record :objects-moved))))
             (let* ((vm (clamsara::workload-provider-vm
                         (clamsara::workload-runtime-root-provider rt)))
                    (cursor (first (maclina.vm-cross::vm-values vm)))
                    (seen (make-hash-table :test #'eq)))
               (dolist (expected moving-oracle)
                 (assert (workload-reference-p env cursor))
                 (assert (not (gethash cursor seen)))
                 (setf (gethash cursor seen) t)
                 (let ((leaf (workload-read-slot env cursor :car)))
                   (assert (workload-reference-p env leaf))
                   (assert (not (gethash leaf seen)))
                   (setf (gethash leaf seen) t)
                   (assert (= expected (workload-read-slot env leaf :car)))
                   (assert (null (workload-read-slot env leaf :cdr))))
                 (setf cursor (workload-read-slot env cursor :cdr)))
               (assert (null cursor))
               (assert (= 6 (hash-table-count seen))))
             ;; Application discharge, not register/vector erasure.
             (workload-eval env nil)
             (assert (zerop (cycle-result-count (full-cycle rt)
                                                :objects-discovered)))
             (format t "~&MAPC-NEXT-PROBE :COMPLETE~%")
             t)
        ;; On either success or error, consume only this probe's result.
        ;; Do not swallow close failure or clear arbitrary roots.
        (workload-eval env nil)
        (close-workload-runtime rt)))))
