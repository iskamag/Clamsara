# v14 workload adapter

This directory is the only bridge from the upstream Maclina bytecode engine to
paper-v14. It is not a legacy `src/maclina/` facade.

## Setup contract

`make-workload-environment` receives an already constructed v14 configuration,
execution record, allocation domain, root client, a registered root provider,
its registration token, fixed location tokens, and opaque object-kind offers.
It calls only `configuration-object-model`, `configuration-barrier`, and
`bind-mutator`. It does not construct an implicit heap, root vector, plan, or
host-GC fallback.

`kinds` is a property list of `workload-kind` values. At minimum the client
must provision `:cons`, `:array`, and `:struct` descriptions. Their strong
identities are supplied by the bound model. Allocation asks
`object-kind-descriptor` for the opaque descriptor and then calls the v14
`allocate-object` protocol.

A source CAR/CDR/AREF/SETF operation uses the private model helper
`%call-with-simulator-reference-location` with `:strong` and the declared
identity. It never scans all slots or computes an address offset. The public
`map-reference-locations` mapper remains the complete collector scanner.

The root provider must cover the preallocated Maclina stack, global variable
cells, dynamic binding cells and closure environments. Exhausting this bound
is an explicit failure. Root stores use `root-provider-store`; they never write
a host slot directly before the composed `:root-store` event commits.

## Workload acceptance

`run-canonical-gabriel` enumerates all 19 checked-in reference files and calls
each source file's own `TEST*` function. It has no skip ledger and no reduced
lookalikes. `run-unmodified-boehm-gcbench` requires an explicit upstream source
pathname and defaults to the original depth 18. It rejects
`test/fixtures/boehm-gc.lisp`, which is a Scheme-to-Common-Lisp translation,
not an unmodified upstream source.

The adapter lowers quoted source lists to managed CONS constructor calls at the
interpreter boundary. This changes no benchmark bytes and is required for
quoted benchmark data to reside in managed storage rather than in host literal
lists. Host symbols, code, and streams remain client-provided objects; any
managed references held by them must be covered by registered providers.
