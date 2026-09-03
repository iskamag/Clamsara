;;;; protocol/object-model.lisp -- clamsara-protocol.object-model.
;;;;
;;;; Normative source: paper-v11/chapters/client-protocols.tex section 1
;;;; (Object-model protocol).  The generics below are the reference interface;
;;;; names and lambda lists are copied from the paper's listings.  This system
;;;; depends on nothing but Common Lisp (architecture.tex section 2: protocol
;;;; systems must not depend on collector configurations).

(defpackage #:clamsara-protocol.object-model
  (:use #:cl)
  (:export #:valid-reference-p
           #:object-start-p
           #:object-size
           #:object-kind
           #:map-reference-locations
           #:load-reference
           #:store-reference-raw
           #:initialize-object
           #:copy-object-representation
           #:reference-equal
           #:offered-metadata-fields
           #:field-read
           #:field-write
           #:field-cas))

(in-package #:clamsara-protocol.object-model)

(defgeneric valid-reference-p (object-model reference)
  (:documentation "Is REFERENCE a reference the object model can decode?
Clamsara treats references as opaque values; only the client decides validity
(client-protocols.tex section 1)."))

(defgeneric object-start-p (object-model reference)
  (:documentation "Is REFERENCE the normalized start of an object?  A client
that admits interior or tagged references defines their normalization there;
OBJECT-START-P and space resolution receive the normalized start reference and
normalization is idempotent."))

(defgeneric object-size (object-model reference)
  (:documentation "Size of the object at REFERENCE in bytes, checked (paper-v11
listing comment: bytes, checked).  A client signals a client-visible error
for a reference that names no object rather than returning an unchecked value."))

(defgeneric object-kind (object-model reference)
  (:documentation "The declared object kind of the object at REFERENCE.  Object
kinds are declared at construction: each admitted kind names its size rule, its
reference-location descriptor, and the metadata fields it carries."))

(defgeneric map-reference-locations (object-model reference function)
  (:documentation "AUTHORITATIVE reference-location discovery.  Calls FUNCTION
once per strong reference LOCATION of the object at REFERENCE
(client-protocols.tex section 1: map-reference-locations is authoritative).
Weak, ephemeron, code relocation, and foreign fields are described by explicit
descriptors and are not strong locations.  A conservative client may visit
extra word-like locations only if its declared plan permits false retention
and the locations can be updated safely.  FUNCTION receives a location value
whose form is the client's; LOAD-REFERENCE and STORE-REFERENCE-RAW must accept
exactly these locations."))

(defgeneric load-reference (object-model location)
  (:documentation "Read the reference stored at LOCATION."))

(defgeneric store-reference-raw (object-model location new-reference)
  (:documentation "Write NEW-REFERENCE to LOCATION without running any
barrier.  This is the raw representation seam; ordered publication rules live
in the barrier layer, not here."))

(defgeneric initialize-object (object-model destination kind size descriptor)
  (:documentation "Initialize raw object state at DESTINATION for KIND with
SIZE and DESCRIPTOR, including enough state that a concurrent scanner can
distinguish uninitialized storage (execution-model.tex section 2).  This
writes representation/ABI state only; logical collector metadata (mark, age,
publication, forwarding) is initialized by Clamsara components."))

(defgeneric copy-object-representation (object-model source destination)
  (:documentation "Copy implementation payload and ABI fields from SOURCE to
DESTINATION.  Must not decide that mark, age, public, or forwarding metadata
survives: the selected Clamsara movement component transfers logical collector
data (client-protocols.tex section 1)."))

(defgeneric reference-equal (object-model left right)
  (:documentation "Do LEFT and RIGHT name the same object?  Identity, not
encoding equality: a client with tagged or coloured references defines
normalization so that two references to one object compare equal."))

(defgeneric offered-metadata-fields (object-model)
  (:documentation "List of physical metadata fields the client advertises
(client-protocols.tex section 1, optional representation fields).  Each field
declares width, admissible values, atomicity, interaction with GC copying and
checkpoint recovery, and which object kinds possess it.  Clamsara chooses
whether a logical datum uses a field; a client with no such fields returns an
empty list."))

(defgeneric field-read (object-model field object-or-reference)
  (:documentation "Read physical metadata FIELD of OBJECT-OR-REFERENCE."))

(defgeneric field-write (object-model field object-or-reference value)
  (:documentation "Write VALUE to physical metadata FIELD."))

(defgeneric field-cas (object-model field object-or-reference old new)
  (:documentation "Compare-and-swap physical metadata FIELD from OLD to NEW;
returns the previous value."))
