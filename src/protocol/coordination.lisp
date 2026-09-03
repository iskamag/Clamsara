;;;; protocol/coordination.lisp -- clamsara-protocol.coordination.
;;;;
;;;; Normative source: paper-v11/chapters/client-protocols.tex section 3
;;;; (Coordination protocol).  Depends on nothing but Common Lisp.

(defpackage #:clamsara-protocol.coordination
  (:use #:cl)
  (:export #:request-safepoint
           #:await-safepoint
           #:release-safepoint
           #:current-mutator
           #:begin-epoch
           #:await-epoch
           #:publish-fence))

(in-package #:clamsara-protocol.coordination)

(defgeneric request-safepoint (coordinator scope reason)
  (:documentation "Request a safepoint stop of SCOPE for REASON.  A stop token
identifies exactly which mutators are stopped and which may still publish
references (client-protocols.tex section 3).  Stop-the-owner is not represented
as a cheaper global stop.  Returns the client's stop token."))

(defgeneric await-safepoint (coordinator token)
  (:documentation "Wait until every mutator named by TOKEN has arrived at the
safepoint.  Returns a client-defined completion value."))

(defgeneric release-safepoint (coordinator token)
  (:documentation "Release the safepoint identified by TOKEN and let the
stopped mutators resume."))

(defgeneric current-mutator (coordinator)
  (:documentation "An identity for the calling mutator context.  Mutator
contexts are runtime state, not CLOS dispatch requirements
(execution-model.tex section 2)."))

(defgeneric begin-epoch (coordinator domain)
  (:documentation "Open an epoch in DOMAIN (a named set of threads and the
operations they run).  Returns the client's epoch object."))

(defgeneric await-epoch (coordinator epoch)
  (:documentation "Return when every operation admitted before EPOCH in its
domain has quiesced.  Epoch grace is the primitive that concurrent movers and
publication handshakes retire storage against."))

(defgeneric publish-fence (coordinator)
  (:documentation "Order every prior write of the calling thread before any
later observation by threads in the scope."))
