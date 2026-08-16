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

(deftest object-model ()
  (let ((vm (make-simulator-vm 4096)))
    (let ((a (vm-write-header vm 512 +tag-object+ 3)))
      (if (and (= (vm-object-reference-count vm a) 3)
               (= (vm-object-total-words vm a) 4)
               (vm-object-start-p vm a))
          (values t "obj ok") (values nil "obj wrong")))))

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
