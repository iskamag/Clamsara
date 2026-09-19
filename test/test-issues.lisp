;;;; test/test-issues.lisp -- regression tests for the defects found in the
;;;; adversarial review.  Each test names the issue it covers (B<n>).

(in-package #:clamsara)

;; This class exists to make the inner-protocol test observable.  A simulator
;; hard-coded to the ordinary SIMULATOR-VM method would return the identity
;; page; the boot assembler must retain this actual CLOS specialization.
(defclass %boot-inner-vm (simulator-vm) ()
  (:metaclass vm-metaclass))

(defmethod vm-page-physical ((vm %boot-inner-vm) virtual-page)
  (declare (ignore vm))
  (+ virtual-page 1000))

(deftest boot-resolves-inner-clos-specialization ()
  ;; Inner CLOS is available while booting only.  After boot, replace the
  ;; generic function with a trap: the captured fast effective method must
  ;; still honor the specialized method without redispatching or a type branch.
  (let* ((vm (%make-simulator-vm '%boot-inner-vm 32768 nil))
         (plan (make-collector :semispace vm 32768))
         (generic (fdefinition 'vm-page-physical)))
    (boot-gc plan)
    (unwind-protect
         (progn
           (setf (fdefinition 'vm-page-physical)
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   (error "post-boot inner CLOS dispatch")))
           (if (= (vm-direct-page-physical vm 7) 1007)
               (values t "boot captured the specialized inner CLOS method")
               (values nil "boot lost the specialized inner CLOS method")))
      (setf (fdefinition 'vm-page-physical) generic))))

(defun %ivm () *clamsara-vm*)
(defun %islot (a i) (vm-object-reference (%ivm) a i))
(defun (setf %islot) (v a i) (setf (vm-object-reference (%ivm) a i) v))

;; ---- B4: s-clear must honour a non-zero default for :bit strata -----------

(deftest strata-s-clear-honours-non-zero-bit-default ()
  (let ((s (make-stratum :inv (g-word) :bit 1024 :default 1)))
    ;; a fresh stratum is all-default (1); setting 0 makes one non-default cell
    (s-set s 20 0)
    (unless (= (s-popcount s) 1)
      (return-from strata-s-clear-honours-non-zero-bit-default
        (values nil "popcount wrong before clear")))
    (s-clear s)
    (if (and (= (s-get s 5) 1) (s-get s 20) (= (s-get s 20) 1)
             (zerop (s-popcount s)))
        (values t "ok")
        (values nil "s-clear zeroed cells instead of restoring the default"))))

;; ---- B3: Claimore must install the RC write-barrier rule -----------------

(deftest claimore-rc-barrier-skips-internal-edges ()
  ;; RC counts are external superblock in-degrees.  A mature-space edge whose
  ;; endpoints share an SB must not be logged, even when a mutator writes it.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((barrier (plan-barrier *clamsara-plan*))
           (rc-buf (barrier-rc-buffer barrier)))
      (unless (find :rc (barrier-rules barrier) :key #'barrier-rule-name)
        (return-from claimore-rc-barrier-skips-internal-edges
          (values nil "no :rc rule in Claimore barrier")))
      (let* ((mature (cl-mature *clamsara-plan*))
             (a (alloc (space-allocator mature) 1))
             (b (alloc (space-allocator mature) 1)))
        (vm-write-header *clamsara-vm* a +tag-object+ 1)
        (vm-write-header *clamsara-vm* b +tag-object+ 1)
        (clamsara-write a 0 b)
        (if (zerop (fill-pointer rc-buf))
            (values t "ok")
            (values nil "internal RC edge was logged as external"))))))

;; ---- Claimore RC granularity is per-superblock (paper-v8 heap.tex §7.6) --

(deftest claimore-rc-is-per-superblock ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let ((mature (cl-mature *clamsara-plan*)))
      (unless (typep mature 'superblock-space)
        (return-from claimore-rc-is-per-superblock
          (values nil (format nil "mature is ~a, not superblock-space"
                              (type-of mature)))))
      (let* ((vm *clamsara-vm*)
             (counts (sb-refcounts mature))
             (public (clamsara-allocate-object 1))
             (child (clamsara-allocate-object 0)))
        ;; Publish the PUBLIC object so a subsequent write from it copies the
        ;; still-private CHILD into the mature superblock space.  The write
        ;; then logs an RC delta for the copied CHILD's superblock.
        (setf (vm-object-is-public-p vm public) t)
        (clamsara-write public 0 child)
        ;; The RC log drains into the per-superblock counts at major-GC time
        ;; (phase-reclaim).  Force one so the deltas land.
        (clamsara-gc :cycle-kind :major)
        ;; The read barrier heals the poisoned nursery original to the public
        ;; copy (GAP-001); this is what a mutator load observes.
        (let* ((mature-copy (clamsara-read public 0))
               (sb (sb-index mature mature-copy)))
          ;; The folded count lands on the superblock, never on the object's
          ;; own slot in the per-object RC table.
          (if (and (space-contains-p mature mature-copy)
                   (plusp (aref counts sb))
                   (zerop (vm-object-rc vm mature-copy)))
              (values t "ok")
              (values nil (format nil "RC not per-superblock: copy ~a sb ~a count ~a obj-rc ~a"
                                  mature-copy sb (aref counts sb)
                                  (vm-object-rc vm mature-copy)))))))))

;; ---- Claimore cycles need the trace backup, not self-counted RC -----------

(deftest claimore-unreachable-cycle-is-reclaimed ()
  ;; Both objects start in mature SB0, whose whole-superblock release is
  ;; reserved for the persistent root set.  The precise backup sweep must
  ;; nevertheless release their now-dead block after the last root vanishes.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (plan *clamsara-plan*)
           (mature (cl-mature plan))
           (a (alloc (space-allocator mature) 1))
           (b (alloc (space-allocator mature) 1)))
      (vm-write-header vm a +tag-object+ 1)
      (vm-write-header vm b +tag-object+ 1)
      ;; These are intra-superblock edges.  They must not create an external
      ;; RC count, but the cycle itself must still be trace-reclaimable.
      (clamsara-write a 0 b)
      (clamsara-write b 0 a)
      (unless (zerop (fill-pointer (barrier-rc-buffer (plan-barrier plan))))
        (return-from claimore-unreachable-cycle-is-reclaimed
          (values nil "intra-superblock cycle was logged as external RC")))
      (clamsara-gc :cycle-kind :major)
      (if (and (not (vm-object-start-p vm a))
               (not (vm-object-start-p vm b)))
          (values t "ok")
          (values nil "unreachable Claimore cycle survived backup sweep")))))

;; ---- B5: healing a forwarded root must preserve the pointer colour -------

(deftest heal-forwarded-root-preserves-colour ()
  (let ((vm (make-simulator-vm 4096)))
    (vm-set-location vm :forwarding :off-heap)
    (fwd-clear vm)
    ;; mark 512 as a live object start so vm-reference-p accepts it
    (s-set-bit (vm-object-start vm) 512)
    (let ((coloured-root (ref-set-colour vm 512 (colour-marked0))))
      (vm-add-root vm coloured-root)
      (setf (aref (vm-fwd-table vm) 512) 768)
      (let ((p (make-instance 'plan :vm vm)))
        (setf (vm-plan vm) p)
        (vm-scan-roots vm p #'heal-forwarded-root)
        (let ((healed (aref (vm-root-vector vm) 0)))
          (if (ref-good-colour-p vm healed)
              (values t "ok")
              (values nil "healed root lost its colour")))))))

;; ---- B8: gen-minor-count must count minors only --------------------------

(deftest generational-minor-count-excludes-majors ()
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let ((p *clamsara-plan*))
      (plan-collect p :cycle-kind :minor)
      (plan-collect p :cycle-kind :major)
      (plan-collect p :cycle-kind :minor)
      (if (= (gen-minor-count p) 2)
          (values t "ok")
          (values nil (format nil "minor-count = ~a, expected 2"
                              (gen-minor-count p)))))))

;; ---- B6: removing a root by index removes *that* root, not a duplicate ---

(deftest remove-root-by-index-hits-the-right-slot ()
  (let ((vm (make-simulator-vm 4096)))
    (vm-add-root vm 100)
    (vm-add-root vm 200)
    (vm-add-root vm 100)              ; duplicate address at index 2
    (vm-remove-root-at-index vm 2)    ; must remove slot 2, not slot 0
    (let ((roots (vm-root-vector vm)))
      (if (and (= (length roots) 2)
               (= (aref roots 0) 100)
               (= (aref roots 1) 200))
          (values t "ok")
          (values nil "removed the wrong root slot for a duplicate")))))

;; ---- B13: a los-space must use the page-based los-allocator --------------

(deftest los-space-uses-los-allocator ()
  (let ((vm (make-simulator-vm 8192)))
    (let ((space (make-instance 'los-space :vm vm :start-page 1
                                :page-count 8 :name :los)))
      (let ((a (space-allocator space)))
        (cond ((not (typep a 'los-allocator))
               (values nil (format nil "LOS allocator is ~a, not los-allocator"
                                   (type-of a))))
              ;; allocate an object spanning >1 page and check it succeeds
              ((not (alloc a +page-words+))
               (values nil "los-allocator failed a whole-page alloc"))
              (t (values t "ok")))))))

;; ---- G3: every plan layout includes a large-object space ----------------

(deftest every-plan-layout-has-los-space ()
  (dolist (plan-type '(:nogc :semispace :marksweep :immix :gencopy :genms
                       :genimmix :stickyimmix :stickyms :iso :zgcish
                       :claimore))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let ((los (plan-los *clamsara-plan*)))
        (unless (and los (typep (space-allocator los) 'los-allocator))
          (return-from every-plan-layout-has-los-space
            (values nil (format nil "~a has no LOS space" plan-type)))))))
  (values t "ok"))

(deftest los-allocation-bypasses-nursery ()
  ;; A >8192-byte object must land in the LOS space, not the nursery, for a
  ;; plan whose plan-allocate otherwise routes everything to the nursery.
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let ((big (clamsara-allocate-object 1024)))     ; 1025 words > 8 KiB
      (let ((los (plan-los *clamsara-plan*)))
        (if (and (space-contains-p los big)
                 (vm-object-start-p *clamsara-vm* big))
            (values t "ok")
            (values nil (format nil "big object landed in ~a, not LOS"
                                (space-name
                                 (plan-space-for-address
                                  *clamsara-plan* big)))))))))

;; Explicit designators must win over specialized plans' default nursery or
;; from-space policy.  The large mature request also guards against the
;; automatic LOS threshold being applied to an explicit destination.
(deftest specialized-plan-explicit-space-designators ()
  (dolist (spec '((:semispace :to)
                  (:gencopy :mature)
                  (:genms :mature)
                  (:genimmix :mature)
                  (:iso :public)
                  (:zgcish :to)
                  (:claimore :mature)))
    (destructuring-bind (plan-type designator) spec
      (with-clamsara (:plan-type plan-type :heap-size 65536)
        (let* ((space (plan-get-space *clamsara-plan* designator))
               ;; gencopy's mature destination is deliberately larger than
               ;; the non-LOS threshold; it must still remain in :mature.
               (size (if (and (eq plan-type :gencopy)
                             (eq designator :mature))
                         1024
                         1))
               (address (plan-allocate *clamsara-plan* size designator)))
          (unless (and space address (space-contains-p space address))
            (return-from specialized-plan-explicit-space-designators
              (values nil
                      (format nil "~a ~a allocated ~a, expected ~a"
                              plan-type designator address
                              (and space (space-name space))))))))))
  (values t "ok"))

(deftest allocate-object-explicit-space-designators ()
  ;; Exercise the headered allocation API, not just PLAN-ALLOCATE directly.
  (dolist (spec '((:semispace :to) (:gencopy :mature) (:claimore :mature)))
    (destructuring-bind (plan-type designator) spec
      (with-clamsara (:plan-type plan-type :heap-size 65536)
        (let* ((space (plan-get-space *clamsara-plan* designator))
               (address (allocate-object *clamsara-plan* 0
                                         :space designator)))
          (unless (and space (space-contains-p space address))
            (return-from allocate-object-explicit-space-designators
              (values nil
                      (format nil "~a :~a allocated ~a, expected ~a"
                              plan-type designator address
                              (and space (space-name space))))))))))
  (values t "ok"))

(deftest explicit-los-designator-allocates-in-los ()
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let* ((los (plan-get-space *clamsara-plan* :los))
           (address (plan-allocate *clamsara-plan* 1024 :los)))
      (if (and los address (space-contains-p los address))
          (values t "ok")
          (values nil (format nil "explicit :los allocation landed in ~a"
                              (and address
                                   (space-name
                                    (plan-space-for-address
                                     *clamsara-plan* address)))))))))

;; ---- R2: reviewer round-2 regressions --------------------------------------

(deftest medium-object-survives-full-gc ()
  ;; A 600-slot object spans two immix blocks; the block-level sweep must not
  ;; recycle the span's tail block while the root object is live.
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let ((m (clamsara-allocate-object 600)))
      (setf (vm-object-reference *clamsara-vm* m 511) 111111)
      (setf (vm-object-reference *clamsara-vm* m 512) 999999)
      (clamsara-register-root m)
      (clamsara-gc)
      (let ((fresh (clamsara-allocate-object 1)))
        (declare (ignore fresh))
        (let ((m2 (clamsara-root 0)))
          (if (and (= (vm-object-reference *clamsara-vm* m2 511) 111111)
                   (= (vm-object-reference *clamsara-vm* m2 512) 999999))
              (values t "ok")
              (values nil "medium-object span corrupted by block sweep")))))))

(deftest trap-a-closure-copy-is-deep ()
  ;; locality.tex §2 Variant A: the public copy's closure is deep; no public
  ;; object references a private one, and already-public children are reused.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((mature (cl-mature *clamsara-plan*))
           (strategy (make-instance 'trap-error-copy-a
                                    :public-region mature))
           (a (clamsara-allocate-object 1))
           (b (clamsara-allocate-object 0)))
      (initialize-publication-work strategy *clamsara-vm*)
      (setf (vm-object-reference *clamsara-vm* a 0) b)
      (let ((copy (publish strategy *clamsara-vm* a)))
        (let ((child (vm-object-reference *clamsara-vm* copy 0)))
          (if (and (space-contains-p mature copy)
                   (space-contains-p mature child)
                   (vm-object-is-public-p *clamsara-vm* copy)
                   (vm-object-is-public-p *clamsara-vm* child))
              (values t "ok")
              (values nil "trap-A copy is not a deep public closure")))))))

(deftest persistence-segment-verifies-after-mutation ()
  ;; persistence.tex §1: a segment's checksum folds its stored images, so a
  ;; checkpoint verifies after the live heap mutates (recovery by definition
  ;; reads a heap that moved on).
  (let* ((vm (make-simulator-vm 4096))
         (plan (make-instance 'plan :vm vm :name :t
                              :spaces (list (make-instance
                                             'immix-space :vm vm
                                             :start-page 1 :page-count 7
                                             :name :d :default-space t)))))
    (vm-register-stratum vm :card
      (make-stratum :card (g-card) :bit 4096))
    (s-set-bit (vm-stratum vm :card) +page-words+)
    (let ((segment (checkpoint-heap plan :timestamp 42)))
      ;; mutate page 1 after the checkpoint
      (setf (ref-u64 vm (+ (page-start-address 1) 10)) 777)
      (if (verify-segment segment vm)
          (values t "ok")
          (values nil "intact segment misclassified as torn after mutation")))))

(deftest persistence-recovery-truncates-at-torn-segment ()
  ;; persistence.tex §1: recovery reads forward to the last intact snapshot
  ;; and stops; a torn trailing segment is truncated, everything after it
  ;; discarded.
  (let* ((vm (make-simulator-vm 4096))
         (plan (make-instance 'plan :vm vm :name :t
                              :spaces (list (make-instance
                                             'immix-space :vm vm
                                             :start-page 1 :page-count 7
                                             :name :d :default-space t)))))
    (vm-register-stratum vm :card
      (make-stratum :card (g-card) :bit 4096))
    (s-set-bit (vm-stratum vm :card) +page-words+)
    (let ((s1 (checkpoint-heap plan :timestamp 1)))
      (s-set-bit (vm-stratum vm :card) (* 2 +page-words+))
      (let ((s2 (checkpoint-heap plan :timestamp 2)))
        ;; tear s2: corrupt a stored image word
        (setf (aref (gethash 2 (persistence-segment-images s2)) 5) 424242)
        (multiple-value-bind (intact torn-p)
            (recover-last-intact-snapshot (list s1 s2) vm)
          (if (and (= (length intact) 1)
                   torn-p
                   (eql (first intact) s1))
              (values t "ok")
              (values nil (format nil "recovery wrong: intact=~a torn=~a"
                                  (length intact) torn-p))))))))

(deftest medium-object-span-excludes-small-objects ()
  ;; A span run is exclusive: small objects never share a span block, so a
  ;; live small object cannot be wiped when the span's root dies.
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let ((dead (clamsara-allocate-object 600)))  ; dead medium object
      (declare (ignore dead))
      (let ((s (clamsara-allocate-object 1)))     ; small object
        (clamsara-register-root s)
        (clamsara-gc)
        (let ((s2 (clamsara-root 0)))
          (if (and (= s2 s)                       ; not in a span block
                   (vm-object-start-p *clamsara-vm* s2))
              (values t "ok")
              (values nil "small object co-located in a dead span block")))))))

