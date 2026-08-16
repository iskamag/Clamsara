;;;; test/test-vm.lisp -- VM object model + coloured pointers + metadata locations.

(in-package #:clamsara)

(deftest simulator-vm-capabilities ()
  ;; Capability mixins are sibling superclasses, so verify the simulator's
  ;; explicit contract rather than relying on CLOS superclass ordering.
  (let ((vm (make-simulator-vm 4096)))
    (if (and (eq (vm-tier vm) :t2)
             (vm-has-feature-p vm :t1)
             (vm-has-feature-p vm :t2)
             (vm-has-feature-p vm :ring0)
             (vm-has-feature-p vm :virtual-memory)
             (vm-has-feature-p vm :coloured-pointers))
        (values t "simulator capabilities ok")
        (values nil "simulator capabilities wrong"))))

(deftest software-mmu-alias-range ()
  ;; T1 aliases may be outside the physical heap's identity-mapped range.  A
  ;; grown VPT must retain the original mapping/protection and still dispatch
  ;; a protection fault through the ordinary T2 handler path.
  (let* ((vm (make-simulator-vm 4096))
         (physical-page 1)
         (original-page physical-page)
         (alias-page (vm-page-count vm))
         (original-address (+ (page-start-address original-page) 7))
         (alias-address (+ (page-start-address alias-page) 7))
         (faults 0))
    (setf (ref-u64 vm original-address) #x1234)
    (vm-mprotect vm original-page 1 :read)
    (let ((alias (vm-map-alias vm physical-page alias-page 1)))
      (vm-install-fault-handler
       vm (lambda (address access-kind)
           (declare (ignore access-kind))
           (incf faults)
           (vm-mprotect vm (address-page address) 1 :read-write)))
      (mmu-arm vm)
      (if (and (= alias alias-page)
               (= (ref-u64 vm original-address) #x1234)
               (= (ref-u64 vm alias-address) #x1234)
               (eq (cdr (aref (mmu-vpt vm) original-page)) :read)
               (eq (cdr (aref (mmu-vpt vm) alias-page)) :read-write))
          (progn
            ;; The original's read-only protection remains effective after
            ;; alias creation, and the handler can make it writable.
            (setf (ref-u64 vm original-address) #x5678)
            (if (and (= faults 1)
                     (= (ref-u64 vm alias-address) #x5678)
                     (= (ref-u64 vm original-address) #x5678))
                (values t "software MMU alias range/fault path ok")
                (values nil "software MMU alias fault path wrong")))
          (values nil "software MMU alias mapping lost the original")))))

(deftest object-model ()
  (let ((vm (make-simulator-vm 4096)))
    (let ((a (vm-write-header vm 512 +tag-object+ 3)))
      (if (and (= (vm-object-reference-count vm a) 3)
               (= (vm-object-total-words vm a) 4)
               (vm-object-start-p vm a))
          (values t "obj ok") (values nil "obj wrong")))))

(deftest vm-address-cons-p-default-and-configured ()
  ;; A bare VM has no headerless cells.  Installing a plan with a named
  ;; cons-space enables the predicate only for addresses in that space.
  (let ((bare (make-simulator-vm 4096)))
    (if (vm-address-cons-p bare 512)
        (values nil "bare VM reported a cons address")
        (let* ((vm (make-simulator-vm 4096))
               (space (make-instance 'cons-space :vm vm :start-page 1
                                     :page-count 2 :name :cons))
               (plan (make-instance 'plan :name :cons-test :vm vm
                                    :spaces (list space))))
          (declare (ignore plan))
          (if (and (not (vm-address-cons-p vm 511))
                   (vm-address-cons-p vm 512)
                   (not (vm-address-cons-p vm 1536)))
              (values t "cons-space address predicate ok")
              (values nil "cons-space address predicate wrong"))))))

(deftest coloured-pointers ()
  ;; axis 2: in-pointer colour.  A plain address is already "good" (remapped).
  (let ((vm (make-simulator-vm 4096)))
    (if (and (ref-good-colour-p vm 512)
             (not (ref-good-colour-p vm (ref-set-colour vm 512 (colour-marked0))))
             (= (ref-strip vm (ref-set-colour vm 512 (colour-marked1))) 512))
        (values t "colour ok") (values nil "colour wrong"))))

(deftest metadata-location-forwarding ()
  ;; axis 2 test: move forwarding in-header -> off-heap WITHOUT changing the
  ;; access code.  Both vm-object-is-forwarded-p / forwarding-pointer work.
  (let ((vm (make-simulator-vm 4096)))
    (vm-write-header vm 512 +tag-object+ 1)
    (vm-set-location vm :forwarding :in-header)
    (setf (vm-object-forwarding-pointer vm 512) 768)
    (let ((in-header-ok (and (vm-object-is-forwarded-p vm 512)
                             (= (vm-object-forwarding-pointer vm 512) 768))))
      (vm-set-location vm :forwarding :off-heap)
      (fwd-clear vm)
      (setf (vm-object-forwarding-pointer vm 512) 1024)
      (let ((off-heap-ok (and (vm-object-is-forwarded-p vm 512)
                              (= (vm-object-forwarding-pointer vm 512) 1024))))
        (if (and in-header-ok off-heap-ok) (values t "fwd-location ok")
            (values nil "fwd-location wrong"))))))

(deftest rc-table ()
  ;; axis 3: reference counting is a first-class policy (off-heap table).
  (let ((vm (make-simulator-vm 4096)))
    (setf (vm-object-rc vm 512) 3) (setf (vm-object-rc vm 512) (1- (vm-object-rc vm 512)))
    (if (= (vm-object-rc vm 512) 2) (values t "rc ok") (values nil "rc wrong"))))

(deftest slot-map-precise-scanning ()
  ;; memory.tex §3: a declared per-type layout restricts scanning to the
  ;; reference-bearing slots; undeclared layouts stay conservative.
  (let ((vm (make-simulator-vm 4096)))
    (vm-write-header vm 512 +tag-object+ 4)     ; slots 0..3
    (vm-write-header vm 800 +tag-object+ 4)
    (setf (vm-object-reference vm 512 0) 800)   ; slot 0 = reference
    (setf (vm-object-reference vm 512 1) 12345) ; slot 1 = raw payload
    ;; register a layout: only slot 0 is a reference
    (register-slot-map vm +tag-object+ 7 #(0))
    (setf (vm-object-header vm 512)
          (dpb 7 (byte 16 48) (vm-object-header vm 512)))
    (let ((seen nil))
      (vm-scan-object-references vm 512 (lambda (r) (push r seen)))
      (if (and (equal seen '(800))
               ;; conservative fallback: unregistered layout scans all slots
               (let ((conservative nil))
                 (setf (vm-object-header vm 512)
                       (dpb 9 (byte 16 48) (vm-object-header vm 512)))
                 (vm-scan-object-references
                  vm 512 (lambda (r) (push r conservative)))
                 (= (length conservative) 2)))
          (values t "ok")
          (values nil (format nil "precise scan wrong: ~a" seen))))))


(deftest simulator-scheduler-protocol ()
  ;; Work packets are VM-owned records.  The one-worker simulator still
  ;; exposes steal, while drain executes FIFO work and returns packets to the
  ;; preallocated pool.
  (let* ((vm (make-simulator-vm 4096 :work-packets 4))
         (p1 (make-work-packet vm :function nil :region-start 1 :region-end 2))
         (p2 (make-work-packet vm :function nil :region-start 3 :region-end 4))
         (p3 (make-work-packet vm :function nil :region-start 5 :region-end 6))
         (seen nil))
    (scheduler-enqueue vm p1)
    (scheduler-enqueue (vm-scheduler vm) p2)
    (scheduler-enqueue vm p3)
    (let ((stolen (scheduler-steal vm)))
      (unless (eq stolen p3)
        (return-from simulator-scheduler-protocol
          (values nil "steal did not take the back packet")))
      (release-work-packet stolen))
    (let ((n (scheduler-drain vm (lambda (packet)
                                   (push (work-packet-region-start packet) seen))))
          (reused (vm-allocate-work-packet vm)))
      (unwind-protect
           (if (and (= n 2) (= (scheduler-queue-size (vm-scheduler vm)) 0)
                    (equal (sort seen #'<) '(1 3))
                    (eq (work-packet-state reused) :detached))
               (values t "scheduler enqueue/steal/drain ok")
               (values nil (format nil "scheduler protocol wrong: ~a" seen)))
        (release-work-packet reused)))))

(deftest plan-mutator-context-ownership ()
  ;; Contexts are plan-owned, even though their VM is the simulator VM.  A
  ;; second context extends the plan's storage rather than a VM-global list.
  (let* ((vm (make-simulator-vm 4096 :work-packets 2))
         (p (make-instance 'plan :name :context-test :vm vm :spaces nil
                           :constraints (make-instance 'plan-constraints)))
         (first (plan-mutator-context p))
         (second (make-mutator-context p)))
    (if (and first second
             (eq (mutator-context-plan first) p)
             (eq (mutator-context-plan second) p)
             (eq (mutator-context-vm second) vm)
             (= (length (plan-mutator-contexts p)) 2))
        (values t "mutator context ownership ok")
        (values nil "mutator context ownership wrong"))))
