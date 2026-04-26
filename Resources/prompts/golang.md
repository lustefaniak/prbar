## Go-specific watchpoints

- **Goroutine leaks** — every `go func()` should have a clear exit path. Look for context-less goroutines, unbounded `for` loops without `select { case <-ctx.Done(): return }`.
- **Context propagation** — functions that take `context.Context` should pass it down, not swap it for `context.Background()`. Background calls in HTTP handlers / RPC paths are usually a bug.
- **Error wrapping** — `fmt.Errorf("doing X: %w", err)` is the norm. Bare `return err` deep in a call stack loses the breadcrumb.
- **`defer` in loops** — `defer` fires at function scope, not loop scope. `for { defer cleanup() }` is almost always wrong.
- **Slice aliasing** — appending to a slice you got from a caller can clobber theirs. `append(dst, src...)` is safe; `dst = src; dst = append(dst, x)` is not.
- **`time.Now()` in tests** — flaky if not injected. Look for hardcoded sleeps in tests too (`time.Sleep` in tests almost always means missing synchronization).
- **Mutex held across I/O** — holding a `sync.Mutex` across a network or DB call serializes every other caller. Look for `m.Lock(); ...db.Query(...); m.Unlock()`.
- **`go test` race detector** — if the change introduces concurrency, `-race` should still pass. Mention if a new goroutine/channel pattern looks race-prone.
- **gRPC/proto changes** — adding a required field to a proto is a breaking wire change. Field deletion is also breaking unless the field number is reserved.

Idiomatic concerns we don't flag in this codebase: capturing the loop variable since Go 1.22 (no longer required), `interface{}` vs `any` (treat as equivalent).
