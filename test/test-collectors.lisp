;;;; test/test-collectors.lisp -- every collector: allocate, link, GC, reclaim,
;;;; verify liveness + that dead objects are reclaimed + sanity check.

(in-package #:clamsara)

(defun %vm () *clamsara-vm*)
(defun %slots (a) (vm-object-reference-count (%vm) a))
(defun %slot (a i) (vm-object-reference (%vm) a i))
(defun (setf %slot) (v a i) (setf (vm-object-reference (%vm) a i) v))

(defun %survives-p (plan-type)
  (with-clamsara (:plan-type plan-type :heap-size 65536)
    (let* ((a (clamsara-allocate-object 3))
           (b (clamsara-allocate-object 2))
           (c (clamsara-allocate-object 2)))
      (setf (%slot a 0) b (%slot a 1) c (%slot b 0) c)
      (let ((root (clamsara-register-root a)))
        (declare (ignore root))
        (clamsara-gc)
        (let ((a2 (clamsara-root 0)))
          (unless (and (plusp a2) (= (%slots a2) 3)
                       (plusp (%slot a2 0)) (plusp (%slot a2 1))
                       (= (%slot (%slot a2 0) 0) (%slot a2 1)))
            (return-from %survives-p (values nil "live graph broke"))))
        (dotimes (i 200) (clamsara-allocate-object 5))  ; garbage
        (clamsara-gc)
        (let ((a3 (clamsara-root 0)))
          (if (and (= (%slots a3) 3) (plusp (%slot a3 0)))
              (values t "ok") (values nil "survivors lost after churn")))))))

(dolist (pt '(:semispace :marksweep :immix :gencopy :genms :genimmix))
  (let ((nm (intern (format nil "COLLECTOR-~a" pt))))
    (push (cons nm (lambda () (%survives-p pt))) *clamsara-tests*)))

(deftest collector-nogc ()
  (with-clamsara (:plan-type :nogc :heap-size 65536)
    (let ((a (clamsara-allocate-object 3)))
      (clamsara-register-root a)
      (if (= (%slots a) 3) (values t "ok") (values nil "alloc wrong")))))

(deftest collector-sticky-survives ()
  (with-clamsara (:plan-type :stickyimmix :heap-size 65536)
    (let ((root (clamsara-allocate-object 2)))
      (clamsara-register-root root)
      (dotimes (i 5)
        (dotimes (j 50) (clamsara-allocate-object 3))
        (clamsara-gc))
      (clamsara-gc :cycle-kind :major)
      (let ((r (clamsara-root 0)))
        (if (and (plusp r) (= (%slots r) 2)) (values t "ok")
            (values nil "sticky root lost"))))))

(deftest sticky-plans-rescan-mutated-marked-objects ()
  (dolist (plan-type '(:stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let ((parent (clamsara-allocate-object 1)))
        (clamsara-register-root parent)
        (plan-collect *clamsara-plan* :cycle-kind :minor)
        (let ((child (clamsara-allocate-object 0)))
          (clamsara-write parent 0 child)
          (plan-collect *clamsara-plan* :cycle-kind :minor)
          (unless (and (eql child
                            (vm-object-reference *clamsara-vm* parent 0))
                       (vm-object-start-p *clamsara-vm* child)
                       (vm-object-is-marked-p *clamsara-vm* child))
            (return-from sticky-plans-rescan-mutated-marked-objects
              (values nil
                      (format nil
                              "~A lost child of mutated marked object"
                              plan-type))))))))
  (values t "ok"))

(defun %generational-evacuates-and-promotes-p (plan-type)
  (with-clamsara (:plan-type plan-type :heap-size 65536)
    (let ((original (clamsara-allocate-object 1)))
      (clamsara-register-root original)
      (plan-collect *clamsara-plan* :cycle-kind :minor)
      (let ((survivor (clamsara-root 0)))
        (unless (and (/= survivor original)
                     (= (vm-object-age *clamsara-vm* survivor) 1)
                     (space-contains-p
                      (gen-nursery *clamsara-plan*) survivor)
                     (not (vm-object-start-p *clamsara-vm* original)))
          (return-from %generational-evacuates-and-promotes-p
            (values nil "first minor did not evacuate into nursery-to")))
        (plan-collect *clamsara-plan* :cycle-kind :minor)
        (let ((promoted (clamsara-root 0)))
          (if (and (/= promoted survivor)
                   (= (vm-object-age *clamsara-vm* promoted) 2)
                   (space-contains-p
                    (gen-mature *clamsara-plan*) promoted)
                   (vm-object-old-p *clamsara-vm* promoted)
                   (not (vm-object-start-p *clamsara-vm* survivor)))
              (values t "ok")
              (values nil "second minor did not promote survivor")))))))

(dolist (pt '(:gencopy :genms :genimmix))
  (let ((name (intern (format nil "~A-EVACUATES-AND-PROMOTES" pt))))
    (push (cons name
                (lambda () (%generational-evacuates-and-promotes-p pt)))
          *clamsara-tests*)))

(deftest generational-remset-heals-slot ()
  (with-clamsara (:plan-type :genms :heap-size 65536)
    (let ((parent (clamsara-allocate-object 1)))
      (clamsara-register-root parent)
      (plan-collect *clamsara-plan* :cycle-kind :minor)
      (plan-collect *clamsara-plan* :cycle-kind :minor)
      (let* ((old-parent (clamsara-root 0))
             (child (clamsara-allocate-object 0)))
        (clamsara-write old-parent 0 child)
        (plan-collect *clamsara-plan* :cycle-kind :minor)
        (let ((survivor (vm-object-reference *clamsara-vm* old-parent 0)))
          (unless (and (/= survivor child)
                       (vm-valid-reference-p *clamsara-vm* survivor)
                       (space-contains-p
                        (gen-nursery *clamsara-plan*) survivor)
                       (not (vm-object-start-p *clamsara-vm* child)))
            (return-from generational-remset-heals-slot
              (values nil "old-to-young remembered slot was not healed")))
          ;; The rewritten edge is still old-to-young. It must remain in the
          ;; remembered set for the next minor, when the child promotes.
          (plan-collect *clamsara-plan* :cycle-kind :minor)
          (let ((promoted
                  (vm-object-reference *clamsara-vm* old-parent 0)))
            (if (and (/= promoted survivor)
                     (vm-valid-reference-p *clamsara-vm* promoted)
                     (space-contains-p
                      (gen-mature *clamsara-plan*) promoted)
                     (not (vm-object-start-p *clamsara-vm* survivor)))
                (values t "ok")
                (values nil
                        "healed old-to-young edge was lost on next minor"))))))))

(deftest immix-forgets-dead-object-start ()
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let ((dead (clamsara-allocate-object 8))
          (live (clamsara-allocate-object 8)))
      (clamsara-register-root live)
      (plan-collect *clamsara-plan* :cycle-kind :full)
      (if (and (not (vm-object-start-p *clamsara-vm* dead))
               (vm-object-start-p *clamsara-vm* live))
          (values t "ok")
          (values nil "Immix retained stale object-start metadata")))))

