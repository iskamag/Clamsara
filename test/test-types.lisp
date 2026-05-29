(in-package #:clamsara.tests)

(def-suite test-types :description "Type and address tests"
  :in clamsara-tests)

(in-suite test-types)

(test address-basics
  "Basic address operations."
  (is (= 0 (address-index 0)))
  (is (= 42 (address-index 42)))
  (is (address= 42 42))
  (is (not (address= 42 43)))
  (is (= 44 (address+ 42 2)))
  (is (= 40 (address- 42 2))))

(test make-object-header
  "Object header construction."
  (let ((h (make-object-header 10 :type-tag +type-tag-object+ :flags +flag-forwarded+)))
    (is (= 10 (header-size h)))
    (is (= +type-tag-object+ (header-type-tag h)))
    (is (header-flag-set-p h +flag-forwarded+))
    (is (not (header-flag-set-p h +flag-pinned+)))))

(test type-tags-are-constants
  "Type tag constants are defined."
  (is (= 0 +type-tag-object+))
  (is (= 1 +type-tag-cons+))
  (is (= 2 +type-tag-array+)))

(test flag-constants
  "Flag constants are defined."
  (is (= 1 +flag-forwarded+))
  (is (= 2 +flag-pinned+))
  (is (= 4 +flag-has-young+))
  (is (= 8 +flag-logged+)))
