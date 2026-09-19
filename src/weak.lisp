;;;; weak.lisp -- weak references and finalization (paper-v8 ch. weak).
;;;;
;;;; A weak pointer's referent slot is not scanned during normal tracing; it
;;;; is processed in a dedicated phase after the transitive closure, before
;;;; reclamation.  For each weak pointer: (1) resolve forwarding -- if the
;;;; referent moved, update the slot (and, under concurrent relocation, heal
;;;; via the load barrier); (2) if the referent is live (marked, forwarded, or
;;;; with non-zero reference count), keep the pointer; (3) otherwise clear the
;;;; slot.  Finalizers registered against dead objects move from `known` to
;;;; `pending` in the epilogue and run on a mutator after the pause, never
;;;; inside it.

(in-package #:clamsara)

;; ---- registration --------------------------------------------------------

(defun weak-pointer-p (vm address)
  "True if the object at ADDRESS is a registered weak pointer (its slot 0 is
  the referent and is excluded from normal tracing)."
  (let ((weak (vm-direct-stratum vm :weak)))
    (and weak (s-test-bit weak address))))

(defun register-weak-pointer (vm address)
  "Declare the object at ADDRESS a weak pointer: its referent slot 0 is
  processed in the weak phase, not the mark phase."
  (let ((weak (vm-direct-stratum vm :weak)))
    (unless weak
      (setf weak (vm-register-stratum
                  vm :weak
                  (make-stratum :weak (vm-min-alignment-words vm) :bit
                                (vm-heap-size vm)))))
    (s-set-bit weak address)
    address))

;; ---- weak phase ----------------------------------------------------------

(defun weak-referent-live-p (vm referent)
  "weak.tex §1: a referent is live if it is marked, forwarded, or has a
  non-zero reference count.  For a hierarchical space the count is
  per-superblock (heap.tex §6); a referent whose superblock count is zero is
  dead unless marked/forwarded.  The cycle backup may later prove it dead;
  the sanity checker treats such referents as dead and clears the pointer."
  (or (vm-direct-object-marked-p vm referent)
      (vm-direct-object-forwarded-p vm referent)
      (plusp (vm-direct-object-rc vm referent))
      (let ((plan (vm-plan vm)))
        (some (lambda (s)
                (and (typep s 'superblock-space)
                     (space-direct-contains-p s referent)
                     (let ((counts (sb-refcounts s)))
                       (and counts
                            (plusp (aref counts (sb-index s referent)))))))
              (and plan (plan-spaces plan))))))

(defun resolve-weak-forwarding (vm referent)
  "Step 1: if the referent moved, resolve its forwarding (in-header or
  off-heap) before the liveness test."
  (if (vm-direct-object-forwarded-p vm referent)
      (vm-direct-object-forwarding-pointer vm referent)
      referent))

