;;;; protocol/diagnostics.lisp -- clamsara-protocol.diagnostics.
;;;;
;;;; IMPLEMENTATION SEAM, NOT A PAPER LISTING.  paper-v11
;;;; client-protocols.tex section 6 (Clock, diagnostics, and fatal failure)
;;;; specifies the obligations in prose but names no interface:
;;;;   - statistics may use a monotonic clock and event counters, but
;;;;     correctness must not depend on wall-clock progress;
;;;;   - every client provides an allocation-free fatal diagnostic path for
;;;;     corrupt heap state; a supervisor deployment must be able to report
;;;;     the violated invariant without invoking the allocator or CLOS.
;;;; MONOTONIC-CLOCK and FATAL-DIAGNOSTIC are this implementation's names for
;;;; that unlisted seam.  If a later paper revision names these generics, the
;;;; names migrate; clients may rename under the status-chapter rename clause.
;;;; Depends on nothing but Common Lisp.

(defpackage #:clamsara-protocol.diagnostics
  (:use #:cl)
  (:export #:monotonic-clock
           #:fatal-diagnostic))

(in-package #:clamsara-protocol.diagnostics)

(defgeneric monotonic-clock (clock-client)
  (:documentation "A monotonic tick for statistics.  Correctness must not
depend on wall-clock progress (client-protocols.tex section 6)."))

(defgeneric fatal-diagnostic (client reason)
  (:documentation "Report REASON (the violated invariant) through the client's
fatal diagnostic path.  A supervisor deployment must be able to report the
violated invariant without invoking the allocator or CLOS; the portable
generic is the seam, and a closed deployment lowers it to the same direct
call it uses for every other hot-path entry."))
