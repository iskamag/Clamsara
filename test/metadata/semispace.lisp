;;;; Real runtime SemiSpace metadata-representation coverage.
;;;; This test deliberately reuses the executable two-object collection cycle in
;;;; test/runtime/semispace.lisp.  It runs that cycle once with packed object
;;;; starts and once with scalar object starts, without changing runtime code.

(defpackage #:clamsara.metadata.semispace.test
  (:use #:cl #:clamsara)
  (:export #:run-metadata-semispace-runtime-tests))
(in-package #:clamsara.metadata.semispace.test)

(defun %run-one (label constructor expected-class)
  (let* ((name 'clamsara::make-object-start-marks)
         (previous (symbol-function name))
         (seen nil))
    (unwind-protect
         (progn
           ;; The runtime lifecycle fixture calls this constructor for each
           ;; of its two spaces.  Capture both instances while preserving the
           ;; fixture's real construction, initialization, and collect path.
           (setf (symbol-function name)
                 (lambda (&rest initargs)
                   (let ((map (apply constructor initargs)))
                     (push map seen)
                     map)))
           (unless (and (fboundp 'clamsara.runtime.test:run-v14-runtime-tests)
                        (clamsara.runtime.test:run-v14-runtime-tests))
             (error "~S SemiSpace lifecycle did not complete" label)))
      (setf (symbol-function name) previous))
    (unless (and (= (length seen) 2)
                 (every (lambda (map) (typep map expected-class)) seen))
      (error "~S lifecycle did not use two ~S object-start stores: ~S"
             label expected-class seen))
    (format t "~&METADATA-SEMISPACE-~A-CYCLE-OK~%" label)
    t))

(defun run-metadata-semispace-runtime-tests ()
  (unless (fboundp 'clamsara.runtime.test:run-v14-runtime-tests)
    (error "Load test/runtime/semispace.lisp before this metadata test"))
  (%run-one :PACKED #'make-object-start-marks 'object-start-marks)
  (%run-one :SCALAR #'make-scalar-object-start-marks 'scalar-object-start-marks)
  t)
