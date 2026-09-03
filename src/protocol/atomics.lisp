;;;; protocol/atomics.lisp -- clamsara-protocol.atomics.
;;;;
;;;; Normative source: paper-v11/chapters/client-protocols.tex section 4
;;;; (Atomic and memory-order protocol).  Ordinary Common Lisp reads and
;;;; writes are insufficient to specify races.  Depends on nothing but
;;;; Common Lisp.

(defpackage #:clamsara-protocol.atomics
  (:use #:cl)
  (:export #:atomic-load
           #:atomic-store
           #:atomic-cas
           #:atomic-fetch-add
           #:atomic-bit-set
           #:atomic-bit-clear
           #:fence))

(in-package #:clamsara-protocol.atomics)

(defgeneric atomic-load (atomics place order)
  (:documentation "Atomically load the word at PLACE with ORDER.  PLACE is a
client-defined address; the client documents, for each atomic operation it
offers, whether it provides acquire, release, or sequential ordering (that
documentation duty is stated with the coordination protocol,
client-protocols.tex section 3 last paragraph; this generic is section 4)."))

(defgeneric atomic-store (atomics place value order)
  (:documentation "Atomically store VALUE at PLACE with ORDER."))

(defgeneric atomic-cas (atomics place old new order)
  (:documentation "Compare PLACE with OLD; if equal, store NEW.  Returns the
previous value, so a caller tests success by comparing it with OLD."))

(defgeneric atomic-fetch-add (atomics place delta order)
  (:documentation "Atomically add DELTA to the word at PLACE; returns the
previous value."))

(defgeneric atomic-bit-set (atomics place index order)
  (:documentation "Atomically set bit INDEX of the word at PLACE; returns the
previous bit as a boolean."))

(defgeneric atomic-bit-clear (atomics place index order)
  (:documentation "Atomically clear bit INDEX of the word at PLACE; returns
the previous bit as a boolean."))

(defgeneric fence (atomics order)
  (:documentation "Issue a memory fence with ORDER (:acquire, :release, or
:seq-cst where a component needs them)."))
