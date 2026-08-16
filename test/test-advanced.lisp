;;;; test/test-advanced.lisp -- Iso (publication/DLG), ZGC (SATB+LVB+relocate),
;;;; Claimore (RC+nursery+checkpoint).  Plus barrier unit tests.

(in-package #:clamsara)

(defun %vm () *clamsara-vm*)
(defun %slot (a i) (vm-object-reference (%vm) a i))
(defun (setf %slot) (v a i) (setf (vm-object-reference (%vm) a i) v))

(deftest iso-publication-dlg ()
  (with-clamsara (:plan-type :iso :heap-size 65536)
    (let ((a (clamsara-allocate-object 2))
          (b (clamsara-allocate-object 1)))
      (setf (%slot a 0) b)
      (clamsara-register-root a)
      (let ((pub (clamsara-allocate-object 1)))
        (setf (vm-object-is-public-p (%vm) pub) t)
        (clamsara-write pub 0 a))   ; publication barrier publishes `a`
      (clamsara-gc)
      (let ((a2 (clamsara-root 0)))
        (if (and (plusp a2) (= (vm-object-reference-count (%vm) a2) 2)
                 (vm-object-is-public-p (%vm) a2))
            (values t "ok") (values nil "publication/DLG failed"))))))

(deftest iso-eager-public-region-is-used ()
  ;; Eager Iso publication must return an incarnation allocated in its public
  ;; region, rather than merely setting a bit on the private object.
  (with-clamsara (:plan-type :iso :heap-size 65536)
    (let* ((source (clamsara-allocate-object 1))
           (child (clamsara-allocate-object 0))
           (public-source (clamsara-allocate-object 1))
           (public (iso-public *clamsara-plan*)))
      (setf (%slot source 0) child
            (vm-object-is-public-p *clamsara-vm* public-source) t)
      (clamsara-write public-source 0 source)
      (let ((copy (%slot public-source 0)))
        (if (and (space-contains-p public copy)
                 (space-contains-p public (%slot copy 0))
                 (vm-object-is-public-p *clamsara-vm* copy))
            (values t "ok")
            (values nil "eager publication ignored the public region"))))))

(deftest lazy-publication-records-child-edges ()
  ;; Both initial publication and read-time child exposure record guarded
  ;; outgoing edges in the append-only set.
  (let ((vm (make-simulator-vm 4096))
        (strategy (make-instance 'lazy-read-barrier)))
    (initialize-publication-work strategy vm)
    (vm-write-header vm 512 +tag-object+ 1)
    (vm-write-header vm 514 +tag-object+ 1)
    (vm-write-header vm 516 +tag-object+ 0)
    (setf (vm-object-reference vm 512 0) 514
          (vm-object-reference vm 514 0) 516)
    (publish strategy vm 512)
    (let ((pr (strategy-published-roots strategy)))
      (if (and (= (published-roots-count pr) 1)
               (published-edge-recorded-p pr vm 512 514))
          (progn
            (funcall (publication-read-rule strategy) vm (+ 512 1) 514)
            (if (and (= (published-roots-count pr) 2)
                     (published-edge-recorded-p pr vm 514 516))
                (values t "ok")
                (values nil "lazy child edges were not recorded")))
          (values nil "lazy root edge was not recorded")))))

(deftest trap-a-exhaustion-rolls-back-closure ()
  ;; A root fits but its child does not: no copied object or public bit may
  ;; survive the failed transactional closure publication.
  (let* ((vm (make-simulator-vm 4096))
         (region (make-instance 'mark-sweep-space :vm vm :start-page 2
                                :page-count 1 :name :public))
         (strategy (make-instance 'trap-error-copy-a :public-region region))
         (plan (make-instance 'plan :name :trap-test :vm vm
                              :spaces (list region)
                              :publication strategy)))
    (initialize-publication-work strategy vm)
    (vm-write-header vm 512 +tag-object+ 1)
    (vm-write-header vm 514 +tag-object+ 511)
    (setf (vm-object-reference vm 512 0) 514)
    (let ((copy (publish strategy vm 512)))
      (if (and (null copy)
               (vm-object-start-p vm 512)
               (not (error-object-p vm 512))
               (not (vm-object-start-p vm 1024))
               (not (vm-object-is-public-p vm 1024))
               (= (space-occupancy region) 0))
          (values t "ok")
          (values nil "trap-A exhaustion leaked copied objects")))))

(deftest zgc-relocate-heal ()
  (with-clamsara (:plan-type :zgcish :heap-size 65536)
    (let ((a (clamsara-allocate-object 3))
          (b (clamsara-allocate-object 2)))
      (setf (%slot a 0) b)
      (clamsara-register-root a)
      (clamsara-gc)
      (let ((a2 (clamsara-root 0)))
        (if (and (/= a2 a)
                 (/= (%slot a2 0) b)
                 (vm-valid-reference-p (%vm) a2)
                 (vm-valid-reference-p (%vm) (%slot a2 0))
                 (not (vm-object-start-p (%vm) a))
                 (not (vm-object-start-p (%vm) b)))
            (values t "ok") (values nil "relocate/heal failed"))))))

(deftest zgc-satb-remark-retains-snapshot-object ()
  (with-clamsara (:plan-type :zgcish :heap-size 65536)
    (let ((parent (clamsara-allocate-object 1))
          (snapshot-child (clamsara-allocate-object 0)))
      (setf (%slot parent 0) snapshot-child)
      (clamsara-register-root parent)
      ;; The SATB barrier records the overwritten child. It is absent from the
      ;; graph by the time root marking begins and must enter through remark.
      (clamsara-write parent 0 0)
      (plan-collect *clamsara-plan* :cycle-kind :full)
      (let* ((space (z-from *clamsara-plan*))
             (object-start (vm-object-start *clamsara-vm*))
             (live-count
               (loop for address from (space-base-address space)
                     below (space-end-address space)
                     count (s-test-bit object-start address))))
        (if (and (= live-count 2)
                 (not (vm-object-start-p *clamsara-vm* snapshot-child)))
            (values t "ok")
            (values nil "SATB remark did not retain/relocate snapshot child"))))))

(deftest claimore-major ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let ((a (clamsara-allocate-object 2))
          (b (clamsara-allocate-object 1)))
      (setf (%slot a 0) b)
      (clamsara-register-root a)
      (clamsara-gc)
      (dotimes (i 3)
        (dotimes (j 40) (clamsara-allocate-object 3))
        (clamsara-gc))
      (clamsara-gc :cycle-kind :major)
      (let ((a2 (clamsara-root 0)))
        (if (and (plusp a2) (= (vm-object-reference-count (%vm) a2) 2))
            (values t "ok") (values nil "claimore major failed"))))))

;; ---- G5: weak references + finalization (weak.tex) -----------------------

(deftest weak-referent-cleared-when-dead ()
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let* ((wm (clamsara-allocate-object 1))
           (target (clamsara-allocate-object 0)))
      (register-weak-pointer *clamsara-vm* wm)
      (setf (%slot wm 0) target)
      (clamsara-register-root wm)
      ;; target is unreachable except through the weak pointer: after a full
      ;; collection its slot must be cleared
      (clamsara-gc)
      (if (zerop (%slot (clamsara-root 0) 0))
          (values t "ok")
          (values nil "weak referent was not cleared")))))

(deftest weak-public-bit-alone-does-not-imply-liveness ()
  ;; Publication metadata describes visibility, not reachability.  A public
  ;; object that is reachable only through a weak slot must still be cleared;
  ;; an actual root remains a valid liveness proof.
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    ;; Mark-sweep plans do not need publication barriers, but installing the
    ;; locality stratum here models the public bit without giving it root
    ;; semantics.
    (vm-register-stratum *clamsara-vm* :public
      (make-stratum :public (vm-min-alignment-words *clamsara-vm*) :bit
                    (vm-heap-size *clamsara-vm*)))
    (let* ((dead-wm (clamsara-allocate-object 1))
           (dead-target (clamsara-allocate-object 0))
           (live-wm (clamsara-allocate-object 1))
           (live-target (clamsara-allocate-object 0)))
      (register-weak-pointer *clamsara-vm* dead-wm)
      (register-weak-pointer *clamsara-vm* live-wm)
      (setf (%slot dead-wm 0) dead-target
            (%slot live-wm 0) live-target
            (vm-object-is-public-p *clamsara-vm* dead-target) t
            (vm-object-is-public-p *clamsara-vm* live-target) t)
      (clamsara-register-root dead-wm)
      (clamsara-register-root live-wm)
      ;; This is the real root that must preserve the second referent.
      (clamsara-register-root live-target)
      (clamsara-gc)
      (let ((live-target-now (clamsara-root 2)))
        (if (and (zerop (%slot (clamsara-root 0) 0))
                 (= (%slot (clamsara-root 1) 0) live-target-now)
                 (vm-object-start-p *clamsara-vm* live-target-now)
                 (not (vm-object-start-p *clamsara-vm* dead-target)))
            (values t "ok")
            (values nil "public metadata was treated as weak liveness"))))))

(deftest weak-referent-kept-when-live ()
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let* ((wm (clamsara-allocate-object 1))
           (target (clamsara-allocate-object 0)))
      (register-weak-pointer *clamsara-vm* wm)
      (setf (%slot wm 0) target)
      (clamsara-register-root wm)
      (clamsara-register-root target)     ; strong root keeps it alive
      (clamsara-gc)
      (let ((live-wm (clamsara-root 0))
            (live-target (clamsara-root 1)))
        (if (and (plusp (%slot live-wm 0))
                 (= (%slot live-wm 0) live-target))
            (values t "ok")
            (values nil "live weak referent was cleared"))))))

