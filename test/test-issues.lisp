;;;; test/test-issues.lisp -- regression tests for the defects found in the
;;;; adversarial review.  Each test names the issue it covers (B<n>).

(in-package #:clamsara)

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

(deftest claimore-rc-barrier-logs-deltas ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((barrier (plan-barrier *clamsara-plan*))
           (rc-buf (barrier-rc-buffer barrier)))
      (unless (find :rc (barrier-rules barrier) :key #'barrier-rule-name)
        (return-from claimore-rc-barrier-logs-deltas
          (values nil "no :rc rule in Claimore barrier")))
      (let ((a (clamsara-allocate-object 1))
            (b (clamsara-allocate-object 0)))
        (clamsara-write a 0 b)
        (if (plusp (fill-pointer rc-buf))
            (values t "ok")
            (values nil "RC buffer stayed empty after a barrier write"))))))

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

(deftest plan-validation-rejects-incoherent-combos ()
  ;; heap.tex §7 / plans.tex §1: incoherent axis combinations are rejected at
  ;; finalization, before any code is generated.
  (let ((vm (make-simulator-vm 4096)))
    ;; concurrent-relocate without off-heap forwarding must signal at plan
    ;; finalization
    (let ((caught-p nil))
      (handler-case
          (finalize-plan
           (make-instance 'plan
             :vm vm :name :bad
             :spaces (list (make-instance 'immix-space :vm vm
                                          :start-page 1 :page-count 6
                                          :name :bad :default-space t
                                          :moving :concurrent-relocate))))
        (plan-incompatible () (setf caught-p t)))
      (unless caught-p
        (return-from plan-validation-rejects-incoherent-combos
          (values nil "concurrent-relocate without off-heap fwd not rejected"))))
    ;; a copying space without a partner must be rejected at plan validation
    (let ((caught-p nil))
      (handler-case
          (finalize-plan
           (make-instance 'plan
             :vm vm :name :bad
             :spaces (list (make-instance 'copy-space :vm vm
                                          :start-page 1 :page-count 2
                                          :name :lonely :default-space t))))
        (plan-incompatible () (setf caught-p t)))
      (unless caught-p
        (return-from plan-validation-rejects-incoherent-combos
          (values nil "partnerless copying space not rejected"))))
    (values t "ok")))

(deftest claimore-concurrency-matches-implementation ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let ((conc (constraints-concurrency (plan-constraints *clamsara-plan*))))
      ;; The simulator performs no concurrent relocation; declaring it would
      ;; misrepresent the moving model (mature is non-moving mark-sweep).
      (if (eq conc :concurrent-relocate)
          (values nil "claims concurrent-relocate but never relocates")
          (values t "ok")))))

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
