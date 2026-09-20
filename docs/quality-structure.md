# Structural quality gate

`tools/check-structure.lisp` is a development-time gate for the canonical
production tree. It uses the Common Lisp reader, loaded function and MOP
introspection, and the preceding native ASDF load. It rejects:

- repeated `DEFUN` names, including exact `(SETF name)` function names;
- function, value, and type namespace collisions;
- repeated methods with the same generic name, qualifiers, and required
  specializers;
- method lambda lists that are not congruent with their generic lambda list;
- definition forms nested in an enclosing body instead of a top-level context;
- definitions introduced outside `CLAMSARA`, except the exact documented
  `CL:INITIALIZE-INSTANCE :AFTER` extension for `METADATA-STORAGE` and the
  `CLOSTRUM-BASIC:MAKE-VARIABLE-CELL` method for `WORKLOAD-MACLINA-CLIENT`;
- versioned production source paths and versioned ASDF system aliases.

The duplicate whitelist is empty. Whitelist entries, if ever needed, must name
one issue code, one exact Lisp name, and a non-empty reason. There is no broad
warning suppression.

## ASDF integration recipe

Add these systems to `clamsara.asd`:

```lisp
(asdf:defsystem :clamsara/quality
  :version "0.1.0"
  :description "Native structural gate; not collector or allocation evidence."
  :depends-on (:clamsara :clamsara/tools)
  :components ((:file "tools/check-structure")))

(asdf:defsystem :clamsara/quality/test
  :version "0.1.0"
  :depends-on (:clamsara/quality)
  :components ((:file "test/quality/structure"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :clamsara.structure.test
                               :run-structure-tests)))
```

Also add `(asdf:test-op :clamsara/quality/test)` to the existing
`:clamsara/test` `:in-order-to` test list. The direct fresh-process command is:

```sh
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system :clamsara/quality/test)'
```

Until that ASDF recipe is installed, the equivalent command is:

```sh
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :clamsara)' \
  --eval '(load "tools/check-structure.lisp")' \
  --eval '(load "test/quality/structure.lisp")' \
  --eval '(clamsara.structure.test:run-structure-tests)'
```

The default run checks the sources compiled by the main `:clamsara` system.
The optional workload has reader-visible dependencies and is never faked with
stub packages. Check it only after its real system loads:

```sh
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :clamsara/workload)' \
  --eval '(asdf:load-system :clamsara/quality)' \
  --eval '(clamsara.structure:assert-project-structure :include-optional-loaded t)'
```

## Baseline evidence

A first native main-system run exposed three exact method replacements in
`src/metadata/metadata.lisp`: `METADATA-RESET-RANGE`, `METADATA-FOLD`, and
`METADATA-MAP-PRESENT` each had a placeholder method followed by the same exact
method signature. The metadata owner consolidated them. No gate whitelist was
added.

After that repair, the equivalent fresh-process command above exited 0. The
fixture suite passed 30 checks, including deliberate ordinary/SETF duplicates,
an exact duplicate method, an incongruent method, a nested definition,
namespace collisions, and versioned path/system names. The main production
scan then reported `:STATUS :OK`, 903 definitions, native introspection enabled,
and no issues. A separate real `:clamsara/workload` load plus optional scan
also exited 0 and reported 1008 definitions with no structural issues. Loading
is not workload execution; its compiler style warnings and behavioral status
remain separate evidence.

This gate does not test collector behavior, specification conformance,
allocation freedom, supervisor safety, or performance. A successful structural
run must not be reported as any of those forms of evidence.
