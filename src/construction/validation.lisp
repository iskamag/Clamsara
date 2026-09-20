;;;; src/construction/validation.lisp -- namespace and order checks.

(in-package #:clamsara)

(defun %all-descriptions (nodes accessor)
  (loop for node across nodes append (copy-list (funcall accessor node))))

(defun %insert-unique-description (table identity description reason)
  (let ((previous (gethash identity table)))
    (when previous
      (%reject reason
               (list (funcall (etypecase previous
                                (%resource-description #'%resource-description-path)
                                (%placement-description #'%placement-description-path)
                                (%barrier-description #'%barrier-description-path))
                              previous)
                     (funcall (etypecase description
                                (%resource-description #'%resource-description-path)
                                (%placement-description #'%placement-description-path)
                                (%barrier-description #'%barrier-description-path))
                              description))))
    (setf (gethash identity table) description)))

(defun %validate-standard-constraint-shape (constraint)
  (let ((kind (%constraint-description-kind constraint))
        (identities (%constraint-description-identities constraint))
        (parameters (%constraint-description-parameters constraint))
        (path (%constraint-description-path constraint)))
    (when (member kind '(:adjacent :separate :alias :equal-extent
                         :numeric-reach) :test #'eql)
      (unless (every (lambda (item) (%valid-designator-p item :placement))
                     identities)
        (%reject :standard-constraint-requires-placements (list path)))
      (ecase kind
        ((:adjacent :separate :alias :numeric-reach)
         (unless (= (length identities) 2)
           (%reject :wrong-standard-constraint-arity (list path))))
        (:equal-extent
         (unless (>= (length identities) 2)
           (%reject :wrong-standard-constraint-arity (list path)))))
      (ecase kind
        ((:adjacent :separate :numeric-reach)
         (unless (%nonnegative-integer-p parameters)
           (%reject :invalid-standard-constraint-parameters (list path))))
        ((:alias :equal-extent)
         (unless (null parameters)
           (%reject :invalid-standard-constraint-parameters (list path))))))))

(defun %validate-derived-dependency-graph (placements placement-table)
  (let ((marks (make-hash-table :test #'eq)))
    (labels ((visit (placement stack)
               (case (gethash placement marks)
                 (:complete nil)
                 (:visiting
                  (%reject :derived-placement-cycle
                           (mapcar #'%placement-description-path
                                   (cons placement stack))))
                 (otherwise
                  (setf (gethash placement marks) :visiting)
                  (dolist (input (%placement-description-inputs placement))
                    (let ((input-description (gethash input placement-table)))
                      (unless input-description
                        (%reject :unknown-derived-placement-input
                                 (list (%placement-description-path placement))))
                      (visit input-description (cons placement stack))))
                  (setf (gethash placement marks) :complete)))))
      (dolist (placement placements) (visit placement nil)))))

(defun %validate-address-policies (placements address-client)
  (dolist (placement placements)
    (dolist (pair `((:lifetime . ,(%placement-description-lifetime placement))
                    (:mobility . ,(%placement-description-mobility placement))
                    (:reclaimability
                     . ,(%placement-description-reclaimability placement))))
      (let ((supported
              (handler-case
                  (%address-space-policy-supported-p
                   address-client (car pair) (cdr pair))
                (error (condition)
                  (%reject :address-policy-admission-signaled
                           (list (%placement-description-path placement))
                           condition)))))
        (unless supported
          (%reject :unsupported-address-policy
                   (list (%placement-description-path placement))))))))

(defun %validate-declarations (nodes address-client)
  "Validate global namespaces and return resources, placements, constraints,
barriers, ordered-barriers, result schema, and their lookup tables."
  (let* ((resources (%all-descriptions nodes #'%component-node-resources))
         (placements (%all-descriptions nodes #'%component-node-placements))
         (constraints (%all-descriptions nodes #'%component-node-constraints))
         (barriers (%all-descriptions nodes #'%component-node-barriers))
         (results (%all-descriptions nodes #'%component-node-results))
         (resource-table (make-hash-table :test #'eql))
         (placement-table (make-hash-table :test #'eql))
         (barrier-table (make-hash-table :test #'eql)))
    ;; Convert per-component list positions to one stable graph/list order for
    ;; the reference placement and barrier tie breakers.
    (loop for placement in placements for index from 0
          for owner-node = (%find-node nodes
                                       (%placement-description-owner placement))
          do (setf (%placement-description-position placement) index
                   (%placement-description-object-start-map placement)
                   (and owner-node (%component-node-space-p owner-node)
                        (%component-node-object-start-map owner-node))))
    (loop for barrier in barriers for index from 0
          do (setf (%barrier-description-position barrier) index))
    (dolist (resource resources)
      (%insert-unique-description resource-table
                                  (%resource-description-identity resource)
                                  resource :duplicate-resource-identity))
    (dolist (placement placements)
      (%insert-unique-description placement-table
                                  (%placement-description-identity placement)
                                  placement :duplicate-placement-identity))
    (dolist (barrier barriers)
      (%insert-unique-description barrier-table
                                  (%barrier-description-identity barrier)
                                  barrier :duplicate-barrier-identity))
    ;; Resource placement references resolve, and separate resource identities
    ;; never share one placement identity.  Physical aliasing is represented by
    ;; separately owned requests tied by :ALIAS.
    (let ((placement-owner (make-hash-table :test #'eql)))
      (dolist (resource resources)
        (let ((placement (%resource-description-placement-identity resource)))
          (when placement
            (unless (gethash placement placement-table)
              (%reject :unknown-resource-placement
                       (list (%resource-description-path resource))))
            (let ((previous (gethash placement placement-owner)))
              (when previous
                (%reject :resources-share-placement-identity
                         (list (%resource-description-path previous)
                               (%resource-description-path resource))))
              (setf (gethash placement placement-owner) resource))))))
    ;; All tagged constraint references resolve in their declared namespace.
    (dolist (constraint constraints)
      (%validate-standard-constraint-shape constraint)
      (dolist (designator (%constraint-description-identities constraint))
        (unless (gethash (second designator)
                         (ecase (first designator)
                           (:resource resource-table)
                           (:placement placement-table)))
          (%reject :dangling-constraint-identity
                   (list (%constraint-description-path constraint)))))
      (let ((counted (make-hash-table :test #'eql)))
        (dolist (designator (%constraint-description-identities constraint))
          (when (and (eql (first designator) :placement)
                     (not (gethash (second designator) counted)))
            (setf (gethash (second designator) counted) t)
            (incf (%placement-description-constraint-count
                   (gethash (second designator) placement-table)))))))
    (%validate-derived-dependency-graph placements placement-table)
    (%validate-address-policies placements address-client)
    ;; Barrier references and claims resolve before any acquisition.
    (dolist (barrier barriers)
      (dolist (identity (append (%barrier-description-before barrier)
                                (%barrier-description-after barrier)))
        (unless (gethash identity barrier-table)
          (%reject :dangling-barrier-order-identity
                   (list (%barrier-description-path barrier)))))
      (dolist (claim (%barrier-description-claims barrier))
        (let* ((key (second (%claim-description-resource-designator claim)))
               (resource (gethash key resource-table)))
          (unless resource
            (%reject :dangling-barrier-claim-resource
                     (list (%claim-description-path claim))))
          (unless (equal (%claim-description-entry-representation claim)
                         (%resource-description-representation resource))
            (%reject :barrier-claim-representation-mismatch
                     (list (%claim-description-path claim)
                           (%resource-description-path resource)))))))
    (let ((ordered-barriers (%order-barriers barriers barrier-table))
          (schema (%merge-result-schema results)))
      (values resources placements constraints barriers ordered-barriers schema
              resource-table placement-table barrier-table))))

(defun %barrier-explicit-edges (barriers table)
  (let ((edges (make-hash-table :test #'eq)))
    (dolist (barrier barriers) (setf (gethash barrier edges) nil))
    (labels ((edge (from to)
               (unless (member to (gethash from edges) :test #'eq)
                 (push to (gethash from edges)))))
      (dolist (barrier barriers)
        (dolist (identity (%barrier-description-before barrier))
          (edge barrier (gethash identity table)))
        (dolist (identity (%barrier-description-after barrier))
          (edge (gethash identity table) barrier))))
    edges))

(defun %reachable-barrier-p (from to edges)
  (let ((seen (make-hash-table :test #'eq)))
    (labels ((walk (node)
               (cond ((eq node to) t)
                     ((gethash node seen) nil)
                     (t (setf (gethash node seen) t)
                        (some #'walk (gethash node edges))))))
      (walk from))))

(defun %barrier-domains-overlap-p (left right)
  (intersection (%barrier-description-events left)
                (%barrier-description-events right) :test #'eql))

(defun %order-barriers (barriers table)
  (let ((edges (%barrier-explicit-edges barriers table)))
    ;; Transformer ordering must be authored.  The observe-final edges added
    ;; below cannot accidentally prove transformer compatibility.
    (let ((transformers
            (remove-if-not
             (lambda (barrier)
               (eql (%barrier-description-replacement-policy barrier)
                    :transform))
             barriers)))
      (loop for tail on transformers
            for left = (first tail)
            do (dolist (right (rest tail))
                 (when (and (%barrier-domains-overlap-p left right)
                            (not (or (%reachable-barrier-p left right edges)
                                     (%reachable-barrier-p right left edges))))
                   (%reject :unordered-barrier-transformers
                            (list (%barrier-description-path left)
                                  (%barrier-description-path right)))))))
    ;; :OBSERVE-FINAL always follows every transformer.
    (dolist (observer barriers)
      (when (eql (%barrier-description-replacement-policy observer)
                 :observe-final)
        (dolist (transformer barriers)
          (when (eql (%barrier-description-replacement-policy transformer)
                     :transform)
            (pushnew observer (gethash transformer edges) :test #'eq)))))
    ;; Stable Kahn order.
    (let ((remaining (copy-list barriers)) (ordered nil))
      (loop while remaining
            for ready =
              (sort
               (remove-if-not
                (lambda (candidate)
                  (notany (lambda (source)
                            (and (member source remaining :test #'eq)
                                 (member candidate (gethash source edges)
                                         :test #'eq)))
                          barriers))
                remaining)
               #'< :key #'%barrier-description-position)
            do (unless ready
                 (%reject :barrier-order-cycle
                          (mapcar #'%barrier-description-path remaining)))
               (let ((next (first ready)))
                 (push next ordered)
                 (setf remaining (delete next remaining :test #'eq))))
      (coerce (nreverse ordered) 'simple-vector))))

(defun %merge-result-schema (results)
  (let ((by-kind (make-hash-table :test #'eql))
        (ordered nil))
    (dolist (result results)
      (let* ((kind (%result-description-kind result))
             (table (or (gethash kind by-kind)
                        (setf (gethash kind by-kind)
                              (make-hash-table :test #'eql))))
             (previous (gethash (%result-description-identity result) table)))
        (cond
          ((null previous)
           (setf (gethash (%result-description-identity result) table) result)
           (push result ordered))
          ((not (equal (%result-description-stable-description previous)
                       (%result-description-stable-description result)))
           (%reject :incompatible-result-duplicate
                    (list (%result-description-path previous)
                          (%result-description-path result)))))))
    (coerce (nreverse ordered) 'simple-vector)))
