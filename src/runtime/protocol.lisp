;;;; paper-v14 sequential execution protocol declarations.
(in-package #:clamsara)

;;; Allocation and cycle reporting.
(defgeneric bind-mutator (configuration execution allocation-domain))
(defgeneric unbind-mutator (configuration context))
(defgeneric allocate-object (context kind bytes alignment descriptor))
(defgeneric allocate-raw (allocator bytes alignment kind))
(defgeneric refill-mutator (allocator context request))
(defgeneric make-cycle-result-record (collection-owner))
(defgeneric cycle-result-owner (result-record))
(defgeneric collect (configuration scope cause result-record &key algorithm))
(defgeneric automatic-collect (configuration scope cause))
(defgeneric cycle-result-status (result-record))
(defgeneric cycle-result-phase (result-record))
(defgeneric cycle-result-scope (result-record))
(defgeneric cycle-result-algorithm (result-record))
(defgeneric cycle-result-cause (result-record))
(defgeneric cycle-result-reason (result-record))
(defgeneric cycle-result-count (result-record counter))
(defgeneric cycle-counter-known-p (collection-owner counter))
(defgeneric cycle-counter-description (collection-owner counter))
(defgeneric cycle-cause-known-p (collection-owner cause))
(defgeneric cycle-cause-description (collection-owner cause))
(defgeneric cycle-reason-known-p (collection-owner reason))
(defgeneric cycle-reason-description (collection-owner reason))

;;; The one construction-bound reference route.
(defgeneric configuration-barrier (configuration))
(defgeneric barrier-store (barrier context location new))
(defgeneric barrier-compare-exchange (barrier context location expected new))
(defgeneric barrier-read (barrier context location))
(defgeneric barrier-contribution-reserve
    (contribution context operation location))
(defgeneric barrier-contribution-admit
    (contribution reservation context operation location))
(defgeneric barrier-contribution-transform
    (contribution reservation context operation location old candidate))
(defgeneric barrier-contribution-before-exposure
    (contribution reservation context operation location old final))
(defgeneric barrier-contribution-after-exposure
    (contribution reservation context operation location old final))
(defgeneric barrier-contribution-cancel (contribution reservation))

;;; Space lifecycle, movement repair, and tracing.
(defgeneric prepare-space (space cycle))
(defgeneric trace-reference (trace-context reference))
(defgeneric trace-object (space trace-context start))
(defgeneric object-live-p (space cycle reference))
(defgeneric reclaim-space (space cycle))
(defgeneric cancel-reclaim-space (space cycle))
(defgeneric finish-space (space cycle))

(defclass movement-participant (component) ())
(defgeneric map-cycle-movements (cycle function))
(defgeneric map-cycle-deaths (cycle function))
(defgeneric prepare-movement-participant (participant cycle))
(defgeneric cancel-movement-participant (participant cycle))
(defgeneric finish-movement-participant (participant cycle))

(defgeneric begin-trace-context (cycle scope work-capacity))
(defgeneric trace-context-cycle (trace-context))
(defgeneric trace-context-scope (trace-context))
(defgeneric trace-scope-contains-p (trace-context space start))
(defgeneric trace-discovery-count (trace-context))
(defgeneric map-trace-discoveries (trace-context function))
(defgeneric trace-claim-object (trace-context space start))
(defgeneric trace-await-claim (trace-context space start))
(defgeneric trace-commit-object
    (trace-context claim reservation work-space work-start))
(defgeneric trace-abandon-object (trace-context claim reservation reason))
(defgeneric trace-take-work (trace-context worker))
(defgeneric trace-finish-work (trace-context worker space start))
(defgeneric trace-fail (trace-context reason))
(defgeneric finish-trace-context (trace-context))
