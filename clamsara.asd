(asdf:defsystem #:clamsara
  :description "Clamsara: A GC Toolkit"
  :author "Your Name <your.name@example.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:closer-mop #:alexandria #:fiveam #:maclina)
  :serial t
  :pathname "src"
  :components
  (  (:file "package")
   (:file "metaclass")
   (:file "types")
   (:file "heap")
   (:file "space")
   (:file "object")
   (:file "metadata")
   (:file "barrier")
   (:file "tracer")
   (:file "allocator")
   (:file "plan")
   (:file "compile")
   (:file "vm")
   (:file "reference")
   (:file "finalization")
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
   (:file "vm-binding")
   (:module "vm"
    :components
    ((:file "simulator")))
                (:file "metaclass")
                (:file "compile")
                (:file "sanity")
                (:file "simulator"))
  :in-order-to ((asdf:test-op (asdf:test-op #:clamsara/tests))))

(asdf:defsystem #:clamsara/tests
  :description "Clamsara test suite"
  :author "Your Name <your.name@example.com>"
  :license "MIT"
  :depends-on (#:clamsara #:fiveam)
  :pathname "test"
  :serial t
  :components
  ((:file "test-package")
   (:file "test-types")
   (:file "test-heap")
   (:file "test-space")
   (:file "test-object")
   (:file "test-metadata")
   (:file "test-allocator")
   (:file "test-plan")
   (:file "test-barrier")
   (:file "test-tracer")
   (:file "test-collectors")
   (:file "test-gen")
               (:file "test-sanity")
               (:file "test-maclina")
               (:file "test-clamsara")
               (:file "test-compile"))
  :perform (asdf:test-op (o c)
             (funcall (read-from-string "clamsara.tests:run-tests"))))