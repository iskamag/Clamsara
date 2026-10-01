;;;; Immix mark-region collector (paper-v14 chapters/collectors.tex, "Immix").
;;;;
;;;; Immix divides each space into blocks of lines.  Marking an object marks
;;;; every line intersecting its reserved byte extent, including a partial last
;;;; line.  Immix reclaims at line granularity: a line is free (a hole) only
;;;; after a complete liveness judgment, and a block is free only after every
;;;; spanning object is accounted for.  Immix does not free an object that
;;;; shares a line with a live object; such a dead object is retained as
;;;; floating garbage.  There is no forwarding store: the base plan is
;;;; nonmoving.  Optional sparse-block evacuation (the SemiSpace copying action)
;;;; is deliberately not installed here.
;;;;
;;;; The authoritative free state is one bit per line (1 = free).  A cycle
;;;; builds a complete candidate by walking the authoritative object-start map
;;;; twice: first occupying every line a live object spans, then reclaiming only
;;;; objects whose whole extent lies in lines no live object touched.  The
;;;; allocator scans the candidate for runs of free lines; an object is placed
;;;; in the first run that fits, and a run whose lines are exhausted is skipped.
(in-package #:clamsara)

(defclass immix-space (marking-space)
  ((line-size :initarg :line-size :reader %immix-line-size)
   (block-size :initarg :block-size :reader %immix-block-size)
   (line-resource-id :initform (gensym "IMMIX-LINES-")
                     :reader %immix-line-resource-id)
   (free-lines :initform nil :accessor %immix-free-lines)
   (candidate-free-lines :initform nil :accessor %immix-candidate-free-lines)
   (candidate-ready-p :initform nil :accessor %immix-candidate-ready-p)
   ;; The cycle whose candidate reclamation is being built, so a death row can be
   ;; staged without threading the cycle through the metadata traversal.
   (current-cycle :initform nil :accessor %immix-current-cycle)
   (occupy-callback :initform nil :accessor %immix-occupy-callback)
   (judge-callback :initform nil :accessor %immix-judge-callback)))

(defclass immix-runtime-allocator (bump-runtime-allocator)
  ((free :initform nil :accessor %immix-allocator-free)
   ;; Cursors themselves are inherited from the bump allocator.  CURSOR-LINE is
   ;; the first line not yet scanned as a run start; LAST-CURSOR-LINE restores it
   ;; so a canceled allocation rescans the same run instead of skipping it.
   (cursor-line :initform 0 :accessor %immix-cursor-line)
   (last-cursor-line :initform 0 :accessor %immix-last-cursor-line)))

(defun %immix-line-count (space)
  (ceiling (%space-extent space) (%immix-line-size space)))

(defmethod component-resources ((space immix-space))
  (let* ((lines (%immix-line-count space))
         ;; Two bit maps: the authoritative free map and the candidate.
         (entries (* 2 lines))
         (bytes (+ 16 (ceiling entries 8))))
    (append (call-next-method)
            (list (make-resource-contribution
                   space (%immix-line-resource-id space) :packed-bit-vector
                   :minimum-physical-bytes bytes
                   :logical-entry-bound entries
                   :auxiliary-bytes 1024
                   :allocation-context :construction-only
                   :exhaustion-action :reject-before-publication)))))

(defmethod initialize-component :after ((space immix-space) context)
  (let* ((lines (%immix-line-count space))
         (entries-required (* 2 lines))
         (bytes (+ 16 (ceiling entries-required 8))))
    (multiple-value-bind (handle present-p physical entries auxiliary)
        (construction-resource context (%immix-line-resource-id space))
      (unless (and present-p (typep handle 'simple-bit-vector)
                   (>= physical bytes)
                   (>= auxiliary 1024)
                   (>= entries entries-required)
                   (>= (length handle) entries-required))
        (%runtime-reject :resource-capacity-mismatch))
      (setf (%immix-free-lines space)
            (make-array lines :displaced-to handle :element-type 'bit)
            (%immix-candidate-free-lines space)
            (make-array lines :displaced-to handle :element-type 'bit
                        :displaced-index-offset lines))
      (dolist (object (list (%immix-free-lines space)
                            (%immix-candidate-free-lines space)))
        (%register-resource-auxiliary context (%immix-line-resource-id space)
                                      object)))
    ;; The whole space starts free; the allocator owns the authoritative map.
    (fill (%immix-free-lines space) 1)
    (fill (%immix-candidate-free-lines space) 1)
    (let ((allocator (make-instance 'immix-runtime-allocator :space space)))
      (setf (%allocator-cursor allocator) 0
            (%allocator-limit allocator) 0
            (%immix-cursor-line allocator) 0
            (%immix-allocator-free allocator) (%immix-free-lines space)
            (%space-allocator space) allocator)
      (%register-resource-auxiliary context (%space-state-resource-id space)
                                    allocator))
    (setf (%immix-occupy-callback space)
          (lambda (key value)
            (declare (ignore value))
            (%immix-occupy-start space key))
          (%immix-judge-callback space)
          (lambda (key value)
            (declare (ignore value))
            (%immix-judge-start space key)))
    (metadata-reset-range (%space-object-start-map space) (%space-range space))
    (metadata-reset-range (%space-marks space) (%space-range space))
    (values)))

(defmethod validate-component :after ((space immix-space) configuration)
  (declare (ignore configuration))
  (let ((line (%immix-line-size space))
        (block (%immix-block-size space))
        (q (%space-packing-quantum space))
        (extent (%space-extent space)))
    (unless (and (typep line '(integer 1 *))
                 (%positive-power-of-two-p line)
                 (typep block '(integer 1 *))
                 (%positive-power-of-two-p block)
                 (>= line q)
                 (zerop (mod block line))
                 (zerop (mod extent line))
                 (<= 1 (/ block line)))
      (%runtime-reject :invalid-immix-geometry)))
  (unless (typep (%space-marks space) 'mark-map)
    (%runtime-reject :invalid-immix-marks))
  (values))

(defun make-immix-space (&key name object-start-map marks extent packing-quantum
                              line-size block-size)
  (unless (and (typep extent '(integer 1 *))
               (%positive-power-of-two-p packing-quantum)
               (zerop (mod extent packing-quantum))
               (typep line-size '(integer 1 *))
               (%positive-power-of-two-p line-size)
               (typep block-size '(integer 1 *))
               (%positive-power-of-two-p block-size)
               (>= line-size packing-quantum)
               (zerop (mod line-size packing-quantum))
               (zerop (mod block-size line-size))
               (zerop (mod extent line-size)))
    (%runtime-reject :invalid-immix-geometry))
  (make-instance 'immix-space :name name :object-start-map object-start-map
                 :marks marks :extent extent :packing-quantum packing-quantum
                 :line-size line-size :block-size block-size))

;;; ------------------------------------------------------------------
;;; Line occupancy in terms of a canonical object start.

(defun %immix-charged-end (space model start)
  (let* ((address (reference-address model start))
         (bytes (object-size model start))
         (charged (%align-up bytes (%space-packing-quantum space))))
    (values address (+ address charged))))

(defun %immix-object-lines (space model start)
  "Return the inclusive line index range [FIRST, LAST] intersecting the object's
reserved extent."
  (multiple-value-bind (start-address end-address)
      (%immix-charged-end space model start)
    (let ((line-size (%immix-line-size space))
          (base (%space-base space)))
      (unless (and (> end-address start-address)
                   (<= end-address (%space-limit space)))
        (%runtime-reject :fatal-invariant))
      (values (floor (- start-address base) line-size)
              (floor (- (1- end-address) base) line-size)))))

(defun %immix-occupy-start (space key)
  (let* ((model (%space-model space))
         (start (runtime-start-reference model space key))
         (free (%immix-candidate-free-lines space)))
    (when (marks-active-p (%space-marks space) key)
      (multiple-value-bind (first last) (%immix-object-lines space model start)
        (loop for index from first to last do (setf (bit free index) 0))))
    (values)))

(defun %immix-start-lines-free-p (space model start)
  (let ((free (%immix-candidate-free-lines space)))
    (multiple-value-bind (first last) (%immix-object-lines space model start)
      (loop for index from first to last
            always (eql 1 (bit free index))))))

(defun %immix-judge-start (space key)
  (let* ((model (%space-model space))
         (start (runtime-start-reference model space key)))
    ;; Only a confirmed dead object whose whole reserved extent lies in lines no
    ;; live object touched may be reclaimed, and then only if every line it
    ;; spans is free (a dead object sharing a live line is retained as floating
    ;; garbage, exactly as Immix requires).
    (unless (marks-active-p (%space-marks space) key)
      (when (%immix-start-lines-free-p space model start)
        (unless (%record-cycle-death (%immix-current-cycle space) space start)
          (%runtime-reject :capacity-exhausted))))
    (values)))

(defmethod prepare-space ((space immix-space) cycle)
  (declare (ignore cycle))
  ;; A fresh logical mark epoch without changing the allocation map.
  (marks-retire (%space-marks space))
  (setf (%immix-candidate-ready-p space) nil)
  (values))

;;; ------------------------------------------------------------------
;;; Reclamation: build the complete candidate free-line map.

(defmethod reclaim-space ((space immix-space) cycle)
  (setf (%immix-current-cycle space) cycle
        (%immix-candidate-ready-p space) nil)
  (handler-case
      (progn
        ;; Start from complete freedom; only a live object occupies lines.
        (fill (%immix-candidate-free-lines space) 1)
        (metadata-map-present (%space-object-start-map space) (%space-range space)
                              (%immix-occupy-callback space))
        (metadata-map-present (%space-object-start-map space) (%space-range space)
                              (%immix-judge-callback space))
        (setf (%immix-candidate-ready-p space) t)
        (values :ready nil))
    (error ()
      (setf (%immix-candidate-ready-p space) nil)
      (values :retained :preflight-failed))))

(defmethod cancel-reclaim-space ((space immix-space) cycle)
  (declare (ignore cycle))
  (setf (%immix-candidate-ready-p space) nil)
  (values))

(defmethod finish-space ((space immix-space) cycle)
  (unless (%immix-candidate-ready-p space)
    (%runtime-reject :fatal-invariant))
  ;; Death enumeration was completely validated during preflight; clearing the
  ;; authoritative starts and retiring dead representations is now a bounded
  ;; non-failing commit obligation.
  (dotimes (index (%cycle-death-count cycle))
    (when (eq space (aref (%cycle-death-spaces cycle) index))
      (let ((start (aref (%cycle-death-starts cycle) index)))
        (metadata-reset (%space-object-start-map space)
                        (reference-address (%space-model space) start))
        (runtime-retire-object-representation (%space-model space) start))))
  ;; The candidate free map becomes authoritative; the previous map is recycled
  ;; as next cycle's candidate.
  (rotatef (%immix-free-lines space) (%immix-candidate-free-lines space))
  (let ((allocator (%space-allocator space)))
    (setf (%immix-allocator-free allocator) (%immix-free-lines space)
          (%allocator-cursor allocator) 0
          (%allocator-limit allocator) 0
          (%immix-cursor-line allocator) 0
          (%allocator-last-valid-p allocator) nil))
  (setf (%immix-candidate-ready-p space) nil)
  (values))

;;; ------------------------------------------------------------------
;;; The line-scanning allocator.

(defun %immix-next-run (allocator from-line)
  "Find the first run of free lines at or after FROM-LINE.  Return the run's
[start-address, limit-address) and the line index just past it, or NIL."
  (let* ((free (%immix-allocator-free allocator))
         (line-size (%immix-line-size (%allocator-space allocator)))
         (base (%space-base (%allocator-space allocator)))
         (count (length free)))
    (loop for start from from-line below count
          when (eql 1 (bit free start))
            do (let ((end (1+ start)))
                 (loop while (and (< end count) (eql 1 (bit free end)))
                       do (incf end))
                 (return-from %immix-next-run
                   (values (+ base (* start line-size))
                           (+ base (* end line-size))
                           end))))
    nil))

(defmethod allocate-raw ((allocator immix-runtime-allocator)
                         bytes alignment kind)
  (declare (ignore kind))
  (%check-raw-allocation-barrier-boundary allocator)
  (loop
    (let* ((old (%allocator-cursor allocator))
           (start (%align-up old alignment))
           (end (+ start bytes)))
      (when (and (>= end start) (<= end (%allocator-limit allocator)))
        ;; Snapshot BOTH cursors, not only the byte cursor: a cancel must
        ;; restore the run-scan cursor too, or the next run selection rescans
        ;; from a stale line and hands back an occupied run.
        (setf (%allocator-last-cursor allocator) old
              (%immix-last-cursor-line allocator) (%immix-cursor-line allocator)
              (%allocator-cursor allocator) end
              (%allocator-last-valid-p allocator) t)
        (return (values start t))))
    ;; The current run cannot satisfy this request: select the next free run.
    (multiple-value-bind (run-start run-limit next-line)
        (%immix-next-run allocator (%immix-cursor-line allocator))
      (unless run-start
        (setf (%allocator-last-valid-p allocator) nil)
        (return (values nil nil)))
      (setf (%allocator-cursor allocator) run-start
            (%allocator-limit allocator) run-limit
            (%immix-last-cursor-line allocator) (%immix-cursor-line allocator)
            (%immix-cursor-line allocator) next-line))))

(defmethod %cancel-raw-allocation ((allocator immix-runtime-allocator))
  (when (%allocator-last-valid-p allocator)
    (setf (%allocator-cursor allocator) (%allocator-last-cursor allocator)
          (%immix-cursor-line allocator) (%immix-last-cursor-line allocator)
          (%allocator-last-valid-p allocator) nil))
  (values))

(defclass immix-plan (sequential-runtime-plan) ())

(defun make-immix-plan (&key space root-client coordinator diagnostics registry
                          trace-capacity conditional-capacity finalizer-capacity
                          packing-quantum allocation-routes movement-participants)
  (unless (and (typep space 'immix-space)
               (= (%space-packing-quantum space) packing-quantum))
    (%runtime-reject :invalid-immix-space))
  (%make-space-plan
   'immix-plan :immix :spaces (list space) :root-client root-client
   :coordinator coordinator :diagnostics diagnostics :registry registry
   :trace-capacity trace-capacity :conditional-capacity conditional-capacity
   :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum
   :allocation-routes allocation-routes :movement-participants movement-participants))
