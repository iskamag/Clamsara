;;;; Focused upstream regressions from tools/patches/maclina-special-bindings.patch.
;;;; This tests native and cross VMs on SBCL. It is not Maclina's full test suite.
;;;; The patch must be applied explicitly to the selected dependency checkout.

(require :asdf)
(asdf:load-system :maclina)
(asdf:load-system :clostrum-basic)
(asdf:load-system :fiveam)
;; Load authentic ASDF components without the unrelated FASL externalizer
;; component that currently exhausts this SBCL's control stack at compile time.
(dolist (path '(("test" "suites") ("test" "cross")
                ("test" "ansi" "special")))
  (asdf:operate 'asdf:load-op (asdf:find-component :maclina/test path)))
;; Do not let an unpatched dependency's original three tests pass this gate.
(dolist (name '(maclina.test::special.global-required-setq
                maclina.test::special.global-required-rebind
                maclina.test::special.global-optional-default
                maclina.test::special.global-key-default
                maclina.test::special.global-aux-default
                maclina.test::special.global-declared-optional
                maclina.test::special.global-declared-key
                maclina.test::special.global-declared-aux
                maclina.test::special.global-callee-writes
                maclina.test::special.global-escaped-reader
                maclina.test::special.global-restoration))
  (assert (fiveam:get-test name) () "Missing patched regression ~S" name))
(maclina.vm-cross:initialize-vm 65536 maclina.test.cross::*client*)
(let* ((env (make-instance 'clostrum-basic:run-time-environment))
       (maclina.test::*environment* env)
       (maclina.machine:*client* maclina.test.cross::*client*))
  (maclina.test.cross:fill-environment env)
  (let ((result (fiveam:run! 'maclina.test::special)))
    (format t "~&MACLINA-SPECIAL-SUITE ~S~%" result)
    (assert result)))

(asdf:load-system :trucler-native)
(maclina.vm-native:initialize-vm 65536)
(let ((maclina.test::*environment* nil)
      (maclina.machine:*client* (make-instance 'trucler-native-sbcl:client)))
  (let ((result (fiveam:run! 'maclina.test::special)))
    (format t "~&MACLINA-NATIVE-SPECIAL-SUITE ~S~%" result)
    (assert result)))
