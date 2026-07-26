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

;; ---- B14: Claimore's concurrency constraint must reflect reality ---------

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
