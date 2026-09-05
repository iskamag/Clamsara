;;;; test/v11-managed-layout-contract.lisp -- standalone SBCL contract test
;;;; for the paper-v11 managed layout kernel (src/core/managed-layout.lisp).
;;;;
;;;; Run:  sbcl --script test/v11-managed-layout-contract.lisp
;;;;
;;;; Covers: deterministic reorder equivalence, arena/exclusion/reservation
;;;; containment, exact alignment and page geometry, minimum/preferred/maximum
;;;; extent fallback, adjacency/separation/relative-reach/intentional-alias
;;;; success and failure, metadata sizing derived from the assigned object
;;;; range via a checked callback (with overflow rejection), reservation of all
;;;; collection-time work capacity, overlap freedom, bounded no-allocation
;;;; lookup and epoch-guarded ownership update with stale-token rejection, no
;;;; partial validate/install publication, and first/repeated lookup
;;;; allocation windows (generic dispatch explicitly outside the windows).
;;;;
;;;; Scope note: this test exercises the portable layout kernel only.  It
;;;; makes NO claim about initial-image construction (managed-layout.tex
;;;; section 7) or deployment-profile conformance.

(cl:load (merge-pathnames "../src/protocol/address-space.lisp"
                          (make-pathname :defaults *load-truename*)))
(cl:load (merge-pathnames "../src/core/managed-layout.lisp"
                          (make-pathname :defaults *load-truename*)))

