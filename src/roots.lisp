(in-package #:clamsara)

;;; --- Root Set & Root Scanning ---

(defstruct (root-set (:conc-name rs-) (:constructor make-root-set))
  "Collection of GC roots."
  (static-roots nil :type list)
  (thread-roots (make-hash-table :test 'eq)))

(defun register-root (root-set addr)
  "Register ADDR as a GC root."
  (pushnew addr (rs-static-roots root-set)))

(defun unregister-root (root-set addr)
  "Remove ADDR from the root set."
  (setf (rs-static-roots root-set)
        (remove addr (rs-static-roots root-set))))

(defstruct (thread-root-set (:conc-name trs-))
  "Per-thread root set."
  (roots nil :type list)
  (gc-map nil :type (or null gc-map)))

(defstruct (gc-map (:constructor create-gc-map))
  "GC map for a function: describes which stack slots hold live references."
  (pc-offsets nil :type list)
  (ref-slots nil :type list))

(defun register-thread-root (root-set thread-id addr)
  "Register ADDR as a root for the given thread."
  (let ((trs (or (gethash thread-id (rs-thread-roots root-set))
                 (let ((new (make-thread-root-set)))
                   (setf (gethash thread-id (rs-thread-roots root-set)) new)
                   new))))
    (pushnew addr (trs-roots trs))
    (setf (gethash thread-id (rs-thread-roots root-set)) trs)))

(defun unregister-thread-root (root-set thread-id addr)
  (let ((trs (gethash thread-id (rs-thread-roots root-set))))
    (when trs
      (let ((roots (remove addr (trs-roots trs))))
        (if roots
            (setf (trs-roots trs) roots)
            (remhash thread-id (rs-thread-roots root-set)))))))

(defun root-set-all-roots (root-set)
  "Return all registered root addresses."
  (let ((all (copy-list (rs-static-roots root-set))))
    (maphash (lambda (thread-id trs)
               (declare (ignore thread-id))
               (dolist (r (trs-roots trs))
                 (pushnew r all)))
             (rs-thread-roots root-set))
    all))

(defun root-set-clear (root-set)
  "Clear all registered roots."
  (setf (rs-static-roots root-set) nil)
  (clrhash (rs-thread-roots root-set)))

(defun update-root-set-forwarded (vm root-set)
  "Replace any forwarded roots in ROOT-SET with their final addresses,
following forwarding chains."
  (labels ((resolve-forwarded (addr)
           (loop for current = addr then (vm-object-forwarding-pointer vm current)
                 while (and current (not (zerop current))
                            (vm-object-is-forwarded-p vm current))
                 finally (return current)))
         (update-list (roots)
           (loop for root in roots
                 collect (if (and root (not (zerop root)))
                             (resolve-forwarded root)
                             root))))
    (setf (rs-static-roots root-set)
          (update-list (rs-static-roots root-set)))
    (maphash (lambda (thread-id trs)
               (setf (trs-roots trs)
                     (update-list (trs-roots trs)))
               (setf (gethash thread-id (rs-thread-roots root-set)) trs))
             (rs-thread-roots root-set))))

;;; --- GC Map Construction ---
;;; GC maps track which stack slots hold live references at each PC offset.
;;; Defined for future use by VM backends that support stack-map-based root scanning.
