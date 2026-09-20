;;;; Clamsara canonical implementation. See docs/migration.md for evidence limits.

(asdf:defsystem :clamsara/protocol
  :version "0.1.0"
  :description "Exact paper-v14 client declarations; no conformance claim."
  :depends-on ()
  :serial t
  :components ((:file "src/package")
               (:module "src/client"
                :serial t
                :components ((:file "object-model")(:file "metadata")(:file "roots")(:file "finalizers")(:file "atomics")(:file "mapping")(:file "diagnostics")(:file "coordinator")))))

(asdf:defsystem :clamsara/construction/protocol
  :version "0.1.0"
  :depends-on (:clamsara/protocol)
  :components ((:file "src/construction/protocol")))

(asdf:defsystem :clamsara/protocol/test
  :version "0.1.0"
  :depends-on (:clamsara/protocol)
  :components ((:file "test/client/protocol-contract"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.client.test
                                      :run-v14-client-contracts)
               (error "v14 client protocol contracts failed"))))

(asdf:defsystem :clamsara/construction
  :version "0.1.0"
  :depends-on (:clamsara/construction/protocol)
  :serial t
  :components ((:module "src/construction" :serial t
                :components ((:file "records") (:file "graph")
                             (:file "validation") (:file "layout") (:file "build")))))

(asdf:defsystem :clamsara/metadata
  :version "0.1.0"
  :depends-on (:clamsara/construction/protocol)
  :components ((:file "src/metadata/metadata")))

(asdf:defsystem :clamsara/host-base
  :version "0.1.0"
  :description "Serialized SBCL host mechanisms; not target supervisor admission."
  :depends-on (:clamsara/construction :clamsara/metadata)
  :serial t
  :components ((:module "src/host" :serial t
                :components ((:file "roots") (:file "coordinator")
                             (:file "resources") (:file "address-space")))))

(asdf:defsystem :clamsara/runtime
  :version "0.1.0"
  :description "Clean sequential collector runtime under validation."
  :depends-on (:clamsara/host-base)
  :serial t
  :components ((:module "src/runtime" :serial t
                :components ((:file "protocol") (:file "records") (:file "barrier") (:file "finalizers") (:file "trace") (:file "spaces") (:file "cycle") (:file "allocation") ))))

(asdf:defsystem :clamsara/construction/test
  :version "0.1.0"
  :depends-on (:clamsara/construction)
  :components ()
  :perform (asdf:test-op (operation component)
             (declare (ignore operation))
             (uiop:run-program
              (list "sbcl" "--noinform" "--script"
                    (namestring (asdf:system-relative-pathname
                                 component "test/construction/contract.lisp")))
              :output *standard-output* :error-output *error-output*)))

(asdf:defsystem :clamsara/host
  :version "0.1.0"
  :description "Hosted object representation and atomic-place client."
  :depends-on (:clamsara/host-base)
  :serial t
  :components ((:file "src/host/object-model")
               (:file "src/host/atomics")
               (:file "src/host/auxiliary")))

(asdf:defsystem :clamsara
  :version "0.1.0"
  :description "Clamsara: paper-v14 rewrite under validation."
  :depends-on (:clamsara/runtime :clamsara/host)
  :in-order-to ((asdf:test-op (asdf:test-op :clamsara/test))))

(asdf:defsystem :clamsara/runtime/test
  :version "0.1.0"
  :depends-on (:clamsara/runtime)
  :components ((:file "test/barrier/barrier"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.barrier.test
                                      :run-v14-barrier-contracts)
               (error "Barrier contracts failed"))))

(asdf:defsystem :clamsara/host/test
  :version "0.1.0"
  :depends-on (:clamsara/host-base)
  :serial t
  :components ((:file "test/host/roots") (:file "test/host/coordination"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.host.test
                                           :run-v14-root-host-contracts)
                          (uiop:symbol-call :clamsara.host.coordination.test
                                           :run-v14-coordination-host-contracts))
               (error "Host contracts failed"))))

(asdf:defsystem :clamsara/acceptance/test
  :version "0.1.0"
  :depends-on (:clamsara)
  :serial t
  :components ((:file "test/acceptance/metadata-safety")
               (:file "test/acceptance/host-safety")
               (:file "test/acceptance/resources-layout")
               (:file "test/acceptance/conditional-lifecycle")
               (:file "test/acceptance/object-model-safety"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.acceptance.metadata
                                           :run-metadata-safety-acceptance)
                          (uiop:symbol-call :clamsara.acceptance.host
                                           :run-host-safety-acceptance)
                          (uiop:symbol-call :clamsara.acceptance.resources-layout
                                           :run-resources-layout-acceptance)
                          (uiop:symbol-call :clamsara.acceptance.conditional-lifecycle
                                           :run-conditional-lifecycle-acceptance)
                          (uiop:symbol-call :clamsara.acceptance.object-model
                                           :run-object-model-safety-acceptance))
               (error "Acceptance contracts failed"))))

(asdf:defsystem :clamsara/test
  :version "0.1.0"
  :description "Current rewrite contracts; not full benchmark/target acceptance."
  :depends-on (:clamsara)
  :in-order-to ((asdf:test-op (asdf:test-op :clamsara/protocol/test)
                             (asdf:test-op :clamsara/construction/test)
                             (asdf:test-op :clamsara/host/test)
                             (asdf:test-op :clamsara/host/atomics/test)
                             (asdf:test-op :clamsara/runtime/test)
                             (asdf:test-op :clamsara/runtime/lifecycle/test)
                             (asdf:test-op :clamsara/acceptance/test))))

(asdf:defsystem :clamsara/workload
  :version "0.1.0"
  :description "Maclina workloads on managed storage; full runs under validation."
  :depends-on (:clamsara :extrinsicl :extrinsicl/maclina
               :clostrum-basic :trucler-native)
  :serial t
  :components ((:module "src/workload" :serial t
                :components ((:file "protocol") (:file "roots")
                             (:file "maclina") (:file "setup")
                             (:file "gabriel") (:file "gcbench")))))

(asdf:defsystem :clamsara/host/atomics/test
  :version "0.1.0"
  :depends-on (:clamsara/protocol)
  :serial t
  :components ((:file "src/host/atomics") (:file "test/host/atomics"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.host.atomics.test
                                      :run-v14-atomics-host-contracts)
               (error "Atomic-place contracts failed"))))

(asdf:defsystem :clamsara/runtime/lifecycle/test
  :version "0.1.0"
  :depends-on (:clamsara)
  :serial t
  :components ((:file "test/runtime/semispace") (:file "test/runtime/marksweep")
               (:file "test/runtime/retained-failure")
               (:file "test/metadata/semispace"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.runtime.test :run-v14-runtime-tests)
                          (uiop:symbol-call :clamsara.runtime.marksweep.test
                                            :run-marksweep-runtime-tests)
                          (uiop:symbol-call :clamsara.metadata.semispace.test
                                            :run-metadata-semispace-runtime-tests)
                          (uiop:symbol-call :clamsara.runtime.retained-failure.test
                                            :run-retained-failure-test))
               (error "Collector lifecycle tests failed"))))