(deftest finalizers-move-dead-to-pending ()
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let* ((dead (clamsara-allocate-object 0))
           (live (clamsara-allocate-object 0)))
      (initialize-finalization *clamsara-plan* *clamsara-vm*)
      (register-finalizer *clamsara-plan* dead)
      (register-finalizer *clamsara-plan* live)
      (clamsara-register-root live)
      (clamsara-gc)   ; phase-weak moves dead finalizers to pending
      (let ((pending (drain-pending-finalizers *clamsara-plan*)))
        (if (and (= (length pending) 1)
                 (equal pending (list dead)))
            (values t "ok")
            (values nil (format nil "pending finalizers wrong: ~a" pending)))))))

(deftest published-roots-record-and-drain ()
  ;; locality.tex §1: the published-roots set records guarded EDGES (object +
  ;; slot) and drains them without clearing (append-only, drained twice).
  (let* ((vm (make-simulator-vm 4096))
         (strategy (make-instance 'lazy-read-barrier)))
    (initialize-publication-work strategy vm)
    (let ((pr (strategy-published-roots strategy)))
      (unless pr
        (return-from published-roots-record-and-drain
          (values nil "no published-roots set on a lazy strategy")))
      (record-published-edge pr 100 0)
      (record-published-edge pr 200 3)
      (let ((drained nil))
        (drain-published-roots pr
          (lambda (object slot) (push (cons object slot) drained)))
        ;; first drain sees both edges
        (unless (= (length drained) 2)
          (return-from published-roots-record-and-drain
            (values nil "first drain missed edges")))
        ;; set is retained (append-only)
        (unless (= (published-roots-count pr) 2)
          (return-from published-roots-record-and-drain
            (values nil "drain cleared the append-only set")))
        (let ((second nil))
          (drain-published-roots pr
            (lambda (object slot) (push (cons object slot) second)))
          (if (= (length second) 2)
              (values t "ok")
              (values nil "second drain missed edges")))))))

(deftest trap-a-poison-clears-weak-redirect-metadata ()
  ;; Poisoning turns slot 0 into a strong trap redirect.  A stale weak bit
  ;; would make tracing skip that redirect and lose the public incarnation.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (public-source (clamsara-allocate-object 1))
           (weak-object (clamsara-allocate-object 1))
           (child (clamsara-allocate-object 0)))
      (register-weak-pointer vm weak-object)
      (vm-set-reference vm weak-object 0 child)
      (setf (vm-object-is-public-p vm public-source) t)
      (clamsara-write public-source 0 weak-object)
      (if (and (error-object-p vm weak-object)
               (not (weak-pointer-p vm weak-object)))
          (values t "ok")
          (values nil "Trap-A poison retained weak redirect metadata")))))

