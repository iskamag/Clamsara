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
                             (asdf:test-op :clamsara/acceptance/test)
                             (asdf:test-op :clamsara/quality/stateful/test)
                             (asdf:test-op :clamsara/quality/barrier-history/test)
                             (asdf:test-op :clamsara/quality/barrier-admission/test)
                             (asdf:test-op :clamsara/quality/allocation/test)
                             (asdf:test-op :clamsara/quality/kind-snapshots/test)
                             (asdf:test-op :clamsara/quality/representation-capacity/test)
                             (asdf:test-op :clamsara/quality/reference-variants/test)
                             (asdf:test-op :clamsara/quality/finalizers/test)
                             (asdf:test-op :clamsara/quality/finalizer-drain/test)
                             (asdf:test-op :clamsara/quality/model-resources/test)
                             (asdf:test-op :clamsara/quality/test))))

(asdf:defsystem :clamsara/quality/barrier-history/test
  :version "0.1.0"
  :description "Hosted composed-barrier histories; not target/full conformance."
  :depends-on (:clamsara/quality/support)
  :serial t
  :components ((:file "test/quality/barrier-history")
               (:file "test/quality/barrier-edges")
               (:file "test/quality/barrier-claims")
               (:file "test/quality/barrier-boundaries"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.quality.barrier-history
                                           :run-barrier-history-tests)
                          (uiop:symbol-call :clamsara.quality.barrier-history
                                           :run-barrier-edge-tests)
                          (uiop:symbol-call :clamsara.quality.barrier-claims
                                           :run-barrier-claim-tests)
                          (uiop:symbol-call :clamsara.quality.barrier-boundaries
                                           :run-barrier-boundary-tests))
               (error "Barrier history contracts failed"))))

(asdf:defsystem :clamsara/quality/barrier-admission/test
  :version "0.1.0"
  :description "Hosted opaque-token admission histories; not full/target admission."
  :depends-on (:clamsara/quality/support)
  :serial t
  :components ((:file "test/quality/barrier-admission")
               (:file "test/quality/barrier-admission-edges"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.quality.barrier-admission
                                           :run-opaque-admission-tests)
                          (uiop:symbol-call :clamsara.quality.barrier-admission-edges
                                           :run-opaque-admission-edge-tests))
               (error "Barrier admission contracts failed"))))

(asdf:defsystem :clamsara/workload
  :version "0.1.0"
  :description "Maclina workloads on managed storage; full runs under validation."
  :depends-on (:clamsara :extrinsicl :extrinsicl/maclina
               :clostrum-basic :trucler-native)
  :serial t
  :components ((:module "src/workload" :serial t
                :components ((:file "protocol") (:file "roots")
                             (:file "source") (:file "maclina")
                             (:file "control") (:file "numbers") (:file "setup")
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

(asdf:defsystem :clamsara/tools
  :version "0.1.0"
  :description "Native development diagnostics, not collector entry code."
  :depends-on (:asdf)
  :components ((:file "tools/debug")))

(asdf:defsystem :clamsara/tools/test
  :version "0.1.0"
  :depends-on (:clamsara/tools :clamsara/protocol)
  :components ((:file "test/tools/debug"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :clamsara.debug.test :run-debug-tests)))

(asdf:defsystem :clamsara/quality/support
  :version "0.1.0"
  :depends-on (:clamsara)
  :components ((:file "test/quality/support")))

(asdf:defsystem :clamsara/quality/stateful/test
  :version "0.1.0"
  :depends-on (:clamsara/quality/support)
  :components ((:file "test/quality/stateful"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.quality.stateful
                                      :run-stateful-quality-tests)
               (error "Stateful quality tests failed"))))

(asdf:defsystem :clamsara/quality
  :version "0.1.0"
  :description "Native structural checks, not collector allocation evidence."
  :depends-on (:clamsara :clamsara/tools)
  :components ((:file "tools/check-structure")))

(asdf:defsystem :clamsara/quality/test
  :version "0.1.0"
  :depends-on (:clamsara/quality)
  :components ((:file "test/quality/structure"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :clamsara.structure.test :run-structure-tests)))

(asdf:defsystem :clamsara/quality/model-resources/test
  :version "0.1.0"
  :depends-on (:clamsara/quality/support)
  :components ((:file "test/quality/model-resources"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.quality.model-resources
                                      :run-model-resource-quality)
               (error "Model/resource quality tests failed"))))

(asdf:defsystem :clamsara/workload/test
  :version "0.1.0"
  :description "Bounded adapter regressions, not the full benchmark gate."
  :depends-on (:clamsara/workload)
  :components ((:file "test/workload/adapter") (:file "test/workload/values")
               (:file "test/workload/teardown") (:file "test/workload/code-roots")
               (:file "test/workload/selectors") (:file "test/workload/numbers")
               (:file "test/workload/mapc") (:file "test/workload/mapc-capacity"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.workload.adapter.test
                                           :run-workload-adapter-tests)
                          (uiop:symbol-call :clamsara.workload.values.test
                                           :run-workload-value-lifetime-tests)
                          (uiop:symbol-call :clamsara.workload.teardown.test
                                           :run-workload-teardown-tests)
                          (uiop:symbol-call :clamsara.workload.code-roots.test
                                           :run-workload-code-root-tests)
                          (uiop:symbol-call :clamsara.workload.selectors.test
                                           :run-workload-selector-tests)
                          (uiop:symbol-call :clamsara.workload.numbers.test
                                           :run-workload-number-tests)
                          (uiop:symbol-call :clamsara.workload.mapc.test
                                           :run-workload-mapc-tests)
                          (uiop:symbol-call :clamsara.workload.mapc-capacity.test
                                           :run-workload-mapc-capacity-tests))
               (error "Workload adapter tests failed"))))

