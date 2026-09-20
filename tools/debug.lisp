;;;; Native development diagnostics. Not part of collector entry code.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :asdf)
  #+sbcl (require :sb-introspect))

(defpackage #:clamsara.debug
  (:use #:cl)
  (:export #:read-source #:compile-source #:run-probe #:inspect-name #:write-report))
(in-package #:clamsara.debug)

(defun %text (object)
  (let ((*print-circle* t) (*print-level* 6) (*print-length* 24)
        (*print-pretty* nil) (*print-readably* nil))
    (write-to-string object)))

(defun %condition-data (condition)
  (list :type (%text (type-of condition))
        :message (handler-case (princ-to-string condition)
                   (error () "Condition printer failed"))
        :slots
        #+sbcl
        (loop for slot in (sb-mop:class-slots (class-of condition))
              for name = (sb-mop:slot-definition-name slot)
              when (slot-boundp condition name)
                collect (list (%text name) (%text (slot-value condition name))))
        #-sbcl nil))

(defun %backtrace ()
  #+sbcl (with-output-to-string (stream)
           (sb-debug:print-backtrace :stream stream :count 50))
  #-sbcl "Backtrace capture is implemented for SBCL only.")

#+sbcl
(defun %call-with-signal-capture (type observer function)
  ;; SBCL's native BREAK-ON-SIGNALS runs before inner HANDLER-CASE handlers.
  ;; Continue that diagnostic break; do not replace the program's handlers.
  (let* ((previous-hook sb-ext:*invoke-debugger-hook*)
         (*break-on-signals* type)
         (sb-ext:*invoke-debugger-hook*
           (lambda (condition hook)
             (let ((continuation (find-restart 'continue condition)))
               (if (and (typep condition 'simple-condition) continuation
                        (search "BREAK-ON-SIGNALS" (princ-to-string condition)))
                   (let ((*break-on-signals* nil))
                     (funcall observer
                              (or (find-if (lambda (value) (typep value 'condition))
                                           (simple-condition-format-arguments condition))
                                  condition))
                     (invoke-restart continuation))
                   (when previous-hook (funcall previous-hook condition hook)))))))
    (funcall function)))

(defun run-probe (name function &key trace-signals)
  "Call FUNCTION and retain pre-unwind errors, condition slots and backtraces.
TRACE-SIGNALS is an optional native SBCL BREAK-ON-SIGNALS type (e.g. ERROR),
which also captures signals hidden by inner HANDLER-CASE. It does not change
handler outcomes. Debug instrumentation allocates; this is not target evidence."
  (let ((observed nil) (seen nil) (started (get-internal-real-time)))
    (labels ((observe (condition)
               (unless (member condition seen :test #'eq)
                 (push condition seen)
                 (push (list :condition (%condition-data condition)
                             :backtrace (%backtrace)) observed)))
             (result (status values failure)
               (list :probe name :status status :values values :failure failure
                     :conditions (nreverse observed)
                     :elapsed-seconds
                     (/ (- (get-internal-real-time) started)
                        (float internal-time-units-per-second)))))
      (handler-case
          (handler-bind ((error #'observe))
            (result :ok
                    (mapcar #'%text
                            (multiple-value-list
                             (if trace-signals
                                 #+sbcl (%call-with-signal-capture trace-signals #'observe function)
                                 #-sbcl (error "TRACE-SIGNALS requires SBCL")
                                 (funcall function)))) nil))
        (error (condition) (result :failed nil (%condition-data condition)))))))

(defun %source-line (text position)
  (1+ (count #\Newline text :end (min (length text) (or position 0)))))

(defun %context (text position)
  (let* ((line (%source-line text position))
         (lines (uiop:split-string text :separator '(#\Newline))))
    (loop for contents in lines for number from 1
          when (<= (max 1 (- line 2)) number (+ line 2))
            collect (list number contents))))

(defun %definition-p (form)
  (and (consp form)
       (member (car form)
               '(defun defmacro defgeneric defmethod defclass defstruct
                 define-condition defpackage defvar defparameter defconstant)
               :test #'eq)))

(defun %nested-definitions (form)
  ;; Definitions under top-level PROGN/EVAL-WHEN/LOCALLY are legitimate.
  ;; Quoted data and backquote templates are not inspected as executable code.
  (let ((answer nil))
    (labels ((walk (node top-level-p enclosing path)
               (when (consp node)
                 (unless (member (car node) '(quote function) :test #'eq)
                   (let* ((definition-p (%definition-p node))
                          (next-enclosing (if definition-p (%text (second node)) enclosing))
                          (wrapper-p (member (car node) '(progn eval-when locally) :test #'eq)))
                     (when (and definition-p (not top-level-p))
                       (push (list :operator (%text (first node))
                                   :name (%text (second node)) :inside enclosing
                                   :path (reverse path)) answer))
                     (loop for child in (cdr node) for index from 1
                           do (walk child (and top-level-p wrapper-p)
                                    next-enclosing (cons index path))))))))
      (walk form t nil nil))
    (nreverse answer)))

(defun read-source (pathname)
  "Read trusted Lisp source with its native reader, without loading definitions.
Load required packages first. #. retains normal trusted-source reader semantics.
Report definitions hidden inside bodies, plus reader position/source context."
  (let ((text (uiop:read-file-string pathname)) (forms nil) (suspects nil)
        (start 0) (number 0) (*package* *package*))
    (with-open-file (stream pathname)
      (handler-case
          (loop
            (setf start (file-position stream))
            (let ((form (read stream nil stream)))
              (when (eq form stream)
                (return (list :source (namestring (pathname pathname)) :status :ok
                              :form-count number :forms (nreverse forms)
                              :nested-definitions (nreverse suspects))))
              (incf number)
              (push (list :index number :offset start :line (%source-line text start)
                          :operator (and (consp form) (%text (first form)))
                          :name (and (%definition-p form) (%text (second form)))) forms)
              (dolist (suspect (%nested-definitions form))
                (push (list :form-index number :line (%source-line text start)
                            :definition suspect) suspects))
              (when (and (consp form) (eq (first form) 'in-package))
                (setf *package* (or (find-package (second form))
                                    (error "Package ~S is absent; load its protocol first."
                                           (second form)))))))
        (error (condition)
          (list :source (namestring (pathname pathname)) :status :failed
                :form-count number :form-start-offset start
                :reader-position (file-position stream)
                :form-context (%context text start)
                :reader-context (%context text (file-position stream))
                :condition (%condition-data condition)
                :forms (nreverse forms) :nested-definitions (nreverse suspects)))))))

(defun compile-source (pathname &key output-file)
  "Compile through the native compiler; report warnings AND failure-p.
Prerequisites must be loaded normally. This function never installs stubs."
  (let ((conditions nil) (native-result nil))
    (let ((probe
            (run-probe
             (namestring (pathname pathname))
             (lambda ()
               (handler-bind
                   ((warning (lambda (condition)
                               (push (%condition-data condition) conditions))))
                 (multiple-value-bind (output warnings-p failure-p)
                     (if output-file (compile-file pathname :output-file output-file)
                         (compile-file pathname))
                   (setf native-result
                         (list :output (and output (namestring output))
                               :warnings-p warnings-p :failure-p failure-p))
                   (when failure-p
                     (error "Native COMPILE-FILE reported failure for ~A" pathname))
                   native-result))))))
      (append probe (list :native-result native-result
                          :compiler-conditions (nreverse conditions))))))

(defun inspect-name (name &optional (package :clamsara))
  "Inspect a real loaded symbol, including native generic method signatures."
  (multiple-value-bind (symbol status) (find-symbol (string name) package)
    (unless symbol (return-from inspect-name (list :name name :status :absent)))
    (let* ((function (and (fboundp symbol) (fdefinition symbol)))
           (class (find-class symbol nil)))
      (list :name (%text symbol) :access status
            :value (and (boundp symbol) (%text (symbol-value symbol)))
            :function-p (not (null function)) :class-p (not (null class))
            :lambda-list #+sbcl (and function
                                    (%text (sb-introspect:function-lambda-list function)))
                         #-sbcl nil
            :methods #+sbcl
            (when (typep function 'generic-function)
              (loop for method in (sb-mop:generic-function-methods function)
                    collect (list :qualifiers (%text (method-qualifiers method))
                                  :lambda-list (%text (sb-mop:method-lambda-list method))
                                  :specializers
                                  (mapcar #'%text (sb-mop:method-specializers method)))))
            #-sbcl nil))))

(defun write-report (report &optional (stream *standard-output*))
  "Write a readable S-expression, suitable for another Lisp process or a log."
  ;; Report leaves are already strings, numbers, symbols and lists. Normal
  ;; WRITE keeps strings readable without SBCL's base-char #A type annotation.
  (let ((*print-circle* t) (*print-readably* nil) (*print-pretty* t)
        (*print-level* nil) (*print-length* nil))
    (write report :stream stream) (terpri stream))
  report)
