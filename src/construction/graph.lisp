;;;; src/construction/graph.lisp -- one-shot graph discovery and freezing.

(in-package #:clamsara)

(defun %reject (reason &optional paths cause)
  (error 'construction-rejected :reason reason :paths paths :cause cause))

(defun %call-at-path (path function &rest arguments)
  (handler-case (apply function arguments)
    (construction-rejected (condition) (error condition))
    (error (condition)
      (%reject :declaration-signaled (list path) condition))))

(defun %multiple-at-path (path function &rest arguments)
  (handler-case (multiple-value-list (apply function arguments))
    (construction-rejected (condition) (error condition))
    (error (condition)
      (%reject :description-signaled (list path) condition))))

(defun %proper-list-copy (value path)
  "Copy one proper list, rejecting atoms, dotted tails and cycles."
  (unless (listp value)
    (%reject :not-a-proper-list (list path)))
  (let ((seen (make-hash-table :test #'eq))
        (head nil)
        (tail nil)
        (cursor value))
    (loop while (consp cursor)
          do (when (gethash cursor seen)
               (%reject :circular-list (list path)))
             (setf (gethash cursor seen) t)
             (let ((cell (list (car cursor))))
               (if head
                   (setf (cdr tail) cell)
                   (setf head cell))
               (setf tail cell
                     cursor (cdr cursor))))
    (unless (null cursor)
      (%reject :not-a-proper-list (list path)))
    head))

(defun %finite-tree-copy (value path)
  "Copy a finite cons tree, preserving shared subtrees and rejecting cycles."
  (let ((memo (make-hash-table :test #'eq))
        (active (make-hash-table :test #'eq)))
    (labels ((copy-one (item)
               (if (atom item)
                   item
                   (progn
                     (when (gethash item active)
                       (%reject :circular-parameter-tree (list path)))
                     (multiple-value-bind (prior present-p) (gethash item memo)
                       (if present-p
                           prior
                           (let ((result (cons nil nil)))
                             (setf (gethash item memo) result
                                   (gethash item active) t)
                             (setf (car result) (copy-one (car item))
                                   (cdr result) (copy-one (cdr item)))
                             (remhash item active)
                             result)))))))
      (copy-one value))))

(defun %stable-text (value path &key allow-nil)
  (cond ((and allow-nil (null value)) nil)
        ((stringp value) (copy-seq value))
        (t (%reject :invalid-stable-description (list path)))))

(defun %nonnegative-integer-p (value)
  (and (integerp value) (not (minusp value))))

(defun %construction-positive-power-of-two-p (value)
  (and (integerp value) (plusp value)
       (zerop (logand value (1- value)))))

(defun %duplicate-eql-p (values)
  (let ((seen (make-hash-table :test #'eql)))
    (loop for value in values
          when (gethash value seen) do (return t)
          do (setf (gethash value seen) t)
          finally (return nil))))

(defun %valid-designator-p (value namespace)
  (and (consp value)
       (eql (car value) namespace)
       (consp (cdr value))
       (null (cddr value))
       (not (null (cadr value)))))

(defun %snapshot-resource (actual owner path position)
  (let* ((description-path (append path (list :resource position :description)))
         (values (%multiple-at-path description-path
                                    #'describe-resource-contribution actual)))
    (unless (= (length values) 8)
      (%reject :wrong-resource-description-values (list description-path)))
    (destructuring-bind
        (identity representation placement minimum logical auxiliary
         allocation-context exhaustion-action) values
      (unless identity (%reject :nil-resource-identity (list description-path)))
      (dolist (pair `((,minimum . :minimum-physical-bytes)
                      (,logical . :logical-entry-bound)
                      (,auxiliary . :auxiliary-bytes)))
        (unless (%nonnegative-integer-p (car pair))
          (%reject :invalid-resource-bound
                   (list (append description-path (list (cdr pair)))))))
      (%make-resource-description
       :actual actual :owner owner :path description-path :position position
       :identity identity :representation representation
       :placement-identity placement :minimum-physical-bytes minimum
       :logical-entry-bound logical :auxiliary-bytes auxiliary
       :allocation-context allocation-context
       :exhaustion-action exhaustion-action))))

(defun %snapshot-placement (actual owner path position)
  (let* ((description-path (append path (list :placement position :description)))
         (values (%multiple-at-path description-path
                                    #'describe-placement-request actual)))
    (unless (= (length values) 13)
      (%reject :wrong-placement-description-values (list description-path)))
    (destructuring-bind
        (identity minimum preferred maximum alignment granularity access lifetime
         mobility reclaimability aliasable-p inputs size-function) values
      (unless identity (%reject :nil-placement-identity (list description-path)))
      (unless (%construction-positive-power-of-two-p alignment)
        (%reject :invalid-placement-alignment (list description-path)))
      (unless (and (integerp granularity) (plusp granularity))
        (%reject :invalid-placement-granularity (list description-path)))
      (let* ((access-copy (%proper-list-copy access
                                             (append description-path
                                                     (list :access))))
             (input-copy (%proper-list-copy inputs
                                            (append description-path
                                                    (list :inputs))))
             (ordinary-p (and (every #'%nonnegative-integer-p
                                     (list minimum preferred maximum))
                              (null input-copy) (null size-function)))
             (derived-p (and (null minimum) (null preferred) (null maximum)
                             input-copy (functionp size-function))))
        (unless (or ordinary-p derived-p)
          (%reject :invalid-placement-shape (list description-path)))
        (when ordinary-p
          (unless (and (<= minimum preferred maximum)
                       (zerop (mod minimum granularity))
                       (zerop (mod preferred granularity))
                       (zerop (mod maximum granularity)))
            (%reject :invalid-placement-extents (list description-path))))
        (unless (and (not (%duplicate-eql-p access-copy))
                     (every (lambda (mode)
                              (member mode '(:read :write :execute :atomic)
                                      :test #'eql))
                            access-copy))
          (%reject :invalid-placement-access (list description-path)))
        (when (or (null lifetime) (null mobility) (null reclaimability))
          (%reject :missing-placement-policy (list description-path)))
        (when (or (%duplicate-eql-p input-copy)
                  (some #'null input-copy))
          (%reject :invalid-derived-inputs (list description-path)))
        (%make-placement-description
         :actual actual :owner owner :path description-path :position position
         :identity identity :minimum-extent minimum :preferred-extent preferred
         :maximum-extent maximum :alignment alignment :granularity granularity
         :access access-copy :lifetime lifetime :mobility mobility
         :reclaimability reclaimability :aliasable-p (not (null aliasable-p))
         :inputs input-copy :size-function size-function :derived-p derived-p
         :constraint-count 0 :object-start-map nil)))))

(defun %snapshot-constraint (actual owner path position)
  (let* ((description-path (append path (list :constraint position :description)))
         (values (%multiple-at-path description-path
                                    #'describe-construction-constraint actual)))
    (unless (= (length values) 5)
      (%reject :wrong-constraint-description-values (list description-path)))
    (destructuring-bind (kind identities parameters predicate description) values
      (let ((identity-copy
              (mapcar #'copy-list
                      (%proper-list-copy
                       identities (append description-path
                                          (list :identities)))))
            (parameter-copy (%finite-tree-copy
                             parameters (append description-path
                                                (list :parameters)))))
        (unless kind (%reject :nil-constraint-kind (list description-path)))
        (unless identity-copy
          (%reject :empty-constraint-identities (list description-path)))
        (unless (every (lambda (item)
                         (or (%valid-designator-p item :placement)
                             (%valid-designator-p item :resource)))
                       identity-copy)
          (%reject :invalid-constraint-designator (list description-path)))
        (unless (or (null predicate) (functionp predicate))
          (%reject :invalid-constraint-predicate (list description-path)))
        (%make-constraint-description
         :actual actual :owner owner :path description-path :position position
         :kind kind :identities identity-copy :parameters parameter-copy
         :predicate predicate
         :description (%stable-text description
                                    (append description-path (list :description))
                                    :allow-nil t))))))

(defun %snapshot-claim (actual path)
  (let ((values (%multiple-at-path path
                                   #'describe-barrier-reservation-claim actual)))
    (unless (= (length values) 3)
      (%reject :wrong-claim-description-values (list path)))
    (destructuring-bind (resource representation maximum) values
      (unless (%valid-designator-p resource :resource)
        (%reject :invalid-claim-resource-designator (list path)))
      (unless (%nonnegative-integer-p maximum)
        (%reject :invalid-claim-maximum (list path)))
      (%make-claim-description
       :actual actual :path path :resource-designator (copy-list resource)
       :entry-representation representation :maximum-live-entries maximum))))

(defun %snapshot-barrier (actual owner path position)
  (let* ((description-path (append path (list :barrier position :description)))
         (values (%multiple-at-path description-path
                                    #'describe-barrier-contribution actual)))
    (unless (= (length values) 9)
      (%reject :wrong-barrier-description-values (list description-path)))
    (destructuring-bind
        (identity events claims needs-old-p needs-new-p before after replacement
         failure) values
      (unless identity (%reject :nil-barrier-identity (list description-path)))
      (let ((event-copy (%proper-list-copy events
                                           (append description-path
                                                   (list :events))))
            (claim-copy (%proper-list-copy claims
                                           (append description-path
                                                   (list :claims))))
            (before-copy (%proper-list-copy before
                                            (append description-path
                                                    (list :before))))
            (after-copy (%proper-list-copy after
                                           (append description-path
                                                   (list :after)))))
        (unless (and (not (%duplicate-eql-p event-copy))
                     (every (lambda (event)
                              (member event
                                      '(:read :store :cas :root-read
                                        :root-store :bulk)
                                      :test #'eql))
                            event-copy))
          (%reject :invalid-barrier-events (list description-path)))
        (when (or (%duplicate-eql-p before-copy)
                  (%duplicate-eql-p after-copy)
                  (some #'null before-copy) (some #'null after-copy))
          (%reject :invalid-barrier-order-list (list description-path)))
        (unless (member replacement '(:observe :transform :observe-final)
                        :test #'eql)
          (%reject :invalid-barrier-replacement-policy
                   (list description-path)))
        (unless (or (eql failure :retry-before-exposure/fatal-after)
                    (equal failure
                           '(:retry-before-exposure :fatal-after-exposure)))
          (%reject :invalid-barrier-failure-policy (list description-path)))
        (let ((frozen-claims
                (loop for claim in claim-copy
                      for index from 0
                      collect (%snapshot-claim
                               claim (append description-path
                                             (list :claim index :description))))))
          (%make-barrier-description
           :actual actual :owner owner :path description-path
           :position position :identity identity :events event-copy
           :claims frozen-claims :needs-old-p (not (null needs-old-p))
           :needs-new-p (not (null needs-new-p)) :before before-copy
           :after after-copy :replacement-policy replacement
           :failure-policy failure))))))

(defun %snapshot-result (actual owner path position)
  (let* ((description-path (append path (list :result position :description)))
         (values (%multiple-at-path description-path
                                    #'describe-result-contribution actual)))
    (unless (= (length values) 3)
      (%reject :wrong-result-description-values (list description-path)))
    (destructuring-bind (kind identity description) values
      (unless (member kind '(:counter :cause :reason) :test #'eql)
        (%reject :invalid-result-kind (list description-path)))
      (unless identity (%reject :nil-result-identity (list description-path)))
      (%make-result-description
       :actual actual :owner owner :path description-path :position position
       :kind kind :identity identity
       :stable-description (%stable-text
                            description
                            (append description-path (list :description))
                            :allow-nil t)))))

(defun %generic-applicable-p (generic arguments)
  (and (fboundp generic)
       (not (null (compute-applicable-methods (fdefinition generic)
                                               arguments)))))

(defun %snapshot-component (component index path)
  (unless (typep component 'component)
    (%reject :dependency-is-not-component (list path)))
  (flet ((declaration (name function)
           (%proper-list-copy
            (%call-at-path (append path (list name)) function component)
            (append path (list name)))))
    (let* ((dependencies (declaration :dependencies #'component-dependencies))
           (resource-values (declaration :resources #'component-resources))
           (placement-values
             (declaration :placements #'component-placement-requests))
           (constraint-values
             (declaration :constraints #'component-constraints))
           (barrier-values
             (declaration :barriers #'component-barrier-contributions))
           (result-values
             (declaration :results #'component-result-contributions))
           (cohort (%call-at-path (append path (list :cohort))
                                  #'component-cohort component))
           (space-p (%generic-applicable-p 'space-object-start-map
                                           (list component)))
           (object-start-map
             (when space-p
               (%call-at-path (append path (list :space-object-start-map))
                              #'space-object-start-map component))))
      (loop for dependency in dependencies
            for position from 0
            unless (typep dependency 'component)
              do (%reject :dependency-is-not-component
                          (list (append path
                                      (list :dependencies position)))))
      (%make-component-node
       :component component :index index :path path
       :dependencies dependencies
       :resources (loop for value in resource-values for position from 0
                        collect (%snapshot-resource value component path position))
       :placements (loop for value in placement-values for position from 0
                         collect (%snapshot-placement value component path position))
       :constraints (loop for value in constraint-values for position from 0
                          collect (%snapshot-constraint value component path position))
       :barriers (loop for value in barrier-values for position from 0
                       collect (%snapshot-barrier value component path position))
       :results (loop for value in result-values for position from 0
                      collect (%snapshot-result value component path position))
       :cohort cohort :space-p space-p :object-start-map object-start-map
       :initialized-p nil :activated-p nil))))

(defun %discover-component-graph (plan coordinator)
  "Return nodes in stable preorder.  Each component declaration is called once."
  (let ((seen (make-hash-table :test #'eq))
        (nodes (make-array 8 :adjustable t :fill-pointer 0)))
    (labels ((visit (component path)
               (or (gethash component seen)
                   (let* ((index (fill-pointer nodes))
                          (node (%snapshot-component component index path)))
                     ;; Install before descent so dependency cycles are finite.
                     (setf (gethash component seen) node)
                     (vector-push-extend node nodes)
                     (loop for dependency in (%component-node-dependencies node)
                           for position from 0
                           do (visit dependency
                                     (append path
                                             (list :dependency position))))
                     node))))
      (visit plan '(:root :plan))
      (visit coordinator '(:root :stop-coordinator))
      (coerce nodes 'simple-vector))))

(defun %find-node (nodes component)
  (find component nodes :key #'%component-node-component :test #'eq))

(defun %strongly-connected-components (nodes)
  (let ((next-index 0) (stack nil)
        (index-table (make-hash-table :test #'eq))
        (low-table (make-hash-table :test #'eq))
        (on-stack (make-hash-table :test #'eq))
        (components nil))
    (labels ((connect (node)
               (setf (gethash node index-table) next-index
                     (gethash node low-table) next-index)
               (incf next-index)
               (push node stack)
               (setf (gethash node on-stack) t)
               (dolist (dependency (%component-node-dependencies node))
                 (let ((target (%find-node nodes dependency)))
                   (multiple-value-bind (target-index known-p)
                       (gethash target index-table)
                     (cond
                       ((not known-p)
                        (connect target)
                        (setf (gethash node low-table)
                              (min (gethash node low-table)
                                   (gethash target low-table))))
                       ((gethash target on-stack)
                        (setf (gethash node low-table)
                              (min (gethash node low-table) target-index)))))))
               (when (= (gethash node low-table)
                        (gethash node index-table))
                 (let ((one nil) (popped nil))
                   (loop do (setf popped (pop stack))
                            (setf (gethash popped on-stack) nil)
                            (push popped one)
                         until (eq popped node))
                   (push (sort one #'< :key #'%component-node-index)
                         components)))))
      (loop for node across nodes
            unless (nth-value 1 (gethash node index-table))
              do (connect node))
      (nreverse components))))

(defun %cyclic-scc-p (scc)
  (or (> (length scc) 1)
      (let ((node (first scc)))
        (member (%component-node-component node)
                (%component-node-dependencies node) :test #'eq))))

(defun %build-initialization-groups (nodes)
  (let ((sccs (%strongly-connected-components nodes))
        (cohort-groups (make-hash-table :test #'eql))
        (node-group (make-hash-table :test #'eq))
        (groups nil))
    ;; First enforce the only legal dependency cycles.
    (dolist (scc sccs)
      (when (%cyclic-scc-p scc)
        (let ((identity (%component-node-cohort (first scc))))
          (unless (and identity
                       (every (lambda (node)
                                (eql (%component-node-cohort node) identity))
                              scc))
            (%reject :dependency-cycle-without-cohort
                     (mapcar #'%component-node-path scc))))))
    ;; A non-nil cohort groups all declarations carrying its EQL identity.
    (loop for node across nodes
          for cohort = (%component-node-cohort node)
          do (if cohort
                 (push node (gethash cohort cohort-groups))
                 (let ((group (%make-initialization-group
                               :identity nil :nodes (list node)
                               :index (%component-node-index node)
                               :cyclic-p nil :continuing-p nil
                               :dependencies nil)))
                   (push group groups)
                   (setf (gethash node node-group) group))))
    (maphash
     (lambda (identity members)
       (let* ((ordered (sort members #'< :key #'%component-node-index))
              (cyclic (some (lambda (scc)
                              (and (%cyclic-scc-p scc)
                                   (member (first scc) ordered :test #'eq)))
                            sccs))
              (group (%make-initialization-group
                      :identity identity :nodes ordered
                      :index (%component-node-index (first ordered))
                      :cyclic-p cyclic
                      :continuing-p
                      (some (lambda (node)
                              (%component-continuing-service-p
                               (%component-node-component node)))
                            ordered)
                      :dependencies nil)))
         (push group groups)
         (dolist (node ordered) (setf (gethash node node-group) group))))
     cohort-groups)
    ;; Dependencies between groups; same-cohort edges are initialization-cycle
    ;; edges and do not participate in the collapsed DAG.
    (dolist (group groups)
      (let ((dependencies nil))
        (dolist (node (%initialization-group-nodes group))
          (dolist (component-dependency (%component-node-dependencies node))
            (let* ((dependency-node (%find-node nodes component-dependency))
                   (dependency-group (gethash dependency-node node-group)))
              (unless (or (eq dependency-group group)
                          (member dependency-group dependencies :test #'eq))
                (push dependency-group dependencies)))))
        (setf (%initialization-group-dependencies group)
              (sort dependencies #'< :key #'%initialization-group-index))))
    ;; Stable Kahn order with dependencies before consumers.
    (let ((remaining (copy-list groups)) (ordered nil))
      (loop while remaining
            for ready = (sort
                         (remove-if-not
                          (lambda (group)
                            (every (lambda (dependency)
                                     (member dependency ordered :test #'eq))
                                   (%initialization-group-dependencies group)))
                          remaining)
                         #'< :key #'%initialization-group-index)
            do (unless ready
                 (%reject :cohort-dependency-cycle
                          (mapcar (lambda (group)
                                    (mapcar #'%component-node-path
                                            (%initialization-group-nodes group)))
                                  remaining)))
               (let ((next (first ready)))
                 (setf remaining (delete next remaining :test #'eq)
                       ordered (append ordered (list next)))))
      ordered)))