(asdf:defsystem :clamsara/generational
  :version "0.1.0"
  :description "Optional sequential generational profile under independent review."
  :depends-on (:clamsara)
  :components ((:file "src/runtime/generational")))

(asdf:defsystem :clamsara/generational/test
  :version "0.1.0"
  :depends-on (:clamsara/generational)
  :components ((:file "test/runtime/generational"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.runtime.generational.test
                                           :run-generational-runtime-tests)
                          (uiop:symbol-call :clamsara.runtime.generational.test
                                           :run-generational-capacity-test))
               (error "Optional generational tests failed"))))

(asdf:defsystem :clamsara/quality/generational/test
  :version "0.1.0"
  :description "Independent hosted generational oracles; explicitly selected."
  :depends-on (:clamsara/generational :clamsara/quality/support
               :clamsara/quality/reference-variants/test)
  :serial t
  :components ((:file "test/quality/generational")
               (:file "test/quality/generational-history")
               (:file "test/quality/reference-variants-generational")
               (:file "test/quality/copy-action"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.quality.generational
                                           :run-generational-quality-tests)
                          (uiop:symbol-call :clamsara.quality.generational
                                           :run-generational-history-tests)
                          (uiop:symbol-call :clamsara.quality.reference-variants
                                           :run-row-generational-acceptance)
                          (uiop:symbol-call :clamsara.quality.copy-action
                                           :run-copy-action-tests))
               (error "Generational quality tests failed"))))

(asdf:defsystem :clamsara/quality/reference-variants/test
  :version "0.1.0"
  :description "Immutable nonbase code rows over the complete descriptor domain."
  :depends-on (:clamsara/quality/support)
  :serial t
  :components ((:file "test/quality/reference-variant-fixture")
               (:file "test/quality/reference-variants")
               (:file "test/quality/reference-variant-directory")
               (:file "test/quality/reference-variant-edges"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.quality.reference-variants
                                           :run-row-acceptance)
                          (uiop:symbol-call :clamsara.quality.reference-variants
                                           :run-row-directory-tests)
                          (uiop:symbol-call :clamsara.quality.reference-variants
                                           :run-additional-row-checks))
               (error "Reference variant acceptance failed"))))

(asdf:defsystem :clamsara/quality/representation-capacity/test
  :version "0.1.0"
  :depends-on (:clamsara/quality/support)
  :components ((:file "test/quality/representation-capacity"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.quality.representation-capacity
                                      :run-representation-capacity-tests)
               (error "Representation capacity tests failed"))))

(asdf:defsystem :clamsara/quality/kind-snapshots/test
  :version "0.1.0"
  :description "Bound allocation geometry; not full description snapshot admission."
  :depends-on (:clamsara/quality/support)
  :serial t
  :components ((:file "test/quality/kind-snapshots")
               (:file "test/quality/kind-history")
               (:file "test/quality/construction-exit-history"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.quality.kind-snapshots
                                           :run-kind-geometry-snapshot-tests)
                          (uiop:symbol-call :clamsara.quality.kind-history
                                           :run-kind-history-tests)
                          (uiop:symbol-call :clamsara.quality.construction-exit-history
                                           :run-construction-exit-history-tests))
               (error "Kind geometry snapshot tests failed"))))

(asdf:defsystem :clamsara/quality/allocation/test
  :version "0.1.0"
  :depends-on (:clamsara/quality/support)
  :components ((:file "test/quality/allocation"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.quality.allocation
                                      :run-allocation-admission-tests)
               (error "Allocation admission tests failed"))))

(asdf:defsystem :clamsara/quality/finalizers/test
  :version "0.1.0"
  :description "Hosted finalizer registration histories; not full callback admission."
  :depends-on (:clamsara/quality/support)
  :components ((:file "test/quality/finalizers"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :clamsara.quality.finalizers
                                      :run-finalizer-registration-tests)
               (error "Finalizer registration tests failed"))))

(asdf:defsystem :clamsara/quality/finalizer-drain/test
  :version "0.1.0"
  :description "Hosted finalizer callback/queue histories; not managed callback admission."
  :depends-on (:clamsara/quality/finalizers/test)
  :serial t
  :components ((:file "test/quality/finalizer-drain")
               (:file "test/quality/finalizer-history"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (and (uiop:symbol-call :clamsara.quality.finalizers :run-finalizer-drain-tests)
                          (uiop:symbol-call :clamsara.quality.finalizer-history
                                            :run-finalizer-history-tests))
               (error "Finalizer drain tests failed"))))
