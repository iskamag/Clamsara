;;;; SOURCE DATA ONLY: unexecuted acceptance obligations, not runtime code.
;;;; No admission API or test-only physical construction seam is approved yet.
(in-package #:clamsara.workload.mapc.strict-draft)
(defparameter *capacity-regression-contract*
  '((:dimension :physical-root-tokens
     :geometry (:fixed-temporary-region :current-vm-and-global-sources
                :active-scopes :new-2n-plus-1-cells :callback-entry-vm-slots
                :callback-known-control-locations)
     :boundaries (:exact-fit :one-token-short))
    (:dimension :activation-slots :boundaries (:exact-fit :one-slot-short)
     :include (:native-mapc-scope :interpreted-callback-entry :outer-live-scopes))
    (:dimension :owned-cell-arena :boundaries (:exact-fit :one-cell-short)
     :require (:return-cursors-arguments-distinct :immutable-live-chain-links))
    (:dimension :known-control-queue :boundaries (:exact-fit :one-object-short)
     :require (:same-identity-dedup-as-snapshot :shared-and-cyclic-code-graph
               :actual-callback-template-and-capture-locations))
    (:dimension :vm-stack :boundaries (:exact-entry-fit :one-entry-slot-short)
     :include (:callback-arguments :callback-locals-frame))
    (:history :nested-admission
     :require (:outer-owner-not-overwritten :no-temporary-slots-0-through-15
               :outer-cursors-return-and-callback-capture-survive-movement
               :inner-rejection-precedes-inner-effects :outer-can-continue))
    (:on-rejected-admission
     :observe (:zero-callbacks :zero-managed-allocations :zero-guest-stores
               :unchanged-frame-count :unchanged-vm-registers
               :unchanged-physical-descriptors :unchanged-outer-owned-cells)
     :then (:prove-retained-live-graph :retry-normal-call :explicit-owner-discharge))
    (:on-any-unexpected-test-failure
     :require (:retain-runtime-and-owner :record-condition-and-phase
               :no-eval-nil :no-root-erasure :no-definition-erasure :no-close))
    (:not-allowed (:falsified-frame-count :unprotected-provider-refresh
                   :truncated-root-census :functionp-only-capture-admission
                   :benchmark-parameter-reduction))))
