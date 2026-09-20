;;;; src/client/mapping.lisp -- paper-v14 logical mapping service.
;;;; Mapping changes are host operations under the configured publication stop.

(in-package #:clamsara)

(defgeneric reserve-virtual-range (mapping range))
(defgeneric map-logical-pages (mapping range source access))
(defgeneric unmap-logical-pages (mapping range))
(defgeneric remap-logical-pages (mapping source destination count))
(defgeneric protect-logical-pages (mapping range access))
(defgeneric flush-address-translations (mapping range))
