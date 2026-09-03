;;;; test/test-v11-protocols.lisp -- paper-v11 protocol system contracts.
;;;;
;;;; Three families of checks:
;;;;   1. the protocol systems load independently (empty dependencies, and a
;;;;      fresh-image load that never brings up :clamsara);
;;;;   2. the simulator adapters (src/protocol/adapters.lisp) implement the
;;;;      reference generics with the exact semantics the existing mechanics
;;;;      supply, and signal at every honest unsupported boundary;
;;;;   3. the location seams' no-per-visit-allocation property is MEASURED,
;;;;      not just claimed (V11-ADAPTERS-NO-ALLOCATION).

(in-package #:clamsara)

(defparameter *v11-protocol-systems*
  '(:clamsara/protocol/object-model
    :clamsara/protocol/roots
    :clamsara/protocol/coordination
    :clamsara/protocol/atomics
    :clamsara/protocol/address-space
    :clamsara/protocol/diagnostics))

(defun %v11-check (ok ok-msg fail-msg)
  (if ok (values t ok-msg) (values nil fail-msg)))

(deftest v11-protocol-systems-independent ()
  (let ((problems nil))
    ;; structural: findable, and no ASDF dependencies at all
    (dolist (name *v11-protocol-systems*)
      (handler-case
          (let ((s (asdf:find-system name nil)))
            (if s
                (let ((deps (asdf:system-depends-on s)))
                  (unless (null deps)
                    (push (format nil "~a declares dependencies ~s" name deps) problems)))
                (push (format nil "~a not findable" name) problems)))
        (error (e) (push (format nil "~a: ~a" name e) problems))))
    ;; fresh-image load: the six protocol systems, without :clamsara
    #+sbcl
    (unless problems
      (let* ((asd (asdf:system-source-file :clamsara/test)))
        ;; ASDF-SOURCE-FILE is the .asd that DEFINED this test system, i.e.
        ;; clamsara.asd itself; a secondary system's source DIRECTORY is not
        ;; necessarily its .asd directory.
        (unless (and asd (uiop:file-exists-p asd))
          (return-from v11-protocol-systems-independent
            (values nil "cannot locate clamsara.asd via asdf:system-source-file")))
        (let ((script (with-output-to-string (s)
                        (write-line "(require :asdf)" s)
                        (format s "(asdf:load-asd #p~s)~%" (namestring asd))
                        (dolist (name *v11-protocol-systems*)
                          (format s "(asdf:load-system :~a)~%" name))
                        ;; loading clamsara.asd must not pull up the main package
                        (write-line "(when (find-package :clamsara) (error \"CLAMSARA PACKAGE LEAKED INTO PROTOCOL LOAD\"))" s)
                        (write-line "(princ \"PROTOCOL-ONLY-LOAD-OK\") (terpri)" s))))
          (uiop:with-temporary-file (:pathname tmp :suffix ".lisp")
            (with-open-file (s tmp :direction :output :if-exists :supersede)
              (write-string script s))
            (let ((out (uiop:run-program
                        (list "sbcl" "--script" (namestring tmp))
                        :output :string :error-output :output)))
              (unless (search "PROTOCOL-ONLY-LOAD-OK" out)
                (push (format nil "fresh-image protocol load failed: ~a"
                              (subseq out (max 0 (- (length out) 400)) (length out)))
                      problems)))))))
    (%v11-check (null problems)
                "protocol systems registered, dependency-free, and load alone"
                (format nil "~{~a~^; ~}" (nreverse problems)))))

