;;;; Unexecuted until native authorization. No ASDF or Clamsara load.
(load (merge-pathnames #p"model.lisp" *load-truename*))
(load (merge-pathnames #p"tests.lisp" *load-truename*))
(claimore.finite.mgc:run-model-tests)
