;;;; src/client/finalizers.lisp -- paper-v14 finalizer registry.
;;;; Finalizers are an explicit client service, never hidden object-model roots.

(in-package #:clamsara)

(defgeneric register-finalizer (registry context referent callback))
(defgeneric cancel-finalizer (registry context token))
(defgeneric map-finalizer-registrations (registry function))
(defgeneric correct-finalizer-referent
    (registry token expected corrected-referent))
(defgeneric freeze-finalizer-candidate
    (registry token expected corrected-referent))
(defgeneric publish-pending-finalizers (registry))
(defgeneric drain-pending-finalizers (registry context))
