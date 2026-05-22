(defsystem "clamsara"
  :description "A Compilable, MOP-Based Garbage Collection Framework for Common Lisp"
  :author "Iska Mag"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria"
               "serapeum"
               "bordeaux-threads")
  :serial t
  :components ((:module "src"
                :serial t
                :components
                ((:file "package")
                 (:file "types")
                 (:file "conditions")
                 (:file "heap")
                 (:file "object-model")
                 (:file "metadata")
                 (:file "vm-binding")
                 (:file "roots")
                 (:module "allocator"
                  :components
                  ((:file "bump-pointer")
                   (:file "free-list")
                   (:file "large-object")))
                 (:file "space")
                 (:file "space-traits")
                 (:file "page-resource")
                 (:file "plan")
                 (:file "barrier")
                 (:file "mutator")
                 (:file "tracer")
                 (:file "scheduler")
                 (:file "copy-config")
                 (:file "reference")
                 (:file "finalization")
                 (:file "stats")
                 (:file "options")
                 (:file "sanity")
                 (:module "vm"
                  :components
                  ((:file "simulator")))
                 (:module "plans"
                  :components
                  ((:file "nogc")
                   (:file "semispace")
                   (:file "marksweep")
                   (:file "immix")
                   (:file "gencopy")
                   (:file "genms")
                   (:file "genimmix")
                   (:file "stickyimmix")
                   (:file "stickyms")))
                 (:file "api"))))
  :in-order-to ((test-op (test-op "clamsara/test"))))

;;; --- Maclina VM integration ---

(defsystem "clamsara/vm"
  :description "Maclina VM integration for Clamsara"
  :author "Iska Mag"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("clamsara"
               "extrinsicl"
               "extrinsicl/maclina"
               "clostrum-basic"
               "eclector")
  :serial t
  :components ((:module "src/vm"
                :serial t
                :components
                ((:file "maclina-vm")
                 (:file "maclina-roots")
                 (:file "maclina-alloc")
                 (:file "maclina-env")))))

(defsystem "clamsara/test"
  :description "Test suite for clamsara"
  :depends-on ("clamsara" "clamsara/vm" "fiveam")
  :serial t
  :components ((:module "test"
                :serial t
                :components
                ((:file "test-package")
                 (:file "test-util")
                 (:file "test-types")
                 (:file "test-heap")
                 (:file "test-object")
                 (:file "test-metadata")
                 (:file "test-allocator")
                 (:file "test-space")
                 (:file "test-plan")
                 (:file "test-barrier")
                 (:file "test-tracer")
                 (:file "test-collectors")
                 (:file "test-gen")
                 (:file "test-sanity")
                 (:file "test-maclina"))))
  :perform (test-op (op c)
              (declare (ignore op c))
              (unless (uiop:symbol-call :clamsara.tests :run-tests)
                (error "clamsara/test failed"))))
