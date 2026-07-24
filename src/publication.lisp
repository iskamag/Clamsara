;;;; publication.lisp -- thread-local scope and publication strategies
;;;; (paper-v8 ch. locality).  The DLG invariant: no public object references
;;;; a private one.  Publication restores it when a private object is about to
;;;; become reachable from a public source.  The strategy is a pluggable
;;;; primitive; Claimore treats the choice as an experimental parameter.

(in-package #:clamsara)

(defclass publication-strategy ()
  ((public-region :initarg :public-region :accessor public-region
                  :initform nil)))

(defgeneric publish (strategy vm object)
  (:documentation "Restore DLG for OBJECT becoming reachable from a public source."))
(defgeneric publication-read-rule (strategy)
  (:documentation "Optional read-barrier rule this strategy requires, or NIL.")
  (:method ((s publication-strategy)) nil))

(defun do-transitive-closure (vm root fn)
  "Walk the transitive closure of ROOT, calling FN on each object once."
  (let ((seen (make-hash-table :test 'eql))
        (work (list root)))
    (loop while work
          for o = (pop work)
          unless (gethash o seen)
          do (setf (gethash o seen) t)
             (funcall fn o)
             (vm-scan-object-references vm o
               (lambda (child)
                 (let ((a (ref-strip-or-self vm child)))
                   (when (vm-reference-p vm a) (push a work))))))))

;; ---- eager closure (Iso) -------------------------------------------------
;; Publish the whole transitive closure at once: set the public bit on each.
;; Each object is published at most once, so amortised cost is constant/object.

(defclass eager-closure (publication-strategy) ())

(defmethod publish ((s eager-closure) vm root)
  (do-transitive-closure vm root
    (lambda (o)
      (unless (vm-object-is-public-p vm o)
        (setf (vm-object-is-public-p vm o) t)))))

;; ---- lazy read-barrier (Marlow/Dolan/Filatov-Mikheev lineage) ------------
;; Publish only the root; a read barrier promotes children on demand.

(defclass lazy-read-barrier (publication-strategy) ())

(defmethod publish ((s lazy-read-barrier) vm object)
  (setf (vm-object-is-public-p vm object) t))

(defmethod publication-read-rule ((s lazy-read-barrier))
  ;; on read of a still-private child of a public object, publish it
  (lambda (vm slot-addr reference)
    (let ((addr (ref-strip-or-self vm reference)))
      (when (and (vm-reference-p vm addr) (not (vm-object-is-public-p vm addr)))
        (setf (vm-object-is-public-p vm addr) t)
        (setf (ref-u64 vm slot-addr) reference)))
    reference))

;; ---- trap / error-copy (Claimore experiments) ----------------------------
;; Variant A: copy into public region, poison the private original with an
;; error stand-in that redirects to the public copy.  Variant B is the mirror.

(defparameter +error-tag+ 6 "Type tag for poisoned stand-ins.")

(defun poison-as-error (vm original copy)
  "Overwrite ORIGINAL's header with an error stand-in pointing at COPY."
  (setf (vm-object-header vm original)
        (pack-header copy +error-tag+)))

(defun error-object-p (vm reference)
  (let ((addr (ref-strip-or-self vm reference)))
    (and (vm-object-start-p vm addr)
         (eql (vm-object-type-tag vm addr) +error-tag+))))

(defun error-redirect (vm reference)
  (forwarding-address (vm-object-header vm (ref-strip-or-self vm reference))))

(defclass trap-error-copy-a (publication-strategy) ())

(defmethod publish ((s trap-error-copy-a) vm object)
  (let ((copy (copy-to-public vm object (public-region s))))
    (setf (vm-object-is-public-p vm copy) t)
    (poison-as-error vm object copy)))

(defmethod publication-read-rule ((s trap-error-copy-a))
  (lambda (vm slot-addr reference)
    (if (error-object-p vm reference)
        (let ((healed (error-redirect vm reference)))
          (setf (ref-u64 vm slot-addr) healed)
          healed)
        reference)))

(defclass trap-error-copy-b (publication-strategy) ())

(defmethod publish ((s trap-error-copy-b) vm object)
  ;; keep the original in place; place an error copy in the public region.
  (setf (vm-object-is-public-p vm object) t))

(defun copy-to-public (vm object public-space)
  "Allocate in PUBLIC-SPACE and copy OBJECT's payload there."
  (if (and public-space (space-allocator public-space))
      (let* ((n (vm-object-total-words vm object))
             (dst (alloc (space-allocator public-space) n)))
        (if dst
            (progn (loop for k below n do (setf (ref-u64 vm (+ dst k)) (ref-u64 vm (+ object k))))
                   (let ((os (vm-object-start vm))) (when os (s-set-bit os dst)))
                   dst)
            object))
      object))