(deftest v11-object-model-adapter ()
  (with-clamsara (:plan-type :nogc :heap-size 8192)
    (let ((vm *clamsara-vm*))
      (let ((a (clamsara-allocate-object 2)))
        ;; validity, starts, size, kind
        (unless (and (valid-reference-p vm a) (object-start-p vm a))
          (return-from v11-object-model-adapter (values nil "allocated object not valid/start")))
        (when (object-start-p vm (+ a 1))
          (return-from v11-object-model-adapter (values nil "interior word reported as object start")))
        (when (or (valid-reference-p vm 0) (valid-reference-p vm (vm-heap-size vm)))
          (return-from v11-object-model-adapter (values nil "null/out-of-heap reported valid")))
        (unless (= (object-size vm a) (* 3 +word-bytes+))
          (return-from v11-object-model-adapter (values nil "object-size is not bytes of header+payload")))
        (unless (eql (object-kind vm a) +tag-object+)
          (return-from v11-object-model-adapter (values nil "object-kind mismatch")))
        ;; precise location discovery: registered layout, exact slot words
        (register-slot-map vm +tag-object+ 7 #(1))
        (let* ((b (clamsara-allocate-object 3 :layout-id 7))
               (locs (let ((found ()))
                       (map-reference-locations vm b (lambda (loc) (push loc found)))
                       (nreverse found))))
          (unless (and (= (length locs) 1) (= (first locs) (+ b 1 1)))
            (return-from v11-object-model-adapter (values nil "map-reference-locations did not name slot word b+2")))
          ;; load/store round-trip through the raw seam, same word as the v8 accessor
          (let ((c (clamsara-allocate-object 1)))
            (store-reference-raw vm (first locs) c)
            (unless (eql (load-reference vm (first locs)) c)
              (return-from v11-object-model-adapter (values nil "load-reference mismatch after store")))
            (unless (eql (vm-object-reference vm b 1) c)
              (return-from v11-object-model-adapter (values nil "raw store did not land in the declared slot word")))
            ;; re-mapping yields the same location for the same slot
            (let ((again (let ((found nil))
                           (map-reference-locations vm b (lambda (loc) (push loc found)))
                           (first found))))
              (unless (eql again (first locs))
                (return-from v11-object-model-adapter (values nil "location is not stable across map calls")))))
          ;; weak referent slot is not a strong location
          (let ((w (clamsara-allocate-object 1)))
            (register-weak-pointer vm w)
            (setf (vm-object-reference vm w 0) a)
            (let ((n 0))
              (map-reference-locations vm w (lambda (loc) (declare (ignore loc)) (incf n)))
              (unless (zerop n)
                (return-from v11-object-model-adapter (values nil "weak referent slot visited as strong"))))))
        ;; initialize-object: header, zeroed payload, size discipline
        (let ((d (clamsara-allocate-object 4)))
          (initialize-object vm d +tag-struct+ 24 5)
          (unless (and (eql (vm-object-type-tag vm d) +tag-struct+)
                       (= (vm-object-total-words vm d) 3)
                       (dotimes (k 2 t) (unless (zerop (vm-object-reference vm d k)) (return nil))))
            (return-from v11-object-model-adapter (values nil "initialize-object wrote the wrong shape")))
          (unless (= (object-size vm d) 24)
            (return-from v11-object-model-adapter (values nil "object-size disagrees with initialize-object")))
          (unless (handler-case (progn (initialize-object vm d +tag-struct+ 25 0) nil)
                     (clamsara-error () t))
            (return-from v11-object-model-adapter (values nil "non-word size accepted")))
          (unless (handler-case (progn (initialize-object vm d +tag-cons+ 16 0) nil)
                     (clamsara-error () t))
            (return-from v11-object-model-adapter (values nil "cons accepted by initialize-object"))))
        ;; representation copy: payload yes, logical metadata no
        (let ((src (clamsara-allocate-object 2))
              (dst (clamsara-allocate-object 2)))
          (setf (vm-object-is-marked-p vm src) t)
          (copy-object-representation vm src dst)
          (unless (and (vm-object-is-marked-p vm src)
                       (not (vm-object-is-marked-p vm dst)))
            (return-from v11-object-model-adapter (values nil "copy transferred logical mark metadata")))
          (setf (vm-object-reference vm src 1) 12345)
          (copy-object-representation vm src dst)
          (unless (and (eql (vm-object-reference vm dst 1) 12345)
                       (= (object-size vm src) (object-size vm dst)))
            (return-from v11-object-model-adapter (values nil "copy did not carry payload"))))
        ;; identity across colours; field seam boundary
        (let ((e (clamsara-allocate-object 1)))
          (unless (reference-equal vm e (ref-set-colour vm e 3))
            (return-from v11-object-model-adapter (values nil "coloured reference not identity-equal")))
          (unless (null (offered-metadata-fields vm))
            (return-from v11-object-model-adapter (values nil "simulator advertised metadata fields")))
          (unless (handler-case (progn (field-read vm :mark e) nil)
                     (clamsara-error () t))
            (return-from v11-object-model-adapter (values nil "field-read accepted on a fieldless client"))))
        (values t "object-model adapter ok")))))

(deftest v11-root-protocol-adapter ()
  (with-clamsara (:plan-type :semispace :heap-size 8192)
    (let ((vm *clamsara-vm*))
      (let* ((o1 (clamsara-allocate-object 1))
             (i1 (clamsara-register-root o1))
             (o2 (clamsara-allocate-object 1))
             (i2 (clamsara-register-root o2))
             (regvec (make-array 4 :initial-element 0))
             (kinds nil)
             (loads nil))
        (unless (and (= i1 0) (= i2 1))
          (return-from v11-root-protocol-adapter (values nil "root indices unexpected")))
        (with-root-snapshot vm :all
            (lambda (snap)
              (map-root-locations snap
                                  (lambda (loc)
                                    (push (root-location-kind vm loc) kinds)
                                    (push (load-root vm loc) loads)))))
        (unless (and (= (count :root-vector kinds) 2)
                     (member o1 loads) (member o2 loads))
          (return-from v11-root-protocol-adapter (values nil "snapshot missed root vector cells")))
        ;; store through a location rewrites the same cell the root vector reads
        (let ((loc2 (let ((found nil))
                      (with-root-snapshot vm :global
                          (lambda (snap)
                            (map-root-locations snap
                                                (lambda (loc)
                                                  (when (eql (load-root vm loc) o2)
                                                    (setf found loc))))))
                      found)))
          (unless (eq (root-location-kind vm loc2) :root-vector)
            (return-from v11-root-protocol-adapter (values nil "o2 location is not a root-vector cell")))
          (store-root vm loc2 0)
          (unless (eql (clamsara-root i2) 0)
            (return-from v11-root-protocol-adapter (values nil "store-root did not write the root vector"))))
        ;; registered region entries appear as region locations and are writable
        (register-root-region vm regvec 0 2 nil)
        (let ((region-loads nil) (region-loc nil))
          (with-root-snapshot vm :all
              (lambda (snap)
                (map-root-locations snap
                                    (lambda (loc)
                                      (when (eq (root-location-kind vm loc) :root-region)
                                        (push (load-root vm loc) region-loads)
                                        (setf region-loc loc))))))
          (unless (= (length region-loads) 2)
            (return-from v11-root-protocol-adapter (values nil "region cells not visited")))
          ;; REGION-LOC is the last visited region cell (index 1)
          (store-root vm region-loc 77)
          (unless (= (aref regvec 1) 77)
            (return-from v11-root-protocol-adapter (values nil "store-root did not write the region vector"))))
        ;; honest boundaries: unsupported scope, unknown location
        (unless (handler-case (progn (with-root-snapshot vm :request #'identity) nil)
                   (clamsara-error () t))
          (return-from v11-root-protocol-adapter (values nil "request scope accepted")))
        (unless (handler-case (progn (load-root vm 1234567890123) nil)
                   (clamsara-error () t))
          (return-from v11-root-protocol-adapter (values nil "bogus root location accepted")))
        (values t "root adapter ok")))))

(deftest v11-coordination-adapter ()
  (with-clamsara (:plan-type :nogc :heap-size 4096)
    (let ((vm *clamsara-vm*))
      ;; safepoints: one outstanding stop interval, token-bound
      (let ((token (request-safepoint vm :all :test)))
        (unless (vm-mutators-stopped-p vm)
          (return-from v11-coordination-adapter (values nil "request-safepoint did not stop the mutators")))
        (unless (= (await-safepoint vm token) (vm-safepoint-epoch vm))
          (return-from v11-coordination-adapter (values nil "await-safepoint returned a foreign epoch")))
        ;; a repeated request for the same active stop is documented idempotent
        (let ((e (vm-safepoint-epoch vm)))
          (request-safepoint vm :all :test)
          (unless (= (vm-safepoint-epoch vm) e)
            (return-from v11-coordination-adapter (values nil "repeat request re-numbered the active stop"))))
        (release-safepoint vm token)
        (when (vm-mutators-stopped-p vm)
          (return-from v11-coordination-adapter (values nil "release-safepoint left mutators stopped")))
        ;; a stale token after release rejects on await AND release
        (unless (handler-case (progn (await-safepoint vm token) nil)
                   (clamsara-error () t))
          (return-from v11-coordination-adapter (values nil "stale await accepted")))
        (unless (handler-case (progn (release-safepoint vm token) nil)
                   (clamsara-error () t))
          (return-from v11-coordination-adapter (values nil "stale release accepted")))
        (unless (handler-case (progn (await-safepoint vm :not-a-token) nil)
                   (clamsara-error () t))
          (return-from v11-coordination-adapter (values nil "foreign safepoint token accepted"))))
      (unless (eq (current-mutator vm) :single-mutator)
        (return-from v11-coordination-adapter (values nil "current-mutator mismatch")))
      ;; epochs: one outstanding per client, token-bound to the client,
      ;; await establishes quiescence and closes; overlap/stale reject
      (let ((e (begin-epoch vm :default)))
        (unless (eq e (vm-coordination-state vm))
          (return-from v11-coordination-adapter (values nil "epoch token is not the client's coordination state")))
        (unless (plusp (await-epoch vm e))
          (return-from v11-coordination-adapter (values nil "await-epoch returned no epoch")))
        (unless (handler-case (progn (await-epoch vm e) nil)
                   (clamsara-error () t))
          (return-from v11-coordination-adapter (values nil "stale second await accepted")))
        (let ((e2 (begin-epoch vm :default)))
          (unless (eq e2 e)
            (return-from v11-coordination-adapter (values nil "token did not identify the same client")))
          (unless (handler-case (progn (begin-epoch vm :default) nil)
                     (clamsara-error () t))
            (return-from v11-coordination-adapter (values nil "overlapping begin-epoch accepted")))
          (unless (plusp (await-epoch vm e2))
            (return-from v11-coordination-adapter (values nil "second epoch did not close cleanly")))))
      (unless (handler-case (progn (await-epoch vm :other-client-token) nil)
                 (clamsara-error () t))
        (return-from v11-coordination-adapter (values nil "foreign epoch token accepted")))
      (unless (handler-case (progn (begin-epoch vm :other-domain) nil)
                 (clamsara-error () t))
        (return-from v11-coordination-adapter (values nil "undeclared epoch domain accepted")))
      (publish-fence vm)
      (values t "coordination adapter ok"))))

(deftest v11-atomics-adapter ()
  (with-clamsara (:plan-type :nogc :heap-size 4096)
    (let ((vm *clamsara-vm*)
          (place 4090))
      (atomic-store vm place 42 :seq-cst)
      (unless (= (atomic-load vm place :seq-cst) 42)
        (return-from v11-atomics-adapter (values nil "atomic store/load mismatch")))
      (unless (= (atomic-load vm place :acquire) 42)
        (return-from v11-atomics-adapter (values nil "acquire load rejected")))
      (let ((prev (atomic-cas vm place 42 100 :seq-cst)))
        (unless (and (= prev 42) (= (atomic-load vm place :relaxed) 100))
          (return-from v11-atomics-adapter (values nil "successful cas reported wrong previous")))
        (let ((prev2 (atomic-cas vm place 7 8 :seq-cst)))
          (unless (and (= prev2 100) (= (atomic-load vm place :relaxed) 100))
            (return-from v11-atomics-adapter (values nil "failing cas mutated the place")))))
      (unless (= (atomic-fetch-add vm place 5 :release) 100)
        (return-from v11-atomics-adapter (values nil "fetch-add did not return previous")))
      (unless (= (atomic-load vm place :relaxed) 105)
        (return-from v11-atomics-adapter (values nil "fetch-add lost the delta")))
      ;; bit set/clear return the previous bit.  The word is now
      ;; 105 = #b01101001, so bit 4 is the first clear bit above bit 0.
      (unless (eq (atomic-bit-set vm place 4 :seq-cst) nil)
        (return-from v11-atomics-adapter (values nil "bit-set on a clear bit returned true")))
      (unless (= (atomic-load vm place :relaxed) 121)
        (return-from v11-atomics-adapter (values nil "bit-set did not set bit 4")))
      (unless (eq (atomic-bit-set vm place 4 :seq-cst) t)
        (return-from v11-atomics-adapter (values nil "bit-set on a set bit returned false")))
      (unless (eq (atomic-bit-clear vm place 4 :seq-cst) t)
        (return-from v11-atomics-adapter (values nil "bit-clear on a set bit returned false")))
      (unless (eq (atomic-bit-clear vm place 4 :seq-cst) nil)
        (return-from v11-atomics-adapter (values nil "bit-clear on a clear bit returned true")))
      (fence vm :seq-cst)
      (fence vm :acquire)
      ;; order validation: nonsense, weaker, and unknown orders reject
      (unless (handler-case (progn (atomic-load vm place :release) nil)
                 (clamsara-error () t))
        (return-from v11-atomics-adapter (values nil "load accepted a release order")))
      (unless (handler-case (progn (atomic-store vm place 1 :acquire) nil)
                 (clamsara-error () t))
        (return-from v11-atomics-adapter (values nil "store accepted an acquire order")))
      (unless (handler-case (progn (atomic-load vm place nil) nil)
                 (clamsara-error () t))
        (return-from v11-atomics-adapter (values nil "load accepted a NIL order")))
      (unless (handler-case (progn (atomic-load vm place :bogus) nil)
                 (clamsara-error () t))
        (return-from v11-atomics-adapter (values nil "load accepted an unknown order")))
      (unless (handler-case (progn (fence vm :relaxed) nil)
                 (clamsara-error () t))
        (return-from v11-atomics-adapter (values nil "relaxed fence accepted")))
      ;; bounds are checked, not silently out-of-heap
      (unless (handler-case (progn (atomic-load vm (vm-heap-size vm) :seq-cst) nil)
                 (clamsara-error () t))
        (return-from v11-atomics-adapter (values nil "out-of-heap atomic place accepted")))
      (values t "atomics adapter ok"))))

(deftest v11-address-space-adapter ()
  (with-clamsara (:plan-type :nogc :heap-size 8192)
    (let* ((vm *clamsara-vm*)
           (plan *clamsara-plan*))
      (let ((offer (managed-arena-offer vm)))
        (unless (and (= (length offer) 1)
                     (simulator-arena-p (first offer))
                     (= (simulator-arena-base (first offer)) 0)
                     (= (simulator-arena-extent (first offer)) (vm-heap-size vm))
                     (equal (simulator-arena-access-modes (first offer)) '(:read :write)))
          (return-from v11-address-space-adapter (values nil "arena offer is not the simulator heap"))))
      (unless (eq (validate-managed-layout vm (list (cons 0 4) (cons 2048 4))) t)
        (return-from v11-address-space-adapter (values nil "disjoint layout rejected")))
      (unless (equal (install-managed-layout vm (list (cons 0 4))) (list (cons 0 4)))
        (return-from v11-address-space-adapter (values nil "install returned something else")))
      (unless (handler-case (progn (validate-managed-layout vm (list (cons 0 8) (cons 4 4))) nil)
                 (clamsara-error () t))
        (return-from v11-address-space-adapter (values nil "overlapping layout accepted")))
      (unless (handler-case (progn (validate-managed-layout vm (list (cons 8190 8))) nil)
                 (clamsara-error () t))
        (return-from v11-address-space-adapter (values nil "out-of-arena layout accepted")))
      ;; space resolution delegates to the plan's SFT realization
      (let* ((o (clamsara-allocate-object 1))
             (space (space-of-reference plan o)))
        ;; NOTE: SPACE-P is exported by package.lisp but has no definition in
        ;; current src (pre-existing gap this test exposed); use the class.
        (unless (and (typep space 'space) (eq space (default-space plan)))
          (return-from v11-address-space-adapter (values nil "space-of-reference did not resolve via the SFT")))
        (unless (null (space-of-reference plan (vm-heap-size vm)))
          (return-from v11-address-space-adapter (values nil "unmanaged address resolved to a space"))))
      (unless (handler-case (progn (update-space-ownership plan (cons 0 4) nil) nil)
                 (clamsara-error () t))
        (return-from v11-address-space-adapter (values nil "ownership reassignment accepted without a mechanism")))
      (values t "address-space adapter ok"))))

(deftest v11-mapping-adapter ()
  (with-clamsara (:plan-type :nogc :heap-size 8192)
    (let ((vm *clamsara-vm*))
      (reserve-virtual-range vm (cons 20 2))
      (unless (and (= (car (aref (mmu-vpt vm) 20)) 0)
                   (eq (cdr (aref (mmu-vpt vm) 20)) :none)
                   (eq (cdr (aref (mmu-vpt vm) 21)) :none))
        (return-from v11-mapping-adapter (values nil "reserve did not leave reserved pages unmapped/protected")))
      (map-logical-pages vm (cons 20 2) 3 :read-write)
      (unless (and (= (vm-page-physical vm 20) 3) (= (vm-page-physical vm 21) 4))
        (return-from v11-mapping-adapter (values nil "map-logical-pages did not map the source pages")))
      (map-logical-pages vm (cons 20 1) 5 :read)
      (unless (and (= (vm-page-physical vm 20) 5)
                   (eq (cdr (aref (mmu-vpt vm) 20)) :read))
        (return-from v11-mapping-adapter (values nil "map-logical-pages ignored ACCESS")))
      (remap-logical-pages vm 5 21 1)
      (unless (= (vm-page-physical vm 21) 5)
        (return-from v11-mapping-adapter (values nil "remap-logical-pages did not re-back the destination")))
      (protect-logical-pages vm (cons 20 2) :none)
      (unless (eq (cdr (aref (mmu-vpt vm) 21)) :none)
        (return-from v11-mapping-adapter (values nil "protect-logical-pages ignored")))
      (unless (null (flush-address-translations vm (cons 20 2)))
        (return-from v11-mapping-adapter (values nil "flush returned asynchronously for the software MMU")))
      (unmap-logical-pages vm (cons 20 2))
      (unless (and (= (car (aref (mmu-vpt vm) 20)) 0)
                   (eq (cdr (aref (mmu-vpt vm) 20)) :none))
        (return-from v11-mapping-adapter (values nil "unmap-logical-pages left backing")))
      (values t "mapping adapter ok"))))

(deftest v11-diagnostics-adapter ()
  ;; NOTE: fatal-diagnostic is a recorded conformance-blocker (see
  ;; V11-IMPLEMENTATION.md): the portable implementation is allocating.  This
  ;; test asserts the diagnostic CONTENT obligation only.
  (with-clamsara (:plan-type :nogc :heap-size 4096)
    (let ((vm *clamsara-vm*))
      (let ((t1 (monotonic-clock vm)))
        (unless (and (typep t1 'fixnum) (>= t1 0) (>= (monotonic-clock vm) t1))
          (return-from v11-diagnostics-adapter (values nil "monotonic clock is not monotonic"))))
      (unless (handler-case (progn (fatal-diagnostic vm :corrupt-heap) nil)
                 (clamsara-error () t))
        (return-from v11-diagnostics-adapter (values nil "fatal-diagnostic did not report")))
      (values t "diagnostics adapter ok"))))

#+sbcl
(sb-alien:define-alien-variable
    ("bytes_allocated" %v11-bytes-allocated)
    sb-alien:unsigned-long)

#+sbcl
(deftest v11-adapters-no-allocation ()
  ;; Measured proof for the location seams' no-per-visit-allocation claim:
  ;; after warm-up (dispatch caches, closures, region walk), mapping 100
  ;; reference locations and 100 root locations, plus load/store round trips
  ;; through them, must not allocate one host byte.  Uses the suite's raw
  ;; bytes_allocated discipline (test-collectors.lisp): close the thread
  ;; allocation region first so the next host allocation is visible.
  (with-clamsara (:plan-type :nogc :heap-size 8192)
    (let ((vm *clamsara-vm*))
      ;; one object whose precise layout names 100 payload slots
      (register-slot-map vm +tag-object+ 11
                         (make-array 100 :initial-contents (loop for k below 100 collect k)))
      (let* ((o (clamsara-allocate-object 100 :layout-id 11))
             (root-value (clamsara-allocate-object 1)))
        (unless (vm-valid-reference-p vm o)
          (return-from v11-adapters-no-allocation (values nil "warm object missing")))
        (dotimes (k 100) (vm-add-root vm root-value))
        ;; measured region: hoisted closures only, no per-visit allocation.
        ;; Warm-up runs EVERY generic on the exact argument types used inside
        ;; the measured interval (including LOAD/STORE-REFERENCE-RAW), so
        ;; first-call dispatch-cache allocation cannot pollute the delta.
        (let* ((ref-visit (lambda (loc)
                            (let ((v (load-reference vm loc)))
                              (store-reference-raw vm loc v))))
               (root-visit (lambda (loc) (load-root vm loc)))
               (snap-visit (lambda (snap) (map-root-locations snap root-visit))))
          (map-reference-locations vm o ref-visit)
          (with-root-snapshot vm :all snap-visit)
          ;; Full GC before each attempt: bytes_allocated tracks the live SBCL
          ;; heap, so a collection inside the measured interval would pollute
          ;; the delta with collector noise, not adapter allocation.  Three
          ;; attempts; one zero-delta pass proves the claim.
          (let ((attempts 0) (bytes nil))
            (loop
              (incf attempts)
              (sb-ext:gc :full t)
              (sb-vm::close-thread-alloc-region)
              (let ((before %v11-bytes-allocated))
                (dotimes (k 100)
                  (map-reference-locations vm o ref-visit)
                  (with-root-snapshot vm :all snap-visit))
                (setf bytes (- %v11-bytes-allocated before)))
              (when (or (zerop bytes) (>= attempts 3))
                (return)))
            (%v11-check (and bytes (zerop bytes))
                        "100 reference + 100 root location visits allocate nothing"
                        (format nil "location seams consed ~D host bytes (best of ~a attempts)"
                                bytes attempts))))))))
