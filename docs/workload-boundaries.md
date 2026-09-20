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

This is not a claim of complete language adaptation. Managed REST lists,
constant/module roots, active closures, foreign primitive argument lifetimes,
macro side effects crossing phase boundaries, general teardown, and the
remaining guest representations still need explicit acceptance. A successful
macro expansion is not full benchmark evidence.
