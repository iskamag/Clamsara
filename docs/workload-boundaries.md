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

## Published code roots

An active function could lose a managed literal before its first use: a native
16KiB test allocated garbage, collected, and then failed with "Stale or corrupt
hosted reference" when the function finally read its literal. Global function
and macro definitions also retained closures outside the active call frames.

The bounded control traversal now follows functions to their modules, closures
to their templates and environments, and modules to literal slots. Managed
literals use writable locations in the original literal vector. Shared/cyclic
code graphs use the existing identity-deduplicated queue; arbitrary host lists
or vectors are not traversed as guest payload.

Traversal starts from active VM roots and the current Clostrum environment's
operator, compiler-macro, setf-expander, symbol-macro-expander, and type-expander
fields. It does not keep a registry of every function ever compiled. Removing
a definition can therefore release its captured or literal payload.

Four native cases in `:clamsara/workload/test` cover an active literal before
first use, a global function literal, a global closure capture, and a global
macro closure capture. Each published-code case moves and corrects its payload,
then proves zero discoveries after FMAKUNBOUND and result release. Existing
root/control capacities are unchanged.

This covers linked code and the known environment fields above. It does not
establish in-flight compiler/linker ownership, LOAD-TIME-VALUE lifetime, quoted
literal identity/conversion, arbitrary host closure captures, or other missing
guest representations. Those remain separate acceptance work.

## Full depth-18 computation checkpoint (not full acceptance)

The `90fddf3` image completed the unchanged depth-18 source and its assertions:
`:STATUS :OK`, `:VALUE T`, elapsed 1066.1439 seconds. It used a 32MiB active
semispace, 64MiB total semispace reserve, and an 8MiB maximum object. All 20
original fixture hashes remained unchanged. Short native diagnostic processes
also ran during this attempt; the elapsed time is not an isolated performance
comparison.

That temporary driver omitted final collection evidence and reported
`:FINAL-COLLECTION-STATUS :NOT-RUN`. Its old close helper then failed with
`:REACHABLE-OBJECTS-NOT-DISCHARGED`. The driver swallowed that close error and
exited 0. This is computation evidence only, not a successful full lifecycle.
The log is `/tmp/clamsara-gcbench-postcontrol.log`.

`tools/run-gcbench.lisp` is the reproducible replacement. It requires automatic
movement evidence, an empty-root final collection without clearing roots, and
successful close; either workload or close failure makes the process fail.
See `tools/README.md`. A fresh full run is required after the close repair.

## Full depth-18 hosted acceptance

Revision `113aa6a` passed `tools/run-gcbench.lisp` in a fresh SBCL process.
The original checked-in Lisp translation ran at depth 18 with no source or
parameter changes. Its assertions returned T. The guest geometry was unchanged:
32MiB active semispace, 64MiB total semispace reserve, 8MiB maximum object.
All 20 original fixture hashes verified unchanged before and after execution.

Observed evidence from `/tmp/clamsara-gcbench-acceptance.log`:

- Latest automatic SemiSpace cycle: complete; 196611 objects moved,
  16777328 bytes moved; 262142 objects dead.
- Explicit final cycle: complete; zero objects discovered or moved;
  262143 objects dead. The runner did not clear roots.
- Close: complete. `GCBENCH-ACCEPTED` present and process exit 0.
- Workload elapsed: 1060.981 seconds; process elapsed: 1069.421 seconds.

Short native validation processes overlapped this run. These times are
operational evidence, not an isolated performance comparison. The published-code
root repair was developed while this image was already running; this result
belongs to `113aa6a`, not retroactively to later revisions. A final current-tree
benchmark gate remains necessary after completing language adaptation.

This establishes the hosted full GCBench lifecycle for that revision. It does
not establish the 19 Gabriel benchmarks, full language adaptation, independent
expanded generational coverage, or Mezzano/supervisor admission.

## Completed-runtime close

The original close helper erased VM registers, unbound both owned contexts,
and then asked the collector to shut down without a discharge collection.
Even one discarded cons therefore caused `:REACHABLE-OBJECTS-NOT-DISCHARGED`,
after the environment had already become unusable. Clearing a live result
also hid its ownership rather than proving that the application released it.

Close now rejects active execution before changing VM state. For a published
runtime it performs an explicit full collection using the registered roots.
A live result, explicit temporary root, or global root rejects close before
unbinding either owned context. Those roots retain their corrected references;
the collection can move their objects even when close rejects. The application
must release the roots and retry. For a completed result, evaluating NIL is an
explicit way to consume it. Close never clears VM values, dynamic bindings, or
application root slots to manufacture an empty heap.

Only a complete discharge with zero discovered objects and an empty allocation
map proceeds to unbinding and shutdown. Non-complete collection or shutdown
statuses are reported, not ignored. Configuration, environment, and root-token
handles are cleared only after successful shutdown and root unregistration.
A configuration already closing retries its shutdown drain/release without a
new collection.

Five native tests are included in `:clamsara/workload/test`: discarded-payload
close, live-result rejection/recovery, explicit-root rejection/recovery,
global-root rejection/recovery, and pre-effect rejection during VM execution.
Successful cases also check configuration completion and repeated close.
This proves these bounded hosted lifecycles, not all possible failure recovery
or ownership of language representations that remain unimplemented.

This is not a claim of complete language adaptation. Managed REST lists,
in-flight compiler/linker roots and literal identity/conversion, foreign primitive
argument lifetimes, macro side effects crossing phase boundaries, host-condition cleanup,
and the remaining guest representations still need explicit acceptance.
A successful macro expansion is not full benchmark evidence.
