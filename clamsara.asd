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
                 (:file "test-sanity")))))
