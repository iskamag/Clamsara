;;;; test/v11-metadata-contract.lisp -- standalone SBCL contract test for
;;;; the paper-v11 logical metadata kernel (src/core/metadata.lisp).
;;;;
;;;; Run:  sbcl --script test/v11-metadata-contract.lisp
;;;;
;;;; Normative sources: paper-v11/chapters/strata.tex (facts, scalar-stratum
;;;; formula, protocol, transfer, concurrency, persistence),
;;;; client-protocols.tex section 1 (offered fields, raw-copy separation,
;;;; weaker-operation rejection), composition.tex (merge with provenance,
;;;; conflicts, silent fallback is non-conforming).
;;;;
;;;; Covers: declaration validation of every closed vocabulary and
;;;; concurrency/transfer/reset rule; compatible merge, dedup, refinement
;;;; of unspecified attributes, alternative narrowing, and complete
;;;; provenance on conflicts (key, attribute, both sides, all providers);
;;;; offered-field acceptance only when width, values, kinds, atomicity,
;;;; order, copy/checkpoint/reset interactions all meet the declarations;
;;;; field rejection then side placement with boot-supplied storage;
;;;; exactly one authoritative EQ handle per key; placement attempted only
;;;; as declared (no silent table fallback, no weaker-atomicity or
;;;; weaker-order binding); bounds/default/reset and bit/integer/reference
;;;; operations with unknown-key rejection instead of silent fallback; all
;;;; six declared movement policies with the client's raw object copy kept
;;;; separate; boot-table realization declared-only, bounded, with
;;;; explicit exhaustion and no runtime growth; and warmed single / 100 repeated
;;;; side-vector read/write/CAS/reset windows measured at exactly zero
;;;; SBCL host bytes with configuration and CLOS dispatch outside the
;;;; measured windows.
;;;;
;;;; Scope note: the zero-byte claim covers the side-vector realization
;;;; only.  The boot-table realization offers :plain atomicity at :relaxed
;;;; order under the caller's coordination, and this test makes NO
;;;; no-allocation claim for it or for offered fields.  Side storage is
;;;; boot-sized once; the test asserts exhaustion is explicit when a
;;;; runtime write would exceed the declared boot size.

(cl:load (merge-pathnames "../src/protocol/object-model.lisp"
                          (make-pathname :defaults *load-truename*)))
(cl:load (merge-pathnames "../src/protocol/atomics.lisp"
                          (make-pathname :defaults *load-truename*)))
(cl:load (merge-pathnames "../src/core/metadata.lisp"
                          (make-pathname :defaults *load-truename*)))

(defpackage :v11-metadata-contract-test
  (:use :cl :clamsara-metadata :clamsara-protocol.object-model))

(in-package :v11-metadata-contract-test)

;;; --- harness ---------------------------------------------------------

(defparameter *checks* 0)
(defparameter *failures* ())

