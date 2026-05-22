(in-package #:clamsara.tests)

(def-suite test-allocator :description "Allocator tests"
  :in clamsara-tests)

(in-suite test-allocator)

;;; --- Bump Allocator ---

(test bump-allocator-basic
  "Bump allocator allocates contiguous memory."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (space (plan-get-space plan :default))
           (alloc (space-allocator space)))
      (let ((a1 (alloc alloc 10))
            (a2 (alloc alloc 20))
            (a3 (alloc alloc 5)))
        (is (not (null a1)))
        (is (not (null a2)))
        (is (not (null a3)))
        (is (not (= a1 a2)))
        (is (not (= a2 a3)))))))

;;; --- Free-List Allocator ---

(test free-list-allocator-basic
  "Free-list allocator allocates from bins."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (space (plan-get-space plan :default))
           (alloc (space-allocator space)))
      (let ((a1 (alloc alloc 10))
            (a2 (alloc alloc 20)))
        (is (not (null a1)))
        (is (not (null a2)))))))

(test free-list-alloc-and-free
  "Free-list allocator can free and reallocate."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (space (plan-get-space plan :default))
           (alloc (space-allocator space)))
      (let ((a1 (alloc alloc 16)))
        (is (not (null a1)))
        ;; Write header to mark it as an object
        (setf (vm-object-header (plan-vm plan) a1)
              (make-object-header 15 :type-tag +type-tag-object+))
        (mark-object-start a1)
        (free alloc a1 16)
        ;; Should be able to allocate again
        (let ((a2 (alloc alloc 16)))
          (is (not (null a2))))))))

;;; --- Immix Allocator ---

(test immix-allocator-basic
  "Immix allocator can allocate."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (let* ((plan *active-plan*)
           (space (plan-get-space plan :default))
           (alloc (space-allocator space)))
      (let ((a1 (alloc alloc 10))
            (a2 (alloc alloc 50)))
        (is (not (null a1)))
        (is (not (null a2)))))))
