# Next bounded Gabriel blocker: MAPC accepts only one list

**Status: source-proven interface defect; native failure prediction, not a run.**
Inspected frozen Clamsara `52e08f1`, the 19 reference sources, workload code and
boundary docs. Shared Maclina `d92e9254` was read only. No Lisp/ASDF/Quicklisp
process ran. No patch, production file, dependency, or fixture was changed.

## Exact fixture path

`src/workload/gabriel.lisp:16,67-70` selects `dderiv.cl`, loads it, then calls
`TESTDDERIV`. During load, before that entrypoint, `dderiv.cl:46-48` executes:

```lisp
(mapc #'(lambda (op fun) (setf (get op 'dderiv) (symbol-function fun)))
      '(+ - * //)
      '(+dderiv -dderiv *dderiv //dderiv))
```

This is a function plus **two** lists. It is real setup, not commented example
code or a dormant derivative branch. Later `DDERIV` (lines 54-55) looks up and
calls these four property values. `TESTDDERIV` calls `DDERIV-RUN` (lines 58-69).
The canonical run currently encounters FRPOLY earlier; this blocker is an
independent DDERIV load gate, not a claim that it is the current suite's first
observed failure.

## Clamsara cause

`src/workload/maclina.lisp:880-886` overwrites guest `CL:MAPC` with:

```lisp
(lambda (function list)
  (if (null list) nil
      (progn (funcall function (car list))
             (mapc function (cdr list))
             list)))
```

The earlier native helper at lines 716-720 also accepts only one list. Neither
implementation can call this fixture's two-argument callback. The installed
function has exactly two required arguments; the fixture supplies three.
`%workload-install-data-function` (62-85) selects native host MAPC only during
compiler source execution. The fixture call is ordinary top-level evaluation,
not execution of a macro body.

The exact installed-function call with callback/NIL/NIL must reject with
Maclina's `WRONG-NUMBER-OF-ARGUMENTS` (3 given, 2 expected), rather than return
NIL without calling the callback. Maclina's fixed-arity check is correct:
`vm-shared.lisp:47-51`. Its ordinary call path gathers all arguments and applies
the callee (`vm-cross.lisp:332-336`). The probe uses direct FDEFINITION lookup
first, so any compiler-macro optimization cannot hide the wrong interface.
No special variable, guest REST parameter, boxed constant, or collection is
needed to isolate this defect. Actual native replay remains pending.

## Native semantic oracle

ANSI MAPC accepts one or more lists, calls FUNCTION on corresponding elements
left to right, stops at the shortest list, and returns its **original first
list**, not the last callback value or a copy. The fixture must perform exactly
these four assignments, with function identity checked in its own environment:

- `+` / `DDERIV` -> `(SYMBOL-FUNCTION '+DDERIV)`
- `-` / `DDERIV` -> `(SYMBOL-FUNCTION '-DDERIV)`
- `*` / `DDERIV` -> `(SYMBOL-FUNCTION '*DDERIV)`
- `//` / `DDERIV` -> `(SYMBOL-FUNCTION '//DDERIV)`

A fixture-load regression should load the original file and test all four EQ
relations. These are setup oracles, not proof that the 5,000 derivative calls
or the complete lifecycle are correct. Guest and host function objects are not
compared to each other across environments.

## Bounded regression source

`mapc-probe.lisp` is **unexecuted source**, with no bootstrap or automatic run.
After an authorized normal workload load, call
`clamsara.workload.mapc.next-probe:run-mapc-next-probe`.

It specifies three gates:

1. Direct installed MAPC with two NIL lists: return NIL, zero callback calls.
   This is a zero-managed-allocation arity red test independent of the patch.
2. Two lists of unequal length: native/guest oracle `(T 33)` checks shortest
   traversal, callback arguments, side effects, and first-list identity.
3. In a fresh 16KiB environment, inline managed input graphs have no external
   alias. Each callback allocates 600 discarded conses, then reads both moved
   arguments and changes the first argument's leaf. Require real automatic
   movement. After return, collect with the real VM result root, reload its
   physical corrected value, and check six distinct managed conses encoding
   leaf values `(11 22 3)`. Explicitly consume the result with EVAL NIL, require
   zero discoveries, and close. No root clearing or swallowed close error.

Before shipping, extend the same bounded matrix to one and three input lists,
empty lists in each position, callback designators, and nested MAPC callbacks
with collection. The nested case must expose root-slot reuse, not be waived.
This is an adapter regression, never reduced-parameter Gabriel acceptance.

## Repair ownership and bound

**No upstream permission is needed to change this operation:** both incorrect
MAPC definitions and their installation are Clamsara-owned. Do not modify the
fixture, replace global Maclina functions, or apply the preserved patch.

A conforming repair must support the general operation, not special-case the
fixture's two lists. Merely adding a guest `&REST` parameter would encounter the
separate known upstream REST lowering hold. A local primitive entry with a
bounded physical argument/cursor/control-root scope can avoid that lowering.
It must retain the callback, every live cursor and the original return list
across callbacks, reserve capacity before effects, reload moved values, and
handle nested calls without borrowing scratch slots already used by CONS.
The current fixed guest implementation avoids unregistered host locals for a
reason (`maclina.lisp:861-864`); reverting to a naive host loop is not a repair.
This is a narrowly scoped MAPC bridge/ownership task, not a compiler redesign.
No candidate implementation or root-safety success is claimed here.

A MAPC repair alone does not discharge DDERIV or all-19 acceptance. Keep the
unaltered full entrypoint, independent derivative-value oracle, and fixture
owner-driven teardown as later gates. This finding adds no payload exemption
and makes no supervisor/Mezzano admission claim.