(deftest trap-b-installs-guarded-stand-in ()
  ;; locality.tex §2 Variant B: the private original stays in place and the
  ;; public region gets a trapping stand-in whose edge is a published root.
  (let* ((vm (make-simulator-vm 4096))
         (strategy (make-instance 'lazy-read-barrier))) ; placeholder region
    (declare (ignore vm strategy))
    (with-clamsara (:plan-type :claimore :heap-size 65536)
      (let* ((mature (cl-mature *clamsara-plan*))
             (private-obj (clamsara-allocate-object 1))
             (strategy (make-instance 'trap-error-copy-b
                                      :public-region mature)))
        (initialize-publication-work strategy *clamsara-vm*)
        (let ((stand-in (publish strategy *clamsara-vm* private-obj)))
          (if (and stand-in
                   (space-contains-p mature stand-in)
                   (error-object-p *clamsara-vm* stand-in)
                   (not (vm-object-is-public-p *clamsara-vm* private-obj))
                   (= (published-roots-count
                       (strategy-published-roots strategy)) 1))
              (values t "ok")
              (values nil (format nil "trap-B stand-in wrong: ~a" stand-in))))))))

(deftest barrier-card-rule ()
  ;; The card rule must actually dirty the source card on an old->young write,
  ;; not merely report the right trigger keyword.
  (let ((vm (make-simulator-vm 4096)))
    (vm-register-stratum vm :card (make-stratum :card (g-card) :bit 4096))
    (vm-register-stratum vm :age (make-stratum :age (g-word) :u4 4096))
    (let ((os (vm-object-start vm)))
      (s-set-bit os 512)                        ; "old" object
      (s-set-bit os 1024))                      ; "young" object
    (s-set (vm-stratum vm :age) 512 3)         ; aged => old
    (let ((rule (card-barrier-rule))
          (barrier (make-instance 'barrier :rules nil)))
      (funcall (barrier-rule-transfer rule) vm barrier 512 0 1024)
      (if (and (eq (barrier-rule-trigger rule) :ref-write)
               (s-test-bit (vm-stratum vm :card) 512))
          (values t "ok")
          (values nil "card rule did not dirty the source card")))))


(deftest claimore-read-declaration-matches-fused-rules ()
  ;; The plan declaration names concrete read rules.  In particular, the
  ;; publication strategy is not itself a barrier rule.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((p *clamsara-plan*)
           (c (plan-constraints p))
           (names (constraints-read-barrier c))
           (rules (barrier-rules (plan-barrier p))))
      (if (and (eq (constraints-requires-tier c) :t2)
               (listp names)
               (every (lambda (name)
                       (find name rules :key #'barrier-rule-name))
                      names))
          (values t "ok")
          (values nil (format nil "read declaration ~a does not match rules ~a"
                              names (mapcar #'barrier-rule-name rules)))))))

(deftest claimore-foreign-edge-needs-two-mature-endpoints ()
  ;; A mature source may point into the nursery.  Such an edge must not index
  ;; the nursery address as a mature block and set bogus escape metadata.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (p *clamsara-plan*)
           (mature (cl-mature p))
           (source (alloc (space-allocator mature) 1))
           (young (clamsara-allocate-object 0))
           (barrier (plan-barrier p))
           (rule (find :rc (barrier-rules barrier)
                       :key #'barrier-rule-name))
           (block (sb-block-index mature source)))
      (vm-write-header vm source +tag-object+ 0)
      (s-set-bit (vm-object-start vm) source)
      (funcall (barrier-rule-transfer rule) vm barrier source 0 young)
      (if (zerop (sb-escape-value mature vm block))
          (values t "ok")
          (values nil "nursery target polluted mature hierarchy metadata")))))

(deftest claimore-search-cross-superblock-foreign-closure ()
  ;; SB1's root points into SB2.  The foreign target bit is the only metadata
  ;; edge between those per-SB matrices; search must seed SB2 as well as SB1.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (s (cl-mature *clamsara-plan*))
           (a (space-allocator s))
           (bpm (%sb-bpm s))
           (mps (%sb-mps s))
           (src-block (* 1 mps bpm))
           (dst-block (* 2 mps bpm))
           (src (sb-block-base s src-block))
           (dst (sb-block-base s dst-block)))
      ;; Search only visits in-use superblocks; reserve one block in each.
      (setf (aref (hierarchical-allocator-cursors a) src-block) (+ src 1)
            (aref (hierarchical-allocator-cursors a) dst-block) (+ dst 1))
      (vm-add-root vm src)
      (superblock-note-write s vm src dst)
      (superblock-search s vm)
      (let ((sb1-reached (aref (%sb-reached-mbs s) 1))
            (sb2-reached (aref (%sb-reached-mbs s) 2)))
        (if (and (= 1 (sbit sb1-reached 0))
                 (= 1 (sbit sb2-reached 0)))
            (values t "ok")
            (values nil "foreign target was not traversed by search"))))))