(defun weak-phase (plan &optional cycle-kind)
  "Process every registered weak pointer after the transitive closure and
before reclamation: resolve forwarding, then clear dead referents.  A minor
collection only collects PLAN's nursery; mature referents therefore remain
untouched, even though they are not marked by the minor trace."
  (let* ((vm (plan-vm plan))
         (weak (vm-direct-stratum vm :weak))
         (os (vm-object-start vm))
         (nursery (and (eq cycle-kind :minor) (plan-nursery plan))))
    (when (and weak os)
      ;; The visitor is dynamic-extent: the weak phase runs once per
      ;; collection and must not open a host allocation (weak.tex: the phase
      ;; is part of the collection's no-allocation window).
      (flet ((visit (address)
               (when (s-test-bit os address)
                 (let* ((referent (vm-direct-object-reference vm address 0))
                        (stripped (and (vm-valid-reference-p vm referent)
                                       (ref-strip-or-self vm referent))))
                   (cond
                     ((null-ref-p referent) nil)  ; already cleared
                     ((not stripped) nil)        ; not a reference (raw payload)
                     ;; A minor has no liveness information for mature objects
                     ;; and does not reclaim them.  Leave their weak slots
                     ;; alone rather than treating an unmarked mature object
                     ;; as dead.
                     ((and nursery
                       (not (space-direct-contains-p nursery stripped))) nil)
                     (t
                      (let ((resolved (resolve-weak-forwarding vm stripped)))
                        ;; heal the slot before the liveness test
                        (unless (eql resolved stripped)
                          (vm-direct-set-object-reference vm address 0 resolved))
                        ;; Publication is not itself a liveness proof.  A
                        ;; public bit describes locality/visibility, not
                        ;; reachability; a public object with no
                        ;; marked/forwarded/RC or root/pin must still be
                        ;; cleared as a weak referent.
                        (unless (weak-referent-live-p vm resolved)
                          (vm-direct-set-object-reference
                           vm address 0 0)))))))))
        (declare (dynamic-extent #'visit))
        (s-for-set-cells weak nil #'visit))))
  plan)

;; ---- finalization trait (weak.tex §2) ------------------------------------
;; The trait slots live directly on the plan class (see plan.lisp), so every
;; plan carries them without redefining the class hierarchy.

(defun initialize-finalization (plan vm)
  "Preallocate the known/pending finalizer vectors at boot (immortal storage
on a target; fixed-capacity vectors on the simulator)."
  (%initialize-finalization-vectors plan vm))

(defun register-finalizer (plan address &optional callback)
  "Register ADDRESS and optional CALLBACK for post-pause finalization.
CALLBACK is invoked as (CALLBACK ADDRESS) by DRAIN-PENDING-FINALIZERS, never
from a collection phase.  The parallel callback vector is fixed-capacity
storage established during plan finalization."
  (unless (or (null callback) (functionp callback))
    (error 'clamsara-error :message "finalizer callback must be a function or NIL"))
  (let* ((known (plan-known-finalizers plan))
         (callbacks (plan-known-finalizer-callbacks plan))
         (index (length known)))
    (unless (and (< index (array-total-size known))
                 (< index (array-total-size callbacks)))
      (error 'heap-exhausted :requested-size 1 :space :finalizers))
    (setf (aref callbacks index) callback)
    (unless (and (vector-push address known)
                 (vector-push callback callbacks))
      (error 'heap-exhausted :requested-size 1 :space :finalizers)))
  address)

(defun rewrite-finalizer-address (plan old-address new-address)
  "Update a registration when publication replaces its external root."
  (let ((known (plan-known-finalizers plan)))
    (when known
      (dotimes (i (length known))
        (when (= (aref known i) old-address)
          (setf (aref known i) new-address)))))
  new-address)

(defun snapshot-finalizer-deadness (plan vm cycle-kind)
  "Snapshot liveness of registered finalizers BEFORE reclaim/release phases
clear the mark stratum.  Dead ones move to a collector-private freeze list;
EPILOGUE moves them to pending.  If tracing forwarded a live object, update its
known finalizer address before the old copy is released."
  (let ((known (plan-known-finalizers plan))
        (known-callbacks (plan-known-finalizer-callbacks plan))
        (freeze (plan-pending-finalizer-freeze plan))
        (freeze-callbacks (plan-pending-finalizer-freeze-callbacks plan))
        (os (vm-object-start vm))
        (dead-count 0))
    (when (and known os)
      (let ((survivors 0))
        (loop for i from 0 below (length known)
              for old-address = (aref known i)
              for callback = (aref known-callbacks i)
              for address =
                (if (and (s-test-bit os old-address)
                         (vm-direct-object-forwarded-p vm old-address))
                    (vm-direct-object-forwarding-pointer vm old-address)
                    old-address)
              do (if (or (not (s-test-bit os address))
                         (and (finalizer-dead-p plan vm address cycle-kind)
                              (not (vm-direct-object-marked-p vm address))
                              (not (vm-direct-object-forwarded-p vm address))
                              (zerop (vm-direct-object-rc vm address))))
                     (progn
                       (unless (and (< dead-count (array-total-size freeze))
                                    (< dead-count (array-total-size freeze-callbacks)))
                         (error 'heap-exhausted :requested-size 1
                                :space :finalizers))
                       (setf (aref freeze dead-count) address
                             (aref freeze-callbacks dead-count) callback)
                       (incf dead-count))
                     (progn
                       ;; A copying trace may have replaced OLD-ADDRESS with a
                       ;; live destination.  Keep the vector in the post-GC
                       ;; address space; otherwise the next cycle loses it.
                       (setf (aref known survivors) address)
                       (incf survivors))))
        (setf (fill-pointer known) survivors
              (fill-pointer known-callbacks) survivors
              (fill-pointer freeze) dead-count
              (fill-pointer freeze-callbacks) dead-count)))
    ;; Keep the preallocated freeze buffers installed between cycles.  An empty
    ;; freeze is still a valid epilogue input and must not turn the next cycle's
    ;; storage into NIL.
    freeze))

(defun process-finalizers (plan frozen-addresses)
  "Move the frozen address/callback pairs from known to pending.
This is epilogue bookkeeping only.  CALLBACKS execute only when a mutator
later calls DRAIN-PENDING-FINALIZERS."
  (let ((pending (plan-pending-finalizers plan))
        (pending-callbacks (plan-pending-finalizer-callbacks plan))
        (freeze-callbacks (plan-pending-finalizer-freeze-callbacks plan)))
    (dotimes (i (length frozen-addresses))
      (let ((address (aref frozen-addresses i))
            (callback (aref freeze-callbacks i)))
        (unless (and (< (length pending) (array-total-size pending))
                     (< (length pending-callbacks)
                        (array-total-size pending-callbacks)))
          (error 'heap-exhausted :requested-size 1 :space :finalizers))
        (unless (and (vector-push address pending)
                     (vector-push callback pending-callbacks))
          (error 'heap-exhausted :requested-size 1 :space :finalizers))))
  plan))

(defun finalizer-dead-p (plan vm address cycle-kind)
  "True if the object at ADDRESS is genuinely dead.  Only cycles that TRACE
  all spaces (:full, :major for non-nursery plans) have complete liveness
  data; a :minor (or any non-tracing cycle kind like :checkpoint) judges
  only the nursery, and objects outside it are kept in known."
  (if (member cycle-kind '(:full :major))
      t
      (let ((nursery (and plan (plan-nursery plan))))
        (and nursery (space-direct-contains-p nursery address)
             (not (vm-direct-object-marked-p vm address))
             (not (vm-direct-object-forwarded-p vm address))))))

(defun pending-finalizer-count (plan)
  (length (plan-pending-finalizers plan)))

(defun drain-pending-finalizers (plan)
  "Pop every pending finalizer and execute its callback after the pause.
Returns a fresh list of addresses for diagnostics and compatibility."
  (let ((pending (plan-pending-finalizers plan))
        (callbacks (plan-pending-finalizer-callbacks plan))
        (result nil))
    (loop while (plusp (length pending))
          do (let ((address (vector-pop pending))
                   (callback (vector-pop callbacks)))
               (when callback (funcall callback address))
               (push address result)))
    (nreverse result)))
