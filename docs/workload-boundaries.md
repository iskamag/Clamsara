# Workload compiler/runtime data boundary

The interpreter handles two kinds of data:

- compiler syntax and interpreter control data, owned by the host;
- guest payload, which must use the supported managed representations.

An unchanged depth-18 GCBench attempt exposed a boundary error while expanding
its `TREE-SIZE` macro. Native reader expansion supplied a host syntax list to
the managed `LIST` implementation. That implementation then rejected the host
list as a guest cons. The failure occurred while compiling the benchmark,
not while executing its tree workload.

The adapter now scopes source-data execution around Maclina's macro
`COMPILE-COMBINATION` generic, guarded by `WORKLOAD-MACLINA-CLIENT`.
Selected data operations use host syntax operators only in that extent.
The client `COMPUTE-INSTANCE-FUNCTION` extension supplies the corresponding
source entry for interpreted library functions without replacing their
Maclina function identity or hiding their closure environment.
No engine function or preexisting method is replaced. Other clients follow
the original methods. Ordinary workload evaluation does not set source mode.

`asdf:test-system :clamsara/workload/test` exercises the original failing
nested macro shape, compound macro arguments, local macros, mode restoration,
and rejection of host conses by ordinary runtime CAR after macroexpansion.
The same command retains its moving smoke, initializer, and TIME regressions.

## Keyword constants

A subsequent unchanged depth-18 attempt reached execution but failed on
`UNBOUND-VARIABLE :LEFT`. The compiler described keywords as unknown special
variables. The workload client's `TRUCLER:DESCRIBE-VARIABLE` method now returns
constant descriptions with the keyword itself as both name and value. Other
names delegate to the existing environment protocol. No mutable global cell
or host-global variable fallback is introduced.

Adapter regressions cover keywords interned after environment construction,
unchanged global-cell counts, unknown non-keyword lookup, multiple keyword
values, and calls using the benchmark's `:LEFT` and `:RIGHT` argument shape.
The benchmark source and parameters remain unchanged.

## Managed structures

The admitted structure shape has a bare name and at most seven bare slot
names, initially NIL. Each object uses the existing 64-byte managed kind:
`:SLOT0` holds the structure-name symbol and `:SLOT1` through `:SLOT7` hold
fields. Named predicates and accessors check this managed tag. No host
structure instance or object-to-type side table stores guest state.

The initial GCBench constructor used integer identities that were not declared
by this fixed layout. Its keyword parser also removed the first character of
`SYMBOL-NAME`. Both errors are repaired. Constructors use `WORKLOAD-ALLOCATE`,
which keeps input values, the new object, and store scratch in distinct roots.
Keyword handling preserves the leftmost value, rejects odd/unknown arguments,
and supports `:ALLOW-OTHER-KEYS`. Unsupported DEFSTRUCT options, default-value
specifications, duplicate names, and excess fields reject explicitly rather
than being silently ignored. This is not full ANSI DEFSTRUCT support.

The adapter suite now includes the unchanged GCBench tree functions in a
bounded 16KiB test. After 240 discarded nodes, building a depth-4 tree triggers
an automatic collection. The observed run moves 16 live nodes and checks all
31 final nodes for distinct identity, valid type tags, and intact edges.
This test is not a reduced-parameter replacement for full depth-18 acceptance.
The adapter suite reports 36 passing checks.

## VM value-lifetime acceptance

On `7c0ff75`, unchanged depth-18 GCBench built its stretch tree but then failed
with `:HEAP-EXHAUSTED`. A 16KiB reproduction showed why: `VM-VALUES` still rooted
the discarded 255-node tree. The collector correctly copied those objects plus
the new root: 256 objects, 16,384 bytes. A separate test showed protected values
becoming stale when an interpreted cleanup call overwrote `VM-VALUES`.

`src/workload/control.lisp` now makes the lifetimes explicit:

- Compiler contexts with nonnegative receiving counts use operand-stack values
  or discard them. Their completed forms clear the unused value register with
  existing VM instructions. All-values contexts retain it.
- The workload-only UNWIND-PROTECT lowering marks its actual cleanup template.
  Linking transfers that marker to the original Maclina function object.
- Fixed activation slots retain active callees and the original saved-value
  cons cells throughout cleanup, including THROW and RETURN-FROM. Collection
  updates those physical cells rather than a detached copy of their values.
- A bounded, identity-deduplicated traversal covers closure environments and
  lexical cells. It does not traverse arbitrary host containers as payload.
- Caller stack/frame/argument registers and activation slots restore on normal
  return and host error. Frame-capacity rejection precedes VM mutation.

The broader tests exposed a separate upstream compiler error: discarding a
MULTIPLE-VALUE-CALL result could also omit its function designator. An
immediate-only non-workload probe reproduced it. The workload-only lowering
now always requests one callee operand, independently of the result context.
No upstream files or global VM functions are replaced. These private compiler
extensions remain coupled to the inspected Maclina interfaces; other clients
use the original methods.

The value suite is now part of `asdf:test-system :clamsara/workload/test`, in
addition to the existing 36 adapter checks. It can also run alone:

```sh
sbcl --noinform --non-interactive --load tools/probe-workload-values.lisp
```

Nine cases pass: discarded results, MULTIPLE-VALUE-PROG1, ordinary cleanup,
THROW, RETURN-FROM, nested saved values, host-error frame recovery, pre-effect
frame-capacity rejection/recovery, and an active closure with a mutable cell.
The discarded-result case now moves only the one live node instead of 256.
The live multiple-value cases preserve both objects through movement.

These are hosted interpreter results, not supervisor allocation-freedom or
Mezzano admission evidence. Host-condition cleanup semantics, complete literal
and module ownership, and the other language boundaries below still need their
own acceptance. Full depth-18 and Gabriel acceptance are separate gates.

This is not a claim of complete language adaptation. Managed REST lists,
constant/module roots, active closures, foreign primitive argument lifetimes,
macro side effects crossing phase boundaries, general teardown, and the
remaining guest representations still need explicit acceptance. A successful
macro expansion is not full benchmark evidence.
