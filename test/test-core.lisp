(in-package #:clamsara.tests)

(def-suite test-core :description "Core unit tests"
  :in clamsara-tests)

(in-suite test-core)

;;; --- Types ---

(test address-ops
  "Address math and header encoding."
  (is (= 0 (address-index 0)))
  (is (address= 42 42))
  (is (not (address= 42 43)))
  (is (= 44 (address+ 42 2)))
  (is (= 40 (address- 42 2)))
  ;; Header construction
  (let ((h (make-object-header 10 :type-tag +type-tag-object+ :flags +flag-forwarded+)))
    (is (= 10 (header-size h)))
    (is (header-flag-set-p h +flag-forwarded+))
    (is (not (header-flag-set-p h +flag-pinned+)))))

;;; --- Heap ---

(test heap-read-write
  "Heap word read/write."
  (ensure-heap 1024)
  (setf (heap-ref 0) 12345)
  (is (= 12345 (heap-ref 0)))
  (setf (heap-ref 100) 67890)
  (is (= 67890 (heap-ref 100))))

(test heap-and-page-table-initialized
  "Heap and page table are created by make-simulator-vm."
  (let ((vm (make-simulator-vm :heap-size 4096)))
    ;; Verify heap is functional by reading/writing
    (setf (heap-ref 0) 42)
    (is (= 42 (heap-ref 0)))
    ;; Verify metadata was initialized
    (is (not (null clamsara::*metadata-words*)))))

(test card-table-creation
  "Card table creation."
  (let ((ct (ensure-card-table +page-size-words+)))
    (is (> (length (card-table-cards ct)) 0))))

;;; --- Object Model ---

(test object-allocate-and-access
  "Allocate object, write/read references, check type-tag and size."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-object *active-plan* 5)))
      (is (vm-object-start-p vm addr))
      (is (= 5 (vm-object-reference-count vm addr)))
      (is (= 6 (vm-object-total-words vm addr)))
      (is (= +type-tag-object+ (vm-object-type-tag vm addr)))
      (setf (vm-object-reference vm addr 0) 42)
      (setf (vm-object-reference vm addr 4) 99)
      (is (= 42 (vm-object-reference vm addr 0)))
      (is (= 99 (vm-object-reference vm addr 4))))))

(test object-copy-preserves-data
  "vm-object-copy preserves slot data."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (src (allocate-fill *active-plan* 3 10 20 30))
           (dst (allocate-object *active-plan* 3)))
      (vm-object-copy vm src dst)
      (is (= 10 (vm-object-reference vm dst 0)))
      (is (= 20 (vm-object-reference vm dst 1)))
      (is (= 30 (vm-object-reference vm dst 2))))))

(test cons-cell
  "CONS cell allocation and access."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-cons *active-plan* 1 2)))
      (is (vm-object-start-p vm addr))
      (is (= +type-tag-cons+ (vm-object-type-tag vm addr)))
      (is (= 1 (vm-object-reference vm addr 0)))
      (is (= 2 (vm-object-reference vm addr 1))))))

(test valid-reference-p
  "vm-valid-reference-p correctly validates addresses."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-object *active-plan* 2)))
      (is (vm-valid-reference-p vm addr))
      (is (not (vm-valid-reference-p vm 0)))
      (is (not (vm-valid-reference-p vm 999999999))))))

;;; --- Metadata ---

(test mark-bits
  "Authoritative mark bits in side metadata."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-object *active-plan* 2)))
      (is (not (vm-object-is-marked-p vm addr)))
      (setf (vm-object-is-marked-p vm addr) t)
      (is (vm-object-is-marked-p vm addr))
      (setf (vm-object-is-marked-p vm addr) nil)
      (is (not (vm-object-is-marked-p vm addr))))))

(test log-bits
  "Log bits in side metadata."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-object *active-plan* 2)))
      (is (not (vm-object-is-logged-p vm addr)))
      (setf (vm-object-is-logged-p vm addr) t)
      (is (vm-object-is-logged-p vm addr))
      (setf (vm-object-is-logged-p vm addr) nil)
      (is (not (vm-object-is-logged-p vm addr))))))

(test forwarding-pointers
  "Forwarding pointer set/check/clear."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-object *active-plan* 2)))
      (is (not (vm-object-is-forwarded-p vm addr)))
      (setf (vm-object-forwarding-pointer vm addr) 999)
      (is (vm-object-is-forwarded-p vm addr))
      (is (= 999 (vm-object-forwarding-pointer vm addr))))))

(test age-and-generation
  "Age and generation metadata."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-object *active-plan* 2)))
      (is (= 0 (vm-object-age vm addr)))
      (setf (vm-object-age vm addr) 5)
      (is (= 5 (vm-object-age vm addr)))
      (is (= 0 (vm-object-generation vm addr)))
      (setf (vm-object-generation vm addr) 1)
      (is (= 1 (vm-object-generation vm addr))))))