(deftest immix-major-evacuates-fragmented-block ()
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let ((dead (clamsara-allocate-object 20))
          (live (clamsara-allocate-object 20)))
      (clamsara-register-root live)
      (plan-collect *clamsara-plan* :cycle-kind :major)
      (let ((moved (clamsara-root 0)))
        (if (and (/= moved live)
                 (vm-valid-reference-p *clamsara-vm* moved)
                 (not (vm-object-start-p *clamsara-vm* dead))
                 (not (vm-object-start-p *clamsara-vm* live)))
            (values t "ok")
            (values nil "fragmented Immix major did not evacuate/heal"))))))

#+sbcl
(sb-alien:define-alien-variable
    ("bytes_allocated" %sbcl-bytes-allocated)
    sb-alien:unsigned-long)

#+sbcl
(deftest post-boot-collection-makes-no-host-allocations ()
  ;; Read SBCL's raw allocation counter: GET-BYTES-CONSED can allocate its own
  ;; bignum and obscure small deltas. Closing the thread allocation region
  ;; makes the next host allocation immediately visible. Boot, mutator work,
  ;; and the public API's post-GC sanity checker are intentionally outside the
  ;; measured interval; the first live collection after boot is inside it.
  (dolist (plan-type '(:semispace :marksweep :immix
                       :gencopy :genms :genimmix
                       :stickyimmix :stickyms :iso :zgcish :claimore))
    (let* ((vm (make-simulator-vm 65536))
           (plan (make-collector plan-type vm 65536)))
      (boot-gc plan)
      (vm-add-root vm (allocate-object plan 2))
      (let ((cycle-kinds (boot-cycle-kinds plan)))
        (sb-vm::close-thread-alloc-region)
        (let ((before %sbcl-bytes-allocated))
          (dolist (cycle-kind cycle-kinds)
            (plan-collect plan :cycle-kind cycle-kind))
          (let ((bytes (- %sbcl-bytes-allocated before)))
          (unless (zerop bytes)
            (return-from post-boot-collection-makes-no-host-allocations
              (values nil
                      (format nil "~A collection consed ~D host bytes"
                              plan-type bytes)))))))))
  ;; Barrier-driven generational path: dirty card scan, child evacuation, and
  ;; post-swap remembered-set rebuild.
  (dolist (plan-type '(:gencopy :genms :genimmix))
    (let* ((vm (make-simulator-vm 65536))
           (plan (make-collector plan-type vm 65536))
           (barrier (plan-barrier plan)))
      (boot-gc plan)
      (vm-add-root vm (allocate-object plan 1))
      (plan-collect plan :cycle-kind :minor)
      (plan-collect plan :cycle-kind :minor)
      (let ((parent (aref (vm-root-vector vm) 0))
            (child (allocate-object plan 0)))
        (barrier-note-write vm barrier parent 0 child)
        (vm-set-reference vm parent 0 child)
        (sb-vm::close-thread-alloc-region)
        (let ((before %sbcl-bytes-allocated))
          (plan-collect plan :cycle-kind :minor)
          (let ((bytes (- %sbcl-bytes-allocated before)))
            (unless (zerop bytes)
              (return-from post-boot-collection-makes-no-host-allocations
                (values nil
                        (format nil
                                "~A remembered-set collection consed ~D bytes"
                                plan-type bytes)))))))))
  ;; Sticky minors must rescan the preallocated dirty-object log.
  (dolist (plan-type '(:stickyimmix :stickyms))
    (let* ((vm (make-simulator-vm 65536))
           (plan (make-collector plan-type vm 65536))
           (barrier (plan-barrier plan)))
      (boot-gc plan)
      (let ((parent (allocate-object plan 1)))
        (vm-add-root vm parent)
        (plan-collect plan :cycle-kind :minor)
        (let ((child (allocate-object plan 0)))
          (barrier-note-write vm barrier parent 0 child)
          (vm-set-reference vm parent 0 child)
          (sb-vm::close-thread-alloc-region)
          (let ((before %sbcl-bytes-allocated))
            (plan-collect plan :cycle-kind :minor)
            (let ((bytes (- %sbcl-bytes-allocated before)))
              (unless (zerop bytes)
                (return-from post-boot-collection-makes-no-host-allocations
                  (values nil
                          (format nil
                                  "~A dirty rescan consed ~D host bytes"
                                  plan-type bytes))))))))))
  ;; SATB remark must not manufacture generic-call rest lists or cache state.
  (let* ((vm (make-simulator-vm 65536))
         (plan (make-collector :zgcish vm 65536))
         (barrier (plan-barrier plan)))
    (boot-gc plan)
    (let ((parent (allocate-object plan 1))
          (child (allocate-object plan 0)))
      (vm-set-reference vm parent 0 child)
      (vm-add-root vm parent)
      (barrier-note-write vm barrier parent 0 0)
      (vm-set-reference vm parent 0 0)
      (sb-vm::close-thread-alloc-region)
      (let ((before %sbcl-bytes-allocated))
        (plan-collect plan :cycle-kind :full)
        (let ((bytes (- %sbcl-bytes-allocated before)))
          (unless (zerop bytes)
            (return-from post-boot-collection-makes-no-host-allocations
              (values nil
                      (format nil
                              "ZGC SATB remark consed ~D host bytes"
                              bytes))))))))
  ;; Exercise Immix's evacuation/healing path, not just its ordinary sweep.
  (let* ((vm (make-simulator-vm 65536))
         (plan (make-collector :immix vm 65536)))
    (boot-gc plan)
    (allocate-object plan 20)
    (vm-add-root vm (allocate-object plan 20))
    (sb-vm::close-thread-alloc-region)
    (let ((before %sbcl-bytes-allocated))
      (plan-collect plan :cycle-kind :major)
      (let ((bytes (- %sbcl-bytes-allocated before)))
        (unless (zerop bytes)
          (return-from post-boot-collection-makes-no-host-allocations
            (values nil
                    (format nil
                            "fragmented Immix major consed ~D host bytes"
                            bytes)))))))
  (values t "ok"))


;; ---- generational weak/finalizer regressions ------------------------------

(deftest generational-weak-minor-semantics ()
  ;; A minor traces only the nursery.  Mature weak referents must therefore
  ;; remain untouched, while a dead nursery referent must not be promoted by
  ;; the remembered-set scan (the weak phase clears it).
  (dolist (plan-type '(:gencopy :genms :genimmix))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let* ((weak (clamsara-allocate-object 1))
             (target (clamsara-allocate-object 0)))
        (register-weak-pointer *clamsara-vm* weak)
        (setf (%slot weak 0) target)
        (let ((weak-index (clamsara-register-root weak))
              (target-index (clamsara-register-root target)))
          ;; Keep both objects alive long enough to promote them.
          (plan-collect *clamsara-plan* :cycle-kind :minor)
          (plan-collect *clamsara-plan* :cycle-kind :minor)
          (let ((weak2 (clamsara-root weak-index))
                (target2 (clamsara-root target-index)))
            (unless (and (space-contains-p (gen-mature *clamsara-plan*) weak2)
                         (space-contains-p (gen-mature *clamsara-plan*) target2))
              (return-from generational-weak-minor-semantics
                (values nil (format nil "~A: setup did not promote weak pair"
                                    plan-type))))
            ;; Remove the strong target root: a minor must not clear the
            ;; mature target merely because it is absent from minor marks.
            (clamsara-remove-root target-index)
            (plan-collect *clamsara-plan* :cycle-kind :minor)
            (unless (= (%slot (clamsara-root weak-index) 0) target2)
              (return-from generational-weak-minor-semantics
                (values nil (format nil
                                    "~A: mature weak referent cleared by minor"
                                    plan-type))))
            ;; A young dead target is a real weak-phase candidate.  It must not
            ;; be copied from the old-to-young remembered card first.
            (let ((dead-young (clamsara-allocate-object 0)))
              (clamsara-write (clamsara-root weak-index) 0 dead-young)
              (plan-collect *clamsara-plan* :cycle-kind :minor)
              (unless (zerop (%slot (clamsara-root weak-index) 0))
                (return-from generational-weak-minor-semantics
                  (values nil (format nil
                                      "~A: dead nursery weak referent survived"
                                      plan-type))))))))))
  (values t "ok"))

(deftest generational-finalizer-follows-forwarding ()
  ;; Finalizer registrations are heap references too: a nursery object that is
  ;; copied must update its known registration before the old address resets.
  (dolist (plan-type '(:gencopy :genms :genimmix))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (unless (and (vectorp (plan-known-finalizers *clamsara-plan*))
                   (vectorp (plan-pending-finalizers *clamsara-plan*)))
        (return-from generational-finalizer-follows-forwarding
          (values nil (format nil "~A: finalizer vectors not initialized"
                              plan-type))))
      (let* ((object (clamsara-allocate-object 0))
             (index (clamsara-register-root object)))
        (register-finalizer *clamsara-plan* object)
        (plan-collect *clamsara-plan* :cycle-kind :minor)
        (let ((moved (clamsara-root index))
              (known (plan-known-finalizers *clamsara-plan*)))
          (unless (and (= (length known) 1) (= (aref known 0) moved))
            (return-from generational-finalizer-follows-forwarding
              (values nil (format nil
                                  "~A: finalizer stayed at old address"
                                  plan-type))))))))
  (values t "ok"))
