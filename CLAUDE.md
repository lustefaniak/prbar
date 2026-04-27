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

This is the fast feedback loop for `ClaudeProviderIntegrationTests` — real-API calls you don't want firing on every full-suite run.

## Architecture (high-level wiring)

`PRBarApp.swift` is `@main`. It constructs and wires three `@MainActor @Observable` classes, exposes them via `.environment(...)`, and views read with `@Environment(...)`:

1. **`PRPoller.live()`** — 60s polling loop calling `GHClient.fetchInbox()`. Per-PR refresh / merge / postReview route through `GHClient` too. `SnapshotCache` (actor) persists `[InboxPR]` to `~/Library/Application Support/io.synq.prbar/inbox-snapshot.json` so launches show known state immediately. After each successful poll, calls `EventDeriver.events(from:, oldPRs:)` (pure function) and `notifier.enqueue(events)`.
2. **`Notifier()`** — coalesces events into a 60s settling window, delivers via `UNUserNotificationCenter` (`UNNotificationDeliverer`). Suppressed while popover is open. Pluggable `NotificationDeliverer` protocol for tests.
3. **`ReviewQueueWorker.live()`** — drains a queue of pending AI reviews. For each PR: `GHClient.fetchDiff` → `MonorepoSplitter.split` (trivial single-Subdiff for now; Phase 4 will multi) → optional `RepoCheckoutManager.provision` (only in `.minimal` mode) → `ContextAssembler.assemble` → `ClaudeProvider.review` → `ResultAggregator.aggregate` → store as `ReviewState.completed(AggregatedReview)`. `maxConcurrent=2`. Auto-enqueues review-requested PRs after each poll via `enqueueNewReviewRequests`.

Subprocess + I/O actors:
- **`GHClient`** (actor) wraps `gh`: `fetchInbox` / `fetchPR` / `fetchDiff` / `mergePR` / `postReview`.
- **`ProcessRunner`** (enum, static async) runs Foundation `Process` with **temp-file redirection** (not `Pipe()`). Pipes deadlock on output >64 KB; the inbox response is ~110 KB.
- **`RepoCheckoutManager`** (actor) — bare clone per repo (`gh repo clone … -- --bare --depth=50 --filter=blob:none`) + transient sparse worktrees per (repo, headSha). Used in `.minimal` mode so the AI has a real cwd for `Read`/`Glob`/`Grep` and per-subfolder `CLAUDE.md` / `.mcp.json` resolves.

AI review pipeline:
- **`ClaudeProvider`** (struct, `ReviewProvider`) — spawns `claude -p --output-format stream-json --verbose --json-schema {…}`. Two modes: `.none` (pure-prompt; everything in `--disallowedTools`; cwd is empty temp dir) and `.minimal` (Read/Glob/Grep + WebFetch/WebSearch allowed; cwd is the workdir from `RepoCheckoutManager`).
- **`ClaudeStreamParser`** (enum, static) — JSONL event parser → `ClaudeStreamState`. Tolerant of unknown event types (`rate_limit_event`, etc.) and malformed lines. `budgetVerdict` checks tool-call cap (informational) and cost cap (fatal).
- **`ContextAssembler`** (enum, static) — pure function: `(InboxPR, Subdiff, diffText, toolMode, workdir) → PromptBundle`. Builds the user prompt with PR meta / file list / existing comments / CI status / CI failures / diff sections. System prompt comes from `PromptLibrary.systemPrompt(for: language)`.
- **`PromptLibrary`** (enum, static) — loads `Resources/schemas/review.json` + `Resources/prompts/{system-base,golang,typescript,swift}.md` from `Bundle.main`.

