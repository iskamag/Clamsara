;;;; Managed arbitrary-precision integers for the hosted workload adapter.
(in-package #:clamsara)

;; Sign and little-endian base-2^30 limbs are immediate numeric words. The
;; separate opaque kind is not a Lisp array and has no reference locations.
(defconstant +workload-limb-bits+ 30)

(defun %guest-bignum-p (environment value)
  (let ((kind (getf (workload-kinds environment) :bignum)))
    (and kind (%guest-ref-p environment value)
         (eq (object-kind (workload-model environment) value)
             (workload-kind-description kind)))))

(defun %bignum-word (environment object index)
  (%with-array-element-location
   environment object index
   (lambda (location) (load-reference (workload-model environment) location))))

(defun %set-bignum-word (environment object index value)
  (%with-array-element-location
   environment object index
   (lambda (location)
     (store-reference-raw (workload-model environment) location value))))

(defun %host-integer->guest (environment value)
  (check-type value integer)
  (when (typep value 'fixnum) (return-from %host-integer->guest value))
  (let* ((magnitude (abs value))
         (limbs (ceiling (integer-length magnitude) +workload-limb-bits+)))
    (%allocate-guest
     environment :bignum (1+ limbs) nil
     (lambda (object)
       ;; Numeric writes cannot allocate guest storage. VALUE is transient
       ;; arithmetic scratch, never a retained side table or guest word.
       (%set-bignum-word environment object 0 (if (minusp value) -1 1))
       (dotimes (i limbs)
         (%set-bignum-word environment object (1+ i)
                           (ldb (byte +workload-limb-bits+
                                      (* i +workload-limb-bits+)) magnitude)))
       object))))

(defun %guest-bignum->host (environment object)
  (unless (%guest-bignum-p environment object)
    (error 'type-error :datum object :expected-type 'bignum))
  (let* ((payload (- (object-size (workload-model environment) object) 16))
         (count (/ payload 8))
         (sign (%bignum-word environment object 0))
         (answer 0))
    (unless (and (integerp count) (>= count 2) (member sign '(-1 1)))
      (error 'workload-error :operation 'bignum-read :reason :corrupt-header))
    (loop for i downfrom (1- count) above 0
          for limb = (%bignum-word environment object i)
          do (unless (and (typep limb '(unsigned-byte 30))
                          (or (/= i (1- count)) (plusp limb)))
               (error 'workload-error :operation 'bignum-read
                      :reason :corrupt-limb))
             (setf answer (+ (ash answer +workload-limb-bits+) limb)))
    (setf answer (* sign answer))
    (when (typep answer 'fixnum)
      (error 'workload-error :operation 'bignum-read :reason :noncanonical))
    answer))

(defun %guest-number->host (environment value)
  (cond ((typep value '(or fixnum single-float)) value)
        ((%guest-bignum-p environment value)
         (%guest-bignum->host environment value))
        (t (error 'type-error :datum value :expected-type 'number))))

(defun %numeric-predicate-argument (environment value)
  (cond ((%guest-bignum-p environment value)
         (%guest-bignum->host environment value))
        ((and (numberp value) (not (typep value '(or fixnum single-float))))
         (error 'workload-capability-error :operation 'numeric-argument
                :reason :unmanaged-boxed-number))
        (t value)))

(defun %admit-numeric-result (value)
  (unless (or (typep value '(or integer single-float)) (member value '(nil t)))
    (error 'workload-capability-error :operation 'numeric-result
           :reason (list :unsupported-representation (type-of value))))
  value)

(defun %numeric-results->guest (environment results)
  ;; Validate every result before allocating any representation. Decoding of
  ;; every argument has also finished before this function is entered.
  (mapc #'%admit-numeric-result results)
  (unless (some (lambda (value) (typep value 'bignum)) results)
    (return-from %numeric-results->guest (values-list results)))
  (unless (<= (+ 2 (length results)) (length (workload-root-locations environment)))
    (error 'workload-capability-error :operation 'numeric-result
           :reason :root-capacity))
  (unwind-protect
       (progn
         (loop for value in results for index from 2
               do (%store-temporary-root
                   environment index
                   (if (typep value 'bignum)
                       (%host-integer->guest environment value) value)))
         ;; Earlier results may have moved while later results were boxed.
         (values-list (loop for index from 2 below (+ 2 (length results))
                            collect (workload-temporary-root-load environment index))))
    (loop for index from 2 below (+ 2 (length results))
          do (workload-temporary-root-clear environment index))))

(defun %guest-eql (environment left right)
  (let ((left-big (%guest-bignum-p environment left))
        (right-big (%guest-bignum-p environment right)))
    (if (or left-big right-big)
        (and left-big right-big
             (= (%guest-bignum->host environment left)
                (%guest-bignum->host environment right)))
        (eql left right))))

(defun %numeric-type-specifier (environment specifier)
  ;; Type syntax is temporary compiler/ANSI control data, not guest payload.
  (cond ((%guest-cons-p environment specifier)
         (cons (%numeric-type-specifier environment (%guest-car environment specifier))
               (%numeric-type-specifier environment (%guest-cdr environment specifier))))
        ((%guest-bignum-p environment specifier)
         (%guest-bignum->host environment specifier))
        (t specifier)))

(defun %install-workload-numbers (client runtime)
  (let ((environment (workload-client-workload client)))
    (flet ((install (name function)
             ;; Host syntax evaluation must retain native arithmetic and data.
             (let ((native (fdefinition name)))
               (setf (clostrum:fdefinition client runtime name)
                     (lambda (&rest arguments)
                       (declare (dynamic-extent arguments))
                       (apply (if *workload-source-execution-p* native function)
                              arguments))))))
      (dolist (name '(+ - * / 1+ 1- abs signum min max
                     = /= < > <= >= zerop plusp minusp oddp evenp
                     floor ceiling truncate round mod rem gcd lcm expt
                     ash integer-length logcount logand logior logxor logeqv
                     lognot logandc1 logandc2 logorc1 logorc2 lognand lognor
                     boole logbitp float))
        (let ((native (fdefinition name)))
          (install name
                   (lambda (&rest arguments)
                     (declare (dynamic-extent arguments))
                     (%numeric-results->guest
                      environment
                      (multiple-value-list
                       (apply native
                              (mapcar (lambda (value)
                                        (%guest-number->host environment value))
                                      arguments))))))))
      (dolist (name '(numberp realp rationalp integerp floatp complexp))
        (let ((native (fdefinition name)))
          (install name
                   (lambda (value)
                     (funcall native (%numeric-predicate-argument environment value))))))
      (install 'eql (lambda (left right) (%guest-eql environment left right)))
      (install 'typep
               (lambda (value type &optional env)
                 (typep (%numeric-predicate-argument environment value)
                        (%numeric-type-specifier environment type) env)))
      (install 'type-of
               (let ((native (clostrum:fdefinition client runtime 'type-of)))
                 (lambda (value)
                   (if (%guest-bignum-p environment value) 'bignum
                       (funcall native value)))))))
  (values))

(defmethod maclina.compile::load-literal-info :around
    ((client workload-maclina-client) (info maclina.compile::constant-info) environment)
  (declare (ignore environment))
  ;; Do not leave a raw boxed number in a published code literal or VM value.
  ;; Allocating here requires separately bounded in-flight linker roots; that
  ;; interface is not yet implemented. Arithmetic on immediate source inputs
  ;; is supported; boxed source constants reject explicitly until it is.
  (let ((value (maclina.compile::constant-info-value info)))
    (when (and (numberp value) (not (typep value '(or fixnum single-float))))
      (error 'workload-capability-error :operation 'numeric-literal
             :reason :requires-managed-linker-literal)))
  (call-next-method))