(defmacro check (label form)
  (let ((value (gensym "VALUE")))
    `(let ((,value ,form))
       (incf *checks*)
       (unless ,value (push ,(string label) *failures*))
       ,value)))

(defun rejected (thunk)
  "The METADATA-ERROR signaled by THUNK, :WRONG-ERROR for a foreign
condition, or NIL when nothing was signaled."
  (handler-case (progn (funcall thunk) nil)
    (metadata-error (c) c)
    (error (c) :wrong-error)))

(defmacro check-rejected (label thunk)
  "Assert THUNK signals a METADATA-ERROR; return the condition."
  (let ((condition (gensym "CONDITION")))
    `(let ((,condition (rejected ,thunk)))
       (incf *checks*)
       (unless (and ,condition
                    (not (eq ,condition :wrong-error))
                    (typep ,condition 'metadata-error))
         (push ,(string label) *failures*))
       ,condition)))

(defun fact-get (condition key)
  (getf (metadata-error-fact condition) key))

;;; --- builders --------------------------------------------------------

(defun mdspec (&key (name (gensym "MD"))
                 (domain :word) (cell-type :bit) width (granularity 1)
                 (default 0) placement (atomicity (list :plain))
                 ownership lifetime (writers :single) (order :relaxed)
                 (transfer :copy) (persistence :ephemeral) (reset :default)
                 kinds recompute merge-function)
  ;; WIDTH is passed only when supplied: make-metadata-specification
  ;; defaults :bit cells to width 1 and leaves others unspecified for
  ;; the declaration checks to judge.
  (let ((args (list :name name :domain domain :cell-type cell-type
                    :granularity granularity :default default
                    :placement (or placement (list :side-vector))
                    :atomicity atomicity :ownership ownership
                    :lifetime lifetime :writers writers :order order
                    :transfer transfer :persistence persistence
                    :reset reset :kinds kinds :recompute recompute
                    :merge-function merge-function)))
    (when width
      (setf args (list* :width width args)))
    (apply #'make-metadata-specification args)))

(defparameter *spy-requests* ())

(defclass test-atomics () ())
(defvar *atomic-events* nil)
(defmethod clamsara-protocol.atomics:atomic-load ((client test-atomics) place order)
  (assert (eq order :relaxed))
  (push :load *atomic-events*)
  (svref (car place) (cdr place)))
(defmethod clamsara-protocol.atomics:atomic-store
    ((client test-atomics) place value order)
  (assert (eq order :relaxed))
  (push :store *atomic-events*)
  (setf (svref (car place) (cdr place)) value))
(defmethod clamsara-protocol.atomics:atomic-cas
    ((client test-atomics) place old new order)
  (assert (eq order :relaxed))
  (push :cas *atomic-events*)
  ;; Sequential protocol spy: verifies routing, not concurrent execution.
  (let ((previous (svref (car place) (cdr place))))
    (when (eql previous old)
      (setf (svref (car place) (cdr place)) new))
    previous))

(defun vector-layout (&optional atomic-p)
  "Boot supply: a dense simple-vector sized to the request and initialized
to the requesting datum's declared default."
  (lambda (request)
    (push request *spy-requests*)
    (let ((storage (make-array (side-request-cells request)
                         :initial-element
                         (metadata-default
                          (side-request-specification request)))))
    (make-side-storage
     :vector storage
     :atomics (and atomic-p (make-instance 'test-atomics))
     :places (and atomic-p
                  (map 'vector #'identity
                       (loop for i below (length storage) collect (cons storage i))))
     :base (side-request-base request)
     :cells (side-request-cells request)))))

(defun table-layout ()
  "Boot supply: a fixed-capacity EQ table sized to the request."
  (lambda (request)
    (push request *spy-requests*)
    (make-side-storage :vector (make-metadata-table (side-request-cells request))
                       :base (side-request-base request)
                       :cells (side-request-cells request))))

(defun constant-layout (supply)
  (lambda (request)
    (declare (ignore request))
    supply))

(defun bind-one (spec &key layout object-model field-guarantees
                    (base 0) (extent 0) object-cells (region-count 0))
  (let ((registry (merge-metadata (list (make-contribution :test spec)))))
    (values
     (bind-metadata registry
                    :object-model object-model
                    :field-guarantees field-guarantees :layout layout
                    :base base :extent extent :object-cells object-cells
                    :region-count region-count)
     registry)))

;;; Toy object-model client offering one physical metadata field whose
;;; guarantee plist the test rewrites per case (client-protocols.tex
;;; section 1: each field declares width, admissible values, atomicity,
;;; copy/checkpoint interaction, and possessing kinds).
(defclass toy-client () ())

(defparameter *toy-field* :mark-field)
(defparameter *toy-cells* (make-hash-table :test #'eq))
(defparameter *toy-guarantees* (make-hash-table :test #'eq))

(defun set-toy-guarantees (&key (width 1) values (atomicity :bit-atomic)
                             (order :relaxed) (copy :clears)
                             (checkpoint :lost) kinds)
  (setf (gethash *toy-field* *toy-guarantees*)
        (list :width width :values values :atomicity atomicity
              :order order :copy copy :checkpoint checkpoint :kinds kinds)))

(defun field-cells (field)
  (let ((cells (gethash field *toy-cells*)))
    (unless cells
      (setf cells (make-hash-table :test #'eq)
            (gethash field *toy-cells*) cells))
    cells))

(defun toy-guarantees (field)
  (gethash field *toy-guarantees*))

(defmethod offered-metadata-fields ((c toy-client))
  (list *toy-field*))

(defmethod field-read ((c toy-client) field key)
  (gethash key (field-cells field) 0))

(defmethod field-write ((c toy-client) field key value)
  (setf (gethash key (field-cells field)) value)
  value)

(defmethod field-cas ((c toy-client) field key old new)
  (let ((previous (gethash key (field-cells field) 0)))
    (when (eql previous old)
      (setf (gethash key (field-cells field)) new))
    previous))

;;; The client's raw copy copies payload only.  It copies NO metadata
;;; field: paper-v11 client-protocols.tex section 1 forbids
;;; copy-object-representation from deciding that mark/age/public/
;;; forwarding state survives.
(defmethod copy-object-representation ((c toy-client) source destination)
  (setf (gethash destination (field-cells :payload))
        (gethash source (field-cells :payload)))
  destination)

;;; --- 1. declaration validation ---------------------------------------

(check valid-specification-accepted
       (mdspec :name :ok :domain :object :cell-type :bit
               :placement (list :side-table) :transfer :copy))

(check-rejected bad-domain-rejected
                (lambda () (mdspec :name :x :domain :galaxy)))

(check-rejected bad-cell-type-rejected
                (lambda () (mdspec :name :x :cell-type :float)))

(check-rejected bad-placement-vocabulary-rejected
                (lambda () (mdspec :name :x :placement (list :banana))))

(check-rejected side-vector-object-domain-rejected
                (lambda () (mdspec :name :x :domain :object
                                   :cell-type :bit
                                   :placement (list :side-vector)
                                   :atomicity (list :bit-atomic))))

(check-rejected side-table-word-domain-rejected
                (lambda () (mdspec :name :x :domain :word
                                   :placement (list :side-table))))

(check-rejected bit-width-contradiction-rejected
                (lambda () (mdspec :name :x :cell-type :bit :width 2)))

(check-rejected integer-width-required
                (lambda () (mdspec :name :x :cell-type :integer
                                   :width nil)))

(check-rejected granularity-required-for-word-domain
                (lambda () (mdspec :name :x :domain :word
                                   :granularity nil)))

(check-rejected bit-default-rejected
                (lambda () (mdspec :name :x :cell-type :bit :default 2
                                   :width nil)))

(check-rejected concurrent-bit-requires-atomic-operation
                (lambda () (mdspec :name :x :cell-type :bit
                                   :writers :concurrent
                                   :atomicity (list :plain))))

(check-rejected concurrent-multi-bit-requires-cas-exclusive-or-log
                (lambda () (mdspec :name :x :width 8
                                   :writers :concurrent
                                   :atomicity (list :plain))))

(check-rejected merge-transfer-requires-merge-function
                (lambda () (mdspec :name :x :transfer :merge)))

(check-rejected reconstructible-requires-reconstruction
                (lambda () (mdspec :name :x :persistence :reconstructible)))

(check-rejected retain-region-requires-region-domain
                (lambda () (mdspec :name :x :domain :word
                                   :transfer :retain-region)))

(check-rejected recompute-reset-requires-recompute-function
                (lambda () (mdspec :name :x :reset :recompute)))

(check-rejected discard-transfer-requires-runnable-reset
                (lambda () (mdspec :name :x :transfer :discard
                                   :reset :forbidden)))

;;; --- 2. merge, dedup, refinement, provenance -------------------------

(let* ((first (mdspec :name :mark :domain :object :cell-type :bit
                      :placement (list :side-table) :transfer :copy))
       (same (mdspec :name :mark :domain :object :cell-type :bit
                     :placement (list :side-table) :transfer :copy))
       (registry (merge-metadata
                  (list (make-contribution :x first)
                        (make-contribution :x same))))
       (merged (find-metadata-specification registry :mark)))
  (check identical-recontribution-deduplicates
         (= 1 (length (registry-specifications registry))))
  (check dedup-keeps-one-provider
         (equal '(:x) (specification-providers merged))))

(let* ((a (mdspec :name :mark :domain :object :cell-type :bit
                  :placement (list :side-table) :transfer :copy))
       (b (mdspec :name :mark :domain :object :cell-type :bit
                  :placement (list :side-table) :transfer :copy
                  :ownership :collector :lifetime :epoch))
       (c (mdspec :name :mark :domain :object :cell-type :bit
                  :placement (list :side-table) :transfer :copy))
       (registry (merge-metadata
                  (list (make-contribution :x a)
                        (make-contribution :y b)
                        (make-contribution :z c))))
       (merged (find-metadata-specification registry :mark)))
  (check refinement-stores-unspecified-attributes
         (and (eq (metadata-ownership merged) :collector)
              (eq (metadata-lifetime merged) :epoch)))
  (check provenance-lists-all-contributors-in-order
         (equal '(:x :y :z) (specification-providers merged))))

(let* ((a (mdspec :name :p :domain :object :cell-type :bit
                  :placement (list :offered-field :side-table)
                  :atomicity (list :plain :bit-atomic :cas)
                  :transfer :copy))
       (b (mdspec :name :p :domain :object :cell-type :bit
                  :placement (list :side-table)
                  :atomicity (list :bit-atomic) :transfer :copy))
       (registry (merge-metadata
                  (list (make-contribution :x a)
                        (make-contribution :y b))))
       (merged (find-metadata-specification registry :p)))
  (check alternatives-narrow-by-intersection
         (and (equal '(:side-table) (metadata-placement merged))
              (equal '(:bit-atomic) (metadata-atomicity merged)))))

(let* ((a (mdspec :name :k1 :transfer :copy))
       (b (mdspec :name :k2 :transfer :copy))
       (registry (merge-metadata
                  (list (make-contribution :x a)
                        (make-contribution :y b)))))
  (check merge-keeps-first-mention-order
         (equal '(:k1 :k2)
                (mapcar #'metadata-name
                        (registry-specifications registry))))
  (check merge-determinism
         (let ((again (merge-metadata
                       (list (make-contribution :x (mdspec :name :k1
                                                           :transfer :copy))
                             (make-contribution :y (mdspec :name :k2
                                                           :transfer :copy))))))
           (equal (mapcar #'metadata-name
                          (registry-specifications registry))
                  (mapcar #'metadata-name
                          (registry-specifications again))))))

(let ((condition (check-rejected conflict-domain-disagrees
                                 (lambda ()
                                   (merge-metadata
                                    (list (make-contribution :x (mdspec :name :m :transfer :copy))
                                          (make-contribution :y (mdspec :name :m :domain :page :granularity 4096 :transfer :copy))))))))
  (when (typep condition 'metadata-conflict)
    (check conflict-names-key
           (eq :m (fact-get condition :specification)))
    (check conflict-names-attribute
           (eq :domain (fact-get condition :attribute)))
    (check conflict-names-both-values
           (and (eq :word (fact-get condition :existing))
                (eq :page (fact-get condition :offending))))
    (check conflict-names-existing-providers
           (equal '(:x) (fact-get condition :existing-providers)))
    (check conflict-names-offending-provider
           (eq :y (fact-get condition :offending-provider)))
    (check conflict-provenance-covers-all-providers
           (and (member :x (metadata-error-contributors condition))
                (member :y (metadata-error-contributors condition))))))

(check-rejected conflict-placement-disjoint
                (lambda ()
                  (merge-metadata
                   (list (make-contribution :x (mdspec :name :m :placement (list :offered-field) :transfer :copy))
                         (make-contribution :y (mdspec :name :m :placement (list :side-table) :transfer :copy))))))

(check-rejected conflict-atomicity-disjoint
                (lambda ()
                  (merge-metadata
                   (list (make-contribution :x (mdspec :name :m :atomicity (list :bit-atomic) :transfer :copy))
                         (make-contribution :y (mdspec :name :m :atomicity (list :cas) :transfer :copy))))))

(check merge-kinds-retains-every-required-kind
       (equal '(:cons :vector)
              (metadata-kinds
               (find-metadata-specification
                (merge-metadata
                 (list (make-contribution :x (mdspec :name :m :kinds '(:cons)))
                       (make-contribution :y (mdspec :name :m :kinds '(:vector)))))
                :m))))

;;; --- 3. offered-field guarantee matching -----------------------------

(set-toy-guarantees)
(defparameter *toy* (make-instance 'toy-client))

(defun bind-field-datum (&key (placement (list :offered-field))
                               (persistence :ephemeral) (reset :default)
                               recompute &allow-other-keys)
  (bind-one (mdspec :name :fmark :domain :object :cell-type :bit
                    :placement placement
                    :atomicity (list :bit-atomic)
                    :transfer :clear :persistence persistence
                    :reset reset :recompute recompute)
            :object-model *toy*
            :field-guarantees #'toy-guarantees))

(check field-accepted-when-every-guarantee-matches
       (let ((binding (bind-field-datum)))
         (and (eq :offered-field
                  (handle-placement (find-metadata binding :fmark)))
              (eq :bit-atomic
                  (handle-atomicity (find-metadata binding :fmark))))))

(check field-width-below-declaration-rejects-then-side-placement
       (progn
         (set-toy-guarantees)
       ;; the field is 1 bit wide; the datum declares 8.  The field is
       ;; rejected and the composition continues on side placement with
       ;; boot-supplied storage.
       (let ((binding (bind-one (mdspec :name :wide :domain :object
                                        :cell-type :integer :width 8
                                        :placement (list :offered-field
                                                         :side-table)
                                        :transfer :copy)
                                :object-model *toy*
                                :field-guarantees #'toy-guarantees
                                :layout (table-layout)
                                :object-cells 8)))
         (eq :side-table
             (handle-placement (find-metadata binding :wide))))))

(check field-values-reject-inadmissible-default
       (let ((binding (bind-one (mdspec :name :vm :domain :object
                                        :cell-type :bit
                                        :placement (list :offered-field
                                                         :side-table)
                                        :atomicity (list :plain)
                                        :transfer :clear)
                                :object-model *toy*
                                :field-guarantees
                                (lambda (f)
                                  (declare (ignore f))
                                  (list :width 1 :values (list 1)
                                        :atomicity :bit-atomic
                                        :copy :clears :checkpoint :lost))
                                :layout (table-layout)
                                :object-cells 8)))
         (eq :side-table
             (handle-placement (find-metadata binding :vm)))))

(check field-atomicity-weaker-rejects
       (progn
         (set-toy-guarantees :atomicity :plain)
       (let ((condition (check-rejected
                         field-atomicity-weaker-rejected
                         (lambda () (bind-field-datum)))))
         (or (null condition) (typep condition 'metadata-unsupported)))))

(check field-order-weaker-rejects
       ;; the datum declares :acquire; the field documents :relaxed
       (progn
         (set-toy-guarantees :order :relaxed)
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :omark :domain :object
                                   :cell-type :bit
                                   :placement (list :offered-field)
                                   :atomicity (list :bit-atomic)
                                   :order :acquire :transfer :clear)
                           :object-model *toy*
                           :field-guarantees #'toy-guarantees)))
              'metadata-unsupported)))

(check field-order-stronger-accepts
       (progn
         (set-toy-guarantees :order :sequential)
       (eq :offered-field
           (handle-placement
            (find-metadata
             (bind-one (mdspec :name :smark :domain :object :cell-type :bit
                               :placement (list :offered-field)
                               :atomicity (list :bit-atomic)
                               :order :acquire :transfer :clear)
                       :object-model *toy*
                       :field-guarantees #'toy-guarantees)
             :smark)))))

(check field-copy-duplicates-must-not-host-clear-policy
       (progn
         (set-toy-guarantees :copy :copies)
       (typep (rejected (lambda () (bind-field-datum)))
              'metadata-unsupported)))

(check field-copy-matches-copy-policy
       (progn
         (set-toy-guarantees :copy :copies)
       (eq :offered-field
           (handle-placement
            (find-metadata
             (bind-one (mdspec :name :cmark :domain :object :cell-type :bit
                               :placement (list :offered-field)
                               :atomicity (list :bit-atomic)
                               :transfer :copy)
                       :object-model *toy*
                       :field-guarantees #'toy-guarantees)
             :cmark)))))

(check raw-copy-separation-non-copy-policies-require-clearing-field
       (let ((ok t))
         (dolist (policy '(:clear :merge :recompute :discard) ok)
           (set-toy-guarantees :copy :clears)
           (let ((spec (mdspec :name (gensym "P") :domain :object
                               :cell-type :bit
                               :placement (list :offered-field)
                               :atomicity (list :bit-atomic)
                               :transfer policy
                               :merge-function #'+
                               :recompute (lambda (k v)
                                            (declare (ignore k v))
                                            0))))
             (unless (eq :offered-field
                         (handle-placement
                          (find-metadata
                           (bind-one spec :object-model *toy*
                                     :field-guarantees #'toy-guarantees)
                           (metadata-name spec))))
               (setf ok nil))))))

(check retain-region-can-never-be-field-backed
       ;; :retain-region requires a region domain; offered fields require
       ;; :object -- so the pair is a declaration error, not a fallback.
       (typep (rejected
               (lambda ()
                 (mdspec :name :rr :domain :region
                         :placement (list :offered-field)
                         :transfer :retain-region)))
              'metadata-invalid))

(check field-checkpoint-authoritative-requires-preserved
       (progn
         (set-toy-guarantees :checkpoint :lost)
         (typep (rejected
                 (lambda ()
                   (bind-field-datum :persistence :authoritative)))
                'metadata-unsupported)))

(check field-checkpoint-reconstructible-preserved-needs-recompute-reset
       (let ((accepts
               ;; declared reconstruction runs before reclamation resumes
               (eq :offered-field
                   (handle-placement
                    (find-metadata
                     (bind-one (mdspec :name :r1 :domain :object
                                       :cell-type :bit
                                       :placement (list :offered-field)
                                       :atomicity (list :bit-atomic)
                                       :transfer :clear
                                       :persistence :reconstructible
                                       :reset :recompute
                                       :recompute (lambda (k v)
                                                    (declare (ignore k v))
                                                    0))
                               :object-model *toy*
                               :field-guarantees #'toy-guarantees)
                     :r1))))
             (rejects
               (progn (set-toy-guarantees :checkpoint :preserved)
                      (typep (rejected
                              (lambda ()
                                (bind-one (mdspec :name :r2 :domain :object
                                                  :cell-type :bit
                                                  :placement
                                                  (list :offered-field)
                                                  :atomicity
                                                  (list :bit-atomic)
                                                  :transfer :clear
                                                  :persistence
                                                  :reconstructible
                                                  :reset :default
                                                  :recompute
                                                  (lambda (k v)
                                                    (declare (ignore k v))
                                                    0))
                                          :object-model *toy*
                                          :field-guarantees
                                          #'toy-guarantees)))
                             'metadata-unsupported))))
         (set-toy-guarantees)
         (and accepts rejects)))

(check field-checkpoint-ephemeral-requires-lost
       (let ((rejects
               (progn (set-toy-guarantees :checkpoint :preserved)
                      (typep (rejected (lambda () (bind-field-datum)))
                             'metadata-unsupported)))
             (accepts
               (progn (set-toy-guarantees :checkpoint :lost)
                      (eq :offered-field
                          (handle-placement
                           (find-metadata (bind-field-datum) :fmark))))))
         (set-toy-guarantees)
         (and rejects accepts)))

(check field-kinds-must-cover-declared-kinds
       (let ((rejects
               (progn (set-toy-guarantees :kinds (list :vector))
                      (typep (rejected
                              (lambda ()
                                (bind-one (mdspec :name :kk :domain :object
                                                  :cell-type :bit
                                                  :placement
                                                  (list :offered-field)
                                                  :atomicity
                                                  (list :bit-atomic)
                                                  :transfer :clear
                                                  :kinds (list :cons))
                                          :object-model *toy*
                                          :field-guarantees
                                          #'toy-guarantees)))
                             'metadata-unsupported)))
             (accepts
               (progn (set-toy-guarantees :kinds (list :cons :vector))
                      (eq :offered-field
                          (handle-placement
                           (find-metadata
                            (bind-one (mdspec :name :kk2 :domain :object
                                              :cell-type :bit
                                              :placement (list :offered-field)
                                              :atomicity (list :bit-atomic)
                                              :transfer :clear
                                              :kinds (list :cons))
                                      :object-model *toy*
                                      :field-guarantees #'toy-guarantees)
                            :kk2)))))
             (universal-rejects
               (progn (set-toy-guarantees :kinds (list :cons))
                      (typep (rejected (lambda () (bind-field-datum)))
                             'metadata-unsupported))))
         (set-toy-guarantees)
         (and rejects accepts universal-rejects)))

(check field-rejection-fails-construction-with-reasons
       (progn
         (set-toy-guarantees :atomicity :plain)
         (let ((condition (rejected (lambda () (bind-field-datum)))))
           (let ((attempts (and (typep condition 'metadata-unsupported)
                                (fact-get condition :attempts))))
             (and (eq :no-legal-placement (fact-get condition :reason))
                  (= 1 (length attempts))
                  (eq :offered-field
                      (getf (first attempts) :alternative))
                  (consp (getf (first attempts) :reason)))))))

;;; --- 4. binding: one authoritative handle per key --------------------

(let* ((specs (list (mdspec :name :alpha :transfer :copy)
                    (mdspec :name :beta :transfer :copy)))
       (registry (merge-metadata
                  (mapcar (lambda (s) (make-contribution :x s)) specs)))
       (binding (bind-metadata registry :layout (vector-layout)
                               :extent 256))
       (alpha (find-metadata binding :alpha))
       (beta (find-metadata binding :beta)))
  (check one-handle-per-key
         (and (= 2 (length (binding-handles binding)))
              (eq alpha (find-metadata binding :alpha))
              (eq beta (find-metadata binding :beta))
              (not (eq alpha beta))
              (= 1 (count :alpha (binding-handles binding)
                          :key #'handle-name))))
  (check binding-preserves-registry-order
         (equal '(:alpha :beta) (mapcar #'handle-name
                                        (binding-handles binding)))))

(let* ((spec (mdspec :name :geo :domain :word :cell-type :integer
                     :granularity 8 :width 8 :transfer :copy))
       (base #x1000)
       (binding (bind-one spec :layout (vector-layout)
                          :base base :extent 4096))
       (request (car *spy-requests*)))
  (check side-request-carries-derived-geometry
         (and (eq :vector (side-request-kind request))
              (= 512 (side-request-cells request))
              (= base (side-request-base request))
              (= 8 (side-request-granularity request))
              (eq :word (side-request-domain request))
              (= 8 (side-request-width request))))
  (check side-vector-uses-boot-supplied-storage
         (let ((handle (find-metadata binding :geo)))
           (and (eq :side-vector (handle-placement handle))
                (= 512 (vector-cells handle))
                (= base (vector-base handle))
                (= 8 (vector-granularity handle))))))

(check layout-must-return-side-storage
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :bad :transfer :copy)
                           :layout (constant-layout 42))))
              'metadata-unsupported))

(check undersized-side-storage-rejected
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :short :transfer :copy)
                           :layout (constant-layout
                                    (make-side-storage
                                     :vector (make-array 8
                                                         :initial-element 0)
                                     :base 0 :cells 8))
                           :extent 256)))
              'metadata-unsupported))

(check missing-layout-callback-rejects-side-placement
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :nolayout :transfer :copy))))
              'metadata-unsupported))

(check table-offered-as-vector-supply-does-not-silently-host
       ;; a table supply cannot satisfy a :vector request, and the
       ;; binder must not fall back to a placement nobody declared
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :nofallback :transfer :copy)
                           :layout (table-layout))))
              'metadata-unsupported))

(check exclusive-atomicity-rejects-side-vector
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :excl :atomicity (list :exclusive)
                                   :transfer :copy))))
              'metadata-unsupported))

(check sealed-log-atomicity-rejects-side-vector
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :slog :atomicity (list :sealed-log)
                                   :transfer :copy))))
              'metadata-unsupported))

(check sequential-order-rejects-side-vector
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :seq :order :sequential
                                   :transfer :copy))))
              'metadata-unsupported))

(check cas-atomicity-rejects-side-table
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :tcas :domain :object :cell-type :integer :width 8
                                   :placement (list :side-table)
                                   :atomicity (list :cas)
                                   :transfer :copy)
                           :layout (table-layout)
                           :object-cells 8)))
              'metadata-unsupported))

(check cas-atomicity-binds-side-vector
       (eq :side-vector
           (handle-placement
            (find-metadata
             (bind-one (mdspec :name :vcas :atomicity (list :cas)
                               :transfer :copy)
                       :layout (vector-layout t) :extent 64)
             :vcas))))

(check table-supply-must-be-preallocated-and-declared
       (and (typep (rejected
                    (lambda ()
                      (bind-one (mdspec :name :teq :domain :object
                                        :placement (list :side-table)
                                        :transfer :copy)
                                :layout (constant-layout
                                         (make-side-storage
                                          :vector (make-hash-table)
                                          :base 0 :cells 8))
                                :object-cells 8)))
                   'metadata-unsupported)
            (typep (rejected
                    (lambda ()
                      (bind-one (mdspec :name :tshort :domain :object
                                        :placement (list :side-table)
                                        :transfer :copy)
                                :layout (constant-layout
                                         (make-side-storage
                                          :vector
                                          (make-metadata-table 8)
                                          :base 0 :cells 8))
                                :object-cells 1024)))
                   'metadata-unsupported)))

;;; --- 5. side-vector operations ---------------------------------------

(defun vector-binding (&key (name :vword) (granularity 1) (width 8)
                         (extent 256) (base 0) (reset :default)
                         (cell-type :integer) recompute)
  (bind-one (mdspec :name name :domain :word :cell-type cell-type
                    :granularity granularity :width width :reset reset
                    :recompute recompute :transfer :copy)
            :layout (vector-layout) :base base :extent extent))

(check vector-ref-reads-boot-default
       (let* ((binding (vector-binding))
              (h (find-metadata binding :vword)))
         (= 0 (metadata-ref h 0))))

(let* ((binding (vector-binding :name :vfloor :granularity 8
                                :extent 256))
       (h (find-metadata binding :vfloor)))
  (metadata-set h 9 5)
  (check vector-formula-floors-address-to-cell
         (and (= 5 (metadata-ref h 9))
              (= 5 (metadata-ref h 15))
              (= 0 (metadata-ref h 16)))))

(let* ((binding (vector-binding :name :vrt))
       (h (find-metadata binding :vrt)))
  (metadata-set h 0 7)
  (metadata-set h 255 9)
  (check vector-set-ref-roundtrip-first-and-last-cell
         (and (= 7 (metadata-ref h 0))
              (= 9 (metadata-ref h 255)))))

(let* ((binding (vector-binding :name :vbnd))
       (h (find-metadata binding :vbnd)))
  (check vector-key-before-base-rejected
         (typep (rejected (lambda () (metadata-ref h -1)))
                'metadata-key-error))
  (check vector-key-beyond-extent-rejected
         (typep (rejected (lambda () (metadata-ref h 256)))
                'metadata-key-error))
  (check vector-non-integer-key-rejected
         (typep (rejected (lambda () (metadata-ref h 'foo)))
                'metadata-key-error))
  (check vector-set-beyond-extent-rejected
         (typep (rejected (lambda () (metadata-set h 256 1)))
                'metadata-key-error)))

(let* ((binding (vector-binding :name :vw4 :width 4))
       (h (find-metadata binding :vw4)))
  (check vector-integer-cell-width-bound
         (and (= 15 (metadata-set h 3 15))
              (typep (rejected (lambda () (metadata-set h 3 16)))
                     'metadata-key-error))))

(let* ((binding (vector-binding :name :vbit :cell-type :bit :width nil))
       (h (find-metadata binding :vbit)))
  (metadata-set-bit h 4)
  (check vector-bit-set-clear-roundtrip
         (and (= 1 (metadata-ref h 4))
              (progn (metadata-clear-bit h 4) (= 0 (metadata-ref h 4)))))
  (check vector-bit-operation-on-non-bit-cell-rejected
         (let* ((int-binding (vector-binding :name :vint))
                (int-h (find-metadata int-binding :vint)))
           (typep (rejected (lambda () (metadata-set-bit int-h 4)))
                  'metadata-key-error)))
  (check vector-bit-value-domain-restricted
         (typep (rejected (lambda () (metadata-set h 4 2)))
                'metadata-key-error)))

(let* ((marker (cons 'marker nil))
       (binding (vector-binding :name :vref :cell-type :reference
                                :width 8))
       (h (find-metadata binding :vref)))
  (metadata-set h 5 marker)
  (check vector-reference-identity-roundtrip
         (eq marker (metadata-ref h 5))))

(let* ((binding (vector-binding :name :vrst))
       (h (find-metadata binding :vrst))
       (storage (vector-storage h)))
  (metadata-set h 7 9)
  (metadata-reset h 7)
  (check vector-reset-restores-default
         (= 0 (metadata-ref h 7)))
  (check vector-storage-identity-and-size-unchanged
         (and (eq storage (vector-storage h))
              (= 256 (length storage)))))

(let* ((binding (vector-binding :name :vrec :reset :recompute
                                :recompute (lambda (key value)
                                             (declare (ignore key))
                                             (+ value 1))))
       (h (find-metadata binding :vrec)))
  (metadata-reset h 3)
  (check vector-recompute-reset-runs-declared-reconstruction
         (= 1 (metadata-ref h 3))))

(let* ((binding (vector-binding :name :vfor :reset :forbidden))
       (h (find-metadata binding :vfor)))
  (check vector-forbidden-reset-signals
         (typep (rejected (lambda () (metadata-reset h 3)))
                'metadata-key-error)))

(let* ((binding (vector-binding :name :vclr))
       (h (find-metadata binding :vclr)))
  (dotimes (i 10) (metadata-set h i 1))
  (metadata-clear-range h (cons 5 8))
  (check vector-clear-range-is-exclusive-at-end
         (and (= 0 (metadata-ref h 5))
              (= 0 (metadata-ref h 7))
              (= 1 (metadata-ref h 8))))
  (check vector-clear-range-rejects-unknown-start
         (typep (rejected (lambda () (metadata-clear-range h (cons 256 300))))
                'metadata-key-error)))

(let* ((binding (vector-binding :name :vfld))
       (h (find-metadata binding :vfld)))
  (dotimes (i 4) (metadata-set h (+ 10 i) 2))
  (check vector-fold-folds-range-in-order
         (= 8 (metadata-fold h (cons 10 14)
                             (lambda (value acc) (+ value acc)) 0))))

(let* ((binding (vector-binding :name :vmp))
       (h (find-metadata binding :vmp))
       (seen ()))
  (metadata-set h 11 5)
  (metadata-set h 13 6)
  (metadata-map-present h (cons 0 256)
                        (lambda (key value)
                          (push (cons key value) seen)))
  (check vector-map-present-visits-non-default-with-address-keys
         (equal '((13 . 6) (11 . 5)) seen)))

(let* ((source (find-metadata (vector-binding :name :psrc) :psrc))
       (destination (find-metadata (vector-binding :name :pdst) :pdst)))
  (metadata-set source 2 3)
  (check vector-project-copies-cellwise-through-reducer
         (= 3 (progn (metadata-project source destination
                                       (lambda (s d)
                                         (declare (ignore d))
                                         s))
                     (metadata-ref destination 2))))
  (check vector-project-reduces-into-destination
         (progn
           (metadata-set source 3 4)
           (metadata-set destination 3 3)
           (= 7 (progn (metadata-project source destination #'+)
                       (metadata-ref destination 3)))))
  (check vector-project-incompatible-geometry-signals
         (typep (rejected
                 (lambda ()
                   (metadata-project
                    source
                    (find-metadata
                     (vector-binding :name :pdst2 :granularity 4) :pdst2)
                    #'+)))
                'metadata-unsupported)))

;;; --- 6. boot-table realization: declared, bounded, explicit ----------

(check table-bound-only-when-declared
       ;; :object domain with a table supply, but the datum declared
       ;; :side-vector: the binder must fail, never fall back to a table
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :vonly :domain :pair
                                   :placement (list :side-vector)
                                   :transfer :copy)
                           :layout (table-layout)
                           :region-count 4)))
              'metadata-unsupported))

(check table-bound-when-declared
       (let* ((binding (bind-one (mdspec :name :tobj :domain :object
                                         :placement (list :side-table)
                                         :transfer :copy)
                                 :layout (table-layout)
                                 :object-cells 8))
              (h (find-metadata binding :tobj)))
         (and (eq :side-table (handle-placement h))
              (metadata-table-p (table-storage h))
              (= 8 (table-cells h)))))

(let* ((binding (bind-one (mdspec :name :tdef :domain :object :cell-type :integer :width 8
                                  :placement (list :side-table)
                                  :transfer :copy)
                          :layout (table-layout) :object-cells 8))
       (h (find-metadata binding :tdef))
       (table (table-storage h)))
  (check table-ref-reads-default
         (= 0 (metadata-ref h 'obj-a)))
  (metadata-set h 'obj-a 5)
  (check table-set-ref-roundtrip
         (and (= 5 (metadata-ref h 'obj-a))
              (= 1 (metadata-table-count table))))
  (metadata-set h 'obj-a 0)
  (check table-default-write-removes-entry
         (and (= 0 (metadata-table-count table))
              (= 0 (metadata-ref h 'obj-a)))))

(let* ((binding (bind-one (mdspec :name :tcap :domain :object :cell-type :integer :width 8
                                  :placement (list :side-table)
                                  :transfer :copy)
                          :layout (table-layout) :object-cells 4))
       (h (find-metadata binding :tcap))
       (table (table-storage h))
       (keys (list 'k0 'k1 'k2 'k3 'k4)))
  (dotimes (i 4)
    (metadata-set h (nth i keys) (+ i 1)))
  (check table-fills-declared-capacity
         (= 4 (metadata-table-count table)))
  (let ((condition (check-rejected table-exhaustion-is-explicit
                                   (lambda ()
                                     (metadata-set h (nth 4 keys) 5)))))
    (when (typep condition 'metadata-exhausted)
      (check table-exhaustion-names-capacity
             (and (= 4 (fact-get condition :capacity))
                  (eq :side-table (fact-get condition :realization))))))
  (check table-exhaustion-does-not-grow-or-lose-cells
         (and (= 4 (metadata-table-count table))
              (= 1 (metadata-ref h 'k0))
              (= 4 (metadata-ref h 'k3))))
  (metadata-reset h 'k1)
  (metadata-set h 'k4 5)
  (check table-capacity-reuse-after-reset
         (and (= 4 (metadata-table-count table))
              (= 0 (metadata-ref h 'k1))
              (= 5 (metadata-ref h 'k4)))))

(let* ((binding (bind-one (mdspec :name :tbit :domain :object
                                  :cell-type :bit
                                  :placement (list :side-table)
                                  :transfer :copy)
                          :layout (table-layout) :object-cells 2))
       (h (find-metadata binding :tbit))
       (table (table-storage h)))
  (metadata-set-bit h 'a)
  (metadata-set-bit h 'b)
  (check table-set-bit-respects-capacity
         (and (= 2 (metadata-table-count table))
              (typep (rejected (lambda () (metadata-set-bit h 'c)))
                     'metadata-exhausted)))
  (metadata-clear-bit h 'a)
  (check table-clear-bit-removes-default-entry
         (= 1 (metadata-table-count table)))
  (check table-clear-bit-absent-is-noop
         (= 0 (progn (metadata-clear-bit h 'a) (metadata-ref h 'a))))
  (check table-bit-operation-on-non-bit-cell-rejected
         (let ((int-h (find-metadata
                       (bind-one (mdspec :name :tint :domain :object :cell-type :integer :width 8
                                         :placement (list :side-table)
                                         :transfer :copy)
                                 :layout (table-layout) :object-cells 2)
                       :tint)))
           (typep (rejected (lambda () (metadata-set-bit int-h 'a)))
                  'metadata-key-error))))

(let* ((binding (bind-one (mdspec :name :tcas :domain :object :cell-type :integer :width 8
                                  :placement (list :side-table)
                                  :transfer :copy)
                          :layout (table-layout) :object-cells 8))
       (h (find-metadata binding :tcas)))
  (check table-cas-stores-on-match
         (and (= 0 (metadata-cas h 'x 0 7))
              (= 7 (metadata-ref h 'x))))
  (check table-cas-keeps-previous-on-mismatch
         (and (= 7 (metadata-cas h 'x 0 9))
              (= 7 (metadata-ref h 'x)))))

(let* ((binding (bind-one (mdspec :name :trng :domain :object :cell-type :integer :width 8
                                  :placement (list :side-table)
                                  :transfer :copy)
                          :layout (table-layout) :object-cells 8))
       (h (find-metadata binding :trng)))
  (metadata-set h 'p 2)
  (metadata-set h 'q 3)
  (check table-fold-covers-present-cells
         (= 5 (metadata-fold h nil (lambda (v a) (+ v a)) 0)))
  (let ((seen ()))
    (metadata-map-present h nil (lambda (k v) (push (cons k v) seen)))
    (check table-map-present-skips-default-cells
           (and (= 2 (length seen))
                (member 'p seen :key #'car))))
  (metadata-clear-range h nil)
  (check table-clear-range-empties-table
         (and (= 0 (metadata-table-count (table-storage h)))
              (= 0 (metadata-ref h 'p))))
  (check table-range-operations-reject-key-ranges
         (and (typep (rejected (lambda () (metadata-fold h (cons 0 2)
                                                         #'+ 0)))
                     'metadata-key-error)
              (typep (rejected (lambda () (metadata-clear-range h
                                                               (cons 0 2))))
                     'metadata-key-error))))

(set-toy-guarantees)
(check table-offered-field-operations-reject-explicitly
       ;; the base methods give every handle an explicit answer
       (let ((h (find-metadata
                 (bind-one (mdspec :name :fref :domain :object :cell-type :bit
                                   :placement (list :offered-field)
                                   :atomicity (list :bit-atomic)
                                   :transfer :clear)
                           :object-model *toy*
                           :field-guarantees #'toy-guarantees)
                 :fref)))
         (and (typep (rejected (lambda () (metadata-clear-range h nil)))
                     'metadata-key-error)
              (typep (rejected (lambda () (metadata-fold h nil #'+ 0)))
                     'metadata-key-error))))

;;; --- 7. movement transfer --------------------------------------------

(defun transfer-handle (policy &key (merge-function #'+)
                                 (recompute (lambda (k v)
                                              (declare (ignore k))
                                              (+ v 10))))
  (let ((spec (mdspec :name (case policy
                              (:copy :tcopy) (:clear :tclear)
                              (:merge :tmerge)
                              (:retain-region :tretain)
                              (:recompute :trecompute)
                              (:discard :tdiscard))
                      :domain :region :cell-type :integer :width 8
                      :transfer policy
                      :merge-function merge-function
                      :recompute recompute)))
    (find-metadata (bind-one spec :layout (vector-layout)
                              :region-count 4)
                   (metadata-name spec))))

(let ((h (transfer-handle :copy)))
  (metadata-set h 0 3)
  (metadata-transfer h 0 1)
  (check transfer-copy-moves-value-to-destination
         (and (= 3 (metadata-ref h 1)) (= 3 (metadata-ref h 0)))))

(let ((h (transfer-handle :clear)))
  (metadata-set h 0 3)
  (metadata-set h 1 3)
  (metadata-transfer h 0 1)
  (check transfer-clear-restores-default-at-destination
         (and (= 0 (metadata-ref h 1)) (= 3 (metadata-ref h 0)))))

(let ((h (transfer-handle :merge)))
  (metadata-set h 0 3)
  (metadata-set h 1 2)
  (metadata-transfer h 0 1)
  (check transfer-merge-applies-declared-merge-function
         (and (= 5 (metadata-ref h 1)) (= 3 (metadata-ref h 0)))))

(let ((h (transfer-handle :retain-region)))
  (metadata-set h 0 3)
  (metadata-transfer h 0 1)
  (check transfer-retain-region-keeps-region-datum-in-place
         (and (= 3 (metadata-ref h 0)) (= 0 (metadata-ref h 1)))))

(let ((h (transfer-handle :recompute)))
  (metadata-set h 0 3)
  (metadata-transfer h 0 1)
  (check transfer-recompute-recomputes-destination
         (and (= 10 (metadata-ref h 1)) (= 3 (metadata-ref h 0)))))

(let ((h (transfer-handle :discard)))
  (metadata-set h 0 3)
  (metadata-set h 1 3)
  (metadata-transfer h 0 1)
  (check transfer-discard-resets-both-keys
         (and (= 0 (metadata-ref h 0)) (= 0 (metadata-ref h 1)))))

(check raw-object-copy-transfers-no-metadata
       ;; the client copies payload only; the field value is untouched by
       ;; copy-object-representation, and only METADATA-TRANSFER moves the
       ;; logical datum (client-protocols.tex section 1)
       (let* ((binding (bind-field-datum))
              (h (find-metadata binding :fmark))
              (src (cons 'src nil))
              (dst (cons 'dst nil)))
         (field-write *toy* :payload src 99)
         (field-write *toy* *toy-field* src 1)
         (field-write *toy* *toy-field* dst 1)
         (copy-object-representation *toy* src dst)
         ;; the raw copy moved payload but decided NOTHING about the
         ;; metadata field: the field reads the same at both keys
         (and (= 99 (field-read *toy* :payload dst))
              (= 1 (field-read *toy* *toy-field* src))
              (= 1 (field-read *toy* *toy-field* dst))
              ;; the authoritative transfer runs the declared :clear
              ;; policy: destination restored to the default, source kept
              (progn (metadata-transfer h src dst)
                     (and (= 0 (field-read *toy* *toy-field* dst))
                          (= 1 (field-read *toy* *toy-field* src)))))))

;;; --- 8. side-vector allocation windows -------------------------------
;;;
;;; The claim: REF, SET, CAS, and RESET on the dense side-vector
;;; realization are zero host bytes in warmed single-call and 100-call
;;; windows.  The harness warms dispatch explicitly.  Binding performs no
;;; warmup, and these windows do not establish first-call supervisor safety.
;;;
;;; No no-allocation claim is made here for the boot-table or
;;; offered-field realizations (see the scope note in the header).

#+sbcl
(progn
  (sb-alien:define-alien-variable ("bytes_allocated" %md-bytes-allocated)
    sb-alien:unsigned-long)

  (defun md-window (fn)
    (sb-ext:gc :full t)
    (sb-vm::close-thread-alloc-region)
    (let ((before %md-bytes-allocated))
      (funcall fn)
      (- %md-bytes-allocated before))))

#+sbcl
(let* ((binding (vector-binding :name :hot :granularity 1 :width 8
                                :extent 256))
       (h (find-metadata binding :hot))
       (k 100)
       (ref-once (lambda () (metadata-ref h k)))
       (set-once (lambda () (metadata-set h k 5)))
       (cas-once (lambda () (metadata-cas h k 5 5)))
       (reset-once (lambda () (metadata-reset h k)))
       (ref-100 (lambda () (dotimes (i 100) (metadata-ref h k))))
       (set-100 (lambda () (dotimes (i 100) (metadata-set h k 5))))
       (cas-100 (lambda () (dotimes (i 100) (metadata-cas h k 5 5))))
       (reset-100 (lambda () (dotimes (i 100) (metadata-reset h k)))))
  (check hot-path-bound-as-side-vector
         (eq :side-vector (handle-placement h)))
  ;; configuration + CLOS dispatch outside the measured windows
  (metadata-set h k 5)
  (metadata-ref h k)
  (metadata-cas h k 5 5)
  (metadata-reset h k)
  (metadata-set h k 5)
  ;; warmed single call per operation
  (let ((ref-bytes (md-window ref-once)))
    (format t "~&  side-vector ref    warmed call: ~d bytes~%" ref-bytes)
    (check side-vector-ref-warmed-call-zero-bytes (zerop ref-bytes)))
  (let ((set-bytes (md-window set-once)))
    (format t "~&  side-vector set    warmed call: ~d bytes~%" set-bytes)
    (check side-vector-set-warmed-call-zero-bytes (zerop set-bytes)))
  (let ((cas-bytes (md-window cas-once)))
    (format t "~&  side-vector cas    warmed call: ~d bytes~%" cas-bytes)
    (check side-vector-cas-warmed-call-zero-bytes (zerop cas-bytes)))
  (let ((reset-bytes (md-window reset-once)))
    (format t "~&  side-vector reset  warmed call: ~d bytes~%" reset-bytes)
    (check side-vector-reset-warmed-call-zero-bytes
           (zerop reset-bytes)))
  ;; 100 repeated calls per operation
  (let ((ref-bytes (md-window ref-100)))
    (format t "~&  side-vector ref    100 calls:   ~d bytes~%" ref-bytes)
    (check side-vector-ref-100-repeated-zero-bytes (zerop ref-bytes)))
  (let ((set-bytes (md-window set-100)))
    (format t "~&  side-vector set    100 calls:   ~d bytes~%" set-bytes)
    (check side-vector-set-100-repeated-zero-bytes (zerop set-bytes)))
  (let ((cas-bytes (md-window cas-100)))
    (format t "~&  side-vector cas    100 calls:   ~d bytes~%" cas-bytes)
    (check side-vector-cas-100-repeated-zero-bytes (zerop cas-bytes)))
  (let ((reset-bytes (md-window reset-100)))
    (format t "~&  side-vector reset  100 calls:   ~d bytes~%" reset-bytes)
    (check side-vector-reset-100-repeated-zero-bytes
           (zerop reset-bytes)))
  ;; correctness outside the windows: the operations did the work
  (metadata-set h k 5)
  (check hot-path-results-correct
         (and (= 5 (metadata-ref h k))
              (= 5 (metadata-cas h k 5 5))
              (progn (metadata-reset h k) (= 0 (metadata-ref h k))))))

;;; --- construction and mutation boundary regressions ------------------

(check-rejected integer-default-must-fit-width
                (lambda () (mdspec :cell-type :integer :width 8 :default 256)))

(let ((callback (lambda (key value) (declare (ignore key)) value)))
  (let ((merged
          (find-metadata-specification
           (merge-metadata
            (list (make-contribution :first (mdspec :name :callback))
                  (make-contribution :second (mdspec :name :callback
                                                      :recompute callback))))
           :callback)))
    (check optional-callback-refinement-preserved
           (eq callback (metadata-recompute merged))))
  (check callback-conflict-is-structured
         (typep (rejected
                 (lambda ()
                   (merge-metadata
                    (list (make-contribution :first
                                             (mdspec :name :callback :recompute callback))
                          (make-contribution :second
                                             (mdspec :name :callback :recompute #'identity))))))
                'metadata-conflict)))

(check nil-reference-default-is-a-value-not-unspecified
       (typep (rejected
               (lambda ()
                 (merge-metadata
                  (list (make-contribution :first
                                           (mdspec :name :ref :cell-type :reference
                                                   :width 64 :default nil))
                        (make-contribution :second
                                           (mdspec :name :ref :cell-type :reference
                                                   :width 64 :default :other))))))
              'metadata-conflict))

(check vector-actual-length-checked
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :short-backing) :extent 8
                           :layout (constant-layout
                                    (make-side-storage :vector (vector 0)
                                                       :cells 8)))))
              'metadata-unsupported))
(check layout-cannot-shift-requested-base
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :shifted) :extent 8
                           :layout (constant-layout
                                    (make-side-storage :vector (make-array 8)
                                                       :base 10 :cells 8)))))
              'metadata-unsupported))
(check layout-end-overflow-rejected
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :overflow) :base most-positive-fixnum
                           :extent 8 :layout (vector-layout))))
              'metadata-unsupported))

(let* ((binding (bind-one (mdspec :name :partial :granularity 8) :extent 9
                          :layout (constant-layout
                                   (make-side-storage :vector (make-array 4 :initial-element 0)
                                                      :cells 4))))
       (handle (find-metadata binding :partial)))
  (check overprovisioned-storage-does-not-enlarge-domain
         (and (= 2 (vector-cells handle))
              (= 9 (vector-span handle))
              (= 0 (metadata-ref handle 8))
              (typep (rejected (lambda () (metadata-ref handle 9))) 'metadata-key-error)))
  (check range-past-domain-rejected
         (typep (rejected (lambda () (metadata-clear-range handle (cons 0 17))))
                'metadata-key-error))
  (check empty-end-range-accepted
         (= 42 (metadata-fold handle (cons 9 9) #'+ 42))))

(let ((calls 0))
  (bind-one (mdspec :name :no-warmup :reset :recompute
                    :recompute (lambda (key value)
                                 (declare (ignore key)) (incf calls) value))
            :extent 8 :layout (vector-layout))
  (check binding-never-invokes-runtime-recompute (zerop calls)))
(check empty-vector-binds-without-probing
       (find-metadata (bind-one (mdspec :name :empty) :extent 0
                               :layout (vector-layout)) :empty))

(let* ((handle (find-metadata
                (bind-one (mdspec :name :atomic :writers :concurrent :atomicity '(:cas))
                          :extent 8 :layout (vector-layout t)) :atomic))
       (*atomic-events* nil))
  (metadata-ref handle 0)
  (metadata-set handle 0 1)
  (metadata-cas handle 0 1 0)
  (metadata-set-bit handle 0)
  (metadata-clear-bit handle 0)
  (check vector-atomics-use-client-protocol
         (equal '(:load :store :cas :cas :cas) (reverse *atomic-events*))))
(check concurrent-vector-needs-explicit-client
       (typep (rejected
               (lambda ()
                 (bind-one (mdspec :name :atomic :writers :concurrent
                                   :atomicity '(:plain :cas))
                           :extent 8 :layout (vector-layout))))
              'metadata-unsupported))

(let ((h (find-metadata (vector-binding :name :checked) :checked)))
  (check vector-cas-validates-replacement
         (and (typep (rejected (lambda () (metadata-cas h 0 0 256))) 'metadata-key-error)
              (= 0 (metadata-ref h 0)))))
(let ((h (find-metadata (vector-binding :name :forbidden :reset :forbidden) :forbidden)))
  (metadata-set h 0 1)
  (check vector-range-cannot-bypass-forbidden-reset
         (and (typep (rejected (lambda () (metadata-clear-range h (cons 0 1))))
                     'metadata-key-error)
              (= 1 (metadata-ref h 0)))))

(flet ((table-handle (name cells)
         (find-metadata
          (bind-one (mdspec :name name :domain :object :cell-type :integer :width 8
                            :placement '(:side-table))
                    :layout (table-layout) :object-cells cells) name)))
  (let ((source (table-handle :source 2)) (destination (table-handle :destination 1)))
    (metadata-set source :a 1)
    (metadata-set destination :b 2)
    (check projection-cannot-grow-past-table-capacity
           (and (typep (rejected (lambda () (metadata-project source destination #'+)))
                       'metadata-exhausted)
                (= 1 (metadata-table-count (table-storage destination)))))
    (check table-cas-validates-replacement
           (and (typep (rejected (lambda () (metadata-cas destination :b 2 256)))
                       'metadata-key-error)
                (= 2 (metadata-ref destination :b))))))

;;; --- summary ---------------------------------------------------------

(format t "~&v11 metadata contract: ~d checks, ~d failure~:p~%"
        *checks* (length *failures*))
(dolist (failure (reverse *failures*))
  (format t "  FAIL: ~a~%" failure))
(sb-ext:exit :code (if *failures* 1 0))
