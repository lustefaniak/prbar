# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

PRBar — macOS menu-bar Swift app that monitors my GitHub PRs (via `gh`) and runs AI-assisted reviews on incoming review requests (via `claude` CLI). The full design + Phase-by-Phase status lives in [docs/PLAN.md](docs/PLAN.md). Read it before any non-trivial change — it documents both intent and the divergences we've already paid for in lessons.

## Build / test / run

ALWAYS use the `bin/` wrappers. Don't invoke `xcodegen` or `xcodebuild` directly.

```sh
bin/regen   # regenerate PRBar.xcodeproj from project.yml
bin/build   # bin/regen + xcodebuild build → build/Debug/PRBar.app
bin/test    # bin/regen + xcodebuild test (uses default DerivedData, separate from build/)
bin/run     # bin/build + open .app (kills prior instance first)
```

Whenever you change `project.yml` or add a new file under `Sources/` or `Tests/`, run `bin/regen` (or `bin/build`, which regenerates first) so XcodeGen picks it up.

Run a single test class:
```sh
xcodebuild -project PRBar.xcodeproj -scheme PRBar -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -only-testing:PRBarTests/PRPollerTests test
```

## Architecture (high-level wiring)

`PRBarApp.swift` is `@main`. It constructs and wires three things:

1. `PRPoller.live()` — auto-starts a 60s polling loop that calls `GHClient.fetchInbox()` and updates `prs: [InboxPR]`. Per-PR refresh and merge route through `GHClient.fetchPR` / `mergePR`. SnapshotCache is wired in for JSON persistence.
2. `Notifier()` — coalesces events from the poller into 60s settling windows and delivers via `UNUserNotificationCenter`. Suppressed while popover is open.
3. Wires them: `poller.notifier = notifier`. After every successful poll, the poller calls `EventDeriver.events(from: delta, oldPRs:)` (a pure function) and `notifier.enqueue(events)`.

Both are `@MainActor @Observable` and exposed to views via `.environment(...)`. Views read state with `@Environment(PRPoller.self)` / `@Environment(Notifier.self)`.

Subprocess + I/O actors:
- `GHClient` (actor) wraps `gh`. Knows nothing about UI or polling cadence.
- `ProcessRunner` (enum, static async) runs Foundation `Process` with **temp-file redirection** (not `Pipe()`) — pipes deadlock on output >64 KB and the inbox response can be ~110 KB.
- `SnapshotCache` (actor) reads/writes JSON at `~/Library/Application Support/io.synq.prbar/inbox-snapshot.json`.

Test seams (use these instead of mocking GHClient directly):
- `PRPoller(fetcher:, prRefresher:, prMerger:, cache:)` — inject closures, not a real client.
- `Notifier(deliverer: NotificationDeliverer)` — a `RecordingDeliverer` actor captures what would have been delivered.

## Testing patterns

Three flavors, all run by `bin/test`:

- **Fixture/unit** (e.g. `InboxResponseTests`, `PRPollerTests`, `EventDeriverTests`, `NotifierTests`, `SnapshotCacheTests`) — fast, no network, no subprocess. Hardcoded JSON or test-only `makePR` helpers.
- **Subprocess smoke** (`ProcessRunnerSmokeTests`) — runs real `/bin/echo`, `gh --version`, etc. Catches subprocess regressions (deadlocks, stdin handling, signal handling) the moment they appear.
- **Real-API integration** (`GHClientIntegrationTests`) — runs the production `gh api graphql` query and the schema introspection. Skips gracefully when `gh` is missing or unauthenticated (`throw XCTSkip(...)`). Locally always runs; in fresh CI it skips. This catches GraphQL schema drift the same hour GitHub ships a breaking change.

When you add a field to `InboxPR`, update the `makePR` helpers in: `EventDeriverTests`, `PRPollerTests`, `SnapshotCacheTests`. The compiler will tell you which arguments are missing — just remember they're four separate files.

## Conventions

- **Swift 6 strict concurrency** (`SWIFT_STRICT_CONCURRENCY = complete`). Use actors for mutable shared state crossed by Sendable values. `@MainActor @Observable` for view-state classes.
- **No third-party Swift deps** while in MVP. If you reach for one, raise the trade-off explicitly first.
- **Foundation `Process` + temp files** for subprocess work; do *not* migrate to `swift-subprocess` ad-hoc — it's a planned future change and needs to land in one go across `ProcessRunner`.
- **No comments unless WHY is non-obvious** (a workaround, a hidden constraint, a counterintuitive ordering). Don't restate code in comments.
- **No emojis** in code, commits, or UI strings unless explicitly requested.

## Gotchas worth not relearning

- `xcodebuild` requires full Xcode, not Command Line Tools. If `xcode-select -p` returns `/Library/Developer/CommandLineTools`, run `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`. `bin/build` detects this and exits early with the fix command.
- `CheckRun.isRequired` in the inbox GraphQL query makes `gh` emit ~3 stderr "PR ID required" errors per PR (and exit 1). It's a `gh` quirk; the GitHub API itself accepts the field (verified via curl). Keep it out of the query; "required" will come from the REST branch-protection cache (Phase 2+).
- `involves:@me` returns PRs where the viewer is a *past* commenter or reviewer too. Those map to `PRRole.other` and intentionally don't appear in My PRs / Inbox tabs. Don't tighten the integration test to forbid `.other`.
- GitHub returns `null` for context entries the viewer can't see. `InboxResponse.NullableNodeList<T>` allows `[T?]`; `InboxPR` mapping uses `compactMap` to drop them.
- Foundation Pipe buffer is 64 KB on Darwin. Process redirects stdout to a temp file in `ProcessRunner` for this reason. Don't switch back.
- `SMAppService.mainApp.register()` (launch-at-login) only works fully when the app is in `/Applications`. From a `bin/run` debug build it logs a warning — ignore during dev.

## Don't

- Don't commit `PRBar.xcodeproj/` — it's generated.
- Don't add Swift files via Xcode "Add Files…" — drop them in `Sources/PRBar/<subdir>/` and run `bin/regen`.
- Don't push directly to `main` — feature branches only. Squash-merge via PR.
- Don't call `claude` with `--permission-mode default` or `bypassPermissions` from app code. See PLAN.md §"AI Review Pipeline" for the locked invocation shape.
- Don't add `Bash` / `Edit` / `Write` / `Task` / `Agent` to the AI's `--allowedTools` list. Those are deliberately disallowed; the AI is a judge, not a fixer.
- Don't drop `--quiet` from `bin/build` (test output is silenced there on purpose) or *add* it to `bin/test` (we want test pass/fail visible).
- Don't merge work without `bin/test` green locally. Integration tests catch real schema drift; ignoring them defeats the purpose.
