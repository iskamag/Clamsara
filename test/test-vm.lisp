;;;; test/test-vm.lisp -- VM object model + coloured pointers + metadata locations.

(in-package #:clamsara)

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
      (clrhash (vm-fwd-table vm))
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
