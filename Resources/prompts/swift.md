## Swift-specific watchpoints

- **Strict concurrency violations** — non-Sendable values captured in `@Sendable` closures, `@MainActor` boundaries crossed without `await`, `Task` initiated from non-actor contexts that mutate actor-isolated state.
- **Force-unwraps in production paths** — `!` is fine in tests and in unambiguously-static fixture code, but suspicious in network/parser/UI paths. Each `!` should have a reason.
- **`try!` and `try?` swallowing errors** — `try!` crashes on failure (only acceptable when failure is genuinely impossible); `try?` silently turns errors into nil (acceptable but should be intentional).
- **Retain cycles in `Task { ... }` and closures** — `[weak self]` is required when the closure outlives `self`. `Task { self.foo() }` from a class is usually a leak.
- **`@Observable` + `@MainActor` interactions** — mutating observable properties from a non-MainActor context is a Swift 6 error; using `@ObservationIgnored` correctly matters.
- **SwiftUI re-render storms** — heavy work in a `body` getter, `onChange` callbacks that themselves mutate observed state, `@Published` chains that recursively trigger.
- **Foundation `Process` + `Pipe`** — pipes have a 64 KB buffer on Darwin; large outputs deadlock if read after `waitUntilExit`. Temp-file redirection is the fix (see `ProcessRunner` in this repo).
- **`NSLock` / `os_unfair_lock` in async code** — synchronous locks held across `await` deadlock. Use actors or `OSAllocatedUnfairLock`.

Style we don't flag: `let foo = Foo()` vs `let foo: Foo = .init()`; trailing closure vs argument-label; one-liner getter vs explicit `return`.
