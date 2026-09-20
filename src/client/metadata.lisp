;;;; src/client/metadata.lisp -- paper-v14 physical metadata offers.
;;;; Only the generic protocol is declared here.  Offers are opaque to users.

(in-package #:clamsara)

(defgeneric make-metadata-field-offer
    (model identity width
     &key legal-values operations orders object-kinds overlaps
          copy-behavior checkpoint-preservation))
(defgeneric describe-metadata-field-offer (model offer))
(defgeneric offered-metadata-fields (model))
(defgeneric field-read (model field object-or-reference))
(defgeneric field-write (model field object-or-reference value))
(defgeneric field-cas (model field object-or-reference old new))
