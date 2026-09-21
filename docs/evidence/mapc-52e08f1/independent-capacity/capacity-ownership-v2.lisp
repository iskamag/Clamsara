;;;; Capacity native harness v2 against /tmp/clamsara-mapc-draft-wd3ba0th.
;;;; V1 preserved. V2 adds stage reporting only; native outcome is not assumed.
;;;; Run only in an exclusive authorized native slot after normal workload load.
;;;; Construction/observation methods are temporary, additive, and unique.
;;;; No production primary, live token vector, or published VM is replaced.
(defpackage #:clamsara.workload.mapc.capacity.v1
  (:use #:cl #:clamsara)
  (:export #:cap-run-boundary-matrix #:cap-run-snapshot-witness
           #:cap-run-nested-rejection #:*cap-owners*))
(in-package #:clamsara.workload.mapc.capacity.v1)

(defstruct cap-owner runtime provider spec phase condition
  (calls 0) (sum 0) (allocations 0) (stores 0)
  reservation stages (snapshot-count 0) (moving-cycles 0) (inner-rejections 0))
(defvar *cap-owners* nil)
(defvar *cap-constructing* nil)
(defvar *cap-active* nil)
(defvar *cap-count-effects* nil)
(defvar *cap-witness* nil)
(defvar *cap-entry-witness-enabled* nil)
(define-condition cap-unexpected-callback (error) ())

(defun cap-env (o) (clamsara::workload-runtime-environment (cap-owner-runtime o)))
(defun cap-client (o) (clamsara::workload-maclina-client (cap-env o)))
(defun cap-guest (o) (clamsara::workload-maclina-environment (cap-env o)))
(defun cap-vm (o) (clamsara::workload-provider-vm (cap-owner-provider o)))
(defun cap-note (o phase)
  (setf (cap-owner-phase o) phase)
  (push phase (cap-owner-stages o))
  (format t "~&CAP-STAGE ~S spec=~S~%" phase (cap-owner-spec o))
  phase)
(defun cap-fn (o name) (clostrum:fdefinition (cap-client o) (cap-guest o) name))
(defun cap-fset (o name fn)
  (setf (clostrum:fdefinition (cap-client o) (cap-guest o) name) fn))
(defun cap-guard (o thunk)
  (handler-bind ((error (lambda (c) (setf (cap-owner-condition o) c))))
    (funcall thunk))) ; no error cleanup, no collection, no EVAL NIL or close

(defun cap-with-unique-method (generic qualifiers classes definition thunk)
  (let ((specializers (mapcar #'find-class classes)))
    (assert (null (find-method generic qualifiers specializers nil)))
    (let ((method (eval definition)))
      ;; Removing only our test method does not release or erase guest owners.
      (unwind-protect (funcall thunk) (remove-method generic method)))))

(defun cap-with-fixture-methods (thunk)
  (labels ((install (specs)
             (if (null specs) (funcall thunk)
                 (destructuring-bind (name qualifiers classes definition) (car specs)
                   (cap-with-unique-method
                    (fdefinition name) qualifiers classes definition
                    (lambda () (install (cdr specs))))))))
    (install
     '((initialize-instance (:after) (clamsara::workload-root-provider)
        (defmethod initialize-instance :after
            ((p clamsara::workload-root-provider) &key &allow-other-keys)
          (when *cap-constructing*
            (let* ((o *cap-constructing*) (spec (cap-owner-spec o))
                   (tokens (clamsara::workload-provider-locations p))
                   (capacity (clamsara::workload-provider-capacity p)))
              (setf (cap-owner-provider o) p)
              (assert (= capacity (length tokens)))
              (assert (zerop (clamsara::workload-provider-frame-count p)))
              (assert (zerop (clamsara::workload-provider-native-cell-count p)))
              (when (getf spec :frames)
                (setf (slot-value p 'clamsara::functions)
                      (make-array (getf spec :frames) :initial-element nil)
                      (slot-value p 'clamsara::saved-values)
                      (make-array (getf spec :frames) :initial-element nil)))
              (when (getf spec :cells)
                (setf (slot-value p 'clamsara::native-cells)
                      (clamsara::%make-workload-native-cells (getf spec :cells))))
              (when (getf spec :snapshot-controls)
                (setf (slot-value p 'clamsara::control-walk)
                      (clamsara::%new-workload-root-walk
                       (getf spec :snapshot-controls))))
              (when (getf spec :census-controls)
                (setf (slot-value p 'clamsara::census-walk)
                      (clamsara::%new-workload-root-walk
                       (getf spec :census-controls))))
              ;; The constructor still fills LOCATIONS after this :AFTER.
              (assert (eq tokens (clamsara::workload-provider-locations p)))
              (assert (= capacity (clamsara::workload-provider-capacity p)))))))
       (initialize-instance (:after) (clamsara::workload-environment)
        (defmethod initialize-instance :after
            ((environment clamsara::workload-environment) &key &allow-other-keys)
          (when *cap-constructing*
            ;; This precedes SETUP-WORKLOAD-MACLINA / INITIALIZE-VM. It changes
            ;; setup geometry, not an already constructed/published VM vector.
            (let ((size (getf (cap-owner-spec *cap-constructing*) :stack)))
              (when size (setf (slot-value environment 'clamsara::stack-size) size))))))
       (allocate-object (:before) (clamsara::sequential-execution-context t t t t)
        (defmethod allocate-object :before
            ((context clamsara::sequential-execution-context) kind bytes alignment descriptor)
          (declare (ignore context kind bytes alignment descriptor))
          (when *cap-count-effects* (incf (cap-owner-allocations *cap-active*)))))
       (barrier-store (:before) (clamsara::composed-barrier clamsara::sequential-execution-context t t)
        (defmethod barrier-store :before
            ((barrier clamsara::composed-barrier)
             (context clamsara::sequential-execution-context) location new)
          (declare (ignore barrier context location new))
          (when *cap-count-effects* (incf (cap-owner-stores *cap-active*)))))
       (map-provider-roots (:after) (clamsara::workload-root-provider t)
        (defmethod map-provider-roots :after
            ((p clamsara::workload-root-provider) function)
          (declare (ignore function))
          ;; Reached ONLY by real COLLECT in CAP-FULL-CYCLE. No direct refresh.
          (when (and *cap-witness* (eq p (first *cap-witness*)))
            (let ((active (count-if
                           (lambda (location)
                             (not (eq :inactive
                                      (clamsara::workload-location-source-kind location))))
                           (clamsara::workload-provider-locations p)))
                  (controls (clamsara::workload-root-walk-count
                              (clamsara::workload-provider-control-walk p))))
              (assert (= (second *cap-witness*) active))
              (assert (= (third *cap-witness*) controls))
              (when (cap-owner-reservation *cap-active*)
                (assert (<= active (cap-owner-reservation *cap-active*))))
              (incf (cap-owner-snapshot-count *cap-active*))))))))))

(defun cap-state (o)
  ;; Read-only scalar/control snapshots. Never use copied managed references
  ;; as GC owners. Comparisons below occur only across nonallocating admission.
  (let* ((p (cap-owner-provider o)) (vm (cap-vm o))
         (walk (clamsara::workload-provider-control-walk p)))
    (cons
     ;; Compare physical source identities with EQ, not structural EQUAL.
     (append
      (list p vm (clamsara::workload-provider-locations p)
            (clamsara::workload-provider-functions p)
            (clamsara::workload-provider-saved-values p)
            (clamsara::workload-provider-native-cells p)
            (maclina.vm-cross::vm-stack vm) walk
            (clamsara::workload-root-walk-queue walk)
            (clamsara::workload-root-walk-seen walk))
      (coerce (clamsara::workload-provider-locations p) 'list)
      (coerce (clamsara::workload-provider-native-cells p) 'list)
      (map 'list #'cdr (clamsara::workload-provider-native-cells p))
      (loop for cell on (maclina.vm-cross::vm-values vm) collect cell))
     (list
     (map 'list (lambda (l)
                  (list (clamsara::workload-location-source-kind l)
                        (clamsara::workload-location-source l)
                        (clamsara::workload-location-source-index l)
                        (clamsara::workload-location-value l)))
          (clamsara::workload-provider-locations p))
     (clamsara::workload-provider-frame-count p)
     (clamsara::workload-provider-native-cell-count p)
     (coerce (clamsara::workload-provider-functions p) 'list)
     (coerce (clamsara::workload-provider-saved-values p) 'list)
     (map 'list (lambda (cell) (list (car cell) (cdr cell)))
          (clamsara::workload-provider-native-cells p))
     (coerce (maclina.vm-cross::vm-stack vm) 'list)
     (maclina.vm-cross::vm-stack-top vm)
     (maclina.vm-cross::vm-frame-pointer vm)
     (maclina.vm-cross::vm-args vm) (maclina.vm-cross::vm-arg-count vm)
     (maclina.vm-cross::vm-pc vm)
     (maclina.vm-cross::vm-values vm) (copy-list (maclina.vm-cross::vm-values vm))
     (maclina.vm-cross::vm-dynenv-stack vm)
     (clamsara::workload-root-walk-count walk)
     (coerce (clamsara::workload-root-walk-queue walk) 'list)
     (loop for key being each hash-key of (clamsara::workload-root-walk-seen walk)
             using (hash-value value) collect (cons key value))))))
(defun cap-unchanged-p (before after)
  (and (= (length (first before)) (length (first after)))
       (every #'eq (first before) (first after))
       (equal (rest before) (rest after))))
(defun cap-census-clean (o)
  (let ((walk (clamsara::workload-provider-census-walk (cap-owner-provider o))))
    (assert (zerop (clamsara::workload-root-walk-count walk)))
    (assert (zerop (hash-table-count (clamsara::workload-root-walk-seen walk))))
    (assert (every #'null (clamsara::workload-root-walk-queue walk)))))
(defun cap-full-cycle (o)
  (cap-note o :gc-census)
  (let* ((p (cap-owner-provider o)) (before (cap-state o))
         (demand (multiple-value-list (clamsara::%provider-root-demand p))))
    (assert (cap-unchanged-p before (cap-state o))) ; census did not retarget descriptors
    (cap-census-clean o)
    ;; BEFORE's borrowed encoded references are never read after collection.
    (setf before nil)
    (let* ((*cap-active* o) (*cap-witness* (cons p demand))
           (rt (cap-owner-runtime o))
           (seen (cap-owner-snapshot-count o))
           (record (make-cycle-result-record (clamsara::workload-runtime-plan rt))))
      (cap-note o :protected-collection)
      (collect (clamsara::workload-runtime-configuration rt) :all :explicit record)
      (assert (eq :complete (cycle-result-status record)))
      (assert (> (cap-owner-snapshot-count o) seen))
      (when (plusp (cycle-result-count record :objects-moved))
        (incf (cap-owner-moving-cycles o)))
      record)))

(defun cap-new (spec)
  (let ((o (make-cap-owner :spec spec :phase :constructing)))
    (push o *cap-owners*) ; retain partial provider even if construction fails
    (cap-guard o
      (lambda ()
        (let ((*cap-constructing* o))
          (setf (cap-owner-runtime o)
                (make-workload-runtime :extent 16384 :max-object-bytes 8192
                                       :root-capacity (getf spec :roots 4096))))
        (cap-note o :constructed)
        (assert (eq (cap-owner-provider o)
                    (clamsara::workload-runtime-root-provider (cap-owner-runtime o))))
        (assert (= (getf spec :roots 4096)
                   (length (clamsara::workload-provider-locations (cap-owner-provider o)))))
        (when (getf spec :stack)
          (assert (= (getf spec :stack) (length (maclina.vm-cross::vm-stack (cap-vm o))))))
        o))))
(defun cap-record-row (value)
  ;; Native test observer gets only a fixnum and does not allocate guest data.
  (assert (typep value 'fixnum))
  (cap-note *cap-active* :callback-row)
  (incf (cap-owner-calls *cap-active*))
  (incf (cap-owner-sum *cap-active*) value)
  value)
(defun cap-entry-witness ()
  (when *cap-entry-witness-enabled*
    (let ((record (cap-full-cycle *cap-active*)))
      (assert (plusp (cycle-result-count record :objects-moved))))))
(defun cap-callback-form ()
  ;; A sizeable actual locals frame permits construction of a truly small
  ;; stack for entry-only exact/one-short tests. No benchmark is changed.
  (let ((pads (loop repeat 64 collect (gensym "CAP-PAD-"))))
    `(let ((capture (cons 41 nil)))
       (lambda (x y)
         (let ,(loop for p in pads collect `(,p 0))
           (unless (and ,@(loop for p in pads collect `(zerop ,p)))
             (error 'cap-unexpected-callback))
           (cap-entry-witness)
           (cap-record-row (+ x y (car capture))))))))
(defun cap-prepare (o)
  (cap-note o :prepare-owned-inputs-and-callback)
  (dolist (name '(cap-record-row cap-entry-witness cap-callback cap-alias
                 cap-observed-mapc cap-inner-attempt cap-inner cap-outer))
    (assert (not (clostrum:fboundp (cap-client o) (cap-guest o) name))))
  (cap-fset o 'cap-record-row #'cap-record-row)
  (cap-fset o 'cap-entry-witness #'cap-entry-witness)
  (cap-fset o 'cap-callback (workload-eval (cap-env o) (cap-callback-form)))
  ;; Real VM-VALUES cells own two input lists. No temporary-slot borrowing.
  (workload-eval (cap-env o) '(values (cons 11 nil) (cons 13 nil)))
  o)
(defun cap-finish (o)
  ;; Success only. No caller invokes this from UNWIND-PROTECT/error cleanup.
  (cap-note o :release-proven-case-owners)
  (dolist (name '(cap-record-row cap-entry-witness cap-callback cap-alias
                 cap-observed-mapc cap-inner-attempt cap-inner cap-outer))
    (when (clostrum:fboundp (cap-client o) (cap-guest o) name)
      (clostrum:fmakunbound (cap-client o) (cap-guest o) name)))
  (cap-note o :consume-proven-result)
  (workload-eval (cap-env o) nil)
  (setf (cap-owner-reservation o) nil)
  (assert (zerop (cycle-result-count (cap-full-cycle o) :objects-discovered)))
  (cap-note o :close-proven-history)
  (close-workload-runtime (cap-owner-runtime o))
  (cap-note o :complete)
  o)
(defun cap-metrics (o)
  (cap-note o :calibration-demand)
  (let* ((p (cap-owner-provider o)) (vm (cap-vm o)) (n 2)
         (fn (cap-fn o 'cap-callback))
         (template (etypecase fn
                     (maclina.machine:function fn)
                     (maclina.machine:closure (maclina.machine:template fn))))
         (entry (+ n (maclina.machine:locals-frame-size template)))
         (top (maclina.vm-cross::vm-stack-top vm)))
    (assert (zerop top))
    (assert (zerop (clamsara::workload-provider-frame-count p)))
    (multiple-value-bind (current controls)
        (clamsara::%provider-root-demand p :extra-function fn
          :entry-local-start (+ top n) :entry-end (+ top entry))
      (let ((total (+ current 5 entry)))
        (assert (= total (clamsara::%provider-mapc-admission p fn n)))
        (list :roots total :frames 2 :cells 5 :snapshot-controls controls
              :census-controls controls :stack entry)))))
(defun cap-calibrate ()
  (let ((o (cap-new '(:roots 4096 :frames 128 :cells 4096
                      :snapshot-controls 4096 :census-controls 4096 :stack 1024))))
    (cap-guard o
      (lambda ()
        (cap-prepare o)
        (let ((metrics (cap-metrics o)))
          (cap-finish o)
          metrics)))))
(defun cap-expect-rejection (o thunk expected-reason)
  (let ((before (cap-state o)) (calls (cap-owner-calls o))
        (allocations (cap-owner-allocations o)) (stores (cap-owner-stores o))
        (*cap-active* o) (*cap-count-effects* t))
    (assert
     (handler-case (progn (funcall thunk) nil)
       (workload-capability-error (c)
         (assert (eq expected-reason (clamsara::workload-error-reason c))) t)))
    (assert (= calls (cap-owner-calls o)))
    (assert (= allocations (cap-owner-allocations o)))
    (assert (= stores (cap-owner-stores o)))
    (assert (cap-unchanged-p before (cap-state o)))
    (cap-census-clean o)))

(defun cap-run-boundary-matrix ()
  "Fresh physical constructions. Stop on the first unexpected error."
  (cap-with-fixture-methods
   (lambda ()
     (let ((metrics (cap-calibrate)))
       (dolist (pair '((:roots :root-provider-capacity-exhausted)
                       (:frames :vm-frame-capacity-exhausted)
                       (:cells :native-cell-capacity-exhausted)
                       (:snapshot-controls :control-root-capacity-exhausted)
                       (:census-controls :control-root-capacity-exhausted)
                       (:stack :vm-stack-capacity-exhausted)))
         (destructuring-bind (dimension reason) pair
           (dolist (short '(nil t))
             (let ((spec (list :roots 4096 :frames 128 :cells 4096
                               :snapshot-controls 4096 :census-controls 4096
                               :stack 1024)))
               (setf (getf spec dimension) (- (getf metrics dimension) (if short 1 0)))
               (let ((o (cap-new spec)))
                 (cap-guard o
                  (lambda ()
                    (cap-prepare o)
                    (cap-note o (list :boundary dimension :one-short short))
                    (let* ((p (cap-owner-provider o)) (fn (cap-fn o 'cap-callback))
                           (*cap-active* o))
                      (cap-note o (list :private-admission dimension :one-short short))
                      (if short
                          (cap-expect-rejection o
                           (lambda () (clamsara::%provider-mapc-admission p fn 2)) reason)
                          (let ((before (cap-state o)) (*cap-count-effects* t))
                            (assert (= (getf metrics :roots)
                                       (clamsara::%provider-mapc-admission p fn 2)))
                            (assert (cap-unchanged-p before (cap-state o)))
                            (assert (zerop (cap-owner-calls o)))
                            (assert (zerop (cap-owner-allocations o)))
                            (assert (zerop (cap-owner-stores o)))
                            (cap-census-clean o)))
                      (cap-note o (list :private-admission-proved dimension :one-short short))
                      ;; Real nonempty MAPC must reject before publication.
                      (cap-note o (list :actual-mapc dimension :one-short short))
                      (if short
                          (cap-expect-rejection o
                           (lambda ()
                             (let ((inputs (maclina.vm-cross::vm-values (cap-vm o))))
                               (funcall (cap-fn o 'cl:mapc) fn
                                        (first inputs) (second inputs)))) reason)
                          (unless (eq dimension :stack)
                            ;; The exact stack boundary promises entry, not later
                            ;; operand growth. Other exact dimensions also execute
                            ;; this no-managed-allocation ML callback for real.
                            (let* ((inputs (maclina.vm-cross::vm-values (cap-vm o)))
                                   (result (funcall (cap-fn o 'cl:mapc) fn
                                                    (first inputs) (second inputs))))
                              ;; No managed allocation before this borrowed return
                              ;; is checked and then discarded by its native caller.
                              (assert (= 11 (workload-read-slot (cap-env o) result :car)))
                              (assert (null (workload-read-slot (cap-env o) result :cdr))))
                            (assert (= 1 (cap-owner-calls o)))
                            (assert (= 65 (cap-owner-sum o))))))
                    (cap-note o (list :actual-mapc-proved-or-stack-entry-only dimension :one-short short))
                    ;; Physical arrays remain small. A legitimate empty MAPC
                    ;; retry must not invoke another callback or claim an extent.
                    (let ((calls (cap-owner-calls o)))
                      (assert (null (funcall (cap-fn o 'cl:mapc)
                                             (cap-fn o 'cap-callback) nil nil)))
                      (assert (= calls (cap-owner-calls o))))
                    (cap-note o (list :empty-retry-proved dimension :one-short short))
                    (when short
                      ;; Expected admission rejection has been proved. Release
                      ;; only this case's callback owner so a deliberately short
                      ;; control queue can now collect the still-live INPUTS.
                      ;; This is not cleanup after an unexpected test failure.
                      (clostrum:fmakunbound (cap-client o) (cap-guest o) 'cap-callback)
                      (let ((record (cap-full-cycle o)))
                        (assert (= 2 (cycle-result-count record :objects-discovered)))
                        (assert (= 2 (cycle-result-count record :objects-moved))))
                      (let ((inputs (maclina.vm-cross::vm-values (cap-vm o))))
                        (assert (= 2 (length inputs)))
                        (loop for input in inputs for expected in '(11 13) do
                          (assert (= expected (workload-read-slot (cap-env o) input :car)))
                          (assert (null (workload-read-slot (cap-env o) input :cdr))))))
                    (cap-finish o))))))))))))

(defun cap-observed-mapc (function left right)
  ;; Deliberate test boundary: transfer inputs immediately to the production
  ;; primitive, then never reload these host locals after managed execution.
  (let* ((o *cap-active*) (p (cap-owner-provider o)))
    (setf (cap-owner-reservation o)
          (clamsara::%provider-mapc-admission p function 2))
    (funcall (cap-fn o 'cl:mapc) function left right)))
(defun cap-run-snapshot-witness ()
  (cap-with-fixture-methods
   (lambda ()
     (let ((o (cap-new '(:roots 4096 :stack 1024))))
       (cap-guard o
        (lambda ()
          (cap-prepare o)
          (cap-note o :shared-control-aliases)
          (let ((before (multiple-value-list
                          (clamsara::%provider-root-demand (cap-owner-provider o)))))
            (cap-fset o 'cap-alias (cap-fn o 'cap-callback))
            (assert (eq (cap-fn o 'cap-alias) (cap-fn o 'cap-callback)))
            (assert (equal before (multiple-value-list
                                   (clamsara::%provider-root-demand
                                    (cap-owner-provider o))))))
          (assert (plusp (cycle-result-count (cap-full-cycle o) :objects-moved)))
          (cap-fset o 'cap-observed-mapc #'cap-observed-mapc)
          (cap-note o :actual-callback-entry-snapshot)
          (let ((*cap-active* o) (*cap-entry-witness-enabled* t))
            (workload-eval (cap-env o)
              '(cap-observed-mapc #'cap-callback (cons 11 nil) (cons 13 nil))))
          (assert (= 1 (cap-owner-calls o)))
          (assert (= 65 (cap-owner-sum o)))
          (assert (>= (cap-owner-moving-cycles o) 2))
          (let ((result (first (maclina.vm-cross::vm-values (cap-vm o)))))
            (assert (= 11 (workload-read-slot (cap-env o) result :car)))
            (assert (null (workload-read-slot (cap-env o) result :cdr))))
          (cap-finish o)))))))

(defun cap-inner-attempt ()
  ;; Native test observer takes no managed arguments. Before collection the
  ;; temporary snapshots/borrowed refs end their host lexical extent.
  (let* ((o *cap-active*) (p (cap-owner-provider o)))
    (assert (= 5 (clamsara::workload-provider-native-cell-count p)))
    (cap-expect-rejection o
      (lambda ()
        (let ((cells (clamsara::workload-provider-native-cells p)))
          (funcall (cap-fn o 'cl:mapc) (cap-fn o 'cap-inner)
                   (car (aref cells 1)) (car (aref cells 2)))))
      :native-cell-capacity-exhausted)
    (incf (cap-owner-inner-rejections o))
    (assert (plusp (cycle-result-count (cap-full-cycle o) :objects-moved)))))
(defun cap-run-nested-rejection ()
  (cap-with-fixture-methods
   (lambda ()
     (let ((o (cap-new '(:roots 4096 :cells 5 :frames 128 :stack 1024))))
       (cap-guard o
        (lambda ()
          (cap-prepare o)
          (cap-fset o 'cap-inner-attempt #'cap-inner-attempt)
          (cap-fset o 'cap-inner
            (workload-eval (cap-env o)
              '(lambda (x y) (declare (ignore x y))
                 (error 'cap-unexpected-callback))))
          (cap-fset o 'cap-outer
            (workload-eval (cap-env o)
              '(let ((capture (cons 7 nil)))
                 (lambda (x y)
                   (cap-inner-attempt)
                   ;; All payload reads happen AFTER inner rejection and GC.
                   (cap-record-row (+ (car x) (car y) (car capture)))))))
          (cap-note o :nested-inner-rejection-outer-movement)
          (let ((*cap-active* o))
            (workload-eval (cap-env o)
              '(funcall #'mapc #'cap-outer
                 (cons (cons 1 nil) (cons (cons 2 nil) nil))
                 (cons (cons 10 nil) (cons (cons 20 nil) nil)))))
          (assert (= 2 (cap-owner-inner-rejections o)))
          (assert (= 2 (cap-owner-calls o)))
          (assert (= 47 (cap-owner-sum o)))
          (assert (= 2 (cap-owner-moving-cycles o)))
          (assert (zerop (clamsara::workload-provider-native-cell-count
                          (cap-owner-provider o))))
          (assert (zerop (clamsara::workload-provider-frame-count
                          (cap-owner-provider o))))
          (let* ((result (first (maclina.vm-cross::vm-values (cap-vm o))))
                 (second (workload-read-slot (cap-env o) result :cdr)))
            (assert (= 1 (workload-read-slot (cap-env o)
                           (workload-read-slot (cap-env o) result :car) :car)))
            (assert (= 2 (workload-read-slot (cap-env o)
                           (workload-read-slot (cap-env o) second :car) :car)))
            (assert (null (workload-read-slot (cap-env o) second :cdr))))
          (cap-finish o)))))))

;;;; Deliberate scope limits:
;;;; - No arbitrary native callback capture/managed-local safety claim.
;;;; - Capacity numbers come from a roomy SAME-SOURCE construction; replay
;;;;   mismatches/setup failure are failed/unreached tests, never capacity passes.
;;;; - Current census/snapshot equality cannot prove roots omitted by both walks.
;;;;   The actual callback/nested moving-payload witnesses are separate checks.
;;;; - Entry reservation does not bound arbitrary later callback VM stack work.
;;;; - No invalid/mutating-list or reduced benchmark acceptance case is included.