Test seams (use these instead of mocking subprocess-y types directly):
- `PRPoller(fetcher:, prRefresher:, prMerger:, prReviewer:, cache:)` — inject closures.
- `Notifier(deliverer: NotificationDeliverer)` — `RecordingDeliverer` actor captures what would have been sent.
- `ReviewQueueWorker(diffFetcher:, checkoutManager: nil)` — inject the diff source; `provider` is settable so tests use `StubProvider` / `SlowStubProvider` / `ThrowingStubProvider` (in `ReviewQueueWorkerTests`).
- `ClaudeProvider.buildArgs(bundle:, options:)` is exposed for argv assertion without spawning claude.

## Testing patterns

Three flavors, all run by `bin/test`:

- **Fixture/unit** (most tests) — fast, no network, no subprocess. Hardcoded JSON or test-only `makePR` helpers.
- **Subprocess smoke** (`ProcessRunnerSmokeTests`) — runs real `/bin/echo`, `gh --version`, etc. Catches subprocess regressions (deadlocks, stdin handling, signal handling) the moment they appear.
- **Real-API integration**:
  - **`GHClientIntegrationTests`** — runs `gh api graphql` + schema introspection. Skips when `gh` is missing/unauthenticated. Always runs locally; CI without secrets skips. Catches GraphQL schema drift the day GitHub ships a breaking change.
  - **`ClaudeProviderIntegrationTests`** — gated by `touch /tmp/prbar-run-claude-tests` because each call costs real money (~$0.05–$0.20). `bin/test` always skips by default. xcodebuild env-var pass-through to the test runner doesn't work reliably, hence the sentinel file.
  - **`RepoCheckoutManagerTests`** — uses a local fixture git repo (no network, no gh auth). Verifies the clone + worktree-add + worktree-remove lifecycle.

When you add a field to `InboxPR`, update the `makePR` helpers in 6 test files: `EventDeriverTests`, `PRPollerTests`, `SnapshotCacheTests`, `ContextAssemblerTests`, `ReviewQueueWorkerTests`, `ClaudeProviderIntegrationTests`. The compiler tells you which.

**Adding a new env-injected `@Observable` service** (e.g. a new `*Store`) means updating: the service file, `AppDelegate` (property + init + popover env), and `PRBarApp.body` (Settings env). LSP false positives make the gap hard to spot from squigglies alone — trust `bin/build`.

## Conventions

- **Swift 6 strict concurrency** (`SWIFT_STRICT_CONCURRENCY = complete`). Use actors for mutable shared state crossed by Sendable values. `@MainActor @Observable` for view-state classes.
- **Foundation `Process` + temp files** for subprocess work; do *not* migrate to `swift-subprocess` ad-hoc — it's a planned future change and needs to land in one go across `ProcessRunner`.
- **No comments unless WHY is non-obvious** (a workaround, a hidden constraint, a counterintuitive ordering). Don't restate code in comments.
- **No emojis** in code, commits, or UI strings unless explicitly requested.
- **Conventional Commits** for every commit: `<type>(<optional-scope>): <subject>`. Types: `feat` / `fix` / `docs` / `refactor` / `test` / `chore` / `perf` / `style` / `build` / `ci`. Subject is imperative, lowercase, no trailing period. Body explains *why* (constraints, prior incidents, tradeoffs) — not what (the diff already says that). Breaking changes: `!` after type or `BREAKING CHANGE:` footer.
- **SwiftData persistence** (`Sources/PRBar/Persistence/PRBarModelContainer.swift`). Hybrid pattern: domain structs (`InboxPR`, `RepoConfig`, `ReviewState`, `[Hunk]`) stay plain `Codable`; thin `@Model` "entry" rows wrap them with a JSON-encoded `payload: Data` plus a few projected columns (timestamps, sort indexes, unique cache keys). Adding a new `@Model` means appending it to `PRBarModelContainer.schema` — a missing entry compiles fine but the type is invisible at runtime. Tests use `PRBarModelContainer.inMemory()`; never construct against the live store from a test.
- **Forward-compatible Codable for SwiftData payloads** — when adding fields to a struct stored as JSON in a `@Model` row (`RepoConfig`, `ReviewState`, etc.), provide an explicit `init(from:)` using `decodeIfPresent ?? <default>` for every field so old payloads still load. Swift drops the synthesized memberwise init when you add an explicit init — restore it manually.

