(defpackage #:clamsara-vm
  (:use #:cl #:clamsara)
  (:nicknames #:clamsara.vm)
  (:export
   #:maclina-vm
   #:make-maclina-vm
   #:clamsara-maclina-client
   #:*clamsara-maclina-client*
   #:*clamsara-maclina-env*
   #:setup-clamsara-maclina-environment
   #:with-clamsara-maclina))

(in-package #:clamsara-vm)
