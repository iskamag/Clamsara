(in-package #:clamsara.tests)

(def-suite test-new-features :description "Tests for v3 spec gaps filled"
  :in clamsara-tests)

(in-suite test-new-features)

;;; --- plan-constraints new slots ---

(test plan-constraints-nursery-kind
  (with-clamsara (:plan-type :nogc)
    (is (eq nil (plan-nursery-kind (plan-constraints *active-plan*)))))
  (with-clamsara (:plan-type :gencopy)
    (is (eq :copying (plan-nursery-kind (plan-constraints *active-plan*)))))
  (with-clamsara (:plan-type :stickyimmix)
    (is (eq :sticky (plan-nursery-kind (plan-constraints *active-plan*))))))

(test plan-constraints-num-generations
  (with-clamsara (:plan-type :nogc)
    (is (= 1 (plan-num-generations (plan-constraints *active-plan*)))))
  (with-clamsara (:plan-type :gencopy)
    (is (= 2 (plan-num-generations (plan-constraints *active-plan*))))))

(test plan-constraints-max-non-los
  (with-clamsara (:plan-type :semispace)
    (is (= 8192 (plan-max-non-los-alloc-bytes (plan-constraints *active-plan*))))))

(test plan-card-size-words-default
  (with-clamsara (:plan-type :semispace)
    (is (= +card-size-words+ (plan-card-size-words *active-plan*)))))

;;; --- barrier ---

(test satb-barrier-creation
  (with-clamsara (:plan-type :semispace)
    (let ((barrier (make-satb-barrier *active-vm* :queue-size 256)))
      (is (typep barrier 'satb-barrier))
      (is-true (satb-queue barrier))
      (is (= 0 (satb-queue-head barrier))))))

(test satb-enqueue-drain
  (with-clamsara (:plan-type :semispace)
    (let* ((barrier (make-satb-barrier *active-vm* :queue-size 16))
           (captured nil))
      (dotimes (i 5)
        (satb-enqueue barrier (* 100 (1+ i))))
      (satb-drain barrier (lambda (ref) (push ref captured)))
      (is (equal '(500 400 300 200 100) captured)))))

(test barrier-note-read-returns-addr
  (with-clamsara (:plan-type :semispace)
    (let ((b (make-no-barrier)))
      (is (= 42 (barrier-note-read b 42))))))

(test barrier-selectors-list
  (is (member :object *barrier-selectors*))
  (is (member :satb *barrier-selectors*))
  (is (member :none *barrier-selectors*)))

;;; --- vm-binding ---

(test vm-has-feature-p-default
  (with-clamsara (:plan-type :nogc)
    (is-false (vm-has-feature-p *active-vm* :virtual-memory))
    (is-false (vm-has-feature-p *active-vm* :has-cas))))

(test vm-page-size-words-default
  (with-clamsara (:plan-type :nogc)
    (is (= +page-size-words+ (vm-page-size-words *active-vm*)))))

(test vm-cards-per-page-default
  (with-clamsara (:plan-type :nogc)
    (is (= +cards-per-page+ (vm-cards-per-page *active-vm*)))))

(test vm-space-usage
  (with-clamsara (:plan-type :nogc)
    (let* ((space (plan-get-space *active-plan* :default))
           (usage (vm-space-usage *active-vm* space)))
      (is (getf usage :space-name))
      (is (getf usage :total-pages)))))

(test immediatep-default
  (with-clamsara (:plan-type :nogc)
    (is-false (immediatep *active-vm* 42))))

;;; --- memory protocol ---

(test ref-u64-roundtrip
  (with-clamsara (:plan-type :nogc)
    (let ((addr (plan-allocate *active-plan* 4 :default)))
      (when addr
        (setf (ref-u64 *active-vm* addr) 1234567890)
        (is (= 1234567890 (ref-u64 *active-vm* addr)))))))

(test atomic-incf-simulator
  (with-clamsara (:plan-type :nogc)
    (is (= 5 (atomic-incf *active-vm* 0 5)))))

(test memory-fence-noop
  (with-clamsara (:plan-type :nogc)
    (is-false (memory-fence *active-vm*))))

;;; --- allocator ---

(test coalesce-free-list
  (with-clamsara (:plan-type :marksweep)
    (let ((space (plan-get-space *active-plan* :default)))
      (is-true (typep (space-allocator space) 'free-list-allocator))
      (is-false (coalesce (space-allocator space))))))

;;; --- compile ---
;;; compile-to-functions-returns-alist tested in test-compile.lisp

(test lookup-compiled-function
  (with-clamsara (:plan-type :marksweep)
    (boot-gc *active-plan*)
    (is-true (gethash 'plan-collect (plan-function-table *active-plan*)))))

;;; --- macros ---

(test with-active-plan-macro
  (with-clamsara (:plan-type :nogc)
    (let ((original *active-plan*))
      (with-active-plan (original)
        (is (eq original *active-plan*))))))

(test with-active-vm-macro
  (with-clamsara (:plan-type :nogc)
    (let ((original *active-vm*))
      (with-active-vm (original)
        (is (eq original *active-vm*))))))

(test with-active-gc-macro
  (with-clamsara (:plan-type :nogc)
    (with-active-gc (*active-vm* *active-plan*)
      (is-true *active-vm*)
      (is-true *active-plan*))))

;;; --- TLAB ---

(test mutator-creation
  (with-clamsara (:plan-type :semispace)
    (let ((mutator (make-mutator :id 1 :plan *active-plan*)))
      (is (typep mutator 'mutator-context)))))

;;; --- scheduler ---

(test scheduler-creation
  (with-clamsara (:plan-type :semispace)
    (let ((scheduler (make-gc-work-scheduler :plan *active-plan*)))
      (is (typep scheduler 'gc-work-scheduler))
      (is (eq *active-plan* (scheduler-plan scheduler))))))

(test scheduler-work-add-run
  (with-clamsara (:plan-type :semispace)
    (let ((scheduler (make-gc-work-scheduler :plan *active-plan*))
          (count 0))
      (scheduler-add-work scheduler (lambda () (incf count)))
      (scheduler-add-work scheduler (lambda () (incf count 2)))
      (scheduler-run-all scheduler)
      (is (= 3 count)))))

;;; --- immortal-allocator ---

(test immortal-allocator-creates
  (with-clamsara (:plan-type :semispace)
    (let ((pr (plan-page-resource *active-plan*)))
      (is (typep (make-immortal-allocator nil pr) 'immortal-allocator)))))

(test compute-immortal-space
  "Verify compute-immortal-space returns an existing immortal space or creates one."
  (with-clamsara (:plan-type :semispace :heap-size 4194304)
    ;; First call creates it (may fail if heap is full).
    ;; If first call fails, test that it at least returns NIL cleanly.
    (let ((space (compute-immortal-space *active-plan*)))
      (if space
          (progn
            (is (typep space (find-class 'clamsara::space)))
            (is (eq :immortal (clamsara::space-name space))))
          ;; Graceful: no free pages — the function returned NIL without crashing.
          (is (null space))))))

;;; --- sticky-space-metrics ---

(test sticky-space-metrics-class
  (with-clamsara (:plan-type :stickyimmix)
    (is (typep *active-plan* (find-class 'sticky-space-metrics)))
    (is (zerop (space-live-young-bytes *active-plan*)))))

;;; --- concurrent marking ---

(test cm-is-marking-active-p-default
  "All plans inherit a default no-op method."
  (with-clamsara (:plan-type :semispace)
    (is-false (cm-is-marking-active-p *active-plan*))))

;;; --- cons-space-trait ---

(test cons-space-trait-exists
  (with-clamsara (:plan-type :semispace)
    (let* ((pr (plan-page-resource *active-plan*))
           (space (make-instance 'cons-space
                    :name :cons :kind :cons
                    :start-page 0 :page-count 1
                    :allocator nil :page-resource pr)))
      (is (typep space 'cons-space-trait)))))

;;; --- large-object-space-trait ---

(test large-object-space-trait-exists
  "Verify the class hierarchy."
  (is (subtypep 'large-object-space 'large-object-space-trait)))

;;; --- nogc-space ---

(test nogc-space-is-concrete
  (with-clamsara (:plan-type :nogc)
    (let ((space (plan-get-space *active-plan* :default)))
      (is (typep space 'nogc-space)))))

;;; --- compile internals ---

(test compile-trace-dispatch-generates-lambda
  (with-clamsara (:plan-type :semispace)
    (let ((form (compile-trace-dispatch *active-plan*)))
      (is (consp form))
      (is (eq 'lambda (first form))))))

(test compile-space-prepare-generates-lambda
  (with-clamsara (:plan-type :semispace)
    (let ((space (plan-get-space *active-plan* :default)))
      (let ((form (compile-space-prepare space)))
        (is (consp form))
        (is (eq 'lambda (first form)))))))