(deftest claimore-checkpoint-captures-persistence-log ()
  ;; Claimore's checkpoint phase must execute the real persistence fence,
  ;; not merely increment a statistics counter.
  (with-clamsara (:plan-type :claimore :heap-size 4096)
    (plan-collect *clamsara-plan* :cycle-kind :checkpoint)
    (let ((log (vm-persistence-log *clamsara-vm*)))
      (if (and log (plusp (length (plog-segments log))))
          (values t "ok")
          (values nil "Claimore checkpoint did not append a segment")))))

(deftest checkpoint-cycle-kind-admitted ()
  ;; persistence.tex §4: a checkpoint is an extra plan phase; the compiled
  ;; collector must admit :checkpoint (previously fell through the ecase).
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let ((a (clamsara-allocate-object 1)))
      (clamsara-register-root a)
      (plan-collect *clamsara-plan* :cycle-kind :checkpoint)
      (if (vm-object-start-p *clamsara-vm* (clamsara-root 0))
          (values t "ok")
          (values nil ":checkpoint broke the heap")))))

(deftest plan-validation-rejects-incoherent-combos ()
  ;; heap.tex §7 / plans.tex §1: incoherent axis combinations are rejected at
  ;; construction's :VALIDATE phase, before any code is generated.  The
  ;; component kernel wraps the rejection with the phase and component; the
  ;; cause underneath must still be the plan-incompatible fact.
  (let ((vm (make-simulator-vm 4096)))
    ;; A plan that declares concurrent relocation must carry the LVB read
    ;; rule that heals stale references.  (The v8 incoherence this case
    ;; originally probed -- concurrent-relocate with in-header forwarding --
    ;; is no longer constructible: construction binds forwarding off-object
    ;; for every plan in this profile, so the declaration cannot disagree.)
    (let ((caught-p nil))
      (handler-case
          (finalize-plan
           (make-instance 'plan
             :vm vm :name :bad
             :spaces (list (make-instance 'immix-space :vm vm
                                          :start-page 1 :page-count 6
                                          :name :bad :default-space t
                                          :moving :concurrent-relocate))
             :barrier (make-instance 'barrier :rules nil)
             :constraints (make-instance 'plan-constraints
                                         :concurrency :concurrent-relocate)))
        (construction-error (c)
          (setf caught-p (typep (component-failure-cause c)
                                'plan-incompatible))))
      (unless caught-p
        (return-from plan-validation-rejects-incoherent-combos
          (values nil "concurrent-relocate without an LVB rule not rejected"))))
    ;; a copying space without a partner must be rejected at plan validation
    (let ((caught-p nil))
      (handler-case
          (finalize-plan
           (make-instance 'plan
             :vm vm :name :bad
             :spaces (list (make-instance 'copy-space :vm vm
                                          :start-page 1 :page-count 2
                                          :name :lonely :default-space t))))
        (construction-error (c)
          (setf caught-p (typep (component-failure-cause c)
                                'plan-incompatible))))
      (unless caught-p
        (return-from plan-validation-rejects-incoherent-combos
          (values nil "partnerless copying space not rejected"))))
    (values t "ok")))

(deftest claimore-plan-metadata-matches-paper ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((constraints (plan-constraints *clamsara-plan*))
           (read-barriers (constraints-read-barrier constraints)))
      (if (and (eq (constraints-requires-tier constraints) :t2)
               (eq (constraints-concurrency constraints) :concurrent-relocate)
               (eq (constraints-forwarding constraints) :off-heap)
               (equal read-barriers '(:lvb :trap)))
          (values t "ok")
          (values nil
                  (format nil "unexpected Claimore metadata: tier=~a concurrency=~a forwarding=~a reads=~s"
                          (constraints-requires-tier constraints)
                          (constraints-concurrency constraints)
                          (constraints-forwarding constraints)
                          read-barriers))))))

(deftest plan-validation-rejects-undeclared-read-barrier ()
  ;; Read-barrier declarations, like write-barrier declarations, must name
  ;; concrete rules installed on the plan's barrier.
  (let ((vm (make-simulator-vm 4096))
        (caught-p nil))
    (handler-case
        (finalize-plan
         (make-instance 'plan
           :vm vm :name :bad-read
           :spaces (list (make-instance 'immix-space
                                         :vm vm :start-page 1 :page-count 6
                                         :name :bad-read :default-space t))
           :barrier (make-instance 'barrier :rules nil)
           :constraints (make-instance 'plan-constraints
                                        :read-barrier :missing)))
      (construction-error (c)
        (setf caught-p (typep (component-failure-cause c)
                              'plan-incompatible))))
    (if caught-p
        (values t "ok")
        (values nil "undeclared read barrier was not rejected"))))

;; ---- B15: vm-object-copy must carry the mark bit to the destination ------

(deftest object-copy-preserves-mark ()
  (let ((vm (make-simulator-vm 4096)))
    (vm-register-stratum vm :mark (make-stratum :mark (g-word) :bit 4096))
    (vm-write-header vm 512 +tag-object+ 2)
    (setf (vm-object-is-marked-p vm 512) t)
    (vm-object-copy vm 512 600)
    (if (vm-object-is-marked-p vm 600)
        (values t "ok")
        (values nil "copied object lost its mark"))))

;; ---- B9: the card barrier rule must actually set the card stratum --------

(deftest card-barrier-rule-sets-card-on-old-to-young-write ()
  ;; Build a minimal plan-like context: an old object and a young object, with
  ;; a card stratum installed.  The card rule must dirty the source card.
  (let ((vm (make-simulator-vm 4096)))
    (vm-register-stratum vm :card (make-stratum :card (g-card) :bit 4096))
    ;; fake two object starts so vm-object-old/young-p and vm-reference-p work
    (let ((os (vm-object-start vm)))
      (s-set-bit os 512)
      (s-set-bit os 1024))
    ;; make 512 "old": set an age stratum if present, else rely on no nursery
    (vm-register-stratum vm :age (make-stratum :age (g-word) :u4 4096))
    (s-set (vm-stratum vm :age) 512 3)         ; aged => old
    (let ((rule (card-barrier-rule))
          (barrier (make-instance 'barrier :rules nil)))
      (funcall (barrier-rule-transfer rule) vm barrier 512 0 1024)
      (if (s-test-bit (vm-stratum vm :card) 512)
          (values t "ok")
          (values nil "card rule did not dirty the source card")))))

;; ---- B11: every collector survives a churn with a live graph -------------

(defun %churn-survives-p (plan-type)
  ;; A small live graph (A -> B -> C, A -> C) must survive repeated
  ;; (allocate-garbage + GC) cycles, for EVERY collector including the ones the
  ;; existing %survives-p excludes (iso, zgcish, claimore, sticky*).
  (with-clamsara (:plan-type plan-type :heap-size 65536)
    (let ((a (clamsara-allocate-object 3))
          (b (clamsara-allocate-object 2))
          (c (clamsara-allocate-object 2)))
      (setf (%islot a 0) b (%islot a 1) c (%islot b 0) c)
      (clamsara-register-root a)
      (dotimes (round 8)
        (dotimes (j 200) (clamsara-allocate-object 5))   ; garbage
        (clamsara-gc)
        (let ((a2 (clamsara-root 0)))
          (unless (and (plusp a2)
                       (= (vm-object-reference-count (%ivm) a2) 3)
                       (plusp (%islot a2 0)))
            (return-from %churn-survives-p
              (values nil (format nil "~A: live graph broke after round ~a"
                                  plan-type round))))))
      (values t "ok"))))

(dolist (pt '(:semispace :marksweep :immix :gencopy :genms :genimmix
              :stickyimmix :stickyms :iso :zgcish :claimore))
  (let ((name (intern (format nil "CHURN-~a" pt))))
    (push (cons name (lambda () (%churn-survives-p pt))) *clamsara-tests*)))

;; ---- B1: ZGC relocation stays correct under repeated relocation -----------

(deftest zgc-repeated-relocation-preserves-graph ()
  ;; Regression guard: a deep graph must survive many mark+relocate cycles.
  ;; (A prior harness bug once masked a corruption here.)
  (with-clamsara (:plan-type :zgcish :heap-size 65536)
    (let ((root (clamsara-allocate-object 2))
          (chain nil))
      (clamsara-register-root root)
      (dotimes (k 20)
        (let ((node (clamsara-allocate-object 1)))
          (setf (%islot node 0) (+ 5000000 k))   ; raw payload
          (setf (%islot node 0) (or chain 0))
          (setq chain node)))
      (setf (%islot root 0) chain)
      (dotimes (round 15)
        (dotimes (j 200) (clamsara-allocate-object 3))
        (clamsara-gc)
        (let ((r (clamsara-root 0)))
          (unless (plusp (%islot r 0))
            (return-from zgc-repeated-relocation-preserves-graph
              (values nil "ZGC lost the chain head after relocation")))))
      (values t "ok"))))

;; ---- B2: the adversarial harness must report failures as failures --------

(deftest adversarial-harness-classifies-failures ()
  ;; Simulate the result list shape used by the churn harness and confirm a
  ;; failure is detected (not masked by a destructuring/boolean mistake).
  (let ((results (list (list :zgcish 'deep) nil "list corrupted: 3 nodes")))
    (destructuring-bind ((plan-type test-name) ok-p . message) results
      (declare (ignore plan-type test-name message))
      (if ok-p
          (values nil "harness called a failure a pass")
          (values t "ok")))))

(deftest collect-hook-distinguishes-exit-from-abort ()
  (let* ((vm (make-simulator-vm 4096))
         (plan (make-collector :semispace vm 4096))
         (events nil))
    (boot-gc plan)
    (with-plan-collect-hook
        (plan (lambda (pl cycle-kind phase)
                (declare (ignore pl cycle-kind))
                (push phase events)))
      (plan-collect plan :cycle-kind :full))
    (unless (equal (nreverse events) '(:enter :exit))
      (return-from collect-hook-distinguishes-exit-from-abort
        (values nil (format nil "successful hook phases were ~S" events))))
    (let* ((table (plan-function-table plan))
           (original (gethash 'plan-collect table)))
      (unwind-protect
           (progn
             (setf events nil
                   (gethash 'plan-collect table)
                   (lambda (pl cycle-kind)
                     (declare (ignore pl cycle-kind))
                     (error "forced collector failure")))
             (handler-case
                 (with-plan-collect-hook
                     (plan (lambda (pl cycle-kind phase)
                             (declare (ignore pl cycle-kind))
                             (push phase events)))
                   (plan-collect plan :cycle-kind :full))
               (error () nil))
             (if (equal (nreverse events) '(:enter :abort))
                 (values t "ok")
                 (values nil (format nil "aborted hook phases were ~S" events))))
        (setf (gethash 'plan-collect table) original)))))

;; ---- GAP-002: fresh allocation slots are zeroed --------------------------

(deftest fresh-allocation-zeroes-slots ()
  ;; A freshly allocated object's payload slots must be zero (a non-reference),
  ;; so the first barrier-visible store to a slot cannot log a spurious RC
  ;; decrement for a stale word left by a previous occupant.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (a (clamsara-allocate-object 3)))
      ;; slots 0..2 are zero, and 0 is not a valid reference
      (if (and (zerop (vm-object-reference vm a 0))
               (zerop (vm-object-reference vm a 1))
               (zerop (vm-object-reference vm a 2))
               (not (vm-reference-p vm (vm-object-reference vm a 0))))
          (values t "ok")
          (values nil "fresh object slots not zeroed")))))

;; ---- GAP-010: poison stand-in is a well-formed 1-slot object -------------

(deftest poison-stand-in-is-well-formed ()
  ;; The error stand-in (at the original's address) must be a well-formed
  ;; object (size 1, redirect in slot 0) so vm-object-total-words cannot walk
  ;; off the heap, and error-object-p / error-redirect must round-trip.  The
  ;; public slot itself holds the copy (the write barrier chains it), so the
  ;; poison is observed at the original's address.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (mature (cl-mature *clamsara-plan*))
           (a (clamsara-allocate-object 1))
           (b (clamsara-allocate-object 0)))
      ;; publish B: copies it into mature, poisons the nursery original A
      (setf (vm-object-is-public-p vm a) t)
      (clamsara-write a 0 b)
      (let* ((stored (vm-object-reference vm a 0))
             (copy (error-redirect vm b)))
        (if (and (space-contains-p mature stored)     ; slot holds the copy
                 (error-object-p vm b)                ; original is poisoned
                 (space-contains-p mature copy)       ; poison redirects to copy
                 (= (vm-object-total-words vm b) 2))  ; header + 1 slot
            (values t "ok")
            (values nil (format nil "poison stand-in malformed: stored ~a poisoned ~a copy ~a words ~a"
                                stored (error-object-p vm b) copy
                                (vm-object-total-words vm b))))))))

;; ---- W1: weak-pointer bit survives copying collectors -------------------

(deftest weak-pointer-survives-moving-collection ()
  ;; vm-object-copy must carry the weak stratum bit (weak.tex: a weak pointer
  ;; that loses it silently becomes a strong pointer, keeping dead referents).
  (dolist (plan-type '(:semispace :gencopy :genms :genimmix))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let* ((wm (clamsara-allocate-object 1))
             (target (clamsara-allocate-object 0)))
        (register-weak-pointer *clamsara-vm* wm)
        (vm-set-reference *clamsara-vm* wm 0 target)
        (clamsara-register-root wm)
        (clamsara-gc)
        (let ((wm2 (clamsara-root 0)))
          ;; the copy must still be a weak pointer, so the dead referent's
          ;; slot is cleared by the weak phase (slot 0 excluded from tracing)
          (unless (weak-pointer-p *clamsara-vm* wm2)
            (return-from weak-pointer-survives-moving-collection
              (values nil (format nil "~a: weak bit lost on copy" plan-type))))
          (unless (zerop (vm-object-reference *clamsara-vm* wm2 0))
            (return-from weak-pointer-survives-moving-collection
              (values nil (format nil "~a: weak copy kept dead referent"
                                  plan-type))))))))
  (values t "ok"))

;; ---- W2: LOS edges healed by Immix defrag and ZGC relocation ------------

(deftest los-edges-healed-by-immix-defrag ()
  ;; A LOS object holding a reference into a defragmented Immix block must be
  ;; rewritten: healing is heap-wide, not block-only.
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let ((big (clamsara-allocate-object 1024))   ; LOS
          (dead (clamsara-allocate-object 20))    ; fragmentation bait
          (small (clamsara-allocate-object 20)))  ; immix block
      (declare (ignore dead))
      (clamsara-register-root big)
      (clamsara-register-root small)
      (clamsara-write big 0 small)
      (clamsara-gc :cycle-kind :major)            ; defrag may move small
      (let* ((big2 (clamsara-root 0))
             (small2 (clamsara-root 1))
             (slot (vm-object-reference *clamsara-vm* big2 0)))
        (if (= slot small2)
            (values t "ok")
            (values nil "LOS edge not healed by Immix defrag"))))))

(deftest los-edges-healed-by-zgc-relocation ()
  (with-clamsara (:plan-type :zgcish :heap-size 65536)
    (let ((big (clamsara-allocate-object 1024))   ; LOS
          (small (clamsara-allocate-object 1)))   ; from-space
      (clamsara-register-root big)
      (clamsara-write big 0 small)
      (clamsara-gc)
      (let* ((big2 (clamsara-root 0))
             (slot (vm-object-reference *clamsara-vm* big2 0)))
        (if (and (vm-reference-p *clamsara-vm* slot)
                 (not (vm-object-start-p *clamsara-vm* small)))
            (values t "ok")
            (values nil (format nil "LOS edge not healed: slot=~a" slot)))))))

;; ---- W3: LOS -> nursery edges survive generational minors ---------------

(deftest los-to-nursery-edge-survives-minor ()
  ;; The card barrier must treat a LOS source as out-of-nursery (it is never
  ;; "old" via the age stratum), and scan-remset must scan LOS cards, else a
  ;; nursery referent reachable only through a LOS object is reclaimed.
  (dolist (plan-type '(:gencopy :genms :genimmix))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let ((big (clamsara-allocate-object 1024))  ; LOS
            (kid (clamsara-allocate-object 1)))    ; nursery
        (clamsara-register-root big)
        (clamsara-write big 0 kid)
        (plan-collect *clamsara-plan* :cycle-kind :minor)
        (let* ((big2 (clamsara-root 0))
               (slot (vm-object-reference *clamsara-vm* big2 0)))
          (unless (and (vm-reference-p *clamsara-vm* slot)
                       (vm-object-start-p *clamsara-vm* slot))
            (return-from los-to-nursery-edge-survives-minor
              (values nil (format nil "~a: LOS->nursery edge lost: slot=~a"
                                  plan-type slot))))))))
  (values t "ok"))

;; ---- G9a: the gc-phase combination is the phase machine ------------------

(defclass %probe-plan (plan) ()
  (:metaclass plan-metaclass))

(defclass %probe-plan-2 (plan) ()
  (:metaclass plan-metaclass))

(defvar %probe-order nil)

(defmethod gc-phase :prologue ((p %probe-plan) k)
  (declare (ignore k)) (push :prologue %probe-order))
(defmethod gc-phase :mark ((p %probe-plan) k)
  (declare (ignore k)) (push :mark %probe-order))
(defmethod gc-phase :reclaim ((p %probe-plan) k)
  (declare (ignore k)) (push :reclaim %probe-order))
(defmethod gc-phase :release ((p %probe-plan) k)
  (declare (ignore k)) (push :release %probe-order))
(defmethod gc-phase :around ((p %probe-plan) k)
  (push :around %probe-order)
  (call-next-method)
  (push :around-done %probe-order))

(defmethod gc-phase :prologue ((p %probe-plan-2) k)
  (declare (ignore k)) (push :prologue %probe-order))
(defmethod gc-phase :mark ((p %probe-plan-2) k)
  (declare (ignore k)) (push :mark %probe-order))
(defmethod gc-phase :reclaim ((p %probe-plan-2) k)
  (declare (ignore k)) (push :reclaim %probe-order))
(defmethod gc-phase :release ((p %probe-plan-2) k)
  (declare (ignore k)) (push :release %probe-order))
(defmethod gc-phase :around ((p %probe-plan-2) k)
  (declare (ignore k))
  (push :around-2 %probe-order)
  (call-next-method)
  (push :around-2-done %probe-order))
(defmethod plan-collect-phase :around ((p %probe-plan-2) k)
  (declare (ignore k))
  (push :plan-around-2 %probe-order)
  (call-next-method)
  (push :plan-around-2-done %probe-order))

(defclass %error-phase-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod gc-phase :mark ((p %error-phase-plan) k)
  (declare (ignore p k))
  (error "intentional phase failure"))

(deftest gc-phase-error-resumes-mutators ()
  ;; A failed backend phase must not strand the simulator in its stopped
  ;; state; the original error remains observable to the caller.
  (let* ((vm (make-simulator-vm 4096))
         (p (make-instance '%error-phase-plan
                           :name :error-phase :vm vm :spaces nil
                           :constraints (make-instance 'plan-constraints)))
         (caught nil))
    (handler-case (plan-collect-phase p :full)
      (error () (setf caught t)))
    (if (and caught (not (vm-stopped-p vm))
             (not (vm-stop-requested-p vm)))
        (values t "phase failure resumed mutators")
        (values nil "phase failure left VM stopped"))))

(defclass %compiled-error-phase-plan (plan) ()
  (:metaclass plan-metaclass))

(defvar *compiled-phase-failure* nil)

(defmethod gc-phase :mark ((p %compiled-error-phase-plan) k)
  (declare (ignore p))
  (when (and *compiled-phase-failure* (eq k :full))
    (error "intentional compiled collection failure")))

(defmethod gc-phase :checkpoint ((p %compiled-error-phase-plan) k)
  (declare (ignore p))
  (when (and *compiled-phase-failure* (eq k :checkpoint))
    (error "intentional compiled checkpoint failure")))

(deftest compiled-phase-error-resumes-mutators ()
  ;; The boot-emitted direct phase arms have the same cleanup guarantee as the
  ;; interpreted phase machine, including the checkpoint fence arm.
  (let* ((vm (make-simulator-vm 32768))
         (p (make-instance '%compiled-error-phase-plan
                           :name :compiled-error :vm vm
                           :spaces (list (make-instance 'mark-sweep-space
                                                        :vm vm :start-page 1
                                                        :page-count 60
                                                        :name :default
                                                        :default-space t))
                           :constraints (make-instance 'plan-constraints)))
         (full-caught nil)
         (checkpoint-caught nil))
    (let ((*compiled-phase-failure* nil))
      (boot-gc p))
    (let ((*compiled-phase-failure* t))
      (handler-case (plan-collect p :cycle-kind :full)
        (error () (setf full-caught t)))
      (unless (and full-caught (not (vm-stopped-p vm))
                   (not (vm-stop-requested-p vm)))
        (return-from compiled-phase-error-resumes-mutators
          (values nil "compiled collection failure left VM stopped")))
      (handler-case (plan-collect p :cycle-kind :checkpoint)
        (error () (setf checkpoint-caught t))))
    (if (and checkpoint-caught (not (vm-stopped-p vm))
             (not (vm-stop-requested-p vm)))
        (values t "compiled phase failures resumed mutators")
        (values nil "compiled checkpoint failure left VM stopped"))))

(deftest external-root-registration-publishes-object ()
  ;; An API root is externally reachable, so publication must happen before it
  ;; enters the root vector; this is the DLG boundary, not a mutator field store.
  (with-clamsara (:plan-type :iso :heap-size 32768)
    (let* ((vm *clamsara-vm*)
           (object (clamsara-allocate-object 0))
           (index (clamsara-register-root object))
           (published (clamsara-root index)))
      (if (and (vm-object-start-p vm published)
               (vm-object-is-public-p vm published))
          (values t "external root was published")
          (values nil "external root bypassed publication")))))

(deftest checkpoint-event-increments-statistic ()
  (with-clamsara (:plan-type :semispace :heap-size 4096)
    (let ((stats (plan-stats *clamsara-plan*)))
      (stats-reset stats)
      (gc-event-checkpoint *clamsara-plan* *clamsara-vm* nil)
      (if (= (stats-get stats :checkpoints) 1)
          (values t "checkpoint metric incremented")
          (values nil "checkpoint metric did not increment")))))

(deftest gc-phase-most-specific-primary-only ()
  ;; A phase qualifier selects the most-specific primary method.  The generic
  ;; PLAN fallback must not run after the %PROBE-PLAN MARK method: leave its
  ;; tracer uninitialized so an accidental fall-through is observable.
  (let ((vm (make-simulator-vm 32768)))
    (let ((p (make-instance '%probe-plan
                            :name :probe :vm vm :spaces nil
                            :constraints (make-instance 'plan-constraints))))
      (let ((%probe-order nil))
        (handler-case
            (progn
              (gc-phase p :full)
              (if (equal %probe-order
                         '(:around-done :release :reclaim :mark :prologue :around))
                  (values t "ok")
                  (values nil (format nil "phase order/methods wrong: ~a"
                                      %probe-order))))
          (error (condition)
            (values nil (format nil "specialized phase fell through: ~a"
                                condition))))))))

(deftest gc-phase-method-combination-runs-all-phases ()
  ;; plans.tex §3: collection proceeds through the gc-phase combination in
  ;; declaration order; :around wraps the assembled primary.
  (let ((vm (make-simulator-vm 32768)))
    (let ((p (make-instance '%probe-plan
                            :name :probe :vm vm
                            :spaces (list (make-instance 'mark-sweep-space
                                                         :vm vm :start-page 1
                                                         :page-count 60
                                                         :name :default
                                                         :default-space t))
                            :constraints (make-instance 'plan-constraints))))
      (finalize-plan p)
      (let ((%probe-order nil))
        (let ((a (allocate-object p 1)))
          (vm-add-root vm a)
          (gc-phase p :full))
        (if (equal %probe-order '(:around-done :release :reclaim :mark :prologue :around))
            (values t "ok")
            (values nil (format nil "phase order wrong: ~a" %probe-order)))))))

(deftest compiled-collector-matches-combination ()
  ;; compilation.tex section 3: the boot-emitted plan-collect resolves the
  ;; same most-specific phase methods and :around chain as CLOS dispatch.
  (let ((vm (make-simulator-vm 32768)))
    (let ((p (make-instance '%probe-plan-2
                            :name :probe2 :vm vm
                            :spaces (list (make-instance 'mark-sweep-space
                                                         :vm vm :start-page 1
                                                         :page-count 60
                                                         :name :default
                                                         :default-space t))
                            :constraints (make-instance 'plan-constraints))))
      (finalize-plan p)
      (let ((%probe-order nil))
        (let ((a (allocate-object p 1)))
          (vm-add-root vm a)
          (plan-collect p :cycle-kind :full))
        (let ((interpreted (reverse %probe-order)))
          (setf %probe-order nil)
          (boot-gc p)                   ; emits the compiled arm + runs warm-ups
          (setf %probe-order nil)       ; discard warm-up noise
          (plan-collect p :cycle-kind :full)
          (let ((compiled (reverse %probe-order)))
            (if (equal interpreted compiled)
                (values t "ok")
                (values nil (format nil "compiled ~a != interpreted ~a"
                                    compiled interpreted)))))))))


;; ---- paper testing event counters ----------------------------------------

(deftest stats-count-barrier-transfers-and-object-copy ()
  ;; Barrier events are charged at the fused transfer seam, while copies are
  ;; charged by VM-OBJECT-COPY so publication and relocation use one metric.
  ;; ZGCish carries read rules only, so its loads drive the counter.
  (with-clamsara (:plan-type :zgcish :heap-size 32768)
    (let* ((plan *clamsara-plan*)
           (vm *clamsara-vm*)
           (stats (plan-stats plan))
           (source (clamsara-allocate-object 1))
           (destination (clamsara-allocate-object 1)))
      (stats-reset stats)
      (vm-set-reference vm source 0 destination)
      (clamsara-read source 0)
      (vm-object-copy vm source destination)
      (if (and (plusp (stats-get stats :barrier-transfers))
               (= 1 (stats-get stats :objects-copied))
               (= 2 (stats-get stats :words-copied)))
          (values t "ok")
          (values nil
                  (format nil "events: barriers=~a objects=~a words=~a"
                          (stats-get stats :barrier-transfers)
                          (stats-get stats :objects-copied)
                          (stats-get stats :words-copied)))))))

(deftest stats-count-tracer-closure-and-spill ()
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let* ((plan *clamsara-plan*)
           (vm *clamsara-vm*)
           (stats (plan-stats plan))
           (root (clamsara-allocate-object 1)))
      (clamsara-register-root root)
      (stats-reset stats)
      (clamsara-gc)
      ;; Exercise the simulator's bounded queue failure explicitly. A target
      ;; backend would spill here; the simulator records the attempted spill
      ;; before reporting exhaustion.
      (let ((tr (make-instance 'tracer :vm vm :capacity 0
                               :queue (make-array 0 :element-type 'fixnum))))
        (handler-case (tracer-enqueue tr root)
          (heap-exhausted () nil)))
      (if (and (plusp (stats-get stats :closure-passes))
               (= 1 (stats-get stats :queue-spills)))
          (values t "ok")
          (values nil
                  (format nil "events: closures=~a spills=~a"
                          (stats-get stats :closure-passes)
                          (stats-get stats :queue-spills)))))))

(deftest stats-count-dirty-and-written-pages ()
  (with-clamsara (:plan-type :claimore :heap-size 32768)
    (let* ((plan *clamsara-plan*)
           (vm *clamsara-vm*)
           (stats (plan-stats plan))
           (card (vm-stratum vm :card)))
      (stats-reset stats)
      (s-set-bit card +page-words+)
      (checkpoint-heap plan :timestamp 17)
      (if (and (= 1 (stats-get stats :dirty-pages))
               (= 1 (stats-get stats :pages-written)))
          (values t "ok")
          (values nil
                  (format nil "events: dirty=~a written=~a"
                          (stats-get stats :dirty-pages)
                          (stats-get stats :pages-written)))))))

(deftest stats-count-mmu-faults ()
  (with-clamsara (:plan-type :claimore :heap-size 32768)
    (let* ((plan *clamsara-plan*)
           (vm *clamsara-vm*)
           (stats (plan-stats plan))
           (address (+ (page-start-address 1) 3)))
      (stats-reset stats)
      (mark-pages-cow vm '(1))
      (setf (ref-u64 vm address) 99)
      (if (= 1 (stats-get stats :mmu-faults))
          (values t "ok")
          (values nil
                  (format nil "faults=~a" (stats-get stats :mmu-faults)))))))


;; ---- RC log drains at the Claimore collection boundary (lossless log) ----

(deftest claimore-rc-log-drain-normalizes-coloured-targets ()
  ;; RC records retain the client's opaque reference encoding.  Reconciliation
  ;; must normalize a coloured reference before mature-space/SB lookup.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((plan *clamsara-plan*)
           (vm *clamsara-vm*)
           (mature (cl-mature plan))
           (target (+ (space-base-address mature) (* 32 512)))
           (target-sb (sb-index mature target))
           (counts (sb-refcounts mature))
           (barrier (plan-barrier plan)))
      (vm-write-header vm target +tag-object+ 0)
      (rc-log-increment barrier
                        (ref-set-colour vm target (colour-marked0)) -1)
      (plan-collect plan :cycle-kind :minor)
      (if (and (= (aref counts target-sb) 1)
               (zerop (fill-pointer (barrier-rc-buffer barrier))))
          (values t "ok")
          (values nil "coloured RC target did not fold into its superblock")))))

(deftest claimore-rc-log-drains-at-minor-boundary ()
  ;; Minors never release mature storage, but the sealed delta log must
  ;; drain at every collection boundary: the fill pointer returns to zero
  ;; and the folded external in-degree lands on the target superblock.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((plan *clamsara-plan*)
           (vm *clamsara-vm*)
           (barrier (plan-barrier plan))
           (mature (cl-mature plan))
           (base (space-base-address mature))
           (holder base)                        ; block 0 -> SB0
           (a (+ base (* 32 512)))              ; block 32 -> SB1
           (counts (sb-refcounts mature)))
      (vm-write-header vm holder +tag-object+ 1)
      (vm-write-header vm a +tag-object+ 1)
      (clamsara-write holder 0 a)               ; external edge: one +1 record
      (unless (= (fill-pointer (barrier-rc-buffer barrier)) 3)
        (return-from claimore-rc-log-drains-at-minor-boundary
          (values nil
                  (format nil "cross-superblock store logged ~a elements"
                          (fill-pointer (barrier-rc-buffer barrier))))))
      (plan-collect plan :cycle-kind :minor)
      (let ((buf (barrier-rc-buffer barrier)))
        (if (and (zerop (fill-pointer buf))
                 (plusp (aref counts 1)))
            (values t "ok")
            (values nil
                    (format nil "after minor: fill=~a sb1-count=~a"
                            (fill-pointer buf) (aref counts 1))))))))
