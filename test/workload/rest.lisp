;;;; Guest &REST bridge regression: a guest lambda with &REST must receive a
;;;; MANAGED list (guest CAR/CDR require managed cons cells), and the built
;;;; list must stay correct across a forced moving collection.
;;;;
;;;; Load after ASDF system CLAMSARA/WORKLOAD.  This is a candidate regression
;;;; for the &REST bridge; see src/workload/maclina.lisp.
(defpackage #:clamsara.workload.rest.test
  (:use #:cl #:clamsara)
  (:export #:run-workload-rest-tests))
(in-package #:clamsara.workload.rest.test)

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments))
  value)

(defun run-workload-rest-tests ()
  (let* ((runtime (make-workload-runtime :extent (* 1024 1024) :root-capacity 1024))
         (env (clamsara::workload-runtime-environment runtime))
         (config (clamsara::workload-runtime-configuration runtime))
         (plan (clamsara::workload-runtime-plan runtime))
         (model (clamsara::workload-model env)))
    (labels ((ev (form) (workload-eval env form))
             (discharge ()
               (dotimes (i (clamsara::workload-provider-temporary-capacity
                            (clamsara::workload-runtime-root-provider runtime)))
                 (clamsara::workload-temporary-root-clear env i))
               (let ((vm (clamsara::workload-provider-vm
                          (clamsara::workload-runtime-root-provider runtime))))
                 (setf (maclina.vm-cross::vm-values vm) nil
                       (maclina.vm-cross::vm-dynenv-stack vm) nil
                       (maclina.vm-cross::vm-stack-top vm) 0))
               (let ((rec (make-cycle-result-record plan)))
                 (collect config :all :explicit rec)
                 (check (eq :complete (cycle-result-status rec))
                        "Discharge collection failed: ~S/~S"
                        (cycle-result-status rec) (cycle-result-reason rec)))))
      (unwind-protect
           (progn
             ;; A &REST parameter is a managed list, not a host list.
             (check (= 1 (ev '((lambda (&rest x) (car x)) 1 2)))
                    "&REST car did not see a managed list")
             (check (= 2 (ev '(length (list 0 3))))
                    "list did not build a 2-element managed list")
             (check (= 0 (ev '(car (list 0 3))))
                    "list first element wrong")
             (check (= 4 (ev '(length (append (list 1) (list 2 3) (list 4)))))
                    "append/&REST lengths wrong")
             (check (= 7 (ev '(car (append (list 7 8) (list 9)))))
                    "append order wrong")
             (check (= 4 (ev '(car (mapcar (lambda (x) x) (list 4 5)))))
                    "mapcar over a rest-built list failed")
             ;; Root a rest-built list and force a moving collection; every
             ;; element must remain reachable and correctly ordered.
             (let ((value (ev '(list 10 20 30)))
                   (record (make-cycle-result-record plan)))
               (clamsara::workload-temporary-root-clear env 0)
               (root-provider-store
                (clamsara::workload-root-client env) (clamsara::workload-context env)
                (clamsara::workload-root-token env)
                (aref (clamsara::workload-root-locations env) 0) value)
               (collect config :all :explicit record)
               (check (eq :complete (cycle-result-status record))
                      "Forced collection failed: ~S/~S"
                      (cycle-result-status record) (cycle-result-reason record))
               (let* ((moved (clamsara::workload-temporary-root-load env 0))
                      (second (workload-read-slot env moved :cdr)))
                 (check (= 10 (workload-read-slot env moved :car))
                        "Moved rest list first element wrong")
                 (check (= 20 (workload-read-slot env second :car))
                        "Moved rest list second element wrong"))))
        (discharge)
        (close-workload-runtime runtime)))
    (format t "~&WORKLOAD-REST-PASS~%")
    t))
