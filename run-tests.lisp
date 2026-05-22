(load (merge-pathnames #p"~/quicklisp/setup.lisp"
                        (truename #p"~/")))
(push #p"/home/iskam/src/vibe/Clamsara/" asdf:*central-registry*)
(asdf:test-system :clamsara/test)