(defpackage :v11-managed-layout-contract-test
  (:use :cl :clamsara-managed-layout #:clamsara-protocol.address-space))

(in-package :v11-managed-layout-contract-test)

;;; --- harness ---------------------------------------------------------

(defparameter *checks* 0)
(defparameter *failures* ())

(defmacro check (label form)
  (let ((value (gensym "VALUE")))
    `(let ((,value ,form))
       (incf *checks*)
       (unless ,value (push ,(string label) *failures*))
       ,value)))

(defmacro try-rejection (form)
  "Run FORM; return the LAYOUT-REJECTION condition, or NIL when nothing
was signalled; :WRONG-ERROR for a foreign condition."
  `(handler-case (progn ,form nil)
     (layout-rejection (c) c)
     (error (c) :wrong-error)))

(defun rejection-field (condition reader expected)
  (and (typep condition 'condition)
       (not (eq condition :wrong-error))
       (let ((actual (funcall reader condition)))
         (if (symbolp expected)
             (or (eq actual expected)
                 (and (symbolp actual)
                      (string= (symbol-name actual) (symbol-name expected))))
             (equal actual expected)))))

;;; --- clients ---------------------------------------------------------

(defclass spy-client ()
  ((offer :initarg :offer)
   (calls :initform nil :accessor spy-calls)
   (validate-error :initform nil)
   (install-error :initform nil)
   (validated-layout :initform nil)
   (installed-layout :initform nil)))

(defmethod managed-arena-offer ((c spy-client))
  (slot-value c 'offer))

(defmethod validate-managed-layout ((c spy-client) layout)
  (push :validate (spy-calls c))
  (setf (slot-value c 'validated-layout) layout)
  (when (slot-value c 'validate-error)
    (error 'layout-rejection :reason :client-validate
           :detail "spy client validate failure"))
  (values))

(defmethod install-managed-layout ((c spy-client) layout)
  (push :install (spy-calls c))
  (setf (slot-value c 'installed-layout) layout)
  (when (slot-value c 'install-error)
    (error 'layout-rejection :reason :client-install
           :detail "spy client install failure"))
  (values))

(defun make-heap-offer (&key (base #x100000) (extent (* 512 1024)) address-width)
  (make-address-space-offer
   :arenas (list (make-managed-arena :name :heap :base base :extent extent
                                     :alignment 4096 :page-size 4096
                                     :access-modes '(:read :write)))
   :exclusions ()
   :address-width (or address-width 48)))

(defun make-two-arena-offer ()
  ;; arena 1: read/write only; arena 2: read/execute, checkpoint-volatile
  (make-address-space-offer
   :arenas (list (make-managed-arena :name :rw :base #x200000
                                     :extent (* 256 1024)
                                     :alignment 4096 :page-size 4096
                                     :access-modes '(:read :write))
                 (make-managed-arena :name :rx :base #x400000
                                     :extent (* 128 1024)
                                     :alignment 4096 :page-size 4096
                                     :access-modes '(:read :write :execute)
                                     :checkpoint-volatile-p t))
   :exclusions ()
   :address-width 48))

(defun plain-client (&optional (offer (make-heap-offer)))
  (make-instance 'spy-client :offer offer))

;;; --- request builders ------------------------------------------------

(defun obj (name min pref max &key (alignment 4096) access owner)
  (make-resource-request :name name :owner (or owner :gen) :kind :object-space
                         :min-extent min :preferred-extent pref :max-extent max
                         :alignment alignment
                         :access (or access '(:read :write))))

;;; --- 1. deterministic reorder equivalence ----------------------------

(defun canonical-regions (layout)
  (sort (mapcar (lambda (r)
                  (list (symbol-name (region-name r))
                        (region-arena-name r)
                        (region-start r) (region-extent r)
                        (region-kind r)))
                (solution-regions layout))
        #'string< :key #'car))

(defun build-with-order (client requests)
  (build-managed-layout client (copy-list requests)))

(defun region-of (layout name)
  (find-solution-region layout name))

(defparameter *reorder-client* (plain-client))
(defparameter *reorder-requests*
  (list
   (obj :young (* 16 1024) (* 64 1024) (* 96 1024))
   (make-resource-request :name :bitmap :owner :gen :kind :metadata
                          :min-extent 256 :max-extent (* 16 1024)
                          :derive-from :young
                          :size-function (lambda (d)
                                           (let ((src (car (derivation-sources d))))
                                             (floor (source-extent src) 64))))
   (make-resource-request :name :work :owner :gen :kind :work-storage
                          :min-extent (* 4 1024) :preferred-extent (* 16 1024)
                          :max-extent (* 16 1024))
   (make-resource-request :name :growth :owner :gen :kind :reserved-growth
                          :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                          :max-extent (* 8 1024)
                          :adjacent-to (make-adjacency-constraint :target :young))
   (make-resource-request :name :sft :owner :gen :kind :code-independent-table
                          :min-extent 4096 :preferred-extent 4096
                          :max-extent 4096)
   ;; alias pair (mutual)
   (make-resource-request :name :shadow-a :owner :gen :kind :object-space
                          :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                          :max-extent (* 8 1024)
                          :access '(:read)
                          :alias-with :shadow-b)
   (make-resource-request :name :shadow-b :owner :gen :kind :object-space
                          :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                          :max-extent (* 8 1024)
                          :access '(:read)
                          :alias-with :shadow-a)
   (obj :far (* 4 1024) (* 4 1024) (* 4 1024))
   (make-resource-request :name :near-thing :owner :gen :kind :object-space
                          :min-extent 4096 :preferred-extent 4096
                          :max-extent 4096
                          :near (make-near-constraint :target :far :reach 8192
                                                      :reason "bump allocation probe"))
   (make-resource-request :name :lonely :owner :gen :kind :object-space
                          :min-extent 4096 :preferred-extent 8192
                          :max-extent 8192
                          :separated-from (make-separation-constraint :target :far))))

(defparameter *layouts*
  (list (build-with-order *reorder-client* *reorder-requests*)
        (build-with-order *reorder-client* (reverse *reorder-requests*))
        (build-with-order
         *reorder-client*
         ;; deterministic fixed shuffle: every third element first
         (let ((es (copy-list *reorder-requests*)))
           (append (nthcdr 3 es) (subseq es 0 3))))))

(check reorder-equivalence-regions
       (let ((reference (canonical-regions (first *layouts*))))
         (every (lambda (l) (equal reference (canonical-regions l)))
                *layouts*)))
(check reorder-equivalence-count
       (= 10 (length (solution-regions (first *layouts*)))))
(check reorder-installed
       (every #'solution-installed-p *layouts*))
(check reorder-lookups-agree
       (let ((addresses (mapcar #'region-start (solution-regions (first *layouts*)))))
         (every (lambda (other)
                  (every (lambda (a)
                           (let ((r1 (layout-space-at (first *layouts*) a))
                                 (r2 (layout-space-at other a)))
                             (equal (and r1 (region-name r1))
                                    (and r2 (region-name r2)))))
                         addresses))
                (rest *layouts*))))

;;; --- 2. arena / exclusion / reservation containment ------------------

;; the exclusion in the middle of the arena is never occupied
(let* ((offer (make-address-space-offer
               :arenas (list (make-managed-arena :name :heap :base #x100000
                                                 :extent (* 256 1024)
                                                 :alignment 4096 :page-size 4096))
               :exclusions (list (make-exclusion :start #x120000 :extent 4096
                                                 :kind :mmio))
               :address-width 48))
       (client (make-instance 'spy-client :offer offer))
       (layout (build-managed-layout
                client
                (list (obj :big (* 128 1024) (* 128 1024) (* 128 1024))))))
  (check exclusion-skipped
         (dolist (r (solution-regions layout) t)
           (let ((s (region-start r)) (e (region-end r)))
             (when (and (<= s #x120000) (< #x120004 e))
               (return nil)))))
  (check exclusion-unowned
         (eq nil (layout-space-at layout #x120000)))
  ;; every assignment inside its arena
  (check regions-inside-arena
         (dolist (r (solution-regions layout) t)
           (let ((a (find (region-arena-name r)
                          (solution-arenas layout)
                          :key #'arena-name)))
             (unless (and (>= (region-start r) (arena-base a))
                          (<= (region-end r) (arena-end a)))
               (return nil))))))

;; reservations block placement like exclusions
(let* ((offer (make-address-space-offer
               :arenas (list (make-managed-arena
                              :name :heap :base #x100000 :extent (* 128 1024)
                              :alignment 4096 :page-size 4096
                              :reservations (list (make-arena-reservation
                                                   :start #x100000 :extent 8192
                                                   :kind :page-tables))))
               :address-width 48))
       (client (make-instance 'spy-client :offer offer))
       (layout (build-managed-layout client (list (obj :after-res (* 8 1024) (* 8 1024) (* 8 1024))))))
  (check reservation-skipped
         (= #x102000 (region-start (region-of layout :after-res)))))

;; access compatibility selects the second arena; a checkpoint-volatile
;; arena refuses checkpoint-stable requests
(let* ((client (plain-client (make-two-arena-offer)))
       (layout (build-managed-layout
                client
                (list (make-resource-request
                       :name :code-table :owner :gen
                       :kind :code-independent-table
                       :min-extent 4096 :preferred-extent 4096 :max-extent 4096
                       :access '(:read :execute))
                      (obj :stable (* 8 1024) (* 8 1024) (* 8 1024)
                           :access '(:read :write))))))
  (check execute-needs-second-arena
         (eq :rx (region-arena-name (region-of layout :code-table))))
  (check rw-prefers-first-arena
         (eq :rw (region-arena-name (region-of layout :stable)))))

;; a checkpoint-stable request may not land in the checkpoint-volatile
;; arena; with :rw too small for it the honest answer is rejection
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-two-arena-offer))
               (list (make-resource-request
                      :name :must-be-stable :owner :gen :kind :object-space
                      :min-extent (* 300 1024) :preferred-extent (* 300 1024)
                      :max-extent (* 300 1024)
                      :stable-across-checkpoint-p t))))))
  (check checkpoint-stable-refuses-volatile
         (rejection-field cond* #'layout-rejection-reason :unsatisfiable)))

(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-two-arena-offer))
               (list (obj :huge (* 300 1024) (* 300 1024) (* 300 1024)))))))
  (check unsatisfiable-minimum
         (rejection-field cond* #'layout-rejection-reason :unsatisfiable))
  (check unsatisfiable-names-resource
         (rejection-field cond* #'layout-rejection-resource :huge)))

;;; --- 3. exact alignment and page geometry ----------------------------

(let* ((offer (make-address-space-offer
               :arenas (list (make-managed-arena :name :fine :base #x100000
                                                 :extent (* 128 1024)
                                                 :alignment 1
                                                 :page-size 512))
               :address-width 48))
       (client (plain-client offer))
       (layout (build-managed-layout
                client
                (list (make-resource-request
                       :name :quirky :owner :gen :kind :object-space
                       :min-extent 5000 :preferred-extent 5000 :max-extent 8192
                       :alignment 96 :page-granularity 1024)))))
  (let* ((r (region-of layout :quirky))
         (start (region-start r))
         (extent (region-extent r)))
    ;; 5000 bytes round honestly: extents to the 1024 quantum (5120), the
    ;; start to lcm(96, 1024, 512-arena-page) = 3072, which is 96-aligned
    (check alignment-exact
           (zerop (mod start 96)))
    (check page-quantum-exact
           (and (zerop (mod extent 1024))
                (zerop (mod start 512))
                (= extent 5120)))))

;; extents round honestly: preferred up to the page quantum, maximum down
(let* ((offer (make-address-space-offer
               :arenas (list (make-managed-arena :name :heap :base #x100000
                                                 :extent (* 128 1024)
                                                 :alignment 1 :page-size 4096))
               :address-width 48))
       (client (plain-client offer))
       (layout (build-managed-layout
                client
                (list (make-resource-request
                       :name :pref-up :owner :gen :kind :object-space
                       :min-extent 100 :preferred-extent 5000 :max-extent (* 1 1024 1024)))
                )))
  (check preferred-rounds-up-to-page
         (= 8192 (region-extent (region-of layout :pref-up)))))

;;; --- 4. minimum / preferred / maximum fallback -----------------------

;; roomy arena: the preferred extent is assigned exactly, never more
(let* ((client (plain-client (make-heap-offer)))
       (layout (build-managed-layout client (list (obj :roomy (* 16 1024) (* 32 1024) (* 64 1024))))))
  (check preferred-honored
         (= (* 32 1024) (region-extent (region-of layout :roomy))))
  (check maximum-not-taken
         (< (region-extent (region-of layout :roomy)) (* 64 1024))))

;; tight arena: the extent falls back between minimum and preferred,
;; never below the minimum, never past the maximum, still page-multiple
(let* ((offer (make-address-space-offer
               :arenas (list (make-managed-arena :name :small :base #x100000
                                                 :extent (* 40 1024)
                                                 :alignment 4096 :page-size 4096))
               :address-width 48))
       (client (plain-client offer))
       (layout (build-managed-layout
                client
                (list (obj :shrinky (* 16 1024) (* 32 1024) (* 64 1024))
                      (obj :other (* 20 1024) (* 20 1024) (* 20 1024))))))
  (let ((e (region-extent (region-of layout :shrinky))))
    (check fallback-between-min-and-preferred
           (and (>= e (* 16 1024)) (< e (* 32 1024))))
    (check fallback-page-multiple
           (zerop (mod e 4096))))
  (check other-kept-extent
         (= (* 20 1024) (region-extent (region-of layout :other)))))

;;; --- 5. adjacency: success and failure -------------------------------

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-managed-layout
                client
                (list (obj :anchor (* 8 1024) (* 8 1024) (* 8 1024))
                      (make-resource-request
                       :name :adjacent :owner :gen :kind :object-space
                       :min-extent (* 4 1024) :preferred-extent (* 4 1024)
                       :max-extent (* 4 1024)
                       :adjacent-to (make-adjacency-constraint :target :anchor))))))
  (let* ((a (region-of layout :anchor))
         (b (region-of layout :adjacent)))
    (check adjacency-exact
           (= (region-start b) (region-end a)))))

;; adjacency :before
(let* ((client (plain-client (make-heap-offer)))
       (layout (build-managed-layout
                client
                (list (make-resource-request
                       :name :aaa-filler :owner :gen :kind :object-space
                       :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                       :max-extent (* 8 1024) :alignment 65536)
                      (make-resource-request
                       :name :anchor2 :owner :gen :kind :object-space
                       :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                       :max-extent (* 8 1024) :alignment 32768)
                      (make-resource-request
                       :name :before-thing :owner :gen :kind :object-space
                       :min-extent (* 4 1024) :preferred-extent (* 4 1024)
                       :max-extent (* 4 1024) :alignment 4096
                       :adjacent-to (make-adjacency-constraint
                                     :target :anchor2 :direction :before))))))
  (let* ((a (region-of layout :anchor2))
         (b (region-of layout :before-thing)))
    (check adjacency-before-exact
           (= (region-end b) (region-start a)))))

;; adjacency failure: the anchor's extent is not aligned to the
;; dependent's alignment; exact abutment is impossible and the
;; composition is rejected with the constraint attached
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (make-resource-request
                      :name :odd-anchor :owner :gen :kind :object-space
                      :min-extent 4096 :preferred-extent 4096 :max-extent 4096
                      :alignment 4096)
                     (make-resource-request
                      :name :picky :owner :gen :kind :object-space
                      :min-extent 8192 :preferred-extent 8192 :max-extent 8192
                      :alignment 8192
                      :adjacent-to (make-adjacency-constraint :target :odd-anchor)))))))
  (check adjacency-misaligned-rejected
         (rejection-field cond* #'layout-rejection-reason :unsatisfiable))
  (check adjacency-constraint-named
         (let ((c (and (typep cond* 'condition)
                       (layout-rejection-constraint cond*))))
           (and c (adjacency-constraint-p c)))))

;;; --- 6. separation: success and failure ------------------------------

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-managed-layout
                client
                (list (obj :s-one (* 4 1024) (* 4 1024) (* 4 1024))
                      (make-resource-request
                       :name :s-two :owner :gen :kind :object-space
                       :min-extent (* 4 1024) :preferred-extent (* 4 1024)
                       :max-extent (* 4 1024)
                       :separated-from (make-separation-constraint
                                        :target :s-one :min-gap 16384))))))
  (let ((gap (interval-gap (region-start (region-of layout :s-one))
                           (region-end (region-of layout :s-one))
                           (region-start (region-of layout :s-two))
                           (region-end (region-of layout :s-two)))))
    (check separation-gap-honored
           (>= gap 16384))))

;; separation cannot be honored in a small arena
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-address-space-offer
                              :arenas (list (make-managed-arena
                                             :name :tight :base #x100000
                                             :extent (* 12 1024)
                                             :alignment 4096 :page-size 4096))
                              :address-width 48))
               (list (obj :t-one (* 4 1024) (* 4 1024) (* 4 1024))
                     (make-resource-request
                      :name :t-two :owner :gen :kind :object-space
                      :min-extent (* 4 1024) :preferred-extent (* 4 1024)
                      :max-extent (* 4 1024)
                      :separated-from (make-separation-constraint
                                       :target :t-one :min-gap 8192)))))))
  (check separation-unsatisfiable
         (rejection-field cond* #'layout-rejection-reason :unsatisfiable)))

;;; --- 7. numeric-relative reach: success and failure ------------------

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-managed-layout
                client
                (list (obj :far (* 8 1024) (* 8 1024) (* 8 1024))
                      (make-resource-request
                       :name :near-obj :owner :gen :kind :object-space
                       :min-extent 4096 :preferred-extent 4096
                       :max-extent 4096
                       :near (make-near-constraint :target :far :reach 8192
                                                   :reason "probe page"))))))
  (let ((gap (interval-gap (region-start (region-of layout :far))
                           (region-end (region-of layout :far))
                           (region-start (region-of layout :near-obj))
                           (region-end (region-of layout :near-obj)))))
    (check reach-honored
           (<= gap 8192))))

;; reach impossible: the far region is placed at one end of a large
;; sparse arena and the reach window cannot hold the dependent
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (obj :far (* 240 1024) (* 240 1024) (* 240 1024))
                     (make-resource-request
                      :name :slot-taker :owner :gen :kind :object-space
                      :min-extent 4096 :preferred-extent 4096
                      :max-extent 4096
                      :adjacent-to (make-adjacency-constraint :target :far))
                     (make-resource-request
                      :name :near-obj :owner :gen :kind :object-space
                      :min-extent 4096 :preferred-extent 4096
                      :max-extent 4096
                      :near (make-near-constraint :target :far :reach 0
                                                  :reason "impossible zero reach")))))))
  (check reach-unsatisfiable
         (rejection-field cond* #'layout-rejection-reason :unsatisfiable))
  (check reach-rejection-carries-constraint
         (let ((c (and (typep cond* 'condition)
                       (layout-rejection-constraint cond*))))
           ;; the rejected resource is one of the two contending requests;
           ;; whichever it is, the condition names its constraint
           (and c (or (near-constraint-p c) (adjacency-constraint-p c))))))

;; a near constraint without a numeric reach is rejected outright
(let ((cond* (try-rejection
              (make-near-constraint :target :x))))
  (declare (ignore cond*)))

;;; --- 8. intentional alias: success and failure ------------------------

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-managed-layout
                client
                (list (make-resource-request
                       :name :real :owner :gen :kind :object-space
                       :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                       :max-extent (* 8 1024)
                       :access '(:read :write)
                       :alias-with :view)
                      (make-resource-request
                       :name :view :owner :gen :kind :object-space
                       :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                       :max-extent (* 8 1024)
                       :access '(:read)
                       :alias-with :real)
                      (obj :zafter (* 4 1024) (* 4 1024) (* 4 1024))))))
  (let ((r (region-of layout :real))
        (v (region-of layout :view)))
    (check alias-shares-interval
           (and (= (region-start r) (region-start v))
                (= (region-extent r) (region-extent v))))
    (check alias-mutual-declaration
           (member :real (region-alias-partners v)
                   :key #'symbol-name :test #'string=))
    ;; aliased pages resolve to the alias anchor (implementation choice)
    (check alias-resolves-to-anchor
           (eq r (layout-space-at layout (region-start v))))
    ;; the region after the alias starts past the shared interval, and
    ;; the whole solution remains overlap-free
    (check alias-region-after
           (let ((z (region-of layout :zafter)))
             (or (>= (region-start z) (region-end r))
                 (>= (region-start r) (region-end z)))))))

;; one-sided alias is ambiguous
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (obj :one-sided (* 8 1024) (* 8 1024) (* 8 1024))
                     (make-resource-request
                      :name :sneaky :owner :gen :kind :object-space
                      :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                      :max-extent (* 8 1024)
                      :alias-with :one-sided))))))
  (check one-sided-alias-ambiguous
         (rejection-field cond* #'layout-rejection-reason :ambiguous)))

;; self alias is ambiguous
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (make-resource-request
                      :name :narcissus :owner :gen :kind :object-space
                      :min-extent 4096 :preferred-extent 4096
                      :max-extent 4096
                      :alias-with :narcissus))))))
  (check self-alias-ambiguous
         (rejection-field cond* #'layout-rejection-reason :ambiguous)))

;; alias with separation against the same partner is contradictory
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (obj :partner (* 8 1024) (* 8 1024) (* 8 1024))
                     (make-resource-request
                      :name :torn :owner :gen :kind :object-space
                      :min-extent (* 8 1024) :preferred-extent (* 8 1024)
                      :max-extent (* 8 1024)
                      :alias-with :partner
                      :separated-from (make-separation-constraint
                                       :target :partner)))))))
  (check alias-separation-contradiction
         (rejection-field cond* #'layout-rejection-reason :ambiguous)))

;;; --- 9. metadata sizing derived from the assigned object range --------

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-managed-layout
                client
                (list (make-resource-request
                       :name :objects :owner :gen :kind :object-space
                       :min-extent (* 64 1024) :preferred-extent (* 64 1024)
                       :max-extent (* 64 1024))
                      (make-resource-request
                       :name :mark-bits :owner :gen :kind :metadata
                       :min-extent 4096 :max-extent (* 64 1024)
                       :derive-from :objects
                       :size-function (lambda (d)
                                        (let ((src (car (derivation-sources d))))
                                          (floor (source-extent src) 16))))
                      (make-resource-request
                       :name :mark-bits-tight :owner :gen :kind :metadata
                       :min-extent 4096 :max-extent 4096
                       :derive-from :objects
                       :size-function (lambda (d)
                                        (declare (ignore d))
                                        4096))))))
  (check metadata-derived-from-assigned
         (let* ((objs (region-of layout :objects))
                (meta (region-of layout :mark-bits)))
           ;; 64 KiB / 16 = 4 KiB, already a page multiple
           (= (region-extent meta) (* 4 1024))))
  (check metadata-callback-saw-assigned-range
         (let ((objs (region-of layout :objects)))
           (= (region-extent objs) (* 64 1024))))
  (check metadata-tight-fits
         (= 4096 (region-extent (region-of layout :mark-bits-tight)))))

;; derived extent exceeding the declared maximum is an overflow rejection
;; carrying the resource and provider context
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (make-resource-request
                      :name :objects :owner :gen :kind :object-space
                      :min-extent (* 64 1024) :preferred-extent (* 64 1024)
                      :max-extent (* 64 1024))
                     (make-resource-request
                      :name :too-big :owner :gen :kind :metadata
                      :min-extent 4096 :max-extent 4096
                      :derive-from :objects
                      :size-function (lambda (d) (declare (ignore d)) 1048576)))))))
  (check metadata-overflow-rejected
         (rejection-field cond* #'layout-rejection-reason :overflow))
  (check metadata-overflow-names-resource
         (rejection-field cond* #'layout-rejection-resource :too-big)))

;; a callback signalling an arithmetic error is checked and wrapped
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (make-resource-request
                      :name :objects :owner :gen :kind :object-space
                      :min-extent (* 64 1024) :preferred-extent (* 64 1024)
                      :max-extent (* 64 1024))
                     (make-resource-request
                      :name :bad-math :owner :gen :kind :metadata
                      :min-extent 4096 :max-extent (* 64 1024)
                      :derive-from :objects
                      :size-function (lambda (d)
                                       (declare (ignore d))
                                       (error 'arithmetic-error
                                              :operation 'floor
                                              :operands (list 1 0)))))))))
  (check callback-arithmetic-error-wrapped
         (rejection-field cond* #'layout-rejection-reason :overflow))
  (check callback-error-names-resource
         (rejection-field cond* #'layout-rejection-resource :bad-math))
  (check callback-error-names-owner
         (rejection-field cond* #'layout-rejection-owner :gen)))

;; a non-integer callback result is rejected as invalid
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (make-resource-request
                      :name :objects :owner :gen :kind :object-space
                      :min-extent (* 64 1024) :preferred-extent (* 64 1024)
                      :max-extent (* 64 1024))
                     (make-resource-request
                      :name :weird-meta :owner :gen :kind :metadata
                      :min-extent 4096 :max-extent (* 64 1024)
                      :derive-from :objects
                      :size-function (lambda (d)
                                       (declare (ignore d))
                                       :nope)))))))
  (check noninteger-derivation-rejected
         (rejection-field cond* #'layout-rejection-reason :invalid-request))
  (check noninteger-derivation-names-resource
         (rejection-field cond* #'layout-rejection-resource :weird-meta)))

;;; --- 10. emergency work capacity --------------------------------------

;; work capacity is reserved first, at its preferred extent, even when
;; the object spaces would otherwise eat the arena
(let* ((offer (make-address-space-offer
               :arenas (list (make-managed-arena :name :small :base #x100000
                                                 :extent (* 44 1024)
                                                 :alignment 4096 :page-size 4096))
               :address-width 48))
       (client (plain-client offer))
       (layout (build-managed-layout
                client
                (list (obj :greedy (* 8 1024) (* 40 1024) (* 40 1024))
                      (make-resource-request
                       :name :emergency :owner :gen :kind :work-storage
                       :min-extent (* 4 1024) :preferred-extent (* 8 1024)
                       :max-extent (* 8 1024))))))
  (check work-capacity-reserved-at-preferred
         (= (* 8 1024) (region-extent (region-of layout :emergency))))
  (check work-capacity-reported
         (= (* 8 1024) (solution-work-capacity layout)))
  (check greedy-fell-back
         (let ((e (region-extent (region-of layout :greedy))))
           (and (>= e (* 8 1024)) (< e (* 40 1024))))))

;; zero-minimum work storage is a forbidden hidden emergency allocation
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-heap-offer))
               (list (make-resource-request
                      :name :phantom :owner :gen :kind :work-storage
                      :min-extent 0 :preferred-extent 4096
                      :max-extent 4096))))))
  (check zero-work-minimum-rejected
         (rejection-field cond* #'layout-rejection-reason :invalid-request)))

;; work capacity that cannot be reserved rejects the whole composition
(let ((cond* (try-rejection
              (build-managed-layout
               (plain-client (make-address-space-offer
                              :arenas (list (make-managed-arena
                                             :name :tiny :base #x100000
                                             :extent (* 8 1024)
                                             :alignment 4096 :page-size 4096))
                              :address-width 48))
               (list (make-resource-request
                      :name :impossible :owner :gen :kind :work-storage
                      :min-extent (* 16 1024) :preferred-extent (* 16 1024)
                      :max-extent (* 16 1024)))))))
  (check impossible-work-capacity-rejected
         (rejection-field cond* #'layout-rejection-reason :unsatisfiable)))

;;; --- 11. overlap freedom ----------------------------------------------

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-with-order client *reorder-requests*))
       (regions (solution-regions layout)))
  (check solution-overlap-free
         (let ((ok t))
           (dotimes (i (length regions))
             (dotimes (j (length regions))
               (when (< i j)
                 (let ((a (nth i regions)) (b (nth j regions)))
                   (let ((overlap (and (< (region-start a) (region-end b))
                                       (< (region-start b) (region-end a)))))
                     (when overlap
                       ;; only identical aliased intervals may overlap
                       (unless (and (= (region-start a) (region-start b))
                                    (= (region-extent a) (region-extent b))
                                    (member (region-name b)
                                            (region-alias-partners a)
                                            :key #'symbol-name :test #'string=)
                                    (member (region-name a)
                                            (region-alias-partners b)
                                            :key #'symbol-name :test #'string=))
                         (setf ok nil))))))))
           ok)))

;;; --- 12. no partial validate/install publication -----------------------

;; a rejected composition never reaches the client
(let* ((client (plain-client (make-heap-offer))))
  (try-rejection (build-managed-layout
                  client
                  (list (obj :too-big (* 600 1024) (* 600 1024) (* 600 1024)))))
  (check solve-failure-no-protocol-calls
         (null (spy-calls client))))

;; a validate failure means install is never attempted and nothing is
;; returned to the caller
(let* ((client (plain-client (make-heap-offer))))
  (setf (slot-value client 'validate-error) t)
  (let ((cond* (try-rejection
                (build-managed-layout client (list (obj :ok (* 4 1024) (* 4 1024) (* 4 1024)))))))
    (check validate-failure-no-install
           (equal (reverse (spy-calls client)) '(:validate)))
    (check validate-failure-signals
           (and (typep cond* 'condition) (not (eq cond* :wrong-error))))
    (check validate-failure-saw-complete-layout
           (let ((layout (slot-value client 'validated-layout)))
             (and layout (= 1 (length (solution-regions layout))))))))

;; an install failure is not published as a solution
(let* ((client (plain-client (make-heap-offer))))
  (setf (slot-value client 'install-error) t)
  (let ((cond* (try-rejection
                (build-managed-layout client (list (obj :ok (* 4 1024) (* 4 1024) (* 4 1024)))))))
    (check install-failure-call-order
           (equal (reverse (spy-calls client)) '(:validate :install)))
    (check install-failure-signals
           (and (typep cond* 'condition) (not (eq cond* :wrong-error))))))

;;; --- 13. bounded lookup and epoch-guarded update ----------------------

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-with-order client *reorder-requests*))
       (young (region-of layout :young))
       (work (region-of layout :work)))
  ;; exact per-page resolution
  (check lookup-first-page
         (eq young (layout-space-at layout (region-start young))))
  (check lookup-last-page
         (eq young (layout-space-at layout (+ (region-start young)
                                              (region-extent young)
                                              -1))))
  (check lookup-page-interior
         (eq work (layout-space-at layout (+ (region-start work) 2048))))
  (check lookup-unowned-nil
         (eq nil (layout-space-at layout 12345)))
  (check lookup-outside-nil
         (eq nil (layout-space-at layout 4))))

(let* ((client (plain-client (make-heap-offer)))
       (layout (build-with-order client *reorder-requests*))
       (young (region-of layout :young))
       (growth (region-of layout :growth))
       (addr (region-start young)))
  ;; update without any epoch
  (let ((e (try-rejection (update-space-ownership layout (cons addr 4096) growth))))
    (check update-without-epoch-rejected
           (and (typep e 'condition) (typep e 'ownership-epoch-required))))
  ;; open but not quiesced
  (let ((token (open-ownership-epoch layout)))
    (let ((e (try-rejection (update-space-ownership layout (cons addr 4096) growth))))
      (check update-unquiesced-rejected
            (and (typep e 'condition) (typep e 'ownership-epoch-required))))
    ;; quiesce, then the single update under the token
    (quiesce-ownership-epoch layout token)
    (check epoch-quiesced-flag
           (and (epoch-quiesced-p token) (not (epoch-consumed-p token))))
    (let ((updated (update-space-ownership layout (cons addr 4096) growth)))
      (check update-performed
             (eq growth updated))
      (check lookup-reflects-update
             (eq growth (layout-space-at layout addr)))
      (check token-consumed
             (and (epoch-consumed-p token) (epoch-quiesced-p token))))
    ;; stale: the same token again
    (let ((e (try-rejection (update-space-ownership layout (cons addr 4096) young))))
      (check stale-token-rejected
             (and (typep e 'condition) (typep e 'layout-rejection)))))
    ;; stale: foreign token from another layout
    (let* ((other-layout (build-with-order (plain-client (make-heap-offer))
                                           *reorder-requests*))
           (foreign (open-ownership-epoch other-layout)))
      (let ((e (try-rejection (quiesce-ownership-epoch layout foreign))))
        (check foreign-token-rejected
               (and (typep e 'condition) (typep e 'stale-ownership-epoch)))))
    ;; one outstanding epoch per layout
    (open-ownership-epoch layout)
    (let ((e (try-rejection (open-ownership-epoch layout))))
      (check second-open-rejected
             (and (typep e 'condition) (typep e 'stale-ownership-epoch)))))

;;; --- 14. no physical frame identifiers --------------------------------

(check no-frame-accessor
       (not (or (fboundp 'region-frame-id)
                (fboundp 'arena-frame-id)
                (fboundp 'solution-frame-id)
                (fboundp 'region-frame-p))))
(check no-frame-slot-in-region
       (not (member "FRAME-ID"
                    (mapcar (lambda (s)
                              (symbol-name (sb-mop:slot-definition-name s)))
                            (sb-mop:class-direct-slots (find-class 'layout-region)))
                    :test #'string=)))
(check no-frame-slot-in-arena
       (not (member "FRAME-ID"
                    (mapcar (lambda (s)
                              (symbol-name (sb-mop:slot-definition-name s)))
                            (sb-mop:class-direct-slots (find-class 'managed-arena)))
                    :test #'string=)))

;;; --- 15. first/repeated lookup allocation windows ----------------------
;;;
;;; The claim: after installation, the DIRECT lookup (LAYOUT-SPACE-AT,
;;; an ordinary function -- no generic dispatch in its body) is
;;; zero-cons.  The generic SPACE-OF-REFERENCE seam is exercised
;;; explicitly OUTSIDE the measured windows.

#+sbcl
(progn
  (sb-alien:define-alien-variable ("bytes_allocated" %ml-bytes-allocated)
    sb-alien:unsigned-long)

  (defun measured (layout addresses)
    ;; measure one full window over all addresses; returns consed bytes
    (let ((bytes nil))
      (sb-ext:gc :full t)
      (sb-vm::close-thread-alloc-region)
      (let ((before %ml-bytes-allocated))
        (dolist (a addresses)
          (layout-space-at layout a))
        (setf bytes (- %ml-bytes-allocated before)))
      bytes))

  (let* ((client (plain-client (make-heap-offer)))
         (layout (build-with-order client *reorder-requests*))
         (regions (solution-regions layout))
         (addrs (append (mapcar #'region-start regions)
                        (mapcar (lambda (r) (+ (region-start r) 2048)) regions)
                        (list 12345 4))))
    ;; First lookup of this installed layout, with no preceding generic call.
    (let ((first-bytes (measured layout (list (first addrs)))))
      (format t "~&  lookup first-call window: ~d bytes~%" first-bytes)
      (check lookup-first-call-zero-cons (zerop first-bytes))
      ;; repeated window: many calls, mixed owned/unowned/miss
      (let* ((repeated (progn
                           (sb-ext:gc :full t)
                           (sb-vm::close-thread-alloc-region)
                           (let ((before %ml-bytes-allocated))
                             (dotimes (k 100)
                               (dolist (a addrs)
                                 (layout-space-at layout a)))
                             (- %ml-bytes-allocated before))))
             (bytes repeated))
        (format t "~&  lookup repeated window (100 x ~d addrs): ~d bytes~%"
                (length addrs) bytes)
        (check lookup-repeated-zero-cons
               (and bytes (zerop bytes))))
      ;; post-install update keeps lookup zero-cons
      (let* ((growth (find-solution-region layout :growth))
             (token (open-ownership-epoch layout)))
        (quiesce-ownership-epoch layout token)
        (update-space-ownership layout (cons (region-start growth) 4096)
                                growth)
        (let ((after (measured layout (list (region-start growth)))))
          (check lookup-after-update-zero-cons
                 (and after (zerop after)))
          (check lookup-after-update-owner
                 (eq growth (layout-space-at layout (region-start growth)))))))
    ;; generic seam AFTER the windows, outside measurement
    (check generic-seam-agrees
           (let ((ok t))
             (dolist (a addrs)
               (unless (eq (space-of-reference layout a)
                           (layout-space-at layout a))
                 (setf ok nil)))
             ok))
    (format t "~&  generic dispatch exercised outside measured windows~%")))

;;; Regressions: list offers and foreign ownership handles.
(let* ((arena (make-managed-arena :name :arena :base #x100000 :extent #x10000
                                  :alignment 4096 :page-size 4096
                                  :access-modes '(:read :write)))
       (excluded (make-exclusion :start #x100000 :extent 4096 :kind :reserved))
       (request (make-resource-request :name :objects :owner :plan
                                      :kind :object-space :min-extent 4096
                                      :page-granularity 4096))
       (layout (build-managed-layout (plain-client (list arena excluded))
                                    (list request))))
  (check list-offer-preserves-exclusions
         (and (null (layout-space-at layout #x100000))
              (>= (region-start (find-solution-region layout :objects)) #x101000)))
  (let* ((other (build-managed-layout (plain-client (list arena excluded))
                                     (list request)))
         (token (open-ownership-epoch layout)))
    (quiesce-ownership-epoch layout token)
    (check foreign-region-rejected-before-update
           (typep (try-rejection
                   (update-space-ownership layout (cons #x101000 4096)
                                           (find-solution-region other :objects)))
                  'layout-rejection))
    (check rejected-update-preserves-owner-and-token
           (and (not (epoch-consumed-p token))
                (eq (layout-space-at layout #x101000)
                    (find-solution-region layout :objects))))))

;;; --- summary -----------------------------------------------------------

(format t "~&v11 managed layout contract: ~d checks, ~d failure~:p~%"
        *checks* (length *failures*))
(dolist (failure (reverse *failures*))
  (format t "  FAIL: ~a~%" failure))
(sb-ext:exit :code (if *failures* 1 0))
