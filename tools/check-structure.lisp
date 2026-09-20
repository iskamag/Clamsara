;;;; Structural quality gate for canonical Clamsara sources.
;;;; This is development tooling. It is not collector entry code and is not
;;;; evidence about allocation freedom or collector semantics.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :asdf))

(defpackage #:clamsara.structure
  (:use #:cl)
  (:export #:check-source-files
           #:check-project-structure
           #:assert-source-structure
           #:assert-project-structure
           #:structure-check-failed
           #:structure-check-report
           #:write-structure-report))
(in-package #:clamsara.structure)

(define-condition structure-check-failed (error)
  ((report :initarg :report :reader structure-check-report))
  (:report (lambda (condition stream)
             (let* ((report (structure-check-report condition))
                    (issues (getf report :issues)))
               (format stream "Structural quality gate found ~D issue~:P."
                       (length issues))))))

(defstruct (source-definition
             (:constructor %make-source-definition
                 (operator name lambda-list qualifiers specializers location)))
  operator name lambda-list qualifiers specializers location)

(defstruct (lambda-shape (:constructor %make-lambda-shape))
  (required 0) (optional 0) (rest-p nil) (key-p nil)
  (keys nil) (allow-other-keys-p nil))

;; The whitelist is intentionally exact and empty. Additions must name one
;; issue code and one Lisp name, and must carry a non-empty reason.
(defparameter *project-duplicate-whitelist* '())

;; This method extends the standard initialization protocol; it does not
;; introduce or replace a function in COMMON-LISP.
(defparameter *project-foreign-method-whitelist*
  '(("COMMON-LISP::INITIALIZE-INSTANCE"
     . "METADATA-STORAGE adds an :AFTER method to the standard initialization protocol.")
    ("CLOSTRUM-BASIC::MAKE-VARIABLE-CELL"
     . "WORKLOAD-MACLINA-CLIENT registers Clostrum global cells as managed roots.")
    ("MACLINA.COMPILE::COMPILE-COMBINATION"
     . "An :AROUND method scopes compiler syntax execution only for WORKLOAD-MACLINA-CLIENT.")
    ("MACLINA.MACHINE::COMPUTE-INSTANCE-FUNCTION"
     . "WORKLOAD-MACLINA-CLIENT supplies compiler-phase data entries without replacing function identities.")))

(defparameter *definition-operators*
  '(defun defmacro defgeneric defmethod defclass defstruct define-condition
    deftype defvar defparameter defconstant define-symbol-macro))

(defun %operator-p (object name)
  (and (symbolp object) (eq object name)))

(defun %definition-operator-p (object)
  (and (symbolp object)
       (member object *definition-operators* :test #'eq)))

(defun %definition-name (form)
  (let ((operator (first form)) (raw-name (second form)))
    (cond ((eq operator 'defstruct)
           (if (consp raw-name) (first raw-name) raw-name))
          (t raw-name))))

(defun %definition-lambda-list (form)
  (case (first form)
    ((defun defmacro defgeneric) (third form))
    (defmethod
     (find-if #'listp (cddr form)))
    (otherwise nil)))

(defun %method-qualifiers-and-lambda-list (form)
  (let ((tail (cddr form)) (qualifiers nil))
    (loop while (and tail (not (listp (first tail))))
          do (push (pop tail) qualifiers))
    (values (nreverse qualifiers) (first tail))))

(defun %required-specializers (lambda-list)
  (loop for parameter in lambda-list
        until (and (symbolp parameter)
                   (> (length (symbol-name parameter)) 0)
                   (char= (char (symbol-name parameter) 0) #\&))
        collect (if (and (consp parameter) (second parameter))
                    (second parameter)
                    t)))

(defun %definition-from-form (form location)
  (let ((operator (first form)))
    (if (eq operator 'defmethod)
        (multiple-value-bind (qualifiers lambda-list)
            (%method-qualifiers-and-lambda-list form)
          (%make-source-definition operator (%definition-name form) lambda-list
                                   qualifiers
                                   (%required-specializers lambda-list)
                                   location))
        (%make-source-definition operator (%definition-name form)
                                 (%definition-lambda-list form) nil nil location))))

(defun %source-line (text position)
  (1+ (count #\Newline text :end (min (length text) (or position 0)))))

(defun %location (pathname form-index offset line &optional path)
  (list :file (namestring (pathname pathname)) :form-index form-index
        :offset offset :line line :path path))

(defun %quoted-form-p (form)
  (and (consp form)
       (let ((operator (first form)))
         (or (eq operator 'quote)
             (eq operator 'function)
             (and (symbolp operator)
                  (string= (symbol-name operator) "QUASIQUOTE"))))))

(defun %walk-source-form (form top-level-p location emit-definition emit-issue
                           &optional enclosing (path nil))
  (when (consp form)
    (unless (%quoted-form-p form)
      (let ((operator (first form)))
        (cond
          ((and top-level-p (eq operator 'progn))
           (loop for child in (rest form) for index from 1
                 do (%walk-source-form child t location emit-definition emit-issue
                                      enclosing (cons index path))))
          ((and top-level-p (eq operator 'eval-when))
           ;; The situation list is syntax, not an executable body.
           (loop for child in (cddr form) for index from 2
                 do (%walk-source-form child t location emit-definition emit-issue
                                      enclosing (cons index path))))
          ((and top-level-p (eq operator 'locally))
           (loop for child in (rest form) for index from 1
                 do (%walk-source-form child t location emit-definition emit-issue
                                      enclosing (cons index path))))
          ((and top-level-p (member operator '(macrolet symbol-macrolet)
                                    :test #'eq))
           ;; Binding definitions are local code. Only the body retains
           ;; top-level processing semantics.
           (%walk-source-form (second form) nil location emit-definition emit-issue
                              enclosing (cons 1 path))
           (loop for child in (cddr form) for index from 2
                 do (%walk-source-form child t location emit-definition emit-issue
                                      enclosing (cons index path))))
          (t
           (let* ((definition-p (%definition-operator-p operator))
                  (name (and definition-p (%definition-name form)))
                  (next-enclosing (if definition-p name enclosing)))
             (when definition-p
               (if top-level-p
                   (funcall emit-definition (%definition-from-form form location))
                   (funcall emit-issue
                            (list :code :nested-definition
                                  :operator operator :name name
                                  :inside enclosing
                                  :location (append location
                                                    (list :path (reverse path)))))))
             (loop for child in (rest form) for index from 1
                   do (%walk-source-form child nil location emit-definition emit-issue
                                        next-enclosing (cons index path))))))))))

(defun %package-designator (form)
  (let ((value (second form)))
    (typecase value
      (package value)
      (symbol (symbol-name value))
      (string value)
      (t value))))

(defun %read-source-file (pathname)
  "Read PATHNAME with the native Lisp reader and return definitions and issues."
  (let ((text (uiop:read-file-string pathname))
        (definitions nil) (issues nil) (form-index 0) (offset 0)
        (*package* *package*))
    (labels ((emit-definition (definition) (push definition definitions))
             (emit-issue (issue) (push issue issues)))
      (with-open-file (stream pathname :direction :input)
        (handler-case
            (loop
              (setf offset (file-position stream))
              (let ((form (read stream nil stream)))
                (when (eq form stream) (return))
                (incf form-index)
                (let ((location (%location pathname form-index offset
                                           (%source-line text offset))))
                  (%walk-source-form form t location
                                     #'emit-definition #'emit-issue)
                  (when (and (consp form) (eq (first form) 'in-package))
                    (let ((package (find-package (%package-designator form))))
                      (if package
                          (setf *package* package)
                          (emit-issue
                           (list :code :missing-reader-package
                                 :package (%package-designator form)
                                 :location location))))))))
          (error (condition)
            (emit-issue
             (list :code :reader-error :location (%location pathname form-index
                                                              offset
                                                              (%source-line text offset))
                   :reader-position (file-position stream)
                   :condition-type (type-of condition)
                   :message (princ-to-string condition))))))
      (values (nreverse definitions) (nreverse issues)))))

(defun %function-name-symbol (name)
  (cond ((symbolp name) name)
        ((and (consp name) (eq (first name) 'setf)
              (symbolp (second name)) (null (cddr name)))
         (second name))
        (t nil)))

(defun %name-string (name)
  (labels ((symbol-text (symbol)
             (let ((package (symbol-package symbol)))
               (if package
                   (format nil "~A::~A" (package-name package) (symbol-name symbol))
                   (format nil "#:~A" (symbol-name symbol))))))
    (if (and (consp name) (eq (first name) 'setf))
        (format nil "(SETF ~A)" (symbol-text (second name)))
        (if (symbolp name) (symbol-text name) (prin1-to-string name)))))

(defun %location-of (definition)
  (source-definition-location definition))

(defun %duplicate-whitelisted-p (code name whitelist)
  (some (lambda (entry)
          (and (listp entry)
               (eq (getf entry :code) code)
               (equal (getf entry :name) name)
               (let ((reason (getf entry :reason)))
                 (and (stringp reason) (plusp (length reason))))))
        whitelist))

(defun %duplicate-issue (code name first second whitelist)
  (unless (%duplicate-whitelisted-p code name whitelist)
    (list :code code :name (%name-string name)
          :first (%location-of first) :second (%location-of second))))

(defun %collect-duplicate-issues (definitions whitelist)
  (let ((function-table (make-hash-table :test #'equal))
        (method-table (make-hash-table :test #'equal))
        (class-table (make-hash-table :test #'eq))
        (value-table (make-hash-table :test #'eq))
        (issues nil))
    (dolist (definition definitions)
      (let ((operator (source-definition-operator definition))
            (name (source-definition-name definition)))
        (cond
          ((member operator '(defun defmacro defgeneric) :test #'eq)
           (let ((previous (gethash name function-table)))
             (when previous
               (let* ((same-operator (eq operator
                                         (source-definition-operator previous)))
                      (code (cond ((not same-operator)
                                   :function-namespace-collision)
                                  ((eq operator 'defun)
                                   :duplicate-function-definition)
                                  ((eq operator 'defgeneric)
                                   :duplicate-generic-definition)
                                  (t :duplicate-macro-definition)))
                      (issue (%duplicate-issue code name previous definition whitelist)))
                 (when issue (push issue issues))))
             (unless previous (setf (gethash name function-table) definition))))
          ((eq operator 'defmethod)
           (let* ((key (list name
                             (source-definition-qualifiers definition)
                             (source-definition-specializers definition)))
                  (previous (gethash key method-table)))
             (when previous
               (let ((issue (%duplicate-issue :duplicate-method-definition
                                              key previous definition whitelist)))
                 (when issue
                   ;; Present the generic name separately from its exact key.
                   (setf (getf issue :name) (%name-string name)
                         (getf issue :qualifiers)
                         (source-definition-qualifiers definition)
                         (getf issue :specializers)
                         (source-definition-specializers definition))
                   (push issue issues))))
             (unless previous (setf (gethash key method-table) definition))))
          ((member operator '(defclass defstruct define-condition deftype) :test #'eq)
           (let ((previous (and (symbolp name) (gethash name class-table))))
             (when previous
               (let ((issue (%duplicate-issue :type-namespace-collision
                                              name previous definition whitelist)))
                 (when issue (push issue issues))))
             (when (and (symbolp name) (null previous))
               (setf (gethash name class-table) definition))))
          ((member operator '(defvar defparameter defconstant define-symbol-macro)
                   :test #'eq)
           (let ((previous (and (symbolp name) (gethash name value-table))))
             (when previous
               (let ((issue (%duplicate-issue :value-namespace-collision
                                              name previous definition whitelist)))
                 (when issue (push issue issues))))
             (when (and (symbolp name) (null previous))
               (setf (gethash name value-table) definition)))))))
    (nreverse issues)))

(defun %lambda-keyword-p (object)
  (and (symbolp object)
       (plusp (length (symbol-name object)))
       (char= (char (symbol-name object) 0) #\&)))

(defun %keyword-parameter-name (parameter)
  (let ((head (if (consp parameter) (first parameter) parameter)))
    (cond ((and (consp head) (symbolp (first head)))
           (symbol-name (first head)))
          ((symbolp head) (symbol-name head))
          (t (prin1-to-string head)))))

(defun %lambda-shape (lambda-list)
  (let ((shape (%make-lambda-shape)) (state :required))
    (dolist (item lambda-list shape)
      (if (%lambda-keyword-p item)
          (let ((name (symbol-name item)))
            (cond ((string= name "&OPTIONAL") (setf state :optional))
                  ((or (string= name "&REST") (string= name "&BODY"))
                   (setf (lambda-shape-rest-p shape) t state :rest-variable))
                  ((string= name "&KEY")
                   (setf (lambda-shape-key-p shape) t state :key))
                  ((string= name "&ALLOW-OTHER-KEYS")
                   (setf (lambda-shape-allow-other-keys-p shape) t))
                  ((string= name "&AUX") (setf state :aux))
                  ;; Generic-function implementation extensions do not alter
                  ;; ordinary method congruence counts.
                  ((member name '("&ENVIRONMENT" "&WHOLE") :test #'string=)
                   (setf state :ignored-variable))
                  (t (setf state :ignored))))
          (case state
            (:required (incf (lambda-shape-required shape)))
            (:optional (incf (lambda-shape-optional shape)))
            (:rest-variable (setf state :after-rest))
            (:key (pushnew (%keyword-parameter-name item)
                           (lambda-shape-keys shape) :test #'string=))
            (:ignored-variable (setf state :ignored)))))))

(defun %shape-data (shape)
  (list :required (lambda-shape-required shape)
        :optional (lambda-shape-optional shape)
        :rest-p (lambda-shape-rest-p shape)
        :key-p (lambda-shape-key-p shape)
        :keys (sort (copy-list (lambda-shape-keys shape)) #'string<)
        :allow-other-keys-p (lambda-shape-allow-other-keys-p shape)))

(defun %lambda-congruence-reason (generic-shape method-shape)
  (cond
    ((/= (lambda-shape-required generic-shape)
         (lambda-shape-required method-shape))
     :required-parameter-count)
    ((/= (lambda-shape-optional generic-shape)
         (lambda-shape-optional method-shape))
     :optional-parameter-count)
    ((not (eql (or (lambda-shape-rest-p generic-shape)
                   (lambda-shape-key-p generic-shape))
               (or (lambda-shape-rest-p method-shape)
                   (lambda-shape-key-p method-shape))))
     :rest-or-key-presence)
    ((and (lambda-shape-key-p generic-shape)
          (not (lambda-shape-allow-other-keys-p generic-shape))
          (not (lambda-shape-allow-other-keys-p method-shape))
          ;; &REST without &KEY accepts every keyword. With &KEY, normal
          ;; keyword validation still applies.
          (not (and (lambda-shape-rest-p method-shape)
                    (not (lambda-shape-key-p method-shape))))
          (not (subsetp (lambda-shape-keys generic-shape)
                        (lambda-shape-keys method-shape) :test #'string=)))
     :generic-keywords)
    (t nil)))

(defun %collect-static-congruence-issues (definitions)
  (let ((generics (make-hash-table :test #'equal))
        (methods (make-hash-table :test #'equal))
        (issues nil))
    (dolist (definition definitions)
      (case (source-definition-operator definition)
        (defgeneric
         (unless (gethash (source-definition-name definition) generics)
           (setf (gethash (source-definition-name definition) generics)
                 definition)))
        (defmethod
         (push definition (gethash (source-definition-name definition) methods)))))
    (maphash
     (lambda (name method-definitions)
       (let* ((generic (gethash name generics))
              (generic-shape
                (if generic
                    (%lambda-shape (source-definition-lambda-list generic))
                    ;; An implicit generic created by DEFMETHOD preserves the
                    ;; arity and variadic kind but does not retain method key names.
                    (let ((shape (%lambda-shape
                                  (source-definition-lambda-list
                                   (car (last method-definitions))))))
                      (setf (lambda-shape-keys shape) nil
                            (lambda-shape-allow-other-keys-p shape) nil)
                      shape))))
         (dolist (method method-definitions)
           (let* ((method-shape
                    (%lambda-shape (source-definition-lambda-list method)))
                  (reason (%lambda-congruence-reason generic-shape method-shape)))
             (when reason
               (push (list :code :incongruent-method-lambda-list
                           :name (%name-string name) :reason reason
                           :generic-lambda-list
                           (and generic (source-definition-lambda-list generic))
                           :generic-shape (%shape-data generic-shape)
                           :generic-location (and generic (%location-of generic))
                           :method-lambda-list
                           (source-definition-lambda-list method)
                           :method-shape (%shape-data method-shape)
                           :method-location (%location-of method))
                     issues))))))
     methods)
    (nreverse issues)))

(defun %foreign-method-whitelisted-p (name whitelist)
  (let ((name-string (%name-string name)))
    (some (lambda (entry)
            (and (consp entry) (string= name-string (car entry))
                 (stringp (cdr entry)) (plusp (length (cdr entry)))))
          whitelist)))

(defun %collect-package-issues (definitions expected-package foreign-method-whitelist)
  (let ((package (and expected-package (find-package expected-package)))
        (issues nil))
    (when (and expected-package (null package))
      (push (list :code :missing-expected-package :package expected-package) issues))
    (when package
      (dolist (definition definitions)
        (let* ((operator (source-definition-operator definition))
               (name (source-definition-name definition))
               (symbol (%function-name-symbol name)))
          (when (and symbol (not (eq (symbol-package symbol) package)))
            (unless (and (eq operator 'defmethod)
                         (%foreign-method-whitelisted-p
                          name foreign-method-whitelist))
              (push (list :code :foreign-package-definition
                          :operator operator :name (%name-string name)
                          :expected-package (package-name package)
                          :actual-package (and (symbol-package symbol)
                                               (package-name
                                                (symbol-package symbol)))
                          :location (%location-of definition))
                    issues))))))
    (nreverse issues)))

#+sbcl
(defun %generic-function-p (function)
  (typep function 'generic-function))
#-sbcl
(defun %generic-function-p (function)
  (typep function 'generic-function))

#+sbcl
(defun %loaded-generic-lambda-list (generic)
  (sb-mop:generic-function-lambda-list generic))
#-sbcl
(defun %loaded-generic-lambda-list (generic)
  (declare (ignore generic)) nil)

(defun %under-workload-p (pathname)
  (member "workload" (pathname-directory (pathname pathname))
          :test #'string-equal))

(defun %collect-loaded-issues (definitions &key include-optional-loaded)
  (let ((issues nil))
    (dolist (definition definitions)
      (unless (and (%under-workload-p
                    (getf (source-definition-location definition) :file))
                   (not include-optional-loaded))
        (let ((operator (source-definition-operator definition))
              (name (source-definition-name definition)))
          (when (member operator '(defun defmacro defgeneric defmethod) :test #'eq)
            (cond
              ((not (fboundp name))
               (push (list :code :missing-loaded-function
                           :operator operator :name (%name-string name)
                           :location (%location-of definition)) issues))
              (t
               (let ((function (fdefinition name)))
                 (cond
                   ((and (eq operator 'defgeneric)
                         (not (%generic-function-p function)))
                    (push (list :code :loaded-function-kind-mismatch
                                :operator operator :name (%name-string name)
                                :actual (type-of function)
                                :location (%location-of definition)) issues))
                   ((and (eq operator 'defun)
                         (or (%generic-function-p function)
                             (macro-function (%function-name-symbol name))))
                    (push (list :code :loaded-function-kind-mismatch
                                :operator operator :name (%name-string name)
                                :actual (type-of function)
                                :location (%location-of definition)) issues))
                   ((and (eq operator 'defmacro)
                         (null (macro-function (%function-name-symbol name))))
                    (push (list :code :loaded-function-kind-mismatch
                                :operator operator :name (%name-string name)
                                :actual (type-of function)
                                :location (%location-of definition)) issues)))
                 (when (and (member operator '(defgeneric defmethod) :test #'eq)
                            (%generic-function-p function))
                   (let* ((generic-shape
                            (%lambda-shape
                             (%loaded-generic-lambda-list function)))
                          (candidate-lambda
                            (source-definition-lambda-list definition))
                          (method-shape (and (eq operator 'defmethod)
                                             (%lambda-shape candidate-lambda)))
                          (reason (and method-shape
                                       (%lambda-congruence-reason generic-shape
                                                                   method-shape))))
                     (when reason
                       (push (list :code :loaded-generic-incongruence
                                   :name (%name-string name) :reason reason
                                   :loaded-generic-lambda-list
                                   (%loaded-generic-lambda-list function)
                                   :source-method-lambda-list candidate-lambda
                                   :location (%location-of definition))
                             issues)))))))))))
    (nreverse issues)))

(defun %lisp-source-files (directory)
  (labels ((walk (dir)
             (append
              (remove-if-not
               (lambda (path)
                 (string-equal (or (pathname-type path) "") "lisp"))
               (uiop:directory-files dir))
              (mapcan #'walk (uiop:subdirectories dir)))))
    (sort (walk (uiop:ensure-directory-pathname directory))
          #'string< :key #'namestring)))

(defun %pathname-under-root-p (pathname root)
  (let ((path (namestring (truename pathname)))
        (root-name (namestring (truename (uiop:ensure-directory-pathname root)))))
    (and (<= (length root-name) (length path))
         (string= root-name path :end2 (length root-name)))))

(defun %dependency-system-name (dependency)
  (cond ((or (stringp dependency) (symbolp dependency)) dependency)
        ((and (consp dependency) (member (first dependency) '(:version :require)
                                         :test #'eq))
         (second dependency))
        ((and (consp dependency) (eq (first dependency) :feature))
         (third dependency))
        (t nil)))

(defun %system-source-files (system-name root)
  "Return actual Lisp component files in local SYSTEM-NAME and local dependencies."
  (let ((seen-systems (make-hash-table :test #'equal))
        (seen-files (make-hash-table :test #'equal))
        (files nil))
    (labels ((collect-component (component)
               (let ((children (and (typep component 'asdf:module)
                                    (asdf:module-components component))))
                 (if children
                     (mapc #'collect-component children)
                     (let ((pathname (asdf:component-pathname component)))
                       (when (and pathname (probe-file pathname)
                                  (member (string-downcase
                                           (or (pathname-type pathname) ""))
                                          '("lisp" "cl") :test #'string=)
                                  (%pathname-under-root-p pathname root))
                         (let ((key (namestring (truename pathname))))
                           (unless (gethash key seen-files)
                             (setf (gethash key seen-files) t)
                             (push (truename pathname) files))))))))
             (collect-system (name)
               (let ((key (string-downcase (string name))))
                 (unless (gethash key seen-systems)
                   (setf (gethash key seen-systems) t)
                   (let ((system (ignore-errors (asdf:find-system name nil))))
                     (when (and system
                                (%pathname-under-root-p
                                 (asdf:system-source-directory system) root))
                       (collect-component system)
                       (dolist (dependency (asdf:system-depends-on system))
                         (let ((dependency-name
                                 (%dependency-system-name dependency)))
                           (when dependency-name
                             (collect-system dependency-name))))))))))
      (collect-system system-name))
    (sort files #'string< :key #'namestring)))

(defun %version-token-p (text)
  (and (> (length text) 1)
       (char-equal (char text 0) #\v)
       (every #'digit-char-p (subseq text 1))))

(defun %name-tokens (name)
  (uiop:split-string (string-downcase (string name))
                     :separator '(#\/ #\\ #\- #\. #\_)))

(defun %versioned-name-p (name)
  (some #'%version-token-p (%name-tokens name)))

(defun %collect-versioned-path-issues (root source-files)
  (let ((issues nil) (root-namestring (namestring (truename root))))
    (dolist (file source-files)
      (let* ((full (namestring (truename file)))
             (relative (if (and (<= (length root-namestring) (length full))
                                (string= root-namestring full
                                         :end2 (length root-namestring)))
                           (subseq full (length root-namestring))
                           full)))
        (when (some #'%version-token-p (%name-tokens relative))
          (push (list :code :stale-versioned-source-path :path relative) issues))))
    (nreverse issues)))

(defun %collect-system-alias-issues (asd-pathname)
  (let ((issues nil) (*package* (find-package :cl-user)))
    (when (probe-file asd-pathname)
      (with-open-file (stream asd-pathname :direction :input)
        (handler-case
            (loop for form = (read stream nil stream)
                  until (eq form stream)
                  do (labels ((walk (node)
                                (when (consp node)
                                  (let ((operator (first node)))
                                    (if (and (symbolp operator)
                                             (string= (symbol-name operator)
                                                      "DEFSYSTEM"))
                                        (let ((name (second node)))
                                          (when (%versioned-name-p name)
                                            (push (list :code
                                                        :stale-versioned-system-alias
                                                        :system (string-downcase
                                                                 (string name))
                                                        :file (namestring asd-pathname))
                                                  issues)))
                                        (unless (%quoted-form-p node)
                                          (mapc #'walk (rest node))))))))
                       (walk form)))
          (error (condition)
            (push (list :code :asd-reader-error :file (namestring asd-pathname)
                        :condition-type (type-of condition)
                        :message (princ-to-string condition)) issues)))))
    (nreverse issues)))

(defun check-source-files (pathnames &key expected-package
                                      (duplicate-whitelist nil)
                                      (foreign-method-whitelist nil)
                                      (inspect-loaded nil)
                                      (include-optional-loaded nil))
  "Check Lisp PATHNAMES using the native reader and optional loaded introspection.
No source is evaluated. INSPECT-LOADED requires the corresponding systems to
have been compiled and loaded normally first."
  (let ((definitions nil) (issues nil)
        (files (sort (mapcar #'pathname pathnames) #'string< :key #'namestring)))
    (dolist (file files)
      (multiple-value-bind (file-definitions file-issues)
          (%read-source-file file)
        (setf definitions (nconc definitions file-definitions)
              issues (nconc issues file-issues))))
    (setf issues
          (nconc issues
                 (%collect-duplicate-issues definitions duplicate-whitelist)
                 (%collect-static-congruence-issues definitions)
                 (%collect-package-issues definitions expected-package
                                          foreign-method-whitelist)
                 (when inspect-loaded
                   (%collect-loaded-issues
                    definitions :include-optional-loaded include-optional-loaded))))
    (list :status (if issues :failed :ok)
          :files (mapcar #'namestring files)
          :definition-count (length definitions)
          :native-reader t :native-introspection (not (null inspect-loaded))
          :issues issues)))

(defun %default-project-root ()
  (asdf:system-source-directory (asdf:find-system :clamsara)))

(defun check-project-structure (&key (root (%default-project-root))
                                     (inspect-loaded t)
                                     (include-optional-loaded nil))
  "Check canonical production sources plus path and system naming invariants.
The normal :CLAMSARA system must be loaded before the default introspection run."
  (let* ((root (uiop:ensure-directory-pathname root))
         (source-directory (merge-pathnames "src/" root))
         (all-files (if (probe-file source-directory)
                        (%lisp-source-files source-directory)
                        nil))
         ;; Read the actual ASDF component closure, not a directory-shaped
         ;; guess. The workload has reader-visible dependencies of its own, so
         ;; its closure is selected only by the explicit post-load mode.
         (files (%system-source-files
                 (if include-optional-loaded :clamsara/workload :clamsara)
                 root))
         (source-report
           (check-source-files
            files :expected-package (and (find-package :clamsara) :clamsara)
            :duplicate-whitelist *project-duplicate-whitelist*
            :foreign-method-whitelist *project-foreign-method-whitelist*
            :inspect-loaded inspect-loaded
            :include-optional-loaded include-optional-loaded))
         (extra-issues
           (nconc
            (unless (probe-file source-directory)
              (list (list :code :missing-source-directory
                          :path (namestring source-directory))))
            (unless files
              (list (list :code :missing-system-source-components
                          :system (if include-optional-loaded
                                      :clamsara/workload :clamsara))))
            ;; Naming checks still cover optional source paths even when its
            ;; reader dependencies were not loaded for this run.
            (%collect-versioned-path-issues root all-files)
            (%collect-system-alias-issues (merge-pathnames "clamsara.asd" root))))
         (issues (nconc (copy-list (getf source-report :issues)) extra-issues)))
    (list :status (if issues :failed :ok)
          :root (namestring root)
          :files (getf source-report :files)
          :definition-count (getf source-report :definition-count)
          :native-reader t
          :native-introspection (getf source-report :native-introspection)
          :native-compilation-prerequisite
          "Load :CLAMSARA through ASDF before INSPECT-LOADED."
          :issues issues)))

(defun assert-source-structure (pathnames &rest arguments)
  (let ((report (apply #'check-source-files pathnames arguments)))
    (unless (eq (getf report :status) :ok)
      (error 'structure-check-failed :report report))
    report))

(defun assert-project-structure (&rest arguments)
  (let ((report (apply #'check-project-structure arguments)))
    (unless (eq (getf report :status) :ok)
      (error 'structure-check-failed :report report))
    report))

(defun write-structure-report (report &optional (stream *standard-output*))
  (let ((*print-circle* t) (*print-readably* nil) (*print-pretty* t)
        (*print-level* nil) (*print-length* nil))
    (write report :stream stream)
    (terpri stream))
  report)
