# Implementation feedback on paper-v14

This records implementation experience and proposed guidance for a later
revision. `paper-v14` remains normative and unchanged. This is not an errata
verdict, permission to relax a requirement, or a claim of completed conformance.

## What “difficult as an implementation guide” means

The problem is not that the prose is generally incomprehensible. Many individual
requirements are unusually explicit. The difficulty is assembling the complete
set of obligations for one operation across the construction, clients,
metadata, execution, and collector chapters, then demonstrating that the
assembled implementation satisfies them together.

An implementer should not have to reconstruct that integration map from memory.
The paper would be stronger with a worked implementation profile, obligation
cross-references, and small executable histories that expose incorrect
compositions. These would supplement the specification, not replace its general
interfaces or prescribe one implementation everywhere.

The fresh [independent review](review-ac22bdd.md) is useful evidence: existing
native suites passed, yet ordinary admitted histories exposed serious defects.
That shows a gap in our implementation and validation. It also identifies
high-value examples for an implementation guide.

## 1. Show the capacity proof across component boundaries

**Observed problem:** equal SemiSpace byte extents and sufficient trace storage
did not establish sufficient object-model representation storage. A model with
three representation records admitted two live source objects. The first copy
consumed its last record; the second failed after forwarding was published.

The existing reservation requirements already rule out this preventable
post-publication failure. The implementation failed them. But a worked proof
should explicitly distinguish these dimensions:

- managed byte extents and alignment/packing charges;
- simultaneous source and destination representations;
- tracing/discovery and retirement records;
- weak, ephemeron, finalizer and pending-work capacity;
- allocator/free-interval descriptors;
- physical and auxiliary storage retained by each owner.

**Requested addition:** an obligation table identifying the owner, declaration,
validation phase, and exhaustion behavior for each bound. Include the concrete
“two sources, two destinations, only three records” counterexample. Show where
composition is rejected or all needed reserves are proved before forwarding.

Relevant sections: construction resource contracts, object-model binding,
SemiSpace destination reservation, and the common collection protocol.

## 2. Give entry-point state/ownership tables, not only a lifecycle description

The finalizer section already specifies record generations, running/done states,
at-most-once invocation, and completion after normal or nonlocal return. Those
rules are clear. Our implementation nevertheless updated a state flag without
actually acquiring ownership of queued work.

**Requested addition:** one worked finalizer history covering:

1. Register A, cancel A, then reuse its physical slot for B. A's stale token
   cannot name B; B's token still resolves to its actual record.
2. Invoke a callback that performs a nonlocal exit. A later drain cannot invoke
   it again, and terminal cleanup still occurs.
3. Invoke a callback that recursively requests a drain.
4. Invoke a callback that triggers another collection and appends new pending
   work. Finishing the original drain must not discard the new work.
5. Track callback and referent roots while a callback is running, including
   nested collection and a collection that retains the stop.

For each public operation, list legal input states, ownership acquired, managed
locations that remain roots, success transitions, and state left on failure.
Include which updates require the composed root/barrier path. This would make
it harder to mistake a state-name assignment for the whole protocol.

Relevant section: `chapters/clients.tex`, “Finalizer registry.”

## 3. Show composed operations that cross event paths

**Observed problem:** a real barrier composition declared a write contribution
before a read contribution. Successful CAS nevertheless ran the whole read
exposure path before the write path. A failed CAS also used a different fault
boundary from a successful CAS.

The paper's global contribution order and closed exposure-failure rules are
already explicit; these are implementation defects, not ambiguous permissions.

**Requested addition:** an annotated CAS trace with write-before-read ordering,
one contribution that handles both events, success and mismatch branches, and
an exposure callback fault. Show the single frozen ordering applied across the
applicable events. State which effects have become irrevocable at each point.
A read-before-write-only example cannot distinguish global composition from a
hard-coded “run the read path, then the write path” implementation.

Relevant section: `chapters/execution.tex`, composed barrier execution.

## 4. Walk through generational recovery and remembered-state publication

**Observed problem:** our implementation required mature promotion room before
starting a major collection, even when that major could reclaim mature garbage.
This was our policy error. The paper explicitly permits nursery copying or
promotion and requires a major to collect all participating spaces.

**Requested addition:** a tiny numeric example:

- mature space is full, but its contents have become unreachable;
- a nursery object remains live;
- promotion cannot reserve mature space;
- a valid major policy still reclaims the mature garbage;
- any surviving mature-to-nursery edge remains remembered for the next minor.

One valid policy is to copy young survivors within the nursery during the major,
then promote during a later minor. The guide need not mandate that policy. It
should show the required proof and the remembered-state consequence of whichever
policy it demonstrates.

Also include an out-of-scope mature ephemeron key retaining a young value, and a
reverse-ordered ephemeron chain that needs more than one fixed-point pass.

Relevant section: `chapters/collectors.tex`, “Generational composition.”

## 5. Make hosted residency acceptance operational

A managed arena can exist while guest data still lives in ordinary host
containers. We encountered exactly that defect. Conversely, a charged host
array implementing the simulator's word plane is not itself evidence of an
illicit guest payload.

**Requested addition:** a short acceptance matrix distinguishing:

| Retained value | Evidence required |
| --- | --- |
| Simulator backing storage | Fixed declared capacity, ownership and exact charge |
| Guest aggregate | Managed allocation, authoritative start, real tracing and reclamation |
| Immediate scalar | Explicit supported representation contract |
| Compiler/interpreter control object | Declared ownership and exact writable locations for embedded guest references |
| Foreign host object used as guest payload | Explicit admitted representation, or rejection before exposure |

Include negative tests for host conses and boxed numeric values entering guest
slots. State that successful evaluation, printed opaque handles, or allocation
counts alone do not establish guest residency.

## 6. Separate active root capacity from registration history

Our first dynamic root service could grow retained host bookkeeping after the
construction account had frozen. That was an implementation bug under the
existing accounting rules.

**Requested addition:** a bounded registration example naming active-provider,
live-location, and historical-token capacities separately. Show which resources
unregistration returns, which identities must never revive, and how exhaustion
rejects before changing visible state. Identify external provider ownership
separately from root-service-owned storage.

## A useful companion deliverable

A small end-to-end profile could connect:

`declare → solve → bind → publish → mutate → collect → correct → retire → release`

At each transition, name the relevant normative clauses and executable
assertions. Include failure/retry traces alongside the successful path. Declare
the profile's limits explicitly: hosted evidence is not supervisor allocation
freedom, target residency, concurrency, or complete language integration.

The paper's listing/declaration checker is useful but cannot validate these
histories. Keep its claim separate from implementation conformance. Likewise,
name the revision or artifact behind statements about repository fixtures: the
current rewrite does not contain the checkpoint fixture referred to in
`chapters/persistence.tex`. That is an artifact/provenance gap to resolve, not
permission to claim the checkpoint profile works.

## What this feedback does not excuse

Incorrect token decoding, missed cleanup, ignored size rules, hidden host guest
payload, and reversed barrier order are not paper defects merely because our
tests missed them. Maclina's special-variable compilation bugs are also separate
integration defects.

No specification contradiction has been established by this feedback. The
request is to make the path from the contracts to a demonstrably conforming
implementation easier to follow and harder to falsely declare complete.