## Gotchas worth not relearning

- `xcodebuild` requires full Xcode, not Command Line Tools. If `xcode-select -p` returns `/Library/Developer/CommandLineTools`, run `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`. `bin/build` detects this and exits early with the fix command.
- `CheckRun.isRequired` in the inbox GraphQL query makes `gh` emit ~3 stderr "PR ID required" errors per PR (and exit 1). It's a `gh` quirk; the GitHub API itself accepts the field (verified via curl). Keep it out of the query; "required" will come from the REST branch-protection cache later.
- `claude --json-schema` rejects schemas containing `$schema`, `description`, `additionalProperties`, `minimum`, `maximum`, or `maxLength` — it just hangs. Stick to `type`, `enum`, `required`, `properties`. `PromptLibraryTests.testOutputSchemaHasNoConstraintsClaudeRejects` is the regression net. Range/length validation moves client-side.
- `claude` in plan mode fires 1–2 ambient tools (Skill, Monitor, MCP integrations) we can't enumerate in `--disallowedTools`. The tool-call cap is informational; the cost cap is fatal. Default `maxToolCalls = 10` is generous for this reason.
- `involves:@me` returns PRs where the viewer is a *past* commenter or reviewer too. Those map to `PRRole.other` and intentionally don't appear in My PRs / Inbox tabs. Don't tighten the integration test to forbid `.other`.
- GitHub returns `null` for context entries the viewer can't see. `InboxResponse.NullableNodeList<T>` allows `[T?]`; `InboxPR` mapping uses `compactMap` to drop them.
- Foundation Pipe buffer is 64 KB on Darwin. `ProcessRunner` redirects stdout to a temp file for this reason. Don't switch back.
- `SMAppService.mainApp.register()` (launch-at-login) only works fully when the app is in `/Applications`. From a `bin/run` debug build it logs a warning — ignore during dev.
- `xcodegen` resource bundling: use explicit subdirs (`path: Resources/schemas` + `path: Resources/prompts`, both with `type: folder`), not `path: Resources` — the latter nests as `Contents/Resources/Resources/...`.
- **SourceKit/LSP diagnostics in this project are unreliable** — cascading "Cannot find type X" / "Generic parameter could not be inferred" errors on cross-file references are frequent and almost always false. Trust `bin/build` and `bin/test` as authoritative; don't chase the LSP squigglies.
- **Failed Actions job logs**: `gh api repos/{owner}/{repo}/actions/jobs/{jobId}/logs` returns the plain-text log (gh follows the 302 → signed URL automatically). Job ID is parseable from a CheckRun's `detailsUrl` (`.../actions/runs/<runId>/job/<jobId>`); legacy StatusContext URLs don't have a job ID and can't get logs. Tail aggressively — full logs are megabytes; `CIFailureLogTail.tail` keeps the last ~200 lines and strips the `2024-…Z ` timestamp prefix every Actions line carries.
- **claude vs codex schema constraints are *opposite*.** Claude rejects schemas with `$schema` / `description` / `additionalProperties` / `minimum` / `maximum` / `maxLength`. Codex (OpenAI strict mode) *requires* `additionalProperties: false` on every object. The shared `Resources/schemas/review.json` stays minimal (claude-style); `CodexProvider.addStrictAdditionalProperties(_:)` injects the strict markers on the way out.
- **`ImageRenderer` can't capture `ScrollView` content, `Menu`, `HSplitView`, or NSControl-backed `Form` widgets** (Toggle / Slider / TextField / TextEditor / Picker render as the yellow placeholder). Production views that need to be screenshottable grow an opt-in `screenshotMode: Bool = false` parameter that swaps `ScrollView`→flat `VStack` and `Menu`→plain `Button`. Pattern lives on `PRDetailView`, `PRRowView`, `PRListView`, `RepoConfigEditor`. Settings panes are intentionally not in `ScreenshotTests` — capture manually via `screencapture -wo` against the running app.
- **`textSelection(.enabled)` fights `onTapGesture`** — every click drops a caret instead of triggering the gesture, and dragging starts a selection. Resolution pattern: branch on state — `Button` when you need tap behaviour (e.g. collapsed-to-expand), selectable `Text` when not (e.g. expanded copy/paste).
- **GFM rendering uses `swift-markdown-ui` (`MarkdownUI`)** via `MarkdownText` (Sources/PRBar/UI/MarkdownText.swift). PR bodies, AI summaries, and per-subreview outcomes all flow through it. Links are scheme-filtered (`http`/`https`/`mailto` only) via `OpenURLAction`; images are `https`-only via `SafeRemoteImageProvider`. Several `Markdown` quirks worth knowing:
  - `Markdown`'s per-block VStack **ignores SwiftUI `lineLimit`**. To truncate visually, clip with `.frame(maxHeight:)` + `.clipped()` + `.mask(LinearGradient(...))` for a fade-out (see collapsed-description preview in `PRDetailView`).
  - `Markdown` lays out at its **ideal** (often single-line) width. Force wrapping with `.fixedSize(horizontal: false, vertical: true)` *and* pin the surrounding `Button`/container to `.frame(maxWidth: .infinity)` — `.buttonStyle(.plain)` will otherwise shrink-wrap the label to the longest paragraph.
  - `Theme.gitHub` heading scale (H1≈2em) overwhelms menu-bar UI. `Theme.prbar` overrides with explicit pt sizes (12pt body, 14/13/12pt H1/H2/H3, 11pt code).
  - `MarkdownUI.Theme` is not `Sendable`. Custom theme `static let`s need `@MainActor` under Swift 6 strict concurrency.
