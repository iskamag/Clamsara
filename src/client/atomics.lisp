;;;; src/client/atomics.lisp -- paper-v14 atomic operations.
;;;; Order validation and width/alignment capability checks belong to binding.
;;;; There are intentionally no host-read/write fallbacks.

(in-package #:clamsara)

(defgeneric atomic-load (atomics place order))
(defgeneric atomic-store (atomics place value order))
(defgeneric atomic-cas (atomics place old new order))
(defgeneric atomic-fetch-add (atomics place delta order))
(defgeneric atomic-bit-set (atomics place index order))
(defgeneric atomic-bit-clear (atomics place index order))
(defgeneric fence (atomics order))
