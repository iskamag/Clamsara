(in-package #:clamsara.tests)

(def-suite test-benchmark :description "Boehm GC benchmark on all plans"
  :in clamsara-tests)

(in-suite test-benchmark)

;;; --- Boehm Tree Benchmark ---
;;;
;;; The classic Boehm-Demers-Weiser GC benchmark: repeatedly build and
;;; discard binary trees, measuring throughput and verifying correctness.
;;;
;;; Run with: (clamsara.tests:run-benchmark :semispace)
;;;   or:   (clamsara.tests:run-all-benchmarks)

(defvar *benchmark-heap-size* 262144
  "Default heap size for the benchmark (256K words = 2 MiB).")

(defvar *benchmark-tree-depth* 14
  "Default tree depth for full benchmarks (2^15-1 = 32767 nodes).")

(defvar *benchmark-iterations* 10
  "Number of tree build/discard cycles for full benchmarks.")

(defvar *quick-tree-depth* 10
  "Tree depth for quick benchmark tests (2^11-1 = 2047 nodes).")

(defvar *quick-iterations* 5
  "Number of iterations for quick benchmark tests.")

;;; --- Tree building ---

(defun benchmark-build-tree (plan depth)
  "Build a binary tree of depth DEPTH. Returns root address, or NIL on failure.
Each node: 3 slots [depth, left, right] = 4 words."
  (let ((addr (allocate-object plan 3)))
    (unless addr
      (return-from benchmark-build-tree nil))
    (let ((vm (plan-vm plan)))
      (setf (vm-object-reference vm addr 0) depth)
      (when (> depth 0)
        (let ((left (benchmark-build-tree plan (1- depth)))
              (right (benchmark-build-tree plan (1- depth))))
          (setf (vm-object-reference vm addr 1) (or left 0))
          (setf (vm-object-reference vm addr 2) (or right 0)))))
    addr))

(defun benchmark-tree-checksum (plan addr)
  "Compute a recursive checksum of the tree for correctness verification."
  (unless (and addr (not (zerop addr)) (vm-object-start-p (plan-vm plan) addr))
    (return-from benchmark-tree-checksum 0))
  (let* ((vm (plan-vm plan))
         (depth (vm-object-reference vm addr 0)))
    (+ depth
       (if (> depth 0)
           (+ (benchmark-tree-checksum plan (vm-object-reference vm addr 1))
              (benchmark-tree-checksum plan (vm-object-reference vm addr 2)))
           0))))

(defun benchmark-expected-checksum (depth)
  "Expected checksum for a balanced binary tree where each node stores its depth.
A tree of depth D has 2^(D+1)-1 nodes. Root stores D, each child is a depth D-1 tree.
Recursively: f(D) = D + 2*f(D-1), with f(0) = 0.
Closed form: f(D) = 2^(D+1) - D - 2."
  (if (zerop depth)
      0
      (+ depth (* 2 (benchmark-expected-checksum (1- depth))))))

;;; --- Single-plan benchmark ---

(defun run-plan-benchmark (plan &key (depth *benchmark-tree-depth*)
                                    (iterations *benchmark-iterations*))
  "Run the Boehm tree benchmark on a single plan.
Returns (values total-time checksum-errors gc-count live-words)."
  (let* ((vm (plan-vm plan))
         (start-time (get-internal-run-time))
         (checksums nil)
         (stats (plan-stats plan))
         (gc-count-before (plan-stats-gc-count stats)))
    (dotimes (i iterations)
      (let* ((tree (benchmark-build-tree plan depth))
             (cs (benchmark-tree-checksum plan tree)))
        (push cs checksums))
      ;; Trigger GC periodically (ignore-errors for NoGC which can't collect)
      (when (zerop (mod (1+ i) 5))
        (ignore-errors (clamsara-gc))))
    (let* ((end-time (get-internal-run-time))
           (elapsed (/ (- end-time start-time) internal-time-units-per-second))
           (expected (benchmark-expected-checksum depth))
           (errors (count-if (lambda (cs) (/= cs expected)) checksums))
           (gc-cycles (- (plan-stats-gc-count (plan-stats plan)) gc-count-before)))
      ;; Final full GC to get live word count (skip for NoGC)
      (ignore-errors (clamsara-gc))
      (let ((live-words (getf (vm-heap-usage vm) :total-words)))
        (values elapsed errors gc-cycles live-words)))))

(defun report-benchmark (plan-type elapsed errors gc-cycles live-words)
  "Print benchmark results for a single plan type."
  (format t "~&  ~14A  ~8,3F s  ~4D errs  ~4D GCs  ~8D live words~%"
          (string-downcase (symbol-name plan-type))
          elapsed errors gc-cycles (or live-words 0)))

;;; --- Benchmarks as test assertions ---

(test boehm-tree-benchmarks
  "Boehm tree benchmark: all 9 plans produce zero checksum errors."
  (let ((plan-types '(:nogc :semispace :marksweep :immix
                      :gencopy :genms :genimmix :stickyimmix :stickyms)))
    (dolist (plan-type plan-types)
      (let ((heap-size (case plan-type
                         (:nogc 2097152)
                         ((:gencopy :genms :genimmix) 524288)
                         (t *benchmark-heap-size*))))
        (with-clamsara (:plan-type plan-type :heap-size heap-size)
          (multiple-value-bind (elapsed errors gc-cycles live-words)
              (run-plan-benchmark *active-plan*
                                  :depth *quick-tree-depth*
                                  :iterations *quick-iterations*)
            (format t "~&  ~14A  ~8,3F s  ~4D errs  ~4D GCs  ~8D live words~%"
                    (string-downcase (symbol-name plan-type))
                    elapsed errors gc-cycles (or live-words 0))
            (is (zerop errors) "~A benchmark had checksum errors." plan-type)))))))

;;; --- Public API ---

(defun run-all-benchmarks (&key (depth *benchmark-tree-depth*)
                                (iterations *benchmark-iterations*))
  "Run the Boehm tree benchmark on all 9 plan types.
Prints a summary table and returns results as a list of plists."
  (let ((plan-types '(:nogc :semispace :marksweep :immix
                      :gencopy :genms :genimmix :stickyimmix :stickyms))
        (results nil))
    (format t "~&=== Clamsara Boehm Tree Benchmark ===~%")
    (format t "~&  Depth: ~D  Iterations: ~D  Nodes/tree: ~D~%"
            depth iterations (1- (ash 1 (1+ depth))))
    (format t "~&  ~14A  ~8A  ~6A  ~6A  ~10A~%"
            "Plan" "Time" "Errs" "GCs" "Live words")
    (format t "~&  ~14A  ~8A  ~6A  ~6A  ~10A~%"
            "--------------" "--------" "------" "------" "----------")
    (dolist (plan-type plan-types)
      (handler-case
          (let ((heap-size (case plan-type
                             (:nogc 8388608)
                             ((:gencopy :genms :genimmix) 4194304)
                             (t 2097152))))
            (with-clamsara (:plan-type plan-type :heap-size heap-size)
              (multiple-value-bind (elapsed errors gc-cycles live-words)
                  (run-plan-benchmark *active-plan* :depth depth :iterations iterations)
                (report-benchmark plan-type elapsed errors gc-cycles live-words)
                (push (list :plan plan-type :time elapsed :errors errors
                            :gcs gc-cycles :live live-words)
                      results))))
        (error (e)
          (format t "~&  ~14A  FAILED: ~A~%" (string-downcase (symbol-name plan-type)) e))))
    (format t "~2%")
    (nreverse results)))

(defun run-benchmark (plan-type &key (depth *benchmark-tree-depth*)
                                    (iterations *benchmark-iterations*)
                                    (heap-size nil))
  "Run the Boehm tree benchmark on a single plan type.
PLAN-TYPE is a keyword like :semispace."
  (let ((hs (or heap-size
                (case plan-type
                  (:nogc 8388608)
                  ((:gencopy :genms :genimmix) 4194304)
                  (t 2097152)))))
    (with-clamsara (:plan-type plan-type :heap-size hs)
      (multiple-value-bind (elapsed errors gc-cycles live-words)
          (run-plan-benchmark *active-plan* :depth depth :iterations iterations)
        (format t "~&=== Benchmark: ~A ===~%" plan-type)
        (format t "~&  Depth: ~D  Iterations: ~D~%" depth iterations)
        (format t "~&  Time: ~,3F s  Errors: ~D  GC cycles: ~D  Live words: ~D~%"
                elapsed errors gc-cycles (or live-words 0))
        (values elapsed errors gc-cycles live-words)))))
