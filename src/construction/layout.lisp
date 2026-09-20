;;;; src/construction/layout.lisp -- finite reference placement solver.

(in-package #:clamsara)

(defun %target-maximum (address-width)
  (unless (and (integerp address-width) (plusp address-width))
    (%reject :invalid-address-width))
  (1- (ash 1 address-width)))

(defun %checked-target-value (value maximum path)
  (unless (and (%nonnegative-integer-p value) (<= value maximum))
    (%reject :target-arithmetic-overflow (list path)))
  value)

(defun %checked-target-add (left right maximum path)
  (%checked-target-value (+ left right) maximum path))

(defun %construction-align-up (value alignment maximum path)
  (let* ((mask (1- alignment))
         (sum (%checked-target-add value mask maximum path)))
    (logand sum (lognot mask))))

(defun %offer-exclusion-range (value path)
  ;; The reference sequential offer uses fresh (BASE . EXCLUSIVE-LIMIT)
  ;; intervals.  A two-element proper list is accepted as the same interval.
  (cond
    ((and (consp value) (integerp (car value)) (integerp (cdr value)))
     (values (car value) (cdr value)))
    ((and (consp value) (consp (cdr value)) (null (cddr value))
          (integerp (first value)) (integerp (second value)))
     (values (first value) (second value)))
    (t (%reject :invalid-arena-exclusion (list path)))))

(defun %normalize-exclusions (values base limit path)
  (let ((ranges nil))
    (loop for value in (%proper-list-copy values path)
          for position from 0
          do (multiple-value-bind (start end)
                 (%offer-exclusion-range value (append path (list position)))
               (unless (and (<= base start end limit))
                 (%reject :arena-exclusion-out-of-range
                          (list (append path (list position)))))
               (when (< start end) (push (cons start end) ranges))))
    (setf ranges (sort ranges #'< :key #'car))
    (let ((merged nil))
      (dolist (range ranges)
        (let ((prior (first merged)))
          (if (and prior (<= (car range) (cdr prior)))
              (setf (cdr prior) (max (cdr prior) (cdr range)))
              (push (cons (car range) (cdr range)) merged))))
      (nreverse merged))))

(defun %snapshot-arena (address-client)
  (let* ((offer-path '(:clients :address-space :managed-arena-offer))
         (offer (%call-at-path offer-path #'managed-arena-offer address-client))
         (description-path '(:clients :address-space
                             :managed-arena-offer :description))
         (values (%multiple-at-path description-path
                                    #'describe-managed-arena-offer
                                    address-client offer)))
    (unless (= (length values) 8)
      (%reject :wrong-arena-description-values (list description-path)))
    (destructuring-bind
        (name base extent alignment page-size accesses address-width exclusions)
        values
      (unless name (%reject :nil-arena-name (list description-path)))
      (unless (%nonnegative-integer-p base)
        (%reject :invalid-arena-base (list description-path)))
      (unless (and (integerp extent) (plusp extent))
        (%reject :invalid-arena-extent (list description-path)))
      (unless (%construction-positive-power-of-two-p alignment)
        (%reject :invalid-arena-alignment (list description-path)))
      (unless (and (integerp page-size) (plusp page-size))
        (%reject :invalid-arena-page-size (list description-path)))
      (unless (zerop (mod base alignment))
        (%reject :misaligned-arena-base (list description-path)))
      (let* ((maximum (%target-maximum address-width))
             (limit (%checked-target-add base extent maximum description-path))
             (access-copy (%proper-list-copy accesses
                                             (append description-path
                                                     (list :accesses)))))
        (unless (and (not (%duplicate-eql-p access-copy))
                     (every (lambda (mode)
                              (member mode '(:read :write :execute :atomic)
                                      :test #'eql))
                            access-copy))
          (%reject :invalid-arena-accesses (list description-path)))
        (%make-arena-description
         :actual offer :path description-path :name name :base base
         :byte-extent extent :alignment alignment :page-size page-size
         :permitted-accesses access-copy :address-width address-width
         :exclusions (%normalize-exclusions
                      exclusions base limit
                      (append description-path (list :exclusions)))
         :exclusive-limit limit)))))

(defun %initial-free-intervals (arena)
  (let ((cursor (%arena-description-base arena))
        (limit (%arena-description-exclusive-limit arena))
        (result nil))
    (dolist (exclusion (%arena-description-exclusions arena))
      (when (< cursor (car exclusion))
        (push (cons cursor (car exclusion)) result))
      (setf cursor (max cursor (cdr exclusion))))
    (when (< cursor limit) (push (cons cursor limit) result))
    (nreverse result)))

(defun %subtract-interval (intervals base limit)
  (if (= base limit)
      (mapcar (lambda (range) (cons (car range) (cdr range))) intervals)
      (loop for range in intervals
            append (cond
                     ((or (<= limit (car range)) (>= base (cdr range)))
                      (list (cons (car range) (cdr range))))
                     (t
                      (append (when (< (car range) base)
                                (list (cons (car range) base)))
                              (when (< limit (cdr range))
                                (list (cons limit (cdr range))))))))))

(defun %ordinary-extent-candidates (placement)
  (let ((minimum (%placement-description-minimum-extent placement))
        (preferred (%placement-description-preferred-extent placement))
        (maximum (%placement-description-maximum-extent placement))
        (granularity (%placement-description-granularity placement))
        (result nil))
    (push preferred result)
    (loop for extent from (- preferred granularity) downto minimum
          by granularity do (push extent result))
    (setf result (nreverse result))
    (loop for extent from (+ preferred granularity) to maximum
          by granularity do (setf result (append result (list extent))))
    result))

(defun %derived-extent (placement assignments cache target-maximum)
  (let ((pairs
          (mapcar (lambda (identity)
                    (let ((solution (gethash identity assignments)))
                      (unless solution
                        (%reject :derived-input-not-assigned
                                 (list (%placement-description-path placement))))
                      (cons (%placement-solution-base solution)
                            (%placement-solution-exclusive-limit solution))))
                  (%placement-description-inputs placement))))
    (multiple-value-bind (cached present-p) (gethash pairs cache)
      (if present-p
          cached
          (let ((extent
                  (handler-case
                      (apply (%placement-description-size-function placement)
                             (mapcar (lambda (pair)
                                       (cons (car pair) (cdr pair)))
                                     pairs))
                    (error (condition)
                      (%reject :derived-size-function-signaled
                               (list (%placement-description-path placement))
                               condition)))))
            (unless (and (%nonnegative-integer-p extent)
                         (<= extent target-maximum)
                         (zerop (mod extent
                                     (%placement-description-granularity
                                      placement))))
              (%reject :invalid-derived-extent
                       (list (%placement-description-path placement))))
            (setf (gethash (copy-tree pairs) cache) extent)
            extent)))))

(defun %alias-constraint-other (constraint identity)
  (when (eql (%constraint-description-kind constraint) :alias)
    (let ((left (second (first (%constraint-description-identities constraint))))
          (right (second (second (%constraint-description-identities constraint)))))
      (cond ((eql identity left) right)
            ((eql identity right) left)
            (t nil)))))

(defun %alias-compatible-p (placement other)
  (and (%placement-description-aliasable-p placement)
       (%placement-description-aliasable-p other)
       (equal (%placement-description-access placement)
              (%placement-description-access other))
       (eql (%placement-description-lifetime placement)
            (%placement-description-lifetime other))))

(defun %alias-range-candidates (placement constraints assignments placement-table)
  (let ((ranges nil))
    (dolist (constraint constraints)
      (let ((other-key
              (%alias-constraint-other constraint
                                       (%placement-description-identity
                                        placement))))
        (when other-key
          (let ((solution (gethash other-key assignments)))
            (when solution
              (let ((other (gethash other-key placement-table)))
                (unless (%alias-compatible-p placement other)
                  (%reject :incompatible-alias-requests
                           (list (%placement-description-path placement)
                                 (%placement-description-path other)
                                 (%constraint-description-path constraint))))
                (pushnew (cons (%placement-solution-base solution)
                               (%placement-solution-exclusive-limit solution))
                         ranges :test #'equal)))))))
    ranges))

(defun %free-range-candidates (placement extent free-intervals target-maximum)
  (let ((alignment (%placement-description-alignment placement))
        (path (%placement-description-path placement))
        (ranges nil))
    (dolist (free free-intervals)
      (let ((base (%construction-align-up (car free) alignment target-maximum path)))
        (loop while (and (<= base (cdr free))
                         (<= extent (- (cdr free) base)))
              do (push (cons base (+ base extent)) ranges)
                 (if (or (zerop extent)
                         (> base (- target-maximum alignment)))
                     (return)
                     (incf base alignment)))))
    (nreverse ranges)))

(defun %constraint-values (constraint construction)
  (let ((values nil) (ready-p t))
    (dolist (designator (%constraint-description-identities constraint))
      (ecase (first designator)
        (:placement
         (multiple-value-bind (base limit present-p)
             (construction-placement construction (second designator))
           (if present-p
               (push (list (copy-list designator) (cons base limit)) values)
               (setf ready-p nil))))
        (:resource
         (multiple-value-bind (handle present-p physical entries auxiliary)
             (construction-resource construction (second designator))
           (if present-p
               (push (list (copy-list designator)
                           (list :handle handle :physical-bytes physical
                                 :entry-capacity entries
                                 :auxiliary-bytes auxiliary))
                     values)
               (setf ready-p nil))))))
    (values (nreverse values) ready-p)))

(defun %constraint-paths (constraint resource-table placement-table)
  (cons (%constraint-description-path constraint)
        (mapcar (lambda (designator)
                  (ecase (first designator)
                    (:resource
                     (%resource-description-path
                      (gethash (second designator) resource-table)))
                    (:placement
                     (%placement-description-path
                      (gethash (second designator) placement-table)))))
                (%constraint-description-identities constraint))))

(defun %standard-constraint-satisfied-p (kind values parameter target-maximum path)
  (let ((ranges (mapcar (lambda (entry) (second entry)) values)))
    (ecase kind
      (:adjacent
       (= (%checked-target-add (cdr (first ranges)) parameter
                               target-maximum path)
          (car (second ranges))))
      (:separate
       (let ((left (first ranges)) (right (second ranges)))
         (or (and (<= (cdr left) (car right))
                  (>= (- (car right) (cdr left)) parameter))
             (and (<= (cdr right) (car left))
                  (>= (- (car left) (cdr right)) parameter)))))
      (:alias (equal (first ranges) (second ranges)))
      (:equal-extent
       (apply #'= (mapcar (lambda (range) (- (cdr range) (car range)))
                          ranges)))
      (:numeric-reach
       (<= (abs (- (car (first ranges)) (car (second ranges)))) parameter)))))

(defun %constraint-satisfied-p
    (constraint construction address-client resource-table placement-table
     target-maximum)
  (multiple-value-bind (values ready-p)
      (%constraint-values constraint construction)
    (unless ready-p (return-from %constraint-satisfied-p (values t nil)))
    (let* ((kind (%constraint-description-kind constraint))
           (paths (%constraint-paths constraint resource-table placement-table))
           (base-result
             (if (member kind '(:adjacent :separate :alias :equal-extent
                                :numeric-reach) :test #'eql)
                 (%standard-constraint-satisfied-p
                  kind values (%constraint-description-parameters constraint)
                  target-maximum (%constraint-description-path constraint))
                 (handler-case
                     (multiple-value-bind (satisfied-p known-p)
                         (%evaluate-construction-constraint
                          address-client kind values
                          (%constraint-description-parameters constraint))
                       (unless known-p
                         (%reject :unknown-constraint-kind paths))
                       (not (null satisfied-p)))
                   (construction-rejected (condition) (error condition))
                   (error (condition)
                     (%reject :constraint-solver-signaled paths condition))))))
      (when (and base-result (%constraint-description-predicate constraint))
        (setf base-result
              (handler-case
                  (not (null (funcall (%constraint-description-predicate constraint)
                                      construction)))
                (error (condition)
                  (%reject :constraint-predicate-signaled paths condition)))))
      (values base-result t))))

(defun %candidate-constraints-satisfied-p
    (constraints construction address-client resource-table placement-table
     target-maximum)
  (dolist (constraint constraints t)
    (multiple-value-bind (satisfied-p ready-p)
        (%constraint-satisfied-p constraint construction address-client
                                 resource-table placement-table target-maximum)
      (when (and ready-p (not satisfied-p)) (return nil)))))

(defun %placement-ready-p (placement assignments)
  (every (lambda (identity) (gethash identity assignments))
         (%placement-description-inputs placement)))

(defun %solve-placements
    (placements constraints arena construction address-client resource-table
     placement-table)
  (let* ((target-maximum (%target-maximum
                          (%arena-description-address-width arena)))
         (ordered
           (stable-sort (copy-list placements)
                 (lambda (left right)
                   (or (> (%placement-description-constraint-count left)
                          (%placement-description-constraint-count right))
                       (and (= (%placement-description-constraint-count left)
                               (%placement-description-constraint-count right))
                            (or (> (%placement-description-alignment left)
                                   (%placement-description-alignment right))
                                (and (= (%placement-description-alignment left)
                                        (%placement-description-alignment right))
                                     (< (%placement-description-position left)
                                        (%placement-description-position
                                         right)))))))))
         (assignments (%context-placements construction))
         (derived-caches (make-hash-table :test #'eq))
         (initial-free (%initial-free-intervals arena)))
    (dolist (placement placements)
      (unless (subsetp (%placement-description-access placement)
                       (%arena-description-permitted-accesses arena)
                       :test #'eql)
        (%reject :placement-access-not-permitted
                 (list (%placement-description-path placement))))
      (dolist (bound (remove nil
                             (list (%placement-description-minimum-extent placement)
                                   (%placement-description-preferred-extent placement)
                                   (%placement-description-maximum-extent placement))))
        (%checked-target-value bound target-maximum
                               (%placement-description-path placement))))
    (labels
        ((place-search (remaining free-intervals)
           (if (null remaining)
               (values t free-intervals)
               (let ((placement
                       (find-if (lambda (item)
                                  (%placement-ready-p item assignments))
                                ordered)))
                 ;; ORDERED contains all requests; select only a member still
                 ;; remaining while preserving its global rank.
                 (setf placement
                       (find-if (lambda (item)
                                  (and (member item remaining :test #'eq)
                                       (%placement-ready-p item assignments)))
                                ordered))
                 (unless placement
                   (%reject :derived-placement-cycle
                            (mapcar #'%placement-description-path remaining)))
                 (let* ((extent-candidates
                          (if (%placement-description-derived-p placement)
                              (list (%derived-extent
                                     placement assignments
                                     (or (gethash placement derived-caches)
                                         (setf (gethash placement derived-caches)
                                               (make-hash-table :test #'equal)))
                                     target-maximum))
                              (%ordinary-extent-candidates placement)))
                        (next-remaining (delete placement (copy-list remaining)
                                                :test #'eq)))
                   (dolist (extent extent-candidates (values nil nil))
                     (let* ((alias-ranges
                              (%alias-range-candidates
                               placement constraints assignments placement-table))
                            (free-ranges
                              (%free-range-candidates
                               placement extent free-intervals target-maximum))
                            (ranges
                              (sort (remove-duplicates
                                     (append alias-ranges free-ranges)
                                     :test #'equal)
                                    #'< :key #'car)))
                       (dolist (range ranges)
                         (when (= (- (cdr range) (car range)) extent)
                           (let* ((alias-p (member range alias-ranges
                                                   :test #'equal))
                                  (solution
                                    (%make-placement-solution
                                     :description placement :base (car range)
                                     :exclusive-limit (cdr range)
                                     :derived-size
                                     (and (%placement-description-derived-p
                                           placement)
                                          extent)
                                     :alias-of (and alias-p (copy-list range))
                                     :object-start-map
                                     (%placement-description-object-start-map
                                      placement)))
                                  (new-free
                                    (if alias-p
                                        free-intervals
                                        (%subtract-interval free-intervals
                                                            (car range)
                                                            (cdr range)))))
                             (setf (gethash
                                    (%placement-description-identity placement)
                                    assignments)
                                   solution)
                             (when (%candidate-constraints-satisfied-p
                                    constraints construction address-client
                                    resource-table placement-table
                                    target-maximum)
                               (multiple-value-bind (success final-free)
                                   (place-search next-remaining new-free)
                                 (when success
                                   (return-from place-search
                                     (values t final-free)))))
                             (remhash (%placement-description-identity placement)
                                      assignments)))))))))))
      (multiple-value-bind (success final-free)
          (place-search ordered initial-free)
        (unless success
          (%reject :no-placement-solution
                   (mapcar #'%placement-description-path ordered)))
        (let ((solutions
                (map 'vector
                     (lambda (placement)
                       (gethash (%placement-description-identity placement)
                                assignments))
                     (coerce placements 'vector))))
          (values
           (make-instance '%reference-layout
                          :arena arena :assignments assignments
                          :ordered-solutions solutions
                          :free-intervals final-free)
           target-maximum))))))
