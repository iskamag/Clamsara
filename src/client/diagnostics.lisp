;;;; src/client/diagnostics.lisp -- paper-v14 clock/fatal diagnostics.

(in-package #:clamsara)

(defgeneric monotonic-clock (diagnostics))
(defgeneric fatal-diagnostic (diagnostics reason))
