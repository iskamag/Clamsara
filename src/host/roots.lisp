;;;; v14 serialized simulator root service. No native stack-map claim.
(in-package #:clamsara)

(define-condition host-protocol-error (error)
  ((reason :initarg :reason :reader host-error-reason))
  (:report (lambda (c s) (format s "Host protocol error: ~S" (host-error-reason c)))))
(defun host-reject (reason) (error 'host-protocol-error :reason reason))

(defgeneric host-root-value (location))
(defgeneric (setf host-root-value) (value location))
(defgeneric host-root-kind (location))
(defgeneric store-provider-root (client context token location reference))

(defclass simulator-root-location ()
  ((value :initform nil :accessor host-root-value)))
(defmethod host-root-kind ((location simulator-root-location))
  (declare (ignore location)) :exact)
(defclass simulator-root-provider ()
  ((locations :initarg :locations :reader simulator-provider-locations)))
(defun make-simulator-root-provider (capacity)
  (unless (typep capacity '(integer 0 #.most-positive-fixnum))
    (host-reject :invalid-provider-capacity))
  (let ((locations (make-array capacity)))
    (dotimes (i capacity)
      (setf (aref locations i) (make-instance 'simulator-root-location)))
    (make-instance 'simulator-root-provider :locations locations)))
(defun simulator-root-location (provider index)
  (aref (simulator-provider-locations provider) index))
(defmethod map-provider-roots ((provider simulator-root-provider) function)
  (let ((locations (simulator-provider-locations provider)))
    (dotimes (i (length locations)) (funcall function (aref locations i))))
  (values))

(defstruct (simulator-provider-token (:constructor %make-provider-token))
  owner identity generation provider (active-p nil) (position 0)
  (entry-head -1) (entry-count 0))
(defstruct (simulator-root-entry (:constructor %make-root-entry))
  token location (next -1) (seen 0) (active-p nil))
(defstruct (simulator-coverage (:constructor %make-simulator-coverage))
  coordinator token roots (root-generation 0) (protected-p nil)
  (correction-failed-p nil) (borrowers 0) terminal-result)
(defstruct (simulator-root-snapshot (:constructor %make-root-snapshot))
  client coverage (active-p nil))
(defclass simulator-root-client ()
  ((providers :initarg :providers :reader simulator-root-providers)
   ;; All post-publication registration state is fixed before construction.
   (token-reserve :initarg :token-reserve :reader simulator-root-token-reserve)
   (entry-reserve :initarg :entry-reserve :reader simulator-root-entry-reserve)
   (registration-capacity :initarg :registration-capacity
                          :reader simulator-root-registration-capacity)
   (location-capacity :initarg :location-capacity
                      :reader simulator-root-location-capacity)
   (next-token :initform 0 :accessor simulator-root-next-token)
   (free-entry-head :initarg :free-entry-head
                    :accessor simulator-root-free-entry-head)
   (free-entry-count :initarg :free-entry-count
                     :accessor simulator-root-free-entry-count)
   (registration-scratch :initarg :registration-scratch
                         :reader simulator-root-registration-scratch)
   (registration-seen :initarg :registration-seen
                      :reader simulator-root-registration-seen)
   (registration-active-p :initform nil
                          :accessor simulator-root-registration-active-p)
   (directory :initarg :directory :reader simulator-root-directory)
   (generation :initform 0 :accessor simulator-root-generation)
   (admission-closed-p :initform nil :accessor simulator-root-admission-closed-p)
   (snapshot :initform (%make-root-snapshot) :reader simulator-client-snapshot)
   (pass :initform 0 :accessor simulator-root-pass)))

(defun make-simulator-root-client
    (&key (provider-capacity 64)
          (registration-capacity (max provider-capacity 64))
          (root-capacity 1024))
  (unless (and (typep provider-capacity '(integer 1 #.most-positive-fixnum))
               (typep registration-capacity
                      '(integer 1 #.most-positive-fixnum))
               (typep root-capacity '(integer 0 #.most-positive-fixnum)))
    (host-reject :invalid-provider-capacity))
  (let* ((providers (make-array provider-capacity :initial-element nil))
         (tokens (make-array registration-capacity))
         (entries (make-array root-capacity))
         (scratch (make-array root-capacity :initial-element nil))
         ;; Both tables receive their maximum number of distinct live keys.
         ;; SBCL provisions their backing here; registration never grows them.
         (directory (make-hash-table :test #'eq :size (max 1 root-capacity)
                                     :rehash-size 2.0 :rehash-threshold 1.0))
         (seen (make-hash-table :test #'eq :size (max 1 root-capacity)
                                :rehash-size 2.0 :rehash-threshold 1.0))
         (client
           (make-instance 'simulator-root-client
                          :providers providers :token-reserve tokens
                          :entry-reserve entries
                          :registration-capacity registration-capacity
                          :location-capacity root-capacity
                          :free-entry-head (if (plusp root-capacity) 0 -1)
                          :free-entry-count root-capacity
                          :registration-scratch scratch
                          :registration-seen seen :directory directory)))
    (dotimes (index registration-capacity)
      (setf (aref tokens index) (%make-provider-token :owner client)))
    (dotimes (index root-capacity)
      (setf (aref entries index)
            (%make-root-entry :next (if (= index (1- root-capacity))
                                        -1 (1+ index)))))
    client))

(defun %valid-provider-token (client token)
  (and (simulator-provider-token-p token)
       (eq client (simulator-provider-token-owner token))
       (simulator-provider-token-active-p token)
       (let ((position (simulator-provider-token-position token))
             (providers (simulator-root-providers client)))
         (and (integerp position) (<= 0 position) (< position (length providers))
              (eq token (aref providers position))))))

(defun %provider-entry (client token location)
  (unless (%valid-provider-token client token)
    (host-reject :invalid-provider-token))
  (let ((entry (gethash location (simulator-root-directory client))))
    (unless (and entry (simulator-root-entry-active-p entry)
                 (eq token (simulator-root-entry-token entry)))
      (host-reject :invalid-root-location))
    entry))

(defvar *simulator-registration-client* nil)
(defvar *simulator-registration-capacity* 0)
(defvar *simulator-registration-count* 0)

(defun %simulator-registration-visitor (location)
  (let* ((client *simulator-registration-client*)
         (count *simulator-registration-count*)
         (seen (simulator-root-registration-seen client)))
    (when (or (>= count *simulator-registration-capacity*) (null location))
      (host-reject :invalid-provider-enumeration))
    (when (or (gethash location (simulator-root-directory client))
              (gethash location seen))
      (host-reject :duplicate-root-location))
    (unless (eq :exact (host-root-kind location))
      (host-reject :unsupported-root-kind))
    (setf (gethash location seen) t
          (aref (simulator-root-registration-scratch client) count) location
          *simulator-registration-count* (1+ count)))
  (values))

(defun %clear-root-registration-scratch (client count)
  (dotimes (index count)
    (setf (aref (simulator-root-registration-scratch client) index) nil))
  (clrhash (simulator-root-registration-seen client))
  (values))

(defun %release-root-entry-chain (client head count &optional remove-directory-p)
  (let ((entries (simulator-root-entry-reserve client))
        (directory (simulator-root-directory client))
        (index head))
    (dotimes (unused count)
      (declare (ignore unused))
      (when (minusp index) (host-reject :root-service-invariant))
      (let* ((entry (aref entries index))
             (next (simulator-root-entry-next entry))
             (location (simulator-root-entry-location entry)))
        (when (and remove-directory-p location) (remhash location directory))
        (setf (simulator-root-entry-token entry) nil
              (simulator-root-entry-location entry) nil
              (simulator-root-entry-seen entry) 0
              (simulator-root-entry-active-p entry) nil
              (simulator-root-entry-next entry)
              (simulator-root-free-entry-head client)
              (simulator-root-free-entry-head client) index)
        (incf (simulator-root-free-entry-count client))
        (setf index next))))
  (values))

(defun %commit-root-registration (client provider-id provider position count)
  (let* ((token-index (simulator-root-next-token client))
         (token (aref (simulator-root-token-reserve client) token-index))
         (entries (simulator-root-entry-reserve client))
         (scratch (simulator-root-registration-scratch client))
         (directory (simulator-root-directory client))
         (head -1)
         (acquired 0)
         (committed nil))
    (setf (simulator-provider-token-identity token) provider-id
          (simulator-provider-token-generation token)
          (1+ (simulator-root-generation client))
          (simulator-provider-token-provider token) provider
          (simulator-provider-token-position token) position
          (simulator-provider-token-entry-head token) -1
          (simulator-provider-token-entry-count token) count
          (simulator-provider-token-active-p token) nil)
    (unwind-protect
         (progn
           (dotimes (index count)
             (let* ((entry-index (simulator-root-free-entry-head client))
                    (entry (aref entries entry-index))
                    (next-free (simulator-root-entry-next entry))
                    (location (aref scratch index)))
               (setf (simulator-root-free-entry-head client) next-free)
               (decf (simulator-root-free-entry-count client))
               (setf (simulator-root-entry-token entry) token
                     (simulator-root-entry-location entry) location
                     (simulator-root-entry-next entry) head
                     (simulator-root-entry-seen entry) 0
                     (simulator-root-entry-active-p entry) t
                     head entry-index)
               (incf acquired)
               (setf (gethash location directory) entry)))
           (setf (simulator-provider-token-entry-head token) head
                 (simulator-provider-token-active-p token) t
                 (aref (simulator-root-providers client) position) token
                 (simulator-root-generation client)
                 (simulator-provider-token-generation token)
                 (simulator-root-next-token client) (1+ token-index)
                 committed t)
           token)
      (unless committed
        (%release-root-entry-chain client head acquired t)
        (setf (simulator-provider-token-identity token) nil
              (simulator-provider-token-provider token) nil
              (simulator-provider-token-entry-head token) -1
              (simulator-provider-token-entry-count token) 0
              (simulator-provider-token-active-p token) nil)))))

(defmethod register-root-provider ((client simulator-root-client)
                                   provider-id capacity provider)
  (when (or (simulator-root-admission-closed-p client)
            (simulator-root-snapshot-active-p (simulator-client-snapshot client)))
    (host-reject :root-registration-closed))
  (when (simulator-root-registration-active-p client)
    (host-reject :root-registration-busy))
  (unless (and provider-id (typep capacity '(integer 0 #.most-positive-fixnum)))
    (host-reject :invalid-provider-description))
  (when (= (simulator-root-generation client) most-positive-fixnum)
    (host-reject :root-generation-exhausted))
  (let* ((providers (simulator-root-providers client))
         (position (position nil providers)))
    (unless position (host-reject :provider-capacity-exhausted))
    (dotimes (index (length providers))
      (let ((other (aref providers index)))
        (when (and other
                   (eql provider-id
                        (simulator-provider-token-identity other)))
          (host-reject :duplicate-provider-identity))))
    (when (= (simulator-root-next-token client)
             (simulator-root-registration-capacity client))
      (host-reject :registration-history-exhausted))
    ;; Capacity exhaustion precedes provider enumeration and consumes nothing.
    (when (> capacity (simulator-root-free-entry-count client))
      (host-reject :root-capacity-exhausted))
    (let ((*simulator-registration-client* client)
          (*simulator-registration-capacity* capacity)
          (*simulator-registration-count* 0))
      (setf (simulator-root-registration-active-p client) t)
      (unwind-protect
           (progn
             (map-provider-roots provider #'%simulator-registration-visitor)
             (%commit-root-registration
              client provider-id provider position
              *simulator-registration-count*))
        (%clear-root-registration-scratch
         client *simulator-registration-count*)
        (setf (simulator-root-registration-active-p client) nil)))))

(defmethod unregister-root-provider ((client simulator-root-client) token)
  (unless (%valid-provider-token client token)
    (host-reject :invalid-provider-token))
  (when (or (simulator-root-admission-closed-p client)
            (simulator-root-snapshot-active-p (simulator-client-snapshot client)))
    (host-reject :root-generation-protected))
  (when (simulator-root-registration-active-p client)
    (host-reject :root-registration-busy))
  (when (= most-positive-fixnum (simulator-root-generation client))
    (host-reject :root-generation-exhausted))
  (%release-root-entry-chain
   client (simulator-provider-token-entry-head token)
   (simulator-provider-token-entry-count token) t)
  (setf (aref (simulator-root-providers client)
              (simulator-provider-token-position token)) nil
        (simulator-provider-token-active-p token) nil
        (simulator-provider-token-identity token) nil
        (simulator-provider-token-provider token) nil
        (simulator-provider-token-entry-head token) -1
        (simulator-provider-token-entry-count token) 0)
  (incf (simulator-root-generation client))
  (values))

(defmethod root-provider-load ((client simulator-root-client) token location)
  (%provider-entry client token location)
  (when (simulator-root-admission-closed-p client)
    (host-reject :root-access-stopped))
  (host-root-value location))
(defmethod root-provider-store ((client simulator-root-client) context token location reference)
  (%provider-entry client token location)
  (when (simulator-root-admission-closed-p client)
    (host-reject :root-access-stopped))
  ;; Context and reference admission, reservations, and sole exposure belong
  ;; to the runtime's composed :ROOT-STORE route. No raw-store fallback.
  (store-provider-root client context token location reference))

(defvar *simulator-borrowed-root-client* nil)
(defvar *simulator-borrowed-root-location* nil)
(defvar *simulator-root-map-client* nil)
(defvar *simulator-root-map-token* nil)
(defvar *simulator-root-map-function* nil)
(defvar *simulator-root-map-count* 0)
(defvar *simulator-root-map-pass* 0)
(defun %simulator-root-visitor (location)
  (let* ((client *simulator-root-map-client*)
         (entry (%provider-entry client *simulator-root-map-token* location)))
    (when (= *simulator-root-map-pass* (simulator-root-entry-seen entry))
      (host-reject :duplicate-root-enumeration))
    (setf (simulator-root-entry-seen entry) *simulator-root-map-pass*)
    (incf *simulator-root-map-count*)
    (let ((*simulator-borrowed-root-client* client)
          (*simulator-borrowed-root-location* location))
      (funcall *simulator-root-map-function* client location))))
(defun %check-borrowed-root (client location)
  (unless (and (eq client *simulator-borrowed-root-client*)
               (eq location *simulator-borrowed-root-location*)
               (simulator-root-snapshot-active-p (simulator-client-snapshot client)))
    (host-reject :root-location-not-borrowed)))
(defmethod load-root ((client simulator-root-client) location)
  (%check-borrowed-root client location)
  (host-root-value location))
(defmethod store-root ((client simulator-root-client) location reference)
  (%check-borrowed-root client location)
  (setf (host-root-value location) reference))
(defmethod root-location-kind ((client simulator-root-client) location)
  (%check-borrowed-root client location)
  (host-root-kind location))

(defmethod with-root-snapshot ((client simulator-root-client) coverage function)
  (unless (and (simulator-coverage-p coverage)
               (eq client (simulator-coverage-roots coverage))
               (simulator-coverage-protected-p coverage)
               (not (simulator-coverage-correction-failed-p coverage))
               (= (simulator-root-generation client)
                  (simulator-coverage-root-generation coverage)))
    (host-reject :invalid-root-coverage))
  (let ((snapshot (simulator-client-snapshot client)) (complete nil))
    (when (simulator-root-snapshot-active-p snapshot)
      (host-reject :snapshot-already-active))
    (setf (simulator-root-snapshot-client snapshot) client
          (simulator-root-snapshot-coverage snapshot) coverage
          (simulator-root-snapshot-active-p snapshot) t)
    (incf (simulator-coverage-borrowers coverage))
    (unwind-protect
         (multiple-value-prog1 (funcall function snapshot) (setf complete t))
      (unless complete (setf (simulator-coverage-correction-failed-p coverage) t))
      (setf (simulator-root-snapshot-active-p snapshot) nil
            (simulator-root-snapshot-coverage snapshot) nil)
      (decf (simulator-coverage-borrowers coverage)))))
(defun %reset-provider-token-entry-seen (client token)
  (let ((entries (simulator-root-entry-reserve client))
        (index (simulator-provider-token-entry-head token)))
    (dotimes (unused (simulator-provider-token-entry-count token))
      (declare (ignore unused))
      (when (minusp index) (host-reject :root-service-invariant))
      (let ((entry (aref entries index)))
        (setf (simulator-root-entry-seen entry) 0
              index (simulator-root-entry-next entry)))))
  (values))

(defmethod map-root-locations ((snapshot simulator-root-snapshot) function)
  (unless (and (simulator-root-snapshot-active-p snapshot)
               (simulator-coverage-protected-p (simulator-root-snapshot-coverage snapshot)))
    (host-reject :inactive-root-snapshot))
  (let* ((client (simulator-root-snapshot-client snapshot))
         (providers (simulator-root-providers client)))
    (when (= most-positive-fixnum (simulator-root-pass client))
      ;; Safe reset under covering stop, before this pass visits a location.
      (dotimes (i (length providers))
        (let ((token (aref providers i)))
          (when token (%reset-provider-token-entry-seen client token))))
      (setf (simulator-root-pass client) 0))
    (let ((*simulator-root-map-client* client)
          (*simulator-root-map-function* function)
          (*simulator-root-map-pass* (incf (simulator-root-pass client))))
      (dotimes (i (length providers))
        (let ((*simulator-root-map-token* (aref providers i))
              (*simulator-root-map-count* 0))
          (when *simulator-root-map-token*
            (map-provider-roots
             (simulator-provider-token-provider *simulator-root-map-token*)
             #'%simulator-root-visitor)
            (unless (= *simulator-root-map-count*
                       (simulator-provider-token-entry-count
                        *simulator-root-map-token*))
              (host-reject :missing-root-location)))))))
  (values))
