;;;; Run the managed VM value-lifetime gate, independently of other suites.
(require :asdf)
(asdf:load-system :clamsara/workload/test)
(uiop:symbol-call :clamsara.workload.values.test :run-workload-value-lifetime-tests)
