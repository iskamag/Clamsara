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
  (let ((weak (vm-stratum vm :weak)))
    (and weak (s-test-bit weak address))))

(defun register-weak-pointer (vm address)
  "Declare the object at ADDRESS a weak pointer: its referent slot 0 is
  processed in the weak phase, not the mark phase."
  (let ((weak (vm-stratum vm :weak)))
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
  (or (vm-object-is-marked-p vm referent)
      (vm-object-is-forwarded-p vm referent)
      (plusp (vm-object-rc vm referent))
      (let ((plan (vm-plan vm)))
        (some (lambda (s)
                (and (typep s 'superblock-space)
                     (space-contains-p s referent)
                     (let ((counts (sb-refcounts s)))
                       (and counts
                            (plusp (aref counts (sb-index s referent)))))))
              (and plan (plan-spaces plan))))))

(defun resolve-weak-forwarding (vm referent)
  "Step 1: if the referent moved, resolve its forwarding (in-header or
  off-heap) before the liveness test."
  (if (vm-object-is-forwarded-p vm referent)
      (vm-object-forwarding-pointer vm referent)
      referent))

(defun weak-phase (plan &optional cycle-kind)
  "Process every registered weak pointer after the transitive closure and
before reclamation: resolve forwarding, then clear dead referents.  A minor
collection only collects PLAN's nursery; mature referents therefore remain
untouched, even though they are not marked by the minor trace."
  (let* ((vm (plan-vm plan))
         (weak (vm-stratum vm :weak))
         (os (vm-object-start vm))
         (nursery (and (eq cycle-kind :minor) (plan-nursery plan))))
    (when (and weak os)
      (s-for-set-cells weak nil
        (lambda (address)
          (when (s-test-bit os address)
            (let* ((referent (vm-object-reference vm address 0))
                   (stripped (and (vm-valid-reference-p vm referent)
                                  (ref-strip-or-self vm referent))))
              (cond
                ((null-ref-p referent) nil)  ; already cleared
                ((not stripped) nil)          ; not a reference (raw payload)
                ;; A minor has no liveness information for mature objects and
                ;; does not reclaim them.  Leave their weak slots alone rather
                ;; than treating an unmarked mature object as dead.
                ((and nursery (not (space-contains-p nursery stripped))) nil)
                (t
                 (let ((resolved (resolve-weak-forwarding vm stripped)))
                   ;; heal the slot before the liveness test
                   (unless (eql resolved stripped)
                     (setf (vm-object-reference vm address 0) resolved))
                   (let ((live-p
                           (or (weak-referent-live-p vm resolved)
                               (vm-object-is-public-p vm resolved))))
                     (unless live-p
                       (setf (vm-object-reference vm address 0) 0))))))))))))
  plan)

;; ---- finalization trait (weak.tex §2) ------------------------------------
;; The trait slots live directly on the plan class (see plan.lisp), so every
;; plan carries them without redefining the class hierarchy.

(defun initialize-finalization (plan vm)
  "Preallocate the known/pending finalizer vectors at boot (immortal storage
on a target; fixed-capacity vectors on the simulator)."
  (%initialize-finalization-vectors plan vm))

(defun register-finalizer (plan address)
  "Register the object at ADDRESS for finalization."
  (let ((known (plan-known-finalizers plan)))
    (unless (vector-push address known)
      (error 'heap-exhausted :requested-size 1 :space :finalizers)))
  address)

(defun snapshot-finalizer-deadness (plan vm cycle-kind)
  "Snapshot liveness of registered finalizers BEFORE reclaim/release phases
clear the mark stratum.  Dead ones move to a collector-private freeze list;
EPILOGUE moves them to pending.  If tracing forwarded a live object, update its
known finalizer address before the old copy is released."
  (let ((known (plan-known-finalizers plan))
        (os (vm-object-start vm))
        (dead nil))
    (when (and known os)
      (let ((survivors 0))
        (loop for i from 0 below (length known)
              for old-address = (aref known i)
              for address =
                (if (and (s-test-bit os old-address)
                         (vm-object-is-forwarded-p vm old-address))
                    (vm-object-forwarding-pointer vm old-address)
                    old-address)
              do (if (or (not (s-test-bit os address))
                         (and (finalizer-dead-p plan vm address cycle-kind)
                              (not (vm-object-is-marked-p vm address))
                              (not (vm-object-is-forwarded-p vm address))
                              (zerop (vm-object-rc vm address))))
                     (push address dead)
                     (progn
                       ;; A copying trace may have replaced OLD-ADDRESS with a
                       ;; live destination.  Keep the vector in the post-GC
                       ;; address space; otherwise the next cycle loses it.
                       (setf (aref known survivors) address)
                       (incf survivors))))
        (setf (fill-pointer known) survivors)))
    dead))

(defun process-finalizers (plan dead-addresses)
  "weak.tex §2: move the (pre-computed) dead finalizer addresses known->
pending.  Runs in the epilogue; finalizers themselves run on a mutator after
the pause, never inside it."
  (let ((pending (plan-pending-finalizers plan)))
    (when pending
      (dolist (address dead-addresses)
        (unless (vector-push address pending)
          (error 'heap-exhausted :requested-size 1 :space :finalizers)))))
  plan)

(defun finalizer-dead-p (plan vm address cycle-kind)
  "True if the object at ADDRESS is genuinely dead.  Only cycles that TRACE
  all spaces (:full, :major for non-nursery plans) have complete liveness
  data; a :minor (or any non-tracing cycle kind like :checkpoint) judges
  only the nursery, and objects outside it are kept in known."
  (if (member cycle-kind '(:full :major))
      t
      (let ((nursery (and plan (plan-nursery plan))))
        (and nursery (space-contains-p nursery address)
             (not (vm-object-is-marked-p vm address))
             (not (vm-object-is-forwarded-p vm address))))))

(defun pending-finalizer-count (plan)
  (length (plan-pending-finalizers plan)))

(defun drain-pending-finalizers (plan)
  "Pop every pending finalizer address (called by a mutator after the
  pause).  Returns a fresh list."
  (let ((pending (plan-pending-finalizers plan))
        (result nil))
    (loop while (plusp (length pending))
          do (push (vector-pop pending) result))
    (nreverse result)))
