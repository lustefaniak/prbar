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
bin/screenshots  # bin/regen + run only ScreenshotTests; rewrites docs/screenshots/*@2x.png
```

Whenever you change `project.yml` or add a new file under `Sources/` or `Tests/`, run `bin/regen` (or `bin/build`, which regenerates first) so XcodeGen picks it up.

Run a single test class:
```sh
xcodebuild -project PRBar.xcodeproj -scheme PRBar -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -only-testing:PRBarTests/PRPollerTests test
```

This is the fast feedback loop for `ScreenshotTests` and `ClaudeProviderIntegrationTests` — both write side effects (PNGs, real-API calls) you don't want firing on every full-suite run.

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

## Conventions

- **Swift 6 strict concurrency** (`SWIFT_STRICT_CONCURRENCY = complete`). Use actors for mutable shared state crossed by Sendable values. `@MainActor @Observable` for view-state classes.
- **Foundation `Process` + temp files** for subprocess work; do *not* migrate to `swift-subprocess` ad-hoc — it's a planned future change and needs to land in one go across `ProcessRunner`.
- **No comments unless WHY is non-obvious** (a workaround, a hidden constraint, a counterintuitive ordering). Don't restate code in comments.
- **No emojis** in code, commits, or UI strings unless explicitly requested.

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
- **claude vs codex schema constraints are *opposite*.** Claude rejects schemas with `$schema` / `description` / `additionalProperties` / `minimum` / `maximum` / `maxLength`. Codex (OpenAI strict mode) *requires* `additionalProperties: false` on every object. The shared `Resources/schemas/review.json` stays minimal (claude-style); `CodexProvider.addStrictAdditionalProperties(_:)` injects the strict markers on the way out.
- **`ImageRenderer` can't capture `ScrollView` content, `Menu`, `HSplitView`, or NSControl-backed `Form` widgets** (Toggle / Slider / TextField / TextEditor / Picker render as the yellow placeholder). Production views that need to be screenshottable grow an opt-in `screenshotMode: Bool = false` parameter that swaps `ScrollView`→flat `VStack` and `Menu`→plain `Button`. Pattern lives on `PRDetailView`, `PRRowView`, `PRListView`, `RepoConfigEditor`. Settings panes are intentionally not in `ScreenshotTests` — capture manually via `screencapture -wo` against the running app.
- **`textSelection(.enabled)` fights `onTapGesture`** — every click drops a caret instead of triggering the gesture, and dragging starts a selection. Resolution pattern: branch on state — `Button` when you need tap behaviour (e.g. collapsed-to-expand), selectable `Text` when not (e.g. expanded copy/paste).
- **GFM rendering uses `swift-markdown-ui` (`MarkdownUI`)** — block-level (headings, fenced code, lists, tables, blockquotes, task lists) renders as native SwiftUI. `ImageRenderer` can't capture some of its NSAttributedString-backed views, so the screenshot path falls back to `Text(AttributedString(markdown: , .inlineOnlyPreservingWhitespace))`. Pattern lives in `MarkdownText` (Sources/PRBar/UI/MarkdownText.swift).
- **`Data.prefix(through:)` returns a SubSequence sharing storage with the source.** If you call `removeSubrange` on the source before reading the SubSequence, you'll read corrupted bytes. Materialize via `Data(buffer.prefix(through: idx))` *before* mutating. Bit `ProcessRunner.runStreaming`'s `LineBox` twice.
- **`ProcessRunner.runStreaming` termination handler must drain `takeCompleteLines()` *before* `flushTrailing()`.** Otherwise tail chunks delivered after the readability handler is nil'd get emitted as one concatenated "line" with embedded newlines.

## Don't

- Don't commit `PRBar.xcodeproj/` — it's generated.
- Don't add Swift files via Xcode "Add Files…" — drop them in `Sources/PRBar/<subdir>/` and run `bin/regen`.
- This is a single-author personal repo — commits go straight to `main` (no PR gating). The global "feature branches only" rule in `~/.claude/CLAUDE.md` is overridden here. Force-with-lease still applies if rewriting history.
- Don't call `claude` with `--permission-mode default` or `bypassPermissions` from app code. See PLAN.md §"AI Review Pipeline" for the locked invocation shape.
- Don't add `Bash` / `Edit` / `Write` / `Task` / `Agent` to the AI's `--allowedTools` list. Those are deliberately disallowed; the AI is a judge, not a fixer.
- Don't drop `--quiet` from `bin/build` (test output is silenced there on purpose) or *add* it to `bin/test` (we want test pass/fail visible).
- Don't merge work without `bin/test` green locally. Integration tests catch real schema drift; ignoring them defeats the purpose.
