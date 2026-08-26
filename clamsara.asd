;;;; clamsara.asd -- ASDF system definition for the Clamsara v8 framework.
;;;;
;;;; No external dependencies: pure ANSI CLOS + SBCL (used for speed/atomics).
;;;; Load without Quicklisp:
;;;;   (require :asdf)
;;;;   (asdf:load-asd (merge-pathnames "clamsara.asd" *default-pathname-defaults*))
;;;;   (asdf:load-system :clamsara)

(asdf:defsystem :clamsara
  :version "8.0.0"
  :description "A compilable, MOP-based garbage-collection framework (v8 rewrite)."
  :licence "MIT"
  :depends-on ()
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
     (:module "vm"
      :serial t
      :components ((:file "binding")
                   (:file "scheduler")
                   (:file "software-mmu")
                   (:file "object-model")
                   (:file "simulator")))
     (:file "metaclass")
     (:file "heap")
     (:file "tracer")
     (:file "publication")
     (:file "barrier")
     (:file "plan")
     (:file "compile")
     (:file "weak")
     (:file "persistence")
     (:file "stats")
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
  :serial t
  :components
  ((:module "test"
    :serial t
    :components ((:file "suite")
                 (:file "test-strata")
                 (:file "test-vm")
                 (:file "test-heap")
                 (:file "test-barrier")
                 (:file "test-collectors")
                 (:file "test-advanced")
                 (:file "test-sanity")
                 (:file "test-persistence")
                 (:file "test-issues")
                 (:file "test-workloads"))))
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


;;; Optional, deliberately small Gabriel-style Maclina benchmark subset.  A
;;; normal load depends only on the core system; TEST-OP declares the optional
;;; Maclina load explicitly so ASDF can schedule it without a recursive
;;; operation warning.
(asdf:defsystem :clamsara/bench/gabriel
  :version "8.0.0"
  :description "Small optional Gabriel-style workloads over Maclina."
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
