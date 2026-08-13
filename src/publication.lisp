;;;; publication.lisp -- thread-local scope and publication strategies
;;;; (paper-v8 ch. locality).  The DLG invariant: no public object references
;;;; a private one.  Publication restores it when a private object is about to
;;;; become reachable from a public source.  The strategy is a pluggable
;;;; primitive; Claimore treats the choice as an experimental parameter.

(in-package #:clamsara)

(defclass publication-strategy ()
  ((public-region :initarg :public-region :accessor public-region
                  :initform nil)
   (work :accessor publication-work :initform (make-array 0 :fill-pointer 0))))

(defgeneric publish (strategy vm object)
  (:documentation "Restore DLG for OBJECT becoming reachable from a public source."))
(defgeneric publication-read-rule (strategy)
  (:documentation "Optional read-barrier rule this strategy requires, or NIL.")
  (:method ((s publication-strategy)) nil))
(defgeneric strategy-read-guarded-p (strategy)
  (:documentation "True if the strategy uses read-guarded DLG (DLG-r).")
  (:method ((s publication-strategy)) nil))
(defgeneric strategy-published-roots (strategy)
  (:documentation "The strategy's published-roots set, or NIL.")
  (:method ((s publication-strategy)) nil))

(defun initialize-publication-work (strategy vm)
  "Allocate the eager-closure queue (and any published-roots set) at boot,
  standing in for immortal storage."
  (setf (publication-work strategy)
        (make-array (vm-heap-size vm) :element-type 'fixnum
                    :initial-element 0 :fill-pointer 0))
  (when (typep strategy 'lazy-read-barrier)
    (initialize-lazy-published-roots strategy vm))
  (when (typep strategy 'trap-error-copy-b)
    (initialize-trap-b-published-roots strategy vm))
  strategy)

;; ---- the published-roots set (locality.tex §1) ---------------------------
;; Every guarded public-to-private edge is recorded here at publication time.
;; The private collection drains it twice: at start (seeding the trace) and
;; again before reclaim (pinning referents of edges appended mid-collection
;; by foreign read rules).  Entries record EDGES (published object + slot),
;; not just objects: the healing mechanism needs the slot.  Two parallel
;; fixnum vectors, no host conses on the mutator path.

(defclass published-roots ()
  ((objects :accessor published-roots-objects)
   (slots :accessor published-roots-slots)
   (fill :accessor published-roots-fill :initform 0)))

(defun make-published-roots (capacity)
  (let ((pr (make-instance 'published-roots)))
    (setf (published-roots-objects pr)
          (make-array capacity :element-type 'fixnum :initial-element 0)
          (published-roots-slots pr)
          (make-array capacity :element-type 'fixnum :initial-element 0))
    pr))

(defun published-roots-empty-p (pr) (zerop (published-roots-fill pr)))

(defun record-published-edge (pr object slot)
  "Append the guarded edge (OBJECT . SLOT).  Append-only: never dropped."
  (let ((fill (published-roots-fill pr)))
    (unless (< fill (length (published-roots-objects pr)))
      (error 'heap-exhausted :requested-size 1 :space :published-roots))
    (setf (aref (published-roots-objects pr) fill) object
          (aref (published-roots-slots pr) fill) slot
          (published-roots-fill pr) (1+ fill))
    pr))

(defun drain-published-roots (pr fn)
  "Invoke (FN object slot) on every recorded edge.  The edge entries are
  retained: the set is append-only and drained, not cleared (locality.tex)."
  (let ((fill (published-roots-fill pr)))
    (dotimes (i fill)
      (funcall fn (aref (published-roots-objects pr) i)
               (aref (published-roots-slots pr) i))))
  pr)

(defun published-roots-count (pr) (published-roots-fill pr))

(defun edge-referent-live-p (vm object slot)
  (let ((child (vm-object-reference vm object slot)))
    (and (vm-reference-p vm child) child)))

;; ---- eager closure (Iso) -------------------------------------------------
;; Publish the whole transitive closure at once: set the public bit on each.
;; Each object is published at most once, so amortised cost is constant/object.

(defclass eager-closure (publication-strategy) ())

(defmethod publish ((s eager-closure) vm root)
  ;; The public bit is also the visited bit: publication is monotone, so an
  ;; object can enter this queue at most once over the whole run.
  (let ((work (publication-work s))
        (head 0)
        (root (ref-strip-or-self vm root)))
    (setf (fill-pointer work) 0)
    (unless (vm-object-is-public-p vm root)
      (setf (vm-object-is-public-p vm root) t)
      (unless (vector-push root work)
        (error 'heap-exhausted :requested-size 1
               :space :publication-queue)))
    (loop while (< head (length work))
          for object = (aref work head)
          do (incf head)
             (vm-map-reference-slots
              vm object
              (lambda (child)
                (let ((addr (ref-strip-or-self vm child)))
                  (when (and (vm-reference-p vm child)
                             (not (vm-object-is-public-p vm addr)))
                    (setf (vm-object-is-public-p vm addr) t)
                    (unless (vector-push addr work)
                      (error 'heap-exhausted :requested-size 1
                             :space :publication-queue)))))))
    (setf (fill-pointer work) 0)
    root))

;; ---- lazy read-barrier (Marlow/Dolan/Filatov-Mikheev lineage) ------------
;; Publish only the root; a read barrier promotes children on demand.  The
;; guarded edge (published object, slot) is recorded in the published-roots
;; set so the private collection can pin/heal the referent (DLG-r).

(defclass lazy-read-barrier (publication-strategy)
  ((published-roots :accessor strategy-published-roots :initform nil)))

(defmethod strategy-read-guarded-p ((s lazy-read-barrier)) t)

(defmethod publish ((s lazy-read-barrier) vm object)
  (setf (vm-object-is-public-p vm object) t)
  ;; record every outgoing slot as a guarded edge: a read of a private child
  ;; publishes on demand, and the private collection must know all such slots
  (let ((pr (strategy-published-roots s)))
    (when pr
      (dotimes (slot (vm-object-reference-count vm object))
        (record-published-edge pr object slot))))
  object)

(defmethod publication-read-rule ((s lazy-read-barrier))
  ;; on read of a still-private child of a public object, publish it
  (lambda (vm slot-addr reference)
    (let ((addr (ref-strip-or-self vm reference)))
      (when (and (vm-reference-p vm addr) (not (vm-object-is-public-p vm addr)))
        (setf (vm-object-is-public-p vm addr) t)
        (setf (ref-u64 vm slot-addr) reference)))
    reference))

(defun initialize-lazy-published-roots (strategy vm)
  (setf (strategy-published-roots strategy)
        (make-published-roots (vm-heap-size vm)))
  strategy)

;; ---- trap / error-copy (Claimore experiments) ----------------------------
;; Variant A: copy into public region, poison the private original with an
;; error stand-in that redirects to the public copy.  Variant B is the mirror.

(defparameter +error-tag+ 6 "Type tag for poisoned stand-ins.")

(defun poison-as-error (vm original copy)
  "Overwrite ORIGINAL with an error stand-in of size 1 whose slot 0 holds the
  public COPY's address.  A 1-slot stand-in is a well-formed object under the
  object model (vm-object-total-words = 2), so a walker scanning it cannot run
  off into the heap."
  (setf (vm-object-header vm original) (pack-header 1 +error-tag+))
  (setf (vm-object-reference vm original 0) copy))

(defun error-object-p (vm reference)
  (let ((addr (ref-strip-or-self vm reference)))
    (and (vm-object-start-p vm addr)
         (eql (vm-object-type-tag vm addr) +error-tag+))))

(defun error-redirect (vm reference)
  "The public copy address stored in slot 0 of the error stand-in."
  (vm-object-reference vm (ref-strip-or-self vm reference) 0))

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

(defclass trap-error-copy-b (publication-strategy)
  ((published-roots :accessor strategy-published-roots :initform nil)))

(defmethod strategy-read-guarded-p ((s trap-error-copy-b)) t)

(defmethod publish ((s trap-error-copy-b) vm object)
  ;; Variant B: keep the original private; install an error stand-in in the
  ;; public region whose edge to the original is a guarded published root.
  ;; Dereferencing the stand-in traps (error tag); the trap handler promotes.
  (let* ((region (public-region s))
         (stand-in (if (and region (space-allocator region))
                       (alloc (space-allocator region) 2)
                       nil)))
    (when stand-in
      (setf (vm-object-header vm stand-in) (pack-header 1 +error-tag+)
            (vm-object-reference vm stand-in 0)
            (ref-strip-or-self vm object))
      (let ((os (vm-object-start vm)))
        (when os (s-set-bit os stand-in)))
      (let ((pr (strategy-published-roots s)))
        (when pr (record-published-edge pr stand-in 0))))
    stand-in))

(defmethod publication-read-rule ((s trap-error-copy-b))
  ;; The trap IS the runtime's type check; the strategy exposes no read rule
  ;; (locality.tex: publication-read-rule returns NIL for trap variants).
  nil)

(defun initialize-trap-b-published-roots (strategy vm)
  (setf (strategy-published-roots strategy)
        (make-published-roots (vm-heap-size vm)))
  strategy)

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
