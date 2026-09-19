;;;; clamsara.asd -- Clamsara systems (v11 migration over the v9 simulator).
;;;;
;;;; No external dependencies: pure ANSI CLOS + SBCL (used for speed/atomics).
;;;; Load without Quicklisp:
;;;;   (require :asdf)
;;;;   (asdf:load-asd (merge-pathnames "clamsara.asd" *default-pathname-defaults*))
;;;;   (asdf:load-system :clamsara)

;;;; paper-v11 protocol systems (architecture chapter, system decomposition).
;;;; Each protocol system is independently loadable and depends on nothing
;;;; but Common Lisp; collector configurations and integrations must not be
;;;; imported there.  The mapping protocol (client-protocols.tex section 5)
;;;; and address-to-space resolution (managed-layout.tex section 5) live in
;;;; clamsara/protocol/address-space, matching the decomposition diagram's
;;;; five protocol systems.  clamsara/protocol/diagnostics is the documented
;;;; implementation seam for client-protocols.tex section 6 prose, which
;;;; names no interface.

(asdf:defsystem :clamsara/protocol/object-model
  :version "11.0.0"
  :description "paper-v11 object-model client protocol (client-protocols.tex section 1)."
  :depends-on ()
  :pathname "src"
  :components ((:file "protocol/object-model")))

(asdf:defsystem :clamsara/protocol/roots
  :version "11.0.0"
  :description "paper-v11 root client protocol (client-protocols.tex section 2)."
  :depends-on ()
  :pathname "src"
  :components ((:file "protocol/roots")))

(asdf:defsystem :clamsara/protocol/coordination
  :version "11.0.0"
  :description "paper-v11 coordination client protocol (client-protocols.tex section 3)."
  :depends-on ()
  :pathname "src"
  :components ((:file "protocol/coordination")))

(asdf:defsystem :clamsara/protocol/atomics
  :version "11.0.0"
  :description "paper-v11 atomic/memory-order client protocol (client-protocols.tex section 4)."
  :depends-on ()
  :pathname "src"
  :components ((:file "protocol/atomics")))

(asdf:defsystem :clamsara/protocol/address-space
  :version "11.0.0"
  :description "paper-v11 address-space client protocol: managed-layout offer, space resolution, optional mapping mechanisms (managed-layout.tex sections 2/5, client-protocols.tex section 5)."
  :depends-on ()
  :pathname "src"
  :components ((:file "protocol/address-space")))

(asdf:defsystem :clamsara/protocol/diagnostics
  :version "11.0.0"
  :description "paper-v11 clock/fatal-diagnostics seam; implementation names for client-protocols.tex section 6 prose."
  :depends-on ()
  :pathname "src"
  :components ((:file "protocol/diagnostics")))

(asdf:defsystem :clamsara/core
  :version "11.0.0"
  :description "paper-v11 portable component construction and lifecycle kernel."
  :depends-on ()
  :pathname "src"
  :components ((:file "core/component")))

(asdf:defsystem :clamsara/core/test
  :version "11.0.0"
  :description "Standalone contract tests for the paper-v11 component kernel."
  :depends-on (:clamsara/core)
  :components ()
  :perform (asdf:test-op (operation component)
             (declare (ignore operation))
             (let ((script (merge-pathnames
                            "test/component-contract.lisp"
                            (asdf:system-source-directory component))))
               (uiop:run-program
                (list "sbcl" "--noinform" "--script" (namestring script))
                :output *standard-output* :error-output *error-output*))))

(asdf:defsystem :clamsara/core/managed-layout
  :version "11.0.0"
  :description "paper-v11 portable managed-layout construction kernel."
  :depends-on (:clamsara/protocol/address-space)
  :pathname "src"
  :components ((:file "core/managed-layout")))

(asdf:defsystem :clamsara/core/managed-layout/test
  :version "11.0.0"
  :description "Standalone contract tests for the paper-v11 managed-layout kernel."
  :depends-on (:clamsara/core/managed-layout)
  :components ()
  :perform (asdf:test-op (operation component)
             (declare (ignore operation))
             (let ((script (merge-pathnames
                            "test/managed-layout-contract.lisp"
                            (asdf:system-source-directory component))))
               (uiop:run-program
                (list "sbcl" "--noinform" "--script" (namestring script))
                :output *standard-output* :error-output *error-output*))))

(asdf:defsystem :clamsara/core/metadata
  :version "11.0.0"
  :description "paper-v11 portable logical-metadata declaration, merge, binding, and operation kernel."
  :depends-on (:clamsara/protocol/object-model :clamsara/protocol/atomics)
  :pathname "src"
  :components ((:file "core/metadata")))

(asdf:defsystem :clamsara/core/metadata/test
  :version "11.0.0"
  :description "Standalone contract tests for the paper-v11 logical-metadata kernel."
  :depends-on (:clamsara/core/metadata)
  :components ()
  :perform (asdf:test-op (operation component)
             (declare (ignore operation))
             (let ((script (merge-pathnames
                            "test/metadata-contract.lisp"
                            (asdf:system-source-directory component))))
               (uiop:run-program
                (list "sbcl" "--noinform" "--script" (namestring script))
                :output *standard-output* :error-output *error-output*))))