- **`.allowsHitTesting(false)` on a `Button`'s label kills the button's gesture.** When you need a non-default hit area on a Button, use `.contentShape(Rectangle())` (or whatever shape) — never `.allowsHitTesting`.
- **`Data.prefix(through:)` returns a SubSequence sharing storage with the source.** If you call `removeSubrange` on the source before reading the SubSequence, you'll read corrupted bytes. Materialize via `Data(buffer.prefix(through: idx))` *before* mutating. Bit `ProcessRunner.runStreaming`'s `LineBox` twice.
- **`TextEditor` + Binding round-trip strips trailing newlines.** If a `Binding<String>`'s `set` normalizes (e.g. `.split(...).filter { !$0.isEmpty }`) and `get` re-derives from the array, every keystroke that produces a transient state (trailing `\n`) round-trips through normalization and erases the newline you just typed — Return appears broken. Fix: hold the editor text in local `@State` seeded on `.onAppear` / `.onChange(of: id)`, sync to the persisted array on text change.
- **`@State` on a parent view outlives `.id(selection)` churn on a child.** A draft buffer in the parent doesn't reset when the inner view rebuilds from a new `.id`. Pair `.id(selection)` with `.onChange(of: selection) { _, _ in draft = nil }`.
- **App relaunch races single-instance enforcement.** `open -n` + `NSApp.terminate(nil)` doesn't work — the new instance launches while the old is still alive, hits `enforceSingleInstance`, and exits. Pattern in `AppReset.relaunch`: spawn a detached `/bin/sh -c 'while kill -0 PID; do sleep 0.2; done; open APP'` so the watchdog re-parents to launchd and only fires `open` once the old PID is gone.
- **`static let` for "default" instances with identity-bearing fields shares one UUID** across every `var cfg = .default` call site, causing id collisions on upsert. Use `static var` (computed) when the default carries an identity (see `RepoConfig.default`).
- **GitHub GraphQL read-model lags `gh` REST writes.** After a successful `gh pr review` / `gh pr merge`, an immediate single-PR refresh can return stale `reviewDecision`. Pattern: refresh now + forced refresh after ~1.2s (`PRPoller.refreshPR(_:force:)`).
- **`RepoConfigStore.save` must be incremental, never delete-all+reinsert.** A single encode failure mid-batch under the old pattern would silently nuke the entire user config store. Match SwiftData rows by stable `config.id`, only update changed payloads, only delete orphans.
- **`ProcessRunner.runStreaming` termination handler must drain `takeCompleteLines()` *before* `flushTrailing()`.** Otherwise tail chunks delivered after the readability handler is nil'd get emitted as one concatenated "line" with embedded newlines.
- **Notification auth on debug builds.** `LSUIElement` ad-hoc-signed agents launched from `build/Debug/` often never surface the OS auth dialog, so `UNUserNotificationCenter.add` silently no-ops forever. Diagnostic: `plutil -p ~/Library/Preferences/com.apple.ncprefs.plist | grep -i prbar` — no entry means macOS never recorded a decision. Fix: copy the `.app` to `/Applications/` and relaunch from there for the auth flow.
- **Notification action buttons need explicit category registration.** Setting `content.categoryIdentifier` per-request is not enough — call `UNUserNotificationCenter.current().setNotificationCategories(...)` once at launch with each `UNNotificationCategory` (id + actions). Skipping this delivers notifications without buttons and produces no warning. `NotificationActionRouter.install()` is the single point that does both registration + sets `center.delegate`.
- **`UNUserNotificationCenter.delegate` is held weakly.** Keep a strong reference (e.g. a property on `AppDelegate`) or the delegate quietly deallocs and taps stop routing. `@preconcurrency` on the protocol conformance is a no-op warning — use plain `nonisolated` methods, and extract `userInfo` into a Sendable struct *before* the `Task { @MainActor }` hop (raw `[AnyHashable: Any]` is not Sendable under strict concurrency).
- **`ReviewQueueWorker.enqueue` cache-hit must still fire `onReviewSettled`.** Returning silently when `reviews[nodeId]` already has a `.completed` state at the current `headSha` breaks `ReadinessCoordinator`: on relaunch with persisted reviews + active review-requests, no settled-pulse means no `flushBatchSettled`, means no notification ever fires. Any new short-circuit path through `enqueue` needs the same pulse with the current `inFlight == 0 && pending.isEmpty` settled bool.
- **`log show` needs the full path in zsh.** Bare `log` collides with a zsh builtin (`(eval):log:1: too many arguments`); use `/usr/bin/log show --predicate 'subsystem == "dev.lustefaniak.prbar"' --last 5m --info`. The app's logger uses subsystem `dev.lustefaniak.prbar`, category `notifications`.

## Don't

- Don't commit `PRBar.xcodeproj/` — it's generated.
- Don't add Swift files via Xcode "Add Files…" — drop them in `Sources/PRBar/<subdir>/` and run `bin/regen`.
- This is a single-author personal repo — commits go straight to `main` (no PR gating). The global "feature branches only" rule in `~/.claude/CLAUDE.md` is overridden here. Force-with-lease still applies if rewriting history.
- Don't call `claude` with `--permission-mode default` or `bypassPermissions` from app code. See PLAN.md §"AI Review Pipeline" for the locked invocation shape.
- Don't add `Bash` / `Edit` / `Write` / `Task` / `Agent` to the AI's `--allowedTools` list. Those are deliberately disallowed; the AI is a judge, not a fixer.
- Don't drop `--quiet` from `bin/build` (test output is silenced there on purpose) or *add* it to `bin/test` (we want test pass/fail visible).
- Don't merge work without `bin/test` green locally. Integration tests catch real schema drift; ignoring them defeats the purpose.
- Don't bake company-specific or repo-specific defaults into `RepoConfig.builtins`. Repo layouts belong with the repo (planned `.prbar.yml`) or in the user's `RepoConfigStore` overrides, not in app source.
