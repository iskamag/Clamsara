;;;; Regression tests for the structural quality gate.
(defpackage #:clamsara.structure.test
  (:use #:cl)
  (:export #:run-structure-fixture-tests #:run-structure-tests))
(in-package #:clamsara.structure.test)

(defvar *checks* 0)

(defun %check (truth format-control &rest arguments)
  (incf *checks*)
  (unless truth
    (error "Structure test failed: ~?" format-control arguments)))

(defun %write-text (pathname text)
  (ensure-directories-exist pathname)
  (with-open-file (stream pathname :direction :output :if-exists :supersede
                                   :if-does-not-exist :create)
    (write-string text stream))
  pathname)

(defun %temporary-root ()
  (let ((root (merge-pathnames
               (format nil "clamsara-structure-~D-~D/"
                       (get-universal-time) (random most-positive-fixnum))
               (uiop:temporary-directory))))
    (ensure-directories-exist (merge-pathnames "placeholder" root))
    root))

(defmacro %with-temporary-root ((variable) &body body)
  `(let ((,variable (%temporary-root)))
     (unwind-protect (progn ,@body)
       (when (probe-file ,variable)
         (uiop:delete-directory-tree ,variable :validate t :if-does-not-exist :ignore)))))

(defun %codes (report)
  (mapcar (lambda (issue) (getf issue :code)) (getf report :issues)))

(defun %assertion-rejects-p (pathname &rest arguments)
  (handler-case
      (progn
        (apply #'clamsara.structure:assert-source-structure
               (list pathname) arguments)
        nil)
    (clamsara.structure:structure-check-failed (condition)
      (eq (getf (clamsara.structure:structure-check-report condition) :status)
          :failed))))

(defun %expect-defect (source code)
  (%with-temporary-root (root)
    (let* ((pathname (%write-text (merge-pathnames "fixture.lisp" root) source))
           (report (clamsara.structure:check-source-files
                    (list pathname)
                    :expected-package :clamsara.structure.test)))
      (%check (eq (getf report :status) :failed)
              "injected ~S defect was accepted: ~S" code report)
      (%check (member code (%codes report) :test #'eq)
              "expected ~S, got issue codes ~S" code (%codes report))
      (%check (%assertion-rejects-p
               pathname :expected-package :clamsara.structure.test)
              "asserting entry point did not reject ~S" code))))

(defun %test-clean-native-compile-and-introspection ()
  (%with-temporary-root (root)
    (let* ((source (%write-text
                    (merge-pathnames "native-clean.lisp" root)
                    "(in-package #:clamsara.structure.test)
(defgeneric fixture-native-generic (object &key token))
(defmethod fixture-native-generic ((object integer) &key token)
  (declare (ignore token)) object)
(defun fixture-native-function (object) object)
(defmacro fixture-native-dotted (head . tail)
  (declare (ignore head tail)) nil)
(defun (setf fixture-native-function) (new object)
  (declare (ignore object)) new)
"))
           (fasl (merge-pathnames "native-clean.fasl" root)))
      (multiple-value-bind (output warnings-p failure-p)
          (compile-file source :output-file fasl)
        (declare (ignore warnings-p))
        (%check (and output (not failure-p))
                "native COMPILE-FILE failed for clean fixture")
        (load output))
      (let ((report
              (clamsara.structure:check-source-files
               (list source) :expected-package :clamsara.structure.test
               :inspect-loaded t)))
        (%check (eq (getf report :status) :ok)
                "clean compiled/introspected fixture failed: ~S" report)))))

(defun %test-deliberate-source-defects ()
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defun duplicate-ordinary (x) x)
(defun duplicate-ordinary (x) (1+ x))
"
   :duplicate-function-definition)
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defun (setf duplicate-setter) (new object) (declare (ignore object)) new)
(defun (setf duplicate-setter) (new object) (declare (ignore object)) new)
"
   :duplicate-function-definition)
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defgeneric duplicate-method (x))
(defmethod duplicate-method :around ((x integer)) (call-next-method))
(defmethod duplicate-method :around ((x integer)) (call-next-method))
"
   :duplicate-method-definition)
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defgeneric incongruent-method (x &key required-key))
(defmethod incongruent-method ((x integer) &key different-key)
  (declare (ignore different-key)) x)
"
   :incongruent-method-lambda-list)
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defun contains-hidden-definition (x)
  (when x (defun swallowed-definition () :hidden)) x)
"
   :nested-definition)
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defun function-macro-collision (x) x)
(defmacro function-macro-collision (x) x)
"
   :function-namespace-collision)
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defclass type-collision () ())
(deftype type-collision () 't)
"
   :type-namespace-collision)
  (%expect-defect
   "(in-package #:clamsara.structure.test)
(defun cl:car (object) object)
"
   :foreign-package-definition))

(defun %test-legitimate-distinct-methods ()
  (%with-temporary-root (root)
    (let* ((source
             (%write-text
              (merge-pathnames "distinct-methods.lisp" root)
              "(in-package #:clamsara.structure.test)
(defgeneric distinct-method (x &key token))
(defmethod distinct-method :before ((x integer) &key token)
  (declare (ignore token)))
(defmethod distinct-method :after ((x integer) &key token)
  (declare (ignore token)))
(defmethod distinct-method :before ((x string) &key token)
  (declare (ignore token)))
"))
           (report (clamsara.structure:check-source-files
                    (list source)
                    :expected-package :clamsara.structure.test)))
      (%check (eq (getf report :status) :ok)
              "distinct qualifier/specializer methods were rejected: ~S" report))))

(defun %test-stale-versioned-path-and-system ()
  (%with-temporary-root (root)
    (%write-text (merge-pathnames "src/v14/stale.lisp" root)
                 "(in-package #:clamsara)
")
    (%write-text (merge-pathnames "clamsara.asd" root)
                 "(asdf:defsystem :clamsara-v14 :components ())
")
    (let* ((report (clamsara.structure:check-project-structure
                    :root root :inspect-loaded nil))
           (codes (%codes report)))
      (%check (eq (getf report :status) :failed)
              "versioned path/system fixture was accepted")
      (%check (member :stale-versioned-source-path codes :test #'eq)
              "versioned source path was not reported: ~S" report)
      (%check (member :stale-versioned-system-alias codes :test #'eq)
              "versioned system alias was not reported: ~S" report))))

(defun run-structure-fixture-tests ()
  "Run injected-defect, native-reader, compiler, and introspection regressions."
  (let ((*checks* 0))
    (%test-clean-native-compile-and-introspection)
    (%test-deliberate-source-defects)
    (%test-legitimate-distinct-methods)
    (%test-stale-versioned-path-and-system)
    (format t "~&Structure fixture tests passed (~D checks).~%" *checks*)
    t))

(defun run-structure-tests ()
  "Run fixture regressions, then fail unless the canonical production tree is clean."
  (run-structure-fixture-tests)
  (let ((report (clamsara.structure:check-project-structure)))
    (clamsara.structure:write-structure-report report)
    (unless (eq (getf report :status) :ok)
      (error 'clamsara.structure:structure-check-failed :report report)))
  t)
