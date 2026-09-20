;;;; Explicit construction-owned host auxiliary storage inventories.
;;;;
;;;; These methods enumerate retained host backing only.  They do not walk
;;;; arbitrary CLOS slots, hash keys, or guest payloads.
(in-package #:clamsara)

;;; `%map-construction-auxiliary-once` and its dynamically scoped owner
;;; registry are declared by the dependency-light construction protocol.
;;; This file only supplies host owner methods.

;;; Root service -------------------------------------------------------------

(defmethod map-construction-auxiliary-storage
    ((location simulator-root-location) function)
  ;; LOCATION contains a guest reference VALUE.  The location record itself
  ;; is retained host storage; its value is deliberately not traversed.
  (call-next-method)
  (values))

(defmethod map-construction-auxiliary-storage
    ((token simulator-provider-token) function)
  ;; A token is a fixed registration record.  Its external PROVIDER and
  ;; registration locations are owned elsewhere; do not traverse either.
  (call-next-method)
  (values))

(defmethod map-construction-auxiliary-storage
    ((provider simulator-root-provider) function)
  ;; External providers are not part of the root client's retained graph.
  ;; Keep this explicit owner header only; registration copies are owned by
  ;; SIMULATOR-ROOT-CLIENT's fixed pools.
  (call-next-method)
  (values))

(defmethod map-construction-auxiliary-storage
    ((client simulator-root-client) function)
  (call-next-method)
  (let ((providers (simulator-root-providers client))
        (token-reserve (simulator-root-token-reserve client))
        (entry-reserve (simulator-root-entry-reserve client))
        (scratch (simulator-root-registration-scratch client))
        (seen (simulator-root-registration-seen client))
        (directory (simulator-root-directory client))
        (snapshot (simulator-client-snapshot client)))
    ;; Every fixed pool and every preallocated record is explicit retained
    ;; host storage.  Record fields such as LOCATION and PROVIDER are not
    ;; traversed: their backing ownership is represented by these pools.
    (when providers
      (funcall function providers)
      (dotimes (index (length providers))
        (let ((token (aref providers index)))
          (when token
            (%map-construction-auxiliary-once token function)))))
    (when token-reserve
      (funcall function token-reserve)
      (dotimes (index (length token-reserve))
        (let ((token (aref token-reserve index)))
          (when token (funcall function token)))))
    (when entry-reserve
      (funcall function entry-reserve)
      (dotimes (index (length entry-reserve))
        (let ((entry (aref entry-reserve index)))
          (when entry (funcall function entry)))))
    (when scratch (funcall function scratch))
    (when seen (funcall function seen))
    (when directory (funcall function directory))
    (when snapshot (funcall function snapshot)))
  (values))

;;; Serialized coordinator --------------------------------------------------

(defmethod map-construction-auxiliary-storage
    ((coordinator simulator-coordinator) function)
  (call-next-method)
  (let ((coverage (simulator-coordinator-coverage coordinator))
        (joined (simulator-joined-providers coordinator))
        (wake-counts (simulator-wake-counts coordinator)))
    (when coverage
      (funcall function coverage)
      (dotimes (index (length coverage))
        (let ((record (aref coverage index)))
          (when record (funcall function record)))))
    (when joined (funcall function joined))
    (when wake-counts (funcall function wake-counts)))
  (values))

;;; Address-space offer ------------------------------------------------------

(defmethod map-construction-auxiliary-storage
    ((client simulator-address-space) function)
  (call-next-method)
  (let ((offer (%simulator-arena-offer client)))
    (when offer
      (funcall function offer)
      ;; These are copied declarative trees.  The cons mapper reports their
      ;; backing cells but intentionally does not infer ownership of leaves.
      (%map-construction-cons-storage
       (%simulator-arena-offer-accesses offer) function)
      (%map-construction-cons-storage
       (%simulator-arena-offer-exclusions offer) function)))
  (values))

;;; Aggregate services ------------------------------------------------------

(defmethod map-construction-auxiliary-storage
    ((clients simulator-clients) function)
  (call-next-method)
  ;; Clients owns the service references.  Delegating through the owner-once
  ;; helper is essential because graph discovery can visit the same service
  ;; component after this aggregate owner.
  (dolist (owner (list (construction-object-model clients)
                       (construction-root-client clients)
                       (construction-stop-coordinator clients)
                       (construction-address-space-client clients)
                       (construction-atomics-client clients)
                       (construction-diagnostics-client clients)))
    (when owner
      (%map-construction-auxiliary-once owner function)))
  (values))

;;; These services retain no additional host backing beyond their own object.
;;; Keeping explicit methods here documents that their state is intentionally
;;; opaque and that guest atomic places/diagnostic payloads are not traversed.
(defmethod map-construction-auxiliary-storage
    ((atomics host-atomics) function)
  (call-next-method)
  (values))

(defmethod map-construction-auxiliary-storage
    ((diagnostics simulator-diagnostics) function)
  (call-next-method)
  (values))