;;; --- Space ---

(test space-contains-p
  "Space containment check."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((space (plan-get-space *active-plan* :default))
           (start (* (space-start-page space) +page-size-words+))
           (end (+ start (* (space-page-count space) +page-size-words+))))
      (is (space-contains-p space start))
      (is (space-contains-p space (1- end)))
      (is (not (space-contains-p space (1+ end)))))))

;;; --- Allocators ---

(test bump-allocator
  "Bump-pointer allocator allocates without collisions."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let ((alloc (space-allocator (plan-get-space *active-plan* :default))))
      (let ((a1 (alloc alloc 10))
            (a2 (alloc alloc 20))
            (a3 (alloc alloc 5)))
        (is (not (null a1)))
        (is (not (null a2)))
        (is (not (null a3)))
        (is (not (= a1 a2)))
        (is (not (= a2 a3)))))))

(test free-list-allocator
  "Free-list allocator allocates and reuses freed space."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (alloc (space-allocator (plan-get-space *active-plan* :default))))
      (let ((a1 (alloc alloc 16)))
        (is (not (null a1)))
        (setf (vm-object-header vm a1) (make-object-header 15 :type-tag +type-tag-object+))
        (mark-object-start a1)
        (free alloc a1 16)
        (let ((a2 (alloc alloc 16)))
          (is (not (null a2))))))))

(test immix-allocator
  "Immix allocator can allocate."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (let ((alloc (space-allocator (plan-get-space *active-plan* :default))))
      (let ((a1 (alloc alloc 10))
            (a2 (alloc alloc 50)))
        (is (not (null a1)))
        (is (not (null a2)))))))

;;; --- Barrier ---

(test no-barrier-is-noop
  "No-barrier is a no-op."
  (let ((b (make-no-barrier)))
    (is (typep b 'no-barrier))
    (barrier-note-write b 100 0 200)
    (barrier-card-scan b nil (lambda (r s) (declare (ignore r s))))
    (barrier-clear-all b)))

(test object-barrier-marks-only-old-to-young
  "Object barrier only dirties card for old-to-young pointer writes."
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let* ((barrier (plan-barrier *active-plan*))
           (nursery-start (barrier-nursery-start barrier))
           (nursery-end (barrier-nursery-end barrier)))
      (barrier-clear-all barrier)
      ;; Old -> Young write must dirty the card
      (barrier-note-write barrier 0 0 nursery-start)
      (is (> (aref (barrier-card-table-cards barrier) 0) 0))
      ;; Young -> Young must not
      (barrier-clear-all barrier)
      (barrier-note-write barrier nursery-start 0 (1+ nursery-start))
      (is (= 0 (aref (barrier-card-table-cards barrier) 0)))
      ;; Young -> Old must not
      (barrier-clear-all barrier)
      (barrier-note-write barrier nursery-start 0 0)
      (is (= 0 (aref (barrier-card-table-cards barrier) 0))))))

(test object-barrier-card-scan-does-not-crash
  "barrier-card-scan runs without error."
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let ((barrier (plan-barrier *active-plan*)))
      (barrier-clear-all barrier)
      (setf (aref (barrier-card-table-cards barrier) 0) 1)
      (let ((found nil))
        (barrier-card-scan barrier (plan-vm *active-plan*)
          (lambda (s target) (push (cons s target) found)))
        (is (listp found))))))

;;; --- Tracer ---

(test tracer-enqueue-dequeue
  "Tracer ring buffer enqueue/dequeue."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (tracer (make-tracer vm (lambda (r) r) :queue-size 128)))
      (is (tracer-empty-p tracer))
      (tracer-enqueue tracer 1)
      (tracer-enqueue tracer 2)
      (tracer-enqueue tracer 3)
      (is (not (tracer-empty-p tracer)))
      (is (= 1 (tracer-dequeue tracer)))
      (is (= 2 (tracer-dequeue tracer)))
      (is (= 3 (tracer-dequeue tracer)))
      (is (tracer-empty-p tracer)))))

(test tracer-processes-reachable-objects
  "Tracer visits objects from roots."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (root (allocate-object *active-plan* 2)))
      (setf (vm-object-reference vm root 0) root)
      (clamsara-register-root root)
      (let ((tracer (make-tracer vm
                      (lambda (r)
                        (unless (vm-object-is-marked-p vm r)
                          (setf (vm-object-is-marked-p vm r) t)
                          r))
                      :queue-size 128)))
        (tracer-process-roots tracer vm *active-plan*)
        (is (vm-object-is-marked-p vm root))
        (is (> (tracer-visit-count tracer) 0))))))
