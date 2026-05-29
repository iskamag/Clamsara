(in-package #:clamsara.tests)

(def-suite test-heap :description "Heap and page table tests"
  :in clamsara-tests)

(in-suite test-heap)

(test heap-creation
  "Heap is created correctly."
  (let ((old-heap clamsara::*heap*)
        (old-size clamsara::*heap-size*))
    (unwind-protect
         (let ((vm (make-simulator-vm :heap-size 1024)))
           (is (not (null clamsara::*heap*)))
           (is (>= (length clamsara::*heap*) 1024)))
      (setf clamsara::*heap* old-heap clamsara::*heap-size* old-size))))

(test heap-read-write
  "Read and write heap words."
  (let ((old-heap clamsara::*heap*)
        (old-size clamsara::*heap-size*))
    (unwind-protect
         (let ((vm (make-simulator-vm :heap-size 1024)))
           (setf (heap-ref 0) 12345)
           (is (= 12345 (heap-ref 0)))
           (setf (heap-ref 100) 67890)
           (is (= 67890 (heap-ref 100))))
      (setf clamsara::*heap* old-heap clamsara::*heap-size* old-size))))

(test page-table-creation
  "Page table is created with correct page count."
  (let ((old-table clamsara::*page-table*))
    (unwind-protect
         (let ((vm (make-simulator-vm :heap-size +page-size-words+)))
           (is (not (null clamsara::*page-table*)))
           (is (= 1 (length clamsara::*page-table*)))
           (is (page-free-p (aref clamsara::*page-table* 0))))
      (setf clamsara::*page-table* old-table))))

(test card-table
  "Card table is created correctly."
  (let ((ct (ensure-card-table +page-size-words+)))
    (is (not (null ct)))
    (is (> (length (card-table-cards ct)) 0))))
