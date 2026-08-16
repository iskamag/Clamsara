;;;; publication.lisp -- thread-local scope and publication strategies
;;;; (paper-v8 ch. locality).  The DLG invariant: no public object references
;;;; a private one.  Publication restores it when a private object is about to
;;;; become reachable from a public source.  The strategy is a pluggable
;;;; primitive; Claimore treats the choice as an experimental parameter.

(in-package #:clamsara)

(defclass publication-strategy ()
  ((public-region :initarg :public-region :accessor public-region
                  :initform nil)
   (work :accessor publication-work :initform (make-array 0 :fill-pointer 0))
   ;; preallocated closure-copy dedup table (boot-time; the publication
   ;; barrier must not call the host allocator)
   (copy-seen :accessor publication-copy-seen :initform nil)))

(defgeneric publish (strategy vm object)
  (:documentation "Restore DLG for OBJECT becoming reachable from a public source."))
(defgeneric publication-read-rule (strategy)
  (:documentation "Optional read-barrier rule this strategy requires, or NIL.")
  (:method ((s publication-strategy)) nil))
(defgeneric strategy-read-guarded-p (strategy)
  (:documentation "True if the strategy uses read-guarded DLG (DLG-r).")
  (:method ((s publication-strategy)) nil))
(defgeneric strategy-published-roots (strategy)
  (:documentation "The strategy's published-roots set, or NIL.")
  (:method ((s publication-strategy)) nil))

(defun initialize-publication-work (strategy vm)
  "Allocate the eager-closure queue (and any published-roots set) at boot,
  standing in for immortal storage."
  ;; Publication metadata is part of the strategy contract.  Plans normally
  ;; install :public in PLAN-INSTALL-STRATA, but direct strategy users and
  ;; custom Iso plans must get the same invariant before the first publish.
  (unless (vm-stratum vm :public)
    (vm-register-stratum vm :public
      (make-stratum :public (vm-min-alignment-words vm) :bit (vm-heap-size vm))))
  (setf (publication-work strategy)
        (make-array (vm-heap-size vm) :element-type 'fixnum
                    :initial-element 0 :fill-pointer 0)
        (publication-copy-seen strategy)
        (make-hash-table :test 'eql))
  (when (typep strategy 'lazy-read-barrier)
    (initialize-lazy-published-roots strategy vm))
  (when (typep strategy 'trap-error-copy-b)
    (initialize-trap-b-published-roots strategy vm))
  strategy)

;; ---- the published-roots set (locality.tex §1) ---------------------------
;; Every guarded public-to-private edge is recorded here at publication time.
;; The private collection drains it twice: at start (seeding the trace) and
;; again before reclaim (pinning referents of edges appended mid-collection
;; by foreign read rules).  Entries record EDGES (published object + slot),
;; not just objects: the healing mechanism needs the slot.  Two parallel
;; fixnum vectors, no host conses on the mutator path.

(defclass published-roots ()
  ((objects :accessor published-roots-objects)
   (slots :accessor published-roots-slots)
   (fill :accessor published-roots-fill :initform 0)))

(defun make-published-roots (capacity)
  (let ((pr (make-instance 'published-roots)))
    (setf (published-roots-objects pr)
          (make-array capacity :element-type 'fixnum :initial-element 0)
          (published-roots-slots pr)
          (make-array capacity :element-type 'fixnum :initial-element 0))
    pr))

(defun published-roots-empty-p (pr) (zerop (published-roots-fill pr)))

(defun record-published-edge (pr object slot)
  "Append the guarded edge (OBJECT . SLOT).  Append-only: never dropped."
  (let ((fill (published-roots-fill pr)))
    (unless (< fill (length (published-roots-objects pr)))
      (error 'heap-exhausted :requested-size 1 :space :published-roots))
    (setf (aref (published-roots-objects pr) fill) object
          (aref (published-roots-slots pr) fill) slot
          (published-roots-fill pr) (1+ fill))
    pr))

(defun drain-published-roots (pr fn)
  "Invoke (FN object slot) on every recorded edge.  The edge entries are
  retained: the set is append-only and drained, not cleared (locality.tex)."
  (let ((fill (published-roots-fill pr)))
    (dotimes (i fill)
      (funcall fn (aref (published-roots-objects pr) i)
               (aref (published-roots-slots pr) i))))
  pr)

(defun published-roots-count (pr) (published-roots-fill pr))

(defun record-published-object-edges (pr vm object)
  "Record every outgoing edge of newly exposed OBJECT.

  A read-guarded publication may expose a child long after its parent was
  published.  The child's edges are guarded too, so the private collector
  must retain them in the append-only published-roots set just as it does the
  original publication edge."
  (when pr
    ;; A declared layout names the slots that may carry references.  Keep the
    ;; conservative payload walk only for objects whose layout is unknown;
    ;; publication metadata must not mistake raw payload words for guarded
    ;; edges.  This direct index walk avoids allocating a callback closure.
    (let ((slots (vm-reference-slots vm object)))
      (if slots
          (loop for i below (length slots)
                do (record-published-edge pr object (aref slots i)))
          (dotimes (slot (vm-object-reference-count vm object))
            (record-published-edge pr object slot)))))
  object)

(defun published-edge-recorded-p (pr vm object referent)
  "True if the published-roots set contains a guarded edge from OBJECT whose
  slot currently holds REFERENT (DLG-r verification: every public-to-private
  edge must be recorded at publication time)."
  (let ((fill (published-roots-fill pr)))
    (loop for i from 0 below fill
          for edge-object = (aref (published-roots-objects pr) i)
          for edge-slot = (aref (published-roots-slots pr) i)
          when (and (eql edge-object object)
                    (eql (vm-object-reference vm edge-object edge-slot)
                         referent))
            return t
          finally (return nil))))

(defun edge-referent-live-p (vm object slot)
  (let ((child (vm-object-reference vm object slot)))
    (and (vm-reference-p vm child) child)))

;; ---- eager closure (Iso) -------------------------------------------------
;; Publish the whole transitive closure at once: set the public bit on each.
;; Each object is published at most once, so amortised cost is constant/object.

(defclass eager-closure (publication-strategy) ())

(defmethod publish ((s eager-closure) vm root)
  ;; Iso's public space is the preferred home for the published incarnation.
  ;; Keep the source closure public as well: existing private roots may still
  ;; point at it, and strong DLG requires that closure to be self-contained.
  ;; The public-space copy is opportunistic (as in locality.tex); if it cannot
  ;; be made, the source closure remains a valid public incarnation.
  (let* ((root (ref-strip-or-self vm root))
         (region (public-region s))
         (copy (and region
                    (space-allocator region)
                    (not (space-contains-p region root))
                    (not (vm-object-is-public-p vm root))
                    (copy-closure-to-public vm root region)))
         (work (publication-work s))
         (head 0))
    ;; The public bit is also the visited bit: publication is monotone, so an
    ;; object can enter this queue at most once over the whole run.
    (setf (fill-pointer work) 0)
    (unless (vm-object-is-public-p vm root)
      (setf (vm-object-is-public-p vm root) t)
      (unless (vector-push root work)
        (error 'heap-exhausted :requested-size 1
               :space :publication-queue)))
    (loop while (< head (length work))
          for object = (aref work head)
          do (incf head)
             (vm-map-reference-slots
              vm object
              (lambda (child)
                (let ((addr (ref-strip-or-self vm child)))
                  (when (and (vm-reference-p vm child)
                             (not (vm-object-is-public-p vm addr)))
                    (setf (vm-object-is-public-p vm addr) t)
                    (unless (vector-push addr work)
                      (error 'heap-exhausted :requested-size 1
                             :space :publication-queue)))))))
    (setf (fill-pointer work) 0)
    (or copy root)))

;; ---- lazy read-barrier (Marlow/Dolan/Filatov-Mikheev lineage) ------------
;; Publish only the root; a read barrier promotes children on demand.  The
;; guarded edge (published object, slot) is recorded in the published-roots
;; set so the private collection can pin/heal the referent (DLG-r).

(defclass lazy-read-barrier (publication-strategy)
  ((published-roots :accessor strategy-published-roots :initform nil)))

(defmethod strategy-read-guarded-p ((s lazy-read-barrier)) t)

(defmethod publish ((s lazy-read-barrier) vm object)
  (let ((object (ref-strip-or-self vm object)))
    (setf (vm-object-is-public-p vm object) t)
    ;; record every outgoing slot as a guarded edge: a read of a private child
    ;; publishes on demand, and the private collection must know all such slots
    (record-published-object-edges (strategy-published-roots s) vm object)
    object))

(defmethod publication-read-rule ((s lazy-read-barrier))
  ;; on read of a still-private child of a public object, publish it.  The
  ;; newly exposed object's own edges are guarded as well and must be retained
  ;; for the next private collection (not just the parent edge).
  (lambda (vm slot-addr reference)
    (let ((addr (ref-strip-or-self vm reference)))
      (when (and (vm-reference-p vm addr) (not (vm-object-is-public-p vm addr)))
        (setf (vm-object-is-public-p vm addr) t)
        (record-published-object-edges (strategy-published-roots s) vm addr)
        (setf (ref-u64 vm slot-addr) reference)))
    reference))

(defun initialize-lazy-published-roots (strategy vm)
  (setf (strategy-published-roots strategy)
        (make-published-roots (vm-heap-size vm)))
  strategy)

;; ---- trap / error-copy (Claimore experiments) ----------------------------
;; Variant A: copy into public region, poison the private original with an
;; error stand-in that redirects to the public copy.  Variant B is the mirror.

(defparameter +error-tag+ 6 "Type tag for poisoned stand-ins.")

(defun poison-as-error (vm original copy)
  "Overwrite ORIGINAL with an error stand-in of size 1 whose slot 0 holds the
  public COPY's address.  A 1-slot stand-in is a well-formed object under the
  object model (vm-object-total-words = 2), so a walker scanning it cannot run
  off into the heap."
  (setf (vm-object-header vm original) (pack-header 1 +error-tag+))
  ;; Slot 0 is now a strong trap redirect, not a weak referent.  Clear the
  ;; poisoned object's weak metadata or the private collector will omit the
  ;; redirect and can reclaim the public incarnation it names.
  (let ((weak (vm-stratum vm :weak)))
    (when weak (s-clear-bit weak original)))
  (setf (vm-object-reference vm original 0) copy))

(defun error-object-p (vm reference)
  (let ((addr (ref-strip-or-self vm reference)))
    (and (vm-object-start-p vm addr)
         (eql (vm-object-type-tag vm addr) +error-tag+))))

(defun error-redirect (vm reference)
  "The public copy address stored in slot 0 of the error stand-in."
  (vm-object-reference vm (ref-strip-or-self vm reference) 0))

(defclass trap-error-copy-a (publication-strategy) ())

(defmethod publish ((s trap-error-copy-a) vm object)
  ;; Variant A (locality.tex §2): copy o's CLOSURE into the public region so
  ;; the public graph is self-contained (strong DLG).  The copy is deep:
  ;; children are copied too, so no public object references a private one.
  ;; On public-region exhaustion the publication aborts cleanly: the
  ;; original is left untouched (never poisoned), NIL is returned, and the
  ;; caller signals instead of storing a private referent.
  (let ((copy (copy-closure-to-public vm object (public-region s))))
    (when copy
      (setf (vm-object-is-public-p vm copy) t)
      (poison-as-error vm object copy))
    copy))

(defmethod publication-read-rule ((s trap-error-copy-a))
  (lambda (vm slot-addr reference)
    (if (error-object-p vm reference)
        (let ((healed (error-redirect vm reference)))
          (setf (ref-u64 vm slot-addr) healed)
          healed)
        reference)))

(defclass trap-error-copy-b (publication-strategy)
  ((published-roots :accessor strategy-published-roots :initform nil)))

(defmethod strategy-read-guarded-p ((s trap-error-copy-b)) t)

(defmethod publish ((s trap-error-copy-b) vm object)
  ;; Variant B: keep the original private; install an error stand-in in the
  ;; public region whose edge to the original is a guarded published root.
  ;; Dereferencing the stand-in traps (error tag); the trap handler promotes.
  (let* ((region (public-region s))
         (stand-in (if (and region (space-allocator region))
                       (alloc (space-allocator region) 2)
                       nil)))
    (when stand-in
      (setf (vm-object-header vm stand-in) (pack-header 1 +error-tag+)
            (vm-object-reference vm stand-in 0)
            (ref-strip-or-self vm object))
      (let ((os (vm-object-start vm)))
        (when os (s-set-bit os stand-in)))
      ;; the stand-in lives in the public region: it IS a public object, so
      ;; the DLG-r sanity check can see its guarded edge
      (setf (vm-object-is-public-p vm stand-in) t)
      (let ((pr (strategy-published-roots s)))
        (when pr (record-published-edge pr stand-in 0))))
    stand-in))

(defmethod publication-read-rule ((s trap-error-copy-b))
  ;; locality.tex §2 Variant B: a public accessor traps on the error copy and
  ;; is redirected to a public copy made at that moment ("now promoted");
  ;; the stand-in's slot is healed so later reads miss the trap.  The
  ;; stand-in KEEPS its error tag: healing rewrites slot 0 to the promoted
  ;; copy, so a second accessor still holding the stand-in re-traps, follows
  ;; the redirect, and receives the SAME promoted copy (idempotent, one
  ;; incarnation per stand-in).
  (lambda (vm slot-addr reference)
    (if (error-object-p vm reference)
        (let* ((stand-in (ref-strip-or-self vm reference))
               (redirect (vm-object-reference vm stand-in 0)))
          (if (not (vm-object-is-public-p vm redirect))
              ;; not yet promoted: the redirect names the private original
              (let ((promoted (copy-closure-to-public
                               vm redirect (public-region s))))
                (unless promoted
                  (error 'heap-exhausted :requested-size 1 :space :public))
                (setf (vm-object-is-public-p vm promoted) t
                      ;; heal slot 0; the error tag stays, so a second
                      ;; accessor re-traps and follows the redirect
                      (vm-object-reference vm stand-in 0) promoted
                      (ref-u64 vm slot-addr) promoted)
                promoted)
              ;; already promoted: redirect names the public copy
              (progn (setf (ref-u64 vm slot-addr) redirect)
                     redirect)))
        reference)))

(defun initialize-trap-b-published-roots (strategy vm)
  (setf (strategy-published-roots strategy)
        (make-published-roots (vm-heap-size vm)))
  strategy)

(defun publication-allocator-checkpoint (allocator)
  "Capture enough allocator state to undo a failed closure copy."
  (typecase allocator
    (immix-allocator
     (list :immix (ix-block-count allocator) (ix-next-base allocator)
           (ix-current allocator)
           (map 'vector #'immix-block-cursor (ix-blocks allocator))
           (copy-seq (ix-span-root allocator))))
    (hierarchical-allocator
     (list :hierarchical
           (copy-seq (hierarchical-allocator-cursors allocator))
           (copy-seq (hierarchical-allocator-span-root allocator))
           (hierarchical-allocator-next-fresh allocator)
           (hierarchical-allocator-current allocator)
           (fill-pointer (hierarchical-allocator-free-blocks allocator))))
    (bump-allocator (list :bump (ba-cursor allocator)))
    (otherwise nil)))

(defun rollback-publication-copies (vm allocator checkpoint work)
  "Forget every destination and restore ALLOCATOR to CHECKPOINT."
  ;; Return allocations to allocators that support individual free (the
  ;; free-list/LOS paths); bump/block allocators are restored below.
  (loop for i downfrom (1- (fill-pointer work)) to 0
        for dst = (aref work i)
        for words = (vm-object-total-words vm dst)
        do (free allocator dst words)
           (vm-forget-object vm dst))
  (when checkpoint
    (case (first checkpoint)
      (:immix
       (destructuring-bind (tag count next current cursors spans) checkpoint
         (declare (ignore tag))
         (dotimes (i (length cursors))
           (setf (immix-block-cursor (aref (ix-blocks allocator) i))
                 (aref cursors i)))
         (replace (ix-span-root allocator) spans)
         (setf (ix-block-count allocator) count
               (ix-next-base allocator) next
               (ix-current allocator) current)))
      (:hierarchical
       (destructuring-bind (tag cursors spans next current free-fill) checkpoint
         (declare (ignore tag))
         (replace (hierarchical-allocator-cursors allocator) cursors)
         (replace (hierarchical-allocator-span-root allocator) spans)
         (setf (hierarchical-allocator-next-fresh allocator) next
               (hierarchical-allocator-current allocator) current
               (fill-pointer (hierarchical-allocator-free-blocks allocator))
               free-fill)))
      (:bump (setf (ba-cursor allocator) (second checkpoint)))))
  (setf (fill-pointer work) 0)
  nil)

(defun copy-closure-to-public (vm object public-space)
  "Deep-copy OBJECT and its transitive closure into PUBLIC-SPACE, rewriting
  every slot so the public graph is self-contained (strong DLG).  Children
  already public are NOT re-copied: their slot is rewritten to point at the
  existing public incarnation (each object is published at most once,
  locality.tex §2).  Uses VM-OBJECT-COPY so side metadata is preserved
  (memory.tex §2).  Returns the address of the copied root, or NIL if the
  public region cannot hold the closure; failed copies are transactional."
  (if (and public-space (space-allocator public-space))
      (let* ((publication (plan-publication (vm-plan vm)))
             (allocator (space-allocator public-space))
             (checkpoint (publication-allocator-checkpoint allocator))
             (work (publication-work publication))
             (seen (publication-copy-seen publication)))
        (setf (fill-pointer work) 0)
        (labels ((abort-copy ()
                   (rollback-publication-copies vm allocator checkpoint work)
                   (clrhash seen)
                   (return-from copy-closure-to-public nil))
                 (copy-one (src)
                   (let* ((n (vm-object-total-words vm src))
                          (dst (alloc allocator n)))
                     (when dst
                       (vm-object-copy vm src dst)
                       (setf (vm-object-is-public-p vm dst) t)
                       ;; Keep every destination in WORK before it can fail;
                       ;; this also tracks a destination whose queue push fails.
                       (unless (vector-push dst work) (abort-copy))
                       dst))))
          (clrhash seen)
          (let ((root-copy (copy-one object)))
            (unless root-copy (return-from copy-closure-to-public nil))
            (setf (gethash object seen) root-copy)
            (let ((head 0))
              (loop while (< head (fill-pointer work))
                    for src = (aref work head)
                    do (incf head)
                       (vm-map-reference-slots
                        vm src
                        (lambda (child)
                          (let ((bare (ref-strip-or-self vm child)))
                            (if (vm-object-is-public-p vm bare)
                                (setf (vm-object-reference
                                       vm src (slot-of-child vm src child)) bare)
                                (progn
                                  (unless (gethash bare seen)
                                    (let ((child-copy (copy-one bare)))
                                      (unless child-copy (abort-copy))
                                      (setf (gethash bare seen) child-copy)))
                                  (setf (vm-object-reference
                                         vm src (slot-of-child vm src child))
                                        (gethash bare seen)))))))))
            (setf (fill-pointer work) 0)
            (clrhash seen)
            root-copy)))
      nil))

(defun slot-of-child (vm src child)
  "The slot index of the first reference slot in SRC holding CHILD."
  (let ((slots (vm-reference-slots vm src)))
    (if slots
        (loop for i across slots
              when (eql (vm-object-reference vm src i) child)
                return i)
        (dotimes (i (vm-object-reference-count vm src))
          (when (eql (vm-object-reference vm src i) child)
            (return i))))))
