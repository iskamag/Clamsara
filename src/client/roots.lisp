;;;; src/client/roots.lisp -- paper-v14 root providers and snapshots.
;;;; No implicit global root map or provider fallback is installed.

(in-package #:clamsara)

(defgeneric register-root-provider (root-client provider-id capacity provider))
(defgeneric map-provider-roots (provider function))
(defgeneric unregister-root-provider (root-client provider-token))
(defgeneric with-root-snapshot (root-client coverage function))
(defgeneric map-root-locations (snapshot function))
(defgeneric load-root (root-client location))
(defgeneric store-root (root-client location reference))
(defgeneric root-location-kind (root-client location))
(defgeneric root-provider-load (root-client provider-token location))
(defgeneric root-provider-read (root-client context provider-token location))
(defgeneric root-provider-store
    (root-client context provider-token location reference))
