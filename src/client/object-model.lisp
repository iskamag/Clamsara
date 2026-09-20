;;;; src/client/object-model.lisp -- paper-v14 client object protocol.
;;;; This file declares only the portable generic interface.  It deliberately
;;;; provides no fallback methods: an unbound operation is not a capability.

(in-package #:clamsara)

;;; References, representations, and construction-time object descriptions.
(defgeneric make-object-start-binding (model space metadata))
(defgeneric describe-object-start-binding (model binding))
(defgeneric bind-object-model (model layout object-start-bindings))
(defgeneric valid-reference-p (model value))
(defgeneric normalize-reference (model reference))
(defgeneric rebuild-reference (model new-start descriptor))
(defgeneric reference-address (model start))
(defgeneric object-size (model start))
(defgeneric object-alignment (model start))
(defgeneric object-kind (model start))
(defgeneric object-kind-descriptor (model kind))
(defgeneric map-reference-locations (model start function))
(defgeneric map-weak-descriptors (model start function))
(defgeneric map-ephemeron-descriptors (model start function))
(defgeneric load-reference (model location &optional order))
(defgeneric store-reference-raw (model location value &optional order))
(defgeneric cas-reference-raw (model location old new order))
(defgeneric make-reference-location-handle (model source-start location))
(defgeneric call-with-reference-location (model handle function))
(defgeneric make-staged-reference-location-handle
    (model staged-object descriptor-strength descriptor-identity future-start))
(defgeneric initialize-object (model address kind size descriptor))
(defgeneric copy-object-representation (model source destination))
(defgeneric copy-object-to-staging (model source address byte-capacity))
(defgeneric map-staged-reference-locations (model staged-object function))
(defgeneric map-staged-weak-descriptors (model staged-object function))
(defgeneric map-staged-ephemeron-descriptors (model staged-object function))
(defgeneric install-staged-object (model staged-object destination))
(defgeneric reference-encoding-equal-p (model left right))
(defgeneric reference-equal (model left right))

;;; Opaque, snapshotted object-kind and conditional-location descriptions.
(defgeneric make-object-kind-description
    (model name &key size-rule alignment-rule strong-layout
                     weak-descriptions ephemeron-descriptions))
(defgeneric describe-object-kind (model description))
(defgeneric make-weak-location-description
    (model identity referent-kind cleared-value))
(defgeneric describe-weak-location (model description))
(defgeneric make-ephemeron-description
    (model identity clear-key-p cleared-key cleared-value))
(defgeneric describe-ephemeron (model description))
