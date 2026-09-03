(defpackage #:clamsara-maclina
  (:use #:cl)
  (:nicknames #:clamsara.vm)
  (:export
   #:maclina-vm
   #:make-maclina-vm
   #:clamsara-maclina-client
   #:maclina-client-plan
   #:*clamsara-maclina-client*
   #:*clamsara-maclina-environment*
   #:setup-clamsara-maclina-environment
   #:clamsara-maclina-eval
   #:clamsara-maclina-eval-string
   #:clamsara-maclina-compile-form
   #:clamsara-maclina-compile-string
   #:load-maclina-source-file
   #:with-clamsara-maclina))

(in-package #:clamsara-maclina)
