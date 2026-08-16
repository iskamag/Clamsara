;;;; vm/scheduler.lisp -- single-threaded scheduler/work-packet protocol.
;;;;
;;;; The simulator owns a fixed packet pool and a fixed queue.  The protocol is
;;;; deliberately expressed as scheduler generics so a VM with real workers
;;;; can replace these methods without changing collectors.  There are no
;;;; locks or host allocations on enqueue/steal/drain: the simulator is the
;;;; one-worker implementation described by vm-capabilities.tex.

(in-package #:clamsara)

;; ---- work packets --------------------------------------------------------

(defclass work-packet ()
  ((function :initarg :function :initform nil :accessor work-packet-function)
   ;; REGION is an opaque description.  START/END are convenient for the
   ;; common contiguous-region case and are kept as separate fixnum slots so
   ;; packet consumers need not allocate a cons describing a range.
   (region :initarg :region :initform nil :accessor work-packet-region)
   (region-start :initarg :region-start :initform 0
                 :accessor work-packet-region-start)
   (region-end :initarg :region-end :initform 0
               :accessor work-packet-region-end)
   (data :initarg :data :initform nil :accessor work-packet-data)
   ;; These slots are VM-internal ownership state.  A packet obtained from a
   ;; VM is never copied; it is returned to the VM's free stack after drain.
   (owner :initarg :owner :initform nil :accessor work-packet-owner)
   (pool-index :initarg :pool-index :initform -1 :accessor work-packet-pool-index)
   (state :initarg :state :initform :detached :accessor work-packet-state)))

(defun work-packet-fn (packet)
  "Compatibility spelling for WORK-PACKET-FUNCTION."
  (work-packet-function packet))

(defun (setf work-packet-fn) (function packet)
  (setf (work-packet-function packet) function))

(defun work-packet-start (packet)
  (work-packet-region-start packet))
(defun (setf work-packet-start) (value packet)
  (setf (work-packet-region-start packet) value))
(defun work-packet-end (packet)
  (work-packet-region-end packet))
(defun (setf work-packet-end) (value packet)
  (setf (work-packet-region-end packet) value))

(defun work-packet-reset (packet)
  "Clear the mutable description of PACKET before returning it to its pool."
  (setf (work-packet-function packet) nil
        (work-packet-region packet) nil
        (work-packet-region-start packet) 0
        (work-packet-region-end packet) 0
        (work-packet-data packet) nil)
  packet)

(defun %packet-plist (args)
  ;; Besides the documented keyword form, accept the compact positional form
  ;; (FUNCTION START END), which is useful in VM-side boot code.
  (if (or (null args) (keywordp (first args)))
      args
      (list :function (first args)
            :region-start (second args)
            :region-end (third args))))

(defun make-work-packet (&rest args)
  "Make a packet, or obtain one from a VM's preallocated packet pool.

With a VM as the first argument this is the allocation-free VM form, e.g.
  (make-work-packet vm :function #'scan :region-start 0 :region-end 10)
Without a VM it makes a standalone packet for protocol tests or a backend
that supplies its own immortal storage."
  (let ((vm (and args (typep (first args) 'vm-binding)
                 (first args))))
    (if vm
        (apply #'vm-allocate-work-packet vm (%packet-plist (rest args)))
        (let* ((plist (%packet-plist args))
               (function (or (getf plist :function) (getf plist :fn)
                             (getf plist :task)))
               (start (or (getf plist :region-start) (getf plist :start) 0))
               (end (or (getf plist :region-end) (getf plist :end) 0)))
          (make-instance 'work-packet
                         :function function
                         :region (getf plist :region)
                         :region-start start
                         :region-end end
                         :data (getf plist :data))))))

;; ---- scheduler -----------------------------------------------------------

(defclass scheduler ()
  ((vm :initarg :vm :reader scheduler-vm)
   ;; A bounded ring permits enqueue after a partial steal without compacting
   ;; or allocating.  HEAD/Tail are indices of the next front/back slot.
   (queue :initarg :queue :reader scheduler-queue)
   (head :initform 0 :accessor scheduler-head)
   (tail :initform 0 :accessor scheduler-tail)
   (count :initform 0 :accessor scheduler-queue-size)
   (capacity :initarg :capacity :reader scheduler-capacity)))

(defun %make-scheduler (vm capacity)
  (make-instance 'scheduler
                 :vm vm
                 :capacity (max 1 capacity)
                 :queue (make-array (max 1 capacity) :initial-element nil)))

(defun make-scheduler (vm &key (capacity (max 1 (vm-heap-size vm))))
  "Create a bounded single-worker scheduler for VM.

Normally use VM's already-created scheduler via VM-SCHEDULER; this constructor
is exposed for simulator protocol tests and backend experimentation."
  (%make-scheduler vm capacity))

(defun initialize-vm-scheduler (vm &key (capacity (max 1 (vm-heap-size vm))))
  "Install VM's preallocated scheduler and work-packet pool once.

The pool is intentionally allocated at VM creation, rather than while a
collector is running.  CAPACITY bounds both packet records and queue entries."
  (or (vm-scheduler vm)
      (let* ((n (max 1 capacity))
             (pool (make-array n :initial-element nil))
             (free (make-array n :element-type 'fixnum :initial-element 0
                               :fill-pointer n))
             (scheduler (%make-scheduler vm n)))
        (dotimes (i n)
          (setf (aref pool i)
                (make-instance 'work-packet
                               :owner vm
                               :pool-index i
                               :state :free)
                ;; A stack is simplest when the last slot is handed out
                ;; first; no packet identity depends on this order.
                (aref free i) i))
        (setf (vm-work-packet-pool vm) pool
              (vm-work-packet-free-stack vm) free
              (vm-scheduler vm) scheduler)
        scheduler)))

(defun vm-work-packet-pool-size (vm)
  (if (vm-work-packet-pool vm)
      (length (vm-work-packet-pool vm))
      0))

(defun vm-work-packet (vm &optional (index nil index-p))
  "Return preallocated packet INDEX, or acquire the next free packet.

The index form is useful for inspecting pool identity; the no-index form is
the normal packet allocation API."
  (if index-p
      (aref (vm-work-packet-pool vm) index)
      (vm-allocate-work-packet vm)))

(defun vm-allocate-work-packet (vm &key function fn task region
                                      region-start start region-end end data)
  "Acquire one packet from VM's fixed pool and populate its description.
FN/TASK and START/END are accepted aliases for FUNCTION and REGION-START/
REGION-END, respectively."
  (unless (vm-scheduler vm)
    (initialize-vm-scheduler vm))
  (let ((free (vm-work-packet-free-stack vm)))
    (when (zerop (fill-pointer free))
      (error 'heap-exhausted :requested-size 1 :space :scheduler-packets))
    (let* ((index (vector-pop free))
           (packet (aref (vm-work-packet-pool vm) index)))
      (work-packet-reset packet)
      (setf (work-packet-region packet) region
            (work-packet-function packet) (or function fn task)
            (work-packet-region-start packet) (or region-start start 0)
            (work-packet-region-end packet) (or region-end end 0)
            (work-packet-data packet) data
            (work-packet-state packet) :detached)
      packet)))

(defun vm-make-work-packet (vm &rest args)
  "Alias for VM-ALLOCATE-WORK-PACKET accepting its keyword description."
  (apply #'vm-allocate-work-packet vm args))

(defun release-work-packet (packet)
  "Return a VM-owned PACKET to its preallocated pool.

A packet stolen by a worker is active until explicitly released.  Drained
packets are released by SCHEDULER-DRAIN, including when its callback signals."
  (let ((vm (work-packet-owner packet)))
    (if (null vm)
        (setf (work-packet-state packet) :detached)
        (let ((state (work-packet-state packet)))
          (when (member state '(:queued :free))
            (error 'clamsara-error
                   :message "cannot release a queued or already-free work packet"))
          (setf (work-packet-state packet) :free)
          (work-packet-reset packet)
          (vector-push (work-packet-pool-index packet)
                       (vm-work-packet-free-stack vm)))))
  packet)

(defun %packet-compatible-p (scheduler packet)
  (or (null (work-packet-owner packet))
      (eq (work-packet-owner packet) (scheduler-vm scheduler))))

(defgeneric scheduler-enqueue (scheduler packet)
  (:documentation "Put preallocated PACKET on SCHEDULER's bounded work queue."))

(defmethod scheduler-enqueue ((s scheduler) (packet work-packet))
  (unless (%packet-compatible-p s packet)
    (error 'clamsara-error :message "work packet belongs to another VM scheduler"))
  (unless (eq (work-packet-state packet) :detached)
    (error 'clamsara-error :message "work packet is not available for enqueue"))
  (when (= (scheduler-queue-size s) (scheduler-capacity s))
    (error 'heap-exhausted :requested-size 1 :space :scheduler-queue))
  (let* ((queue (scheduler-queue s))
         (tail (scheduler-tail s)))
    (setf (aref queue tail) packet
          (scheduler-tail s) (mod (1+ tail) (scheduler-capacity s)))
    (incf (scheduler-queue-size s))
    (setf (work-packet-state packet) :queued)
    packet))

;; A simulator VM is itself a convenient scheduler handle.  This is the
;; single-threaded surface used by collector code; VM-SCHEDULER exposes the
;; explicit scheduler object when desired.
(defmethod scheduler-enqueue ((vm vm-binding) (packet work-packet))
  (scheduler-enqueue (or (vm-scheduler vm) (initialize-vm-scheduler vm)) packet))

(defun %scheduler-pop-front (s)
  (when (plusp (scheduler-queue-size s))
    (let* ((queue (scheduler-queue s))
           (head (scheduler-head s))
           (packet (aref queue head)))
      (setf (aref queue head) nil
            (scheduler-head s) (mod (1+ head) (scheduler-capacity s)))
      (decf (scheduler-queue-size s))
      (when (zerop (scheduler-queue-size s))
        (setf (scheduler-head s) 0 (scheduler-tail s) 0))
      (setf (work-packet-state packet) :active)
      packet)))

(defgeneric scheduler-steal (scheduler)
  (:documentation "Take one packet from the back of SCHEDULER, or NIL."))

(defmethod scheduler-steal ((s scheduler))
  ;; LIFO from the back is the conventional worker-steal direction.  It is
  ;; deterministic here because there is only one worker.
  (when (plusp (scheduler-queue-size s))
    (let* ((queue (scheduler-queue s))
           (tail (mod (1- (scheduler-tail s)) (scheduler-capacity s)))
           (packet (aref queue tail)))
      (setf (aref queue tail) nil
            (scheduler-tail s) tail)
      (decf (scheduler-queue-size s))
      (when (zerop (scheduler-queue-size s))
        (setf (scheduler-head s) 0 (scheduler-tail s) 0))
      (setf (work-packet-state packet) :active)
      packet)))

(defmethod scheduler-steal ((vm vm-binding))
  (scheduler-steal (or (vm-scheduler vm) (initialize-vm-scheduler vm))))

(defun %run-work-packet (packet)
  (let ((function (work-packet-function packet)))
    (when function
      (if (functionp function)
          (funcall function packet)
          (when (and (symbolp function) (fboundp function))
            (funcall function packet))))))

(defgeneric scheduler-drain (scheduler &optional fn)
  (:documentation "Drain all packets in FIFO order.  FN, when supplied, is
called with each packet; otherwise the packet's function designator is run.
Returns the number drained.  Drained VM-owned packets return to the pool."))

(defmethod scheduler-drain ((s scheduler) &optional fn)
  (let ((drained 0))
    (loop while (plusp (scheduler-queue-size s))
          do (let ((packet (%scheduler-pop-front s)))
               (unwind-protect
                    (if fn (funcall fn packet) (%run-work-packet packet))
                 (release-work-packet packet))
               (incf drained)))
    drained))

(defmethod scheduler-drain ((vm vm-binding) &optional fn)
  (scheduler-drain (or (vm-scheduler vm) (initialize-vm-scheduler vm)) fn))

;; ---- mutator context -----------------------------------------------------

(defclass mutator-context ()
  ((plan :initarg :plan :reader mutator-context-plan)
   (vm :initarg :vm :reader mutator-context-vm)
   (tlab-cursor :initarg :tlab-cursor :initform 0
                :accessor mutator-context-tlab-cursor)
   (tlab-limit :initarg :tlab-limit :initform 0
               :accessor mutator-context-tlab-limit)
   (allocator :initarg :allocator :initform nil
              :accessor mutator-context-allocator)
   (barrier :initarg :barrier :initform nil
            :accessor mutator-context-barrier)))

(defun %new-mutator-context (plan &key vm allocator barrier
                                      (tlab-cursor 0) (tlab-limit 0))
  (make-instance 'mutator-context
                 :plan plan :vm vm :allocator allocator :barrier barrier
                 :tlab-cursor tlab-cursor :tlab-limit tlab-limit))

(defun make-mutator-context (plan &key vm allocator barrier
                                      (tlab-cursor 0) (tlab-limit 0))
  "Create and register a context owned by PLAN.

The initial context is made by PLAN construction.  Additional contexts are
kept in PLAN-MUTATOR-CONTEXTS; no VM-global context slot is used."
  (let ((actual-vm (or vm (plan-vm plan))))
    (unless (eq actual-vm (plan-vm plan))
      (error 'clamsara-error
             :message "mutator context belongs to another VM"))
    (let* ((context (%new-mutator-context
                     plan :vm actual-vm :allocator allocator
                     :barrier (or barrier (plan-barrier plan))
                     :tlab-cursor tlab-cursor :tlab-limit tlab-limit))
           (contexts (plan-mutator-contexts plan)))
      (vector-push-extend context contexts)
      context)))
