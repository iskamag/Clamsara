;;;; protocol/roots.lisp -- clamsara-protocol.roots.
;;;;
;;;; Normative source: paper-v11/chapters/client-protocols.tex section 2
;;;; (Root protocol).  Roots are locations, not merely values, because a moving
;;;; collector must update them.  Depends on nothing but Common Lisp.

(defpackage #:clamsara-protocol.roots
  (:use #:cl)
  (:export #:with-root-snapshot
           #:map-root-locations
           #:load-root
           #:store-root
           #:root-location-kind))

(in-package #:clamsara-protocol.roots)

(defgeneric with-root-snapshot (root-client scope function)
  (:documentation "Call FUNCTION with a root snapshot for SCOPE (paper-v11
client-protocols.tex section 2).  SCOPE names all mutators, one owner, one
request, globals, handles, or an explicit union; the accepted names are the
client's declared vocabulary.  A snapshot carries an epoch.  The client
guarantees that every root location visited remains valid until the snapshot
is released and that no unreported root mutation escapes the selected
coordination protocol.  Returns the values of FUNCTION."))

(defgeneric map-root-locations (root-snapshot function)
  (:documentation "Call FUNCTION once per root LOCATION in ROOT-SNAPSHOT.
Locations are client values; LOAD-ROOT and STORE-ROOT accept exactly these."))

(defgeneric load-root (root-client root-location)
  (:documentation "Read the reference currently stored at ROOT-LOCATION."))

(defgeneric store-root (root-client root-location reference)
  (:documentation "Store REFERENCE at ROOT-LOCATION.  A moving collector uses
this to rewrite roots."))

(defgeneric root-location-kind (root-client root-location)
  (:documentation "The client's kind designation for ROOT-LOCATION (for
example a root-vector entry versus a registered code-constant region)."))
