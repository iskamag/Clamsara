;;;; src/client/coordinator.lisp -- paper-v14 threst coordinator protocol.
;;;; The COORDINATOR class itself is part of the construction component graph;
;;;; this file declares only the host-callable protocol so it can be loaded
;;;; before concrete component implementations.

(in-package #:clamsara)

(defgeneric request-safepoint (coordinator scope reason))
(defgeneric await-safepoint (coordinator token))
(defgeneric release-safepoint (coordinator token))
