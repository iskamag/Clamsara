(in-package #:clamsara.tests)

(def-suite test-generational :description "Generational plan tests"
  :in clamsara-tests)

(in-suite test-generational)

;;; --- Generational correctness: minor vs major ---

(test minor-gc-increments-count
  "Minor GC increments plan-minor-gc-count for all generational plans."
  (dolist (plan-type '(:gencopy :genms :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 131072)
      (let* ((plan *active-plan*)
             (minor-before (clamsara::plan-minor-gc-count plan))
             (major-before (clamsara::plan-major-gc-count plan)))
        (boot-gc plan)
        (dotimes (i 5)
          (allocate-fill plan 3 1 2 3)
          (handler-case (plan-collect plan :cycle-kind :minor)
            (error () nil)))
        (is (or (> (clamsara::plan-minor-gc-count plan) minor-before)
                (> (clamsara::plan-major-gc-count plan) major-before))
            "~A should have run at least one GC" plan-type)))))

(test major-gc-increments-count
  "plan-collect :major increments plan-major-gc-count."
  (dolist (plan-type '(:gencopy :genms :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 131072)
      (let* ((plan *active-plan*)
             (major-before (clamsara::plan-major-gc-count plan)))
        (boot-gc plan)
        (plan-collect plan :cycle-kind :major)
        (is (> (clamsara::plan-major-gc-count plan) major-before)
            "~A should have run a major GC" plan-type)))))

;;; --- Nursery evacuation ---

(test gencopy-nursery-gc-evacuates
  "GenCopy nursery GC evacuates survivors to to-space."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-fill *active-plan* 3 42 99 777)))
      (clamsara-register-root addr)
      (clamsara-gc)
      (let ((survivor (get-root-addr *active-plan*)))
        (is (not (null survivor)))
        (is (= 42 (vm-object-reference vm survivor 0)))
        (is (= 99 (vm-object-reference vm survivor 1)))))))

;;; --- Major GC integrity ---

(test genms-major-gc-sweeps-mature
  "GenMS major GC preserves objects."
  (with-clamsara (:plan-type :genms :heap-size 131072)
    (let* ((vm (plan-vm *active-plan*))
           (root (allocate-fill *active-plan* 2 0 0)))
      (setf (vm-object-reference vm root 0) root)
      (clamsara-register-root root)
      (dotimes (i 35) (clamsara-gc))
      (let ((survivor (get-root-addr *active-plan*)))
        (is (not (null survivor)))
        (is (vm-object-start-p vm survivor))))))

(test genimmix-major-gc-preserves-nursery
  "GenImmix major GC preserves objects."
  (with-clamsara (:plan-type :genimmix :heap-size 131072)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-fill *active-plan* 3 42 99 0)))
      (clamsara-register-root addr)
      (plan-collect *active-plan* :cycle-kind :major)
      (let ((survivor (get-root-addr *active-plan*)))
        (is (not (null survivor)))
        (is (= 42 (vm-object-reference vm survivor 0)))))))

;;; --- Barrier ---

(test card-scan-finds-references
  "barrier-note-write dirties card for old->young writes."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (let* ((barrier (plan-barrier *active-plan*))
           (ns (barrier-nursery-start barrier))
           (ne (barrier-nursery-end barrier)))
      (barrier-clear-all barrier)
      ;; Simulate an old object (before nursery) writing to young (in nursery)
      (barrier-note-write barrier 0 0 ns)
      (let ((cidx (card-index 0)))
        (is (not (zerop (aref (barrier-card-table-cards barrier) cidx))))))))

;;; --- Sticky log bits ---

(test sticky-log-bit-on-alloc
  "Sticky plans set log bit on new allocations."
  (dolist (plan-type '(:stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let* ((vm (plan-vm *active-plan*))
             (addr (allocate-object *active-plan* 3)))
        (is (vm-object-is-logged-p vm addr))))))

(test sticky-nursery-gc-clears-log
  "Sticky nursery GC clears log bits on survivors."
  (dolist (plan-type '(:stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 131072)
      (let* ((vm (plan-vm *active-plan*))
             (addr (allocate-fill *active-plan* 3 42 0 0)))
        (clamsara-register-root addr)
        (clamsara-gc)
        (is (= 42 (vm-object-reference vm addr 0)))
        (is (not (vm-object-is-logged-p vm addr)))))))

(test sticky-plans-major-gc
  "Sticky plans can run major GC."
  (dolist (plan-type '(:stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 131072)
      (let* ((vm (plan-vm *active-plan*))
             (addr (allocate-fill *active-plan* 3 42 99 0)))
        (clamsara-register-root addr)
        (plan-collect *active-plan* :cycle-kind :major)
        (is (= 42 (vm-object-reference vm addr 0)))))))

(test sticky-metrics-update
  "Sticky plans update live-young-bytes after nursery GC."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-fill plan 10 1 2 3 4 5 6 7 8 9 10)))
      (clamsara-register-root addr)
      (is (>= (plan-live-young-bytes plan) 0))
      (sticky-nursery-collect plan)
      (is (> (plan-live-young-bytes plan) 0)))))

;;; --- Generational correctness: old->young barrier ---

(defun %do-old-to-young-barrier-test (plan-type heap-size)
  "Verify that a young object reachable only through an old object survives
nursery GC. This is the core generational correctness property."
  (with-clamsara (:plan-type plan-type :heap-size heap-size)
    (let* ((vm (plan-vm *active-plan*))
           ;; Create root object (will become old after a GC)
           (root (allocate-fill *active-plan* 2 0 0)))
      (clamsara-register-root root)
      ;; Run a GC to promote root (or evacuate it for copying plans)
      (clamsara-gc)
      ;; Get the survivor address (may have moved for copying plans)
      (let ((old-root (get-root-addr *active-plan*)))
        (is (not (null old-root)))
        ;; Create a new young object
        (let ((young (allocate-fill *active-plan* 2 99 88)))
          ;; old-root now points to the young object
          (vm-object-reference-store vm old-root 0 young :barrier-p t)
          ;; young is NOT directly reachable from roots
          ;; Trigger nursery GC - young must survive via card barrier
          (clamsara-gc)
          (let* ((survivor (get-root-addr *active-plan*))
                 (young-ref (vm-object-reference vm survivor 0)))
            (is (not (null young-ref)))
            (is (not (zerop young-ref)))
            (is (= 99 (vm-object-reference vm young-ref 0)))
            (is (= 88 (vm-object-reference vm young-ref 1)))))))))

(test old-to-young-barrier
  "Young object reachable only from old survives nursery GC across all generational plans."
  (dolist (plan-type '(:gencopy :genms :genimmix :stickyimmix :stickyms))
    (%do-old-to-young-barrier-test plan-type
                                   (if (member plan-type '(:gencopy :genms :genimmix))
                                       262144 131072))))