(asdf:defsystem :clamsara
  ;; Version stays 9.0.0 while the v11 migration is incomplete: this system
  ;; does not yet conform to paper-v11 (see V11-IMPLEMENTATION.md).  Version
  ;; promotion to 11.x is gated on the v11 conformance ledger covering every
  ;; normative requirement the paper names, not on protocol seams alone.
  :version "9.0.0"
  :description "Clamsara simulator: v11 migration in progress.  The independent clamsara/protocol/* systems carry the exact paper-v11 client protocols; the collector internals behind them remain v8/v9-lineage and migrate slice by slice."
  :licence "MIT"
  :depends-on (:clamsara/core
               :clamsara/core/managed-layout
               :clamsara/core/metadata
               :clamsara/protocol/object-model
               :clamsara/protocol/roots
               :clamsara/protocol/coordination
               :clamsara/protocol/atomics
               :clamsara/protocol/address-space
               :clamsara/protocol/diagnostics)
  ;; Make the ordinary ASDF entry point useful; historically TEST-SYSTEM on
  ;; :CLAMSARA was a silent no-op while only :CLAMSARA/TEST ran the suite.
  :in-order-to ((asdf:test-op (asdf:test-op "clamsara/test")))
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "package")
     (:file "types")
     (:file "conditions")
     (:file "strata")
     (:file "page-resource")
     (:file "metaclass")
     (:module "vm"
      :serial t
      :components ((:file "binding")
                   (:file "scheduler")
                   (:file "software-mmu")
                   (:file "object-model")
                   (:file "simulator")))
     ;; composition.lisp: the paper-v11 composition vocabulary (discovery
     ;; seams, shared metadata facts, bound-metadata realization) that
     ;; heap.lisp's space components speak.
     (:file "composition")
     (:file "heap")
     (:file "tracer")
     (:file "publication")
     (:file "barrier")
     (:file "plan")
     ;; construction.lisp: the construction engine (seven phases over the plan's
     ;; component graph) the plans below construct through.
     (:file "construction")
     (:file "compile")
     (:file "weak")
     (:file "persistence")
     (:file "stats")
     (:file "protocol/adapters")
     (:module "plans"
      :serial t
      :components ((:file "nogc")
                   (:file "semispace")
                   (:file "marksweep")
                   (:file "immix")
                   (:file "gencopy")
                   (:file "genms")
                   (:file "genimmix")
                   (:file "stickyimmix")
                   (:file "stickyms")
                   (:file "iso")
                   (:file "zgcish")
                   (:file "claimore")))
     (:file "sanity")
     (:file "api")))))

(asdf:defsystem :clamsara/test
  :version "8.0.0"
  :description "Clamsara test suite."
  :depends-on (:clamsara)
  :in-order-to ((asdf:test-op
                 (asdf:test-op "clamsara/core/test")
                 (asdf:test-op "clamsara/core/managed-layout/test")
                 (asdf:test-op "clamsara/core/metadata/test")))
  :serial t
  :components
  ((:module "test"
    :serial t
    :components ((:file "suite")
                 (:file "test-stats")
                 (:file "test-strata")
                 (:file "test-vm")
                 (:file "test-heap")
                 (:file "test-barrier")
                 (:file "test-collectors")
                 (:file "test-advanced")
                 (:file "test-sanity")
                 (:file "test-persistence")
                 (:file "test-issues")
                 (:file "test-workloads")
                 (:file "test-protocols"))))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (let ((summary
                     (uiop:symbol-call :clamsara :run-test-suite
                                       :verbose nil)))
               (unless (zerop (cdr summary))
                 (error "Clamsara core suite failed ~D test~:P"
                        (cdr summary)))
               (format t "~&Clamsara core suite: ~D passed~%"
                       (car summary)))))

;;; Optional Maclina workload driver. EXTRINSICL must be loaded before its
;;; maclina adapter (the upstream subsystem omits that dependency), hence the
;;; explicit order here.
(asdf:defsystem :clamsara/maclina
  :version "8.0.0"
  :description "Maclina-driven Common Lisp workloads over the Clamsara VM."
  :depends-on (:clamsara :extrinsicl :extrinsicl/maclina
               :clostrum-basic :trucler-native)
  :serial t
  :components
  ((:module "src/maclina"
    :serial t
    :components ((:file "package")
                 (:file "adapter")))))

;;; Compatibility name used by the v7 tree.
(asdf:defsystem :clamsara/vm
  :version "8.0.0"
  :depends-on (:clamsara/maclina))

(asdf:defsystem :clamsara/maclina/test
  :version "8.0.0"
  :description "Smoke and moving-GC tests for the optional Maclina adapter."
  :depends-on (:clamsara/maclina)
  :serial t
  :components ((:file "test/test-maclina"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :clamsara-maclina :run-maclina-tests)))


;;; Optional canonical Gabriel TAK/TAKR plus explicitly labelled smoke tests.
;;; A normal load depends only on the core system; TEST-OP declares the optional
;;; Maclina load explicitly so ASDF can schedule it without a recursive
;;; operation warning.
(asdf:defsystem :clamsara/bench/gabriel
  :version "8.0.0"
  :description "Canonical Gabriel TAK/TAKR plus labelled Maclina smoke workloads."
  :depends-on (:clamsara)
  :serial t
  :components
  ((:module "bench/gabriel"
    :serial t
    :components ((:file "package")
                 (:file "forms")
                 (:file "runner"))))
  :in-order-to ((asdf:test-op
                 (asdf:load-op "clamsara/maclina")))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :clamsara-gabriel-bench
                               :run-gabriel-tests)))

;;; The upstream Boehm GCBench source translated to Common Lisp, driven
;;; through Maclina in the simulated heap.  This is a benchmark, not a test:
;;; the fixture is a data file for the runner.
(asdf:defsystem :clamsara/bench/gcbench
  :version "8.0.0"
  :description "The upstream Boehm GCBench over Maclina and Clamsara."
  :depends-on (:clamsara)
  :serial t
  :components
  ((:module "bench/gcbench"
    :serial t
    :components ((:file "package")
                 (:file "runner"))))
  :in-order-to ((asdf:test-op
                 (asdf:load-op "clamsara/maclina")))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :clamsara-bench-gcbench
                               :run-gcbench-tests)))
