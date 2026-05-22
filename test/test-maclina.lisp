(in-package #:clamsara.tests)

(def-suite test-maclina :description "Maclina VM integration tests"
  :in clamsara-tests)

(in-suite test-maclina)

(test maclina-env-setup
  "Setup creates a Maclina environment with Clamsara plan."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((plan *active-plan*))
      (multiple-value-bind (client rte) (setup-clamsara-maclina-environment plan)
        (is (not (null client)))
        (is (not (null rte)))
        (is (typep client 'clamsara-maclina-client))))))

(test maclina-cons-allocation
  "CONS in the Maclina environment allocates in Clamsara heap."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((plan *active-plan*))
      (setup-clamsara-maclina-environment plan)
      (let ((env-cons (clostrum:fdefinition *clamsara-maclina-client*
                                            *clamsara-maclina-env* 'cons)))
        (let ((vm (plan-vm plan))
              (addr (funcall env-cons 10 20)))
          (is (not (null addr)))
          (is (integerp addr))
          (is (vm-object-start-p vm addr))
          (is (= +type-tag-cons+ (vm-object-type-tag vm addr)))
          (is (= 10 (vm-object-reference vm addr 0)))
          (is (= 20 (vm-object-reference vm addr 1))))))))

(test maclina-cons-survives-gc
  "A cons allocated in the Maclina environment survives GC."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((plan *active-plan*))
      (setup-clamsara-maclina-environment plan)
      (let ((env-cons (clostrum:fdefinition *clamsara-maclina-client*
                                            *clamsara-maclina-env* 'cons))
            (env-car (clostrum:fdefinition *clamsara-maclina-client*
                                           *clamsara-maclina-env* 'car))
            (env-cdr (clostrum:fdefinition *clamsara-maclina-client*
                                           *clamsara-maclina-env* 'cdr)))
        (let* ((inner (funcall env-cons 42 99))
               (outer (funcall env-cons inner 0)))
          (clamsara-register-root outer)
          (clamsara-gc)
          (is (= inner (funcall env-car outer)))
          (let ((recovered (funcall env-car outer)))
            (is (= 42 (funcall env-car recovered)))
            (is (= 99 (funcall env-cdr recovered)))))))))

;;; --- Boehm GC Benchmark ---

(test maclina-struct-allocation
  "%MAKE-STRUCT-RAW allocates structs in the Maclina environment."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((plan *active-plan*))
      (setup-clamsara-maclina-environment plan)
        (let* ((vm (plan-vm plan))
               (make-struct (clostrum:fdefinition *clamsara-maclina-client*
                                                  *clamsara-maclina-env*
                                                  'clamsara::%make-struct-raw))
               (struct-ref (clostrum:fdefinition *clamsara-maclina-client*
                                                 *clamsara-maclina-env*
                                                 'clamsara::%struct-ref))
             (addr (funcall make-struct 4 10 20 30 40)))
        (is (not (null addr)))
        (is (integerp addr))
        (is (vm-object-start-p vm addr))
        (is (= +type-tag-struct+ (vm-object-type-tag vm addr)))
        (is (= 10 (funcall struct-ref addr 0)))
        (is (= 20 (funcall struct-ref addr 1)))
        (is (= 30 (funcall struct-ref addr 2)))
        (is (= 40 (funcall struct-ref addr 3)))))))

(test maclina-recursive-tree-gc
  "Recursive tree builder works and survives GC in Maclina environment."
  (with-clamsara (:plan-type :marksweep :heap-size 524288)
    (let ((plan *active-plan*))
      (setup-clamsara-maclina-environment plan)
      (setf *active-plan* plan)
      (let ((make-struct (clostrum:fdefinition *clamsara-maclina-client*
                                               *clamsara-maclina-env*
                                               'clamsara::%make-struct-raw))
            (struct-ref (clostrum:fdefinition *clamsara-maclina-client*
                                              *clamsara-maclina-env*
                                              'clamsara::%struct-ref))
            (struct-set (clostrum:fdefinition *clamsara-maclina-client*
                                              *clamsara-maclina-env*
                                              'clamsara::%struct-set)))
        (labels ((build-tree (depth)
                   (let ((addr (funcall make-struct 4 0 0 0 0)))
                     (when (> depth 0)
                       (funcall struct-set (build-tree (- depth 1)) addr 0)
                       (funcall struct-set (build-tree (- depth 1)) addr 1))
                     addr)))
          (let ((root (build-tree 3)))
            (is (integerp root))
            (is (object-start-p root))
            (clamsara-register-root root)
            (clamsara-gc)
            (is (object-start-p root))))))))

(test maclina-tree-benchmark
  "Build and discard trees in a benchmark-style loop via Maclina."
  (with-clamsara (:plan-type :marksweep :heap-size 2097152)
    (let ((plan *active-plan*))
      (setup-clamsara-maclina-environment plan)
      (setf *active-plan* plan)
      (let ((make-struct (clostrum:fdefinition *clamsara-maclina-client*
                                               *clamsara-maclina-env*
                                               'clamsara::%make-struct-raw))
            (struct-set (clostrum:fdefinition *clamsara-maclina-client*
                                              *clamsara-maclina-env*
                                              'clamsara::%struct-set)))
        (labels ((bench-loop (n)
                   (dotimes (i n)
                     (let ((addr (funcall make-struct 4 0 0 0 0)))
                       (funcall struct-set
                                (funcall make-struct 4 0 0 0 0) addr 0)
                       (funcall struct-set
                                (funcall make-struct 4 0 0 0 0) addr 1))
                     nil)))
          (bench-loop 50)
          (clamsara-gc)
          (is-true t))))))
