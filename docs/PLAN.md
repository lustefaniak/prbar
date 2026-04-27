# PRBar — Native macOS PR Co-Pilot

A menu-bar Swift app that closes the loop on two daily pain points: *(1) babysitting CI on PRs I authored* and *(2) burning context on shallow PR reviews other people send me*. It reuses my existing `gh` auth and my Claude Max subscription via the `claude` CLI — no GitHub OAuth, no API keys.

> Working dir: `/Users/lustefaniak/getsynq/prbar`. Remote: `github.com/lustefaniak/prbar` (private). App bundle id: `dev.lustefaniak.prbar`.

---

## Status

**Phases 0, 1, 2, 3, 4, and 6 are shipped end to end. Persistence + several UX rounds beyond the original plan are in too.** 216 tests passing including real-API integration tests for both `gh` and `claude` (the latter gated by a `/tmp/prbar-run-claude-tests` sentinel since it costs real money — `bin/test` skips it by default).

The AI review pipeline works end to end in both `.none` (pure-prompt, default) and `.minimal` (read-only tools, scoped per subfolder) modes. `RepoCheckoutManager` provisions bare-clone-backed sparse worktrees per (repo, headSha), `ReviewQueueWorker` orchestrates the splitter → checkout → assembler → provider → aggregator pipeline, and `PRDetailView` shows the verdict + summary + cost + tool count alongside the unified diff with AI annotations rendered inline (severity-colored bars, click-to-expand bodies). Approve/Comment/Request-changes buttons post back via `gh pr review`.

`RepoConfig` (renamed from `MonorepoConfig`) is now the unified per-repo settings struct: exclusion, splitter shape (`.perSubfolder` / `.single`), `collapseAboveSubreviewCount` threshold, custom system prompt with `replaceBaseSystemPrompt` toggle, tool-mode override, per-subreview budget caps, and an `AutoApproveConfig` (enabled / minConfidence / requireZeroBlockingAnnotations / maxAdditions). `RepoConfigStore` persists user overrides via SwiftData; the Settings → Repositories tab is a sidebar+detail editor with built-in suggestions and an "Add from inbox" picker. Auto-approve fires through a *batched* 30-second undo banner that only appears once *every* enqueued review has settled — explicit design choice to collapse N PRs' worth of context switches into one.

**Persistence is unified on SwiftData** (`store.sqlite` in `~/Library/Application Support/io.synq.prbar/`): inbox snapshot, repo configs, AI review states, action history, parsed diffs, failed-job log tails. The shared `ModelContainer` lives in `Sources/PRBar/Persistence/PRBarModelContainer.swift`; each store opens its own `ModelContext` from the container.

### What's shipped beyond the original plan

- **Per-repo settings** (`RepoConfig` ← `MonorepoConfig`): exclusion, splitMode (`.perSubfolder` / `.single`), `collapseAboveSubreviewCount` (sprawling-PR fallback), `customSystemPrompt` + `replaceBaseSystemPrompt`, draft filter (`reviewDrafts`, default off), per-subreview tool/cost caps, `AutoApproveConfig`. Persisted via SwiftData (`RepoConfigEntry` @Model — JSON-encoded payload + `orderIndex` for editor + glob-precedence ordering); sidebar+detail editor under Settings → Repositories with an "Add from inbox" picker.
- **Review persistence** (`ReviewCache` → `ReviewStateEntry` @Model, JSON-encoded `ReviewState` payload keyed by `prNodeId`): AI verdicts survive relaunch, keyed by `(prNodeId, headSha)`. Stale detection re-queues automatically when the PR's head moves; `PRDetailView` shows an orange "review is for SHA …" banner while the new triage runs. Crashed-mid-run states downgrade to `.failed("Interrupted")` with a Re-run hint.
- **Activity trace** (`ReviewTraceParser` + `ReviewTraceView`): re-derives the AI's full timeline from `rawJson` — assistant text, tool calls (with one-line summaries + expandable JSON inputs), tool result previews, rate-limit pings, final verdict. Disclosure under the AI section. Helps build user confidence + debug prompts.
- **Annotation titles + summary list** (`AnnotationsSummaryView`): each annotation now carries a short glanceable title; sorted-by-severity list appears directly under the verdict. Click the location label to jump the inline diff to that line and pop the bubble open (`focusedDiffKey` + `ScrollViewReader`).
- **Diff persistence** (`DiffStore` + `DiffCacheEntry` @Model): cached parsed `[Hunk]` per `(prNodeId, headSha)` so detail re-opens are instant *and* survive relaunches. Only `.loaded` terminal states write through; `.loading` / `.failed` stay in-memory. Force-push naturally invalidates because the SHA changes (key includes it).
- **Subscription detection**: `ClaudeStreamParser` reads `apiKeySource` from claude's init event; cost label grays out on subscription auth (the `total_cost_usd` is API-equivalent / informational, not actually billed).
- **CI status panel** (`CIStatusView`): failed checks pinned with red shield header, pending+passed under disclosure, click-through to GitHub when `detailsUrl` / `targetUrl` available.
- **Clickable verdict badge**: the APPROVE / COMMENT / CHANGES pill under "AI Review" doubles as a one-click way to post that exact verdict to GitHub using the AI's summary as the body. Hidden on `.authored`-only PRs (no self-review).
- **Split merge button**: replaces the hover-only `…` menu when a PR is `isReadyToMerge`. Primary action is the per-repo last-used method (UserDefaults), chevron exposes alternatives. `.borderedProminent` green tint mirrors GitHub's own merge button. Secondary `…` menu (Open in browser / Refresh) stays reachable next to it.
- **Single-instance enforcement**: bundle-ID + PID check in `PRBarApp.init`; XCTest hosts exempted.
- **Right-click menu** (Settings + Quit): replaced `MenuBarExtra(.window)` with an `NSStatusItem` driven by `AppDelegate`. Left-click toggles the SwiftUI popover (still SwiftUI via `NSHostingController`); right-click opens an `NSMenu`. Settings gear icon also lives at the bottom-right of the popover for in-popover discoverability.
- **Popover sizing pinned** at 560×640 via `PRBarPopoverSize` to fix the NSPopover-collapses-to-intrinsic-size bug.
- **Annotations → diff jump + scroll-to-top**: `arrow.down.right.square` per annotation row scrolls + expands the matching bubble; floating `arrow.up.circle.fill` at bottom-right of detail view scrolls back to top.
- **Worktree sweep**: `RepoCheckoutManager.sweepStaleWorktrees()` runs at launch and removes worktree dirs > 1 h old (catches leaks from crashed previous runs). Diagnostics shows total bare-clone bytes + manual Prune button.
- **Custom app icon + status-bar icon**: rasterized from SVG into Asset Catalog (`AppIcon.appiconset`, `MenuBarIcon.imageset` template-rendered, `PopoverIcon.imageset`).
- **PR number formatting fix**: `InboxPR.numberString` avoids SwiftUI's locale grouping that was rendering `#20609` as `#20 609`.
- **Drafts skipped by default** (`RepoConfig.reviewDrafts`, opt-in per repo). Manual Re-run still works.
- **About tab**: app icon, version, copyright, authors row crediting Łukasz Stefaniak + Claude Code Opus, links to `@lustefaniak` and the source repo.
- **Versioning derived from git** (`bin/version`): `marketing` reads the latest tag (sans `v`, validated semver-shape), `build` reads `git rev-list --count HEAD` (monotonic), `describe` powers the DMG filename. `bin/build` and `bin/release-dmg` pass these to `xcodebuild` so `Info.plist` is honest. About tab reflects them at runtime.
- **Universal DMG release pipeline** (`bin/release-dmg` + `.github/workflows/release.yml`): builds an arm64+x86_64 archive, sanity-checks both slices via `lipo`, packages a UDZO DMG with an `/Applications` symlink, uploads as workflow artifact + publishes a GitHub Release on tag pushes. Pinned to `Xcode_16.0`. App is ad-hoc signed today (notarization is a follow-up).
- **Review-readiness coordinator** (`ReadinessCoordinator`): owns the "ready for human review" signal. Per-repo `NotifyPolicy` — `.batchSettled` (default) holds notifications until every in-flight AI triage settles, then fires one grouped banner; `.eachReady` keeps the old per-PR behaviour. Per-repo `aiReviewEnabled` toggle — when false the worker skips auto-enqueue and the PR enters "ready" instantly, riding the same batch as AI-triaged PRs from other repos. Replaces the per-poll `.newReviewRequest` emission from `EventDeriver`; author-side events (ready-to-merge, CI failures) still flow through there.
- **Sequential focus mode** (`PopoverView.advanceOrClose`, `@AppStorage("sequentialFocusMode")`, default on): after Approve/Comment/Request-changes, the detail pane jumps to the next ready review-requested PR instead of returning to the list. Skips drafts, already-approved PRs, and PRs whose AI triage is still running. Toggleable in General Settings.
- **Prior-review retriage** (`ReviewState.priorReview`, `PriorReview` struct, `ContextAssembler.priorReview`): when the PR's head moves, the prior `AggregatedReview` is captured on the new entry. The detail view keeps showing the previous verdict + annotations (with an orange retriage banner) while the new run executes. The new prompt gains a "Previous review" section with prior verdict, summary, and blocking annotations so the AI is framed as "did the new commits address prior concerns?" — successful retriage clears the prior; a failure keeps it so the user doesn't lose their last good triage.
- **Dynamic menu-bar badge** (`BadgeCounter`, `AppDelegate.startBadgeObservation`): status item shows a numeric count when something's actionable. Per-source toggles in General → Menu bar badge — ready-to-merge, pending review requests, authored PRs with red CI — all default on. Re-renders both on inbox change (via `withObservationTracking`) and on UserDefaults toggle flips.
- **Streaming subprocess + live review progress** (`ProcessRunner.runStreaming`, `ClaudeProvider`'s LiveState, `ReviewQueueWorker.liveProgress`): per-line `Pipe` reader (with mutex-guarded `LineBox`) replaces the temp-file redirect for `claude` runs; each parsed event updates the worker's `liveProgress` map keyed by PR. Detail view shows tools-used / current tool / cost-so-far during `.running` — no more bare spinner. Cost-cap is now enforced **live** via SIGTERM mid-stream (was post-hoc); tool-cap stays informational. Foundation `run(...)` stays for non-streamed callers (the inbox-110KB deadlock-avoidance case).
- **CI workflow** (`.github/workflows/ci.yml`): `bin/build` + `bin/test` on push to main and on every PR, pinned to `Xcode_16.0`. `concurrency` cancels stale runs when a branch is force-pushed. `gh`-dependent integration tests skip cleanly without secrets.
- **SwiftData store** (`PRBarModelContainer` + entry models): one `store.sqlite` under `~/Library/Application Support/io.synq.prbar/`. Inhabitants: `ActionLogEntry`, `ReviewStateEntry`, `RepoConfigEntry`, `InboxSnapshotEntry`, `DiffCacheEntry`, `FailureLogCacheEntry`. Schema additions are append-only — every entry stores its domain object as a JSON payload alongside a few projected query columns (timestamps, sort indexes, cache keys), so the underlying structs (`InboxPR`, `RepoConfig`, `ReviewState`, `[Hunk]`) can evolve freely without a SwiftData migration each time. In-memory containers via `PRBarModelContainer.inMemory()` give tests fresh isolated stores. Container fallback to in-memory on a corrupt store — the user loses history on restart, preferable to a stuck launch.
- **Action history** (`ActionLogStore` + `ActionLogEntry` @Model): every `gh pr review` / `gh pr merge` / auto-approve fire records one entry (success and failure both logged) with denormalized PR coords + title so the History tab keeps rendering rows after the underlying PR leaves the inbox. `HistoryView` groups by day with relative date headers, shows kind icon + PR coords + title + time + cost (when set) or error (when failed), click opens the GitHub URL.
- **Per-repo PR filters** (`RepoConfig.excludeTitlePatterns`, `RepoConfig.skipAIIfReviewedByOthers`): fnmatch-style title globs (case-insensitive, multiline editor) drop matching PRs from lists, notifications, and AI auto-enqueue at the `PRPoller` level — useful for `[Prod deploy]` / `chore: bump *` noise. The reviewer-already-weighed-in filter softer: row stays visible, AI just doesn't burn a triage on PRs that already have an APPROVED / CHANGES_REQUESTED decision from someone else. Live config edits trigger an immediate re-poll so existing inbox entries reflect the new rules without waiting 60s.
- **Forward-compatible RepoConfig codable**: explicit `init(from:)` decodes every field via `decodeIfPresent ?? <default>`, so adding new fields to the struct never breaks stored payloads in `RepoConfigEntry`. The Hashable / Encodable / Equatable conformances stay synthesized.
- **Incremental `RepoConfigStore.save`**: in-place updates by `orderIndex` replace the earlier delete-all + reinsert pattern, so a single encode failure mid-batch can no longer wipe the entire user config store. Side benefit: SwiftData row identity is preserved across edits (no churn per keystroke through the editor's TextField bindings).
- **Split-button Approve** (`@AppStorage("approveIncludesComment")`, default false): primary action posts `gh pr review --approve` with no body; chevron always exposes the with-comment alternative one click away. Avoids the trivial "approve" body posted by accident; the General Settings toggle flips the default.
- **"Reset all data" lever** (Settings → Diagnostics): deletes `store.sqlite` + `-shm` / `-wal` sidecars, clears the app's UserDefaults persistent domain, then `open -n`s a fresh instance and quits. Destructive alert confirmation. Belt-and-suspenders for the in-memory fallback path on a corrupt store — you can launch but want a clean slate from inside the app.

### Still to do — ranked by value

**High value, low effort:**
1. **Refresh PR after action** — `PRPoller.postReview` already calls `refreshPR` after success, but (a) GitHub's GraphQL view sometimes lags the write so the refreshed `reviewDecision` is still stale, and (b) the auto-approve fire path in `ReviewQueueWorker.fireBatch` doesn't refresh at all. Add a short delay before the post-action refresh + wire the worker's auto-approve completion to `PRPoller.refreshPR`. ~½ day.
2. **Drag-to-reorder repo rules** — sidebar list in Settings → Repositories. Order matters for glob-match precedence; today the only way to reorder is delete + recreate. `.onMove` on the `List` + persist via `setAll`. Lands cleaner alongside the config-UUID change so row identity survives reorder.
3. **Config UUID for stable identity** — `RepoConfig` matches by `repoGlobs.joined(",")` today; editing globs invalidates the row id and the `@State draft` fix is a band-aid. Adding a `var id: UUID = UUID()` to `RepoConfig` (with the row's persisted id adopted on first read for old payloads) makes the editor's identity story deterministic. Pairs naturally with reorder.
4. **Auto-update** — *recommend Sparkle* over building it. ~1 day end-to-end (SPM dep, EdDSA keys, `appcast.xml` on `gh-pages`, `sign_update` step in the release workflow, "Check for Updates…" item in the right-click menu). Lighter alternative: in-popover "Update available" banner that compares Bundle.main version to the latest GH Release tag.
5. **Marketing screenshots** — the ImageRenderer-based `ScreenshotTests` suite was removed; replacement plan is full-app captures (run the real app against fixture data, `screencapture -wo`). Production views still carry the harmless `screenshotMode: Bool = false` opt-in flag in case we want a programmatic capture path again.
6. **Provider judge / multi-AI** — only worth it if real workload shows single-`claude` review missing things often enough to justify 2× cost + latency. Not a near-term default.

**Polish + safety:**
7. **Notification action buttons** — `UNUserNotificationCenter` categories are wired; routing delegate that turns "Merge all" / "Open" / "Undo" taps into actions isn't implemented. Auto-approve banner is also popover-only today; a real notification banner would let undo work without opening the app.
8. **Bigger PR detail window** — separate `Window` scene at full size for large diffs (popover stays for triage). Already prototyped in the design; ~½ day.
9. **Codex per-subfolder + multi-judge** — `CodexProvider` ships and `RepoConfig.providerOverride` already lets you pick claude or codex per repo. Still open: per-subfolder provider routing + multi-judge aggregation. *Skip* until real workload shows single-provider is missing things; multi-judge doubles cost for a maybe-improvement.
10. **Sparse-checkout** — `RepoCheckoutManager` checks out the full SHA today; sparse-by-subpath shrinks worktree disk use and lines up with the per-PR exclude list (`.env*` / `*.pem`).
11. **Bare-clone LRU eviction** — manual Prune button shipped; automatic 5 GB cap not yet wired.
12. **Branch-protection cache** — no `BranchProtectionCache.swift` yet; the inbox query drops `CheckRun.isRequired` because of a `gh` quirk, so the "required-only" filtering called for in the spec is missing.
13. **DMG notarization** — Developer ID cert + AC API key + `xcrun notarytool` step in the release workflow. Removes the right-click-Open Gatekeeper warning on first launch for non-technical users.
14. **Delta-diff fetch on retriage** — prior-verdict prompt context is in (see Prior-review retriage above). Still open: fetch `gh api repos/{o}/{r}/compare/{old}...{new}` and feed *only the delta diff* to the AI when retriaging. Cost win, not a quality win.

**Phase 5 / 7 remnants:**
15. **Pure-prompt mode polish** — in `.none` mode, the assembler doesn't inline `<subpath>/CLAUDE.md` (capped at 8 KB) the way the spec called for. Important for repos where you've turned off code exploration but still want the per-subfolder voice.
16. **Cost dashboard** — sum of `costUsd` per day/week broken out by repo / tool-mode. With `ActionLogEntry.costUsd` already populated for auto-approves, this is now a query + chart on top of the existing SwiftData store. Lower priority on a subscription (cost is informational anyway).

Notable divergences from the original spec, tracked here so they don't get lost:

1. **Persistence consolidated on SwiftData**, but the entry models hold JSON-encoded payloads instead of fully relational `@Model`s for the domain structs. Reasons: (a) `InboxPR` / `ReviewState` / `RepoConfig` evolve frequently and the JSON-blob layout means no SwiftData schema migration on every change; (b) the app doesn't actually need relational queries against the nested fields. Projected query columns (timestamps, sort indexes, unique cache keys) sit alongside the payload so list views and lookups stay cheap.
2. **`CheckRun.isRequired` is not queried.** gh CLI emits ~3 stderr "PR ID required" errors per PR (and exits 1) when this field is in the GraphQL query, even though stdout JSON is valid — a gh-side quirk, confirmed via curl that the GitHub API itself accepts the field. Workaround: drop the field; "required" will come from the REST branch-protection cache later (the canonical source anyway).
3. **Subprocess** — Foundation `Process` still, not `swift-subprocess`. Now has two paths: `ProcessRunner.run(...)` keeps the temp-file redirection for large non-streamed outputs (the inbox-110KB Pipe-deadlock case); `ProcessRunner.runStreaming(...)` uses `Pipe` + a readability handler with mutex-guarded line buffering for `claude` (so we get live progress + SIGTERM-on-overrun). swift-subprocess remains a future swap when there's a clear additional win.
4. **`claude --json-schema` is picky about JSON Schema dialect.** `$schema`, `description`, `additionalProperties`, `minimum`, `maximum`, and `maxLength` cause `claude` to hang silently. Bisected on 2026-04-26; the GitHub API itself accepts these (verified via curl), so it's a `claude` CLI / API constraint. `Resources/schemas/review.json` sticks to `type` + `enum` + `required` + `properties` only; range/length validation moves client-side. `PromptLibraryTests.testOutputSchemaHasNoConstraintsClaudeRejects` is the regression net.
5. **`claude` cost-cap is now live SIGTERM** (was post-hoc). Each parsed event re-checks the cap; overrun terminates the child mid-stream and surfaces as `ClaudeError.budgetExceeded`. Tool-call cap stays informational — claude in plan mode fires ambient tools we can't enumerate in `--disallowedTools` (Skill, Monitor, MCP integrations) — typically 1–2 calls.
6. **Notifications fire title/body but not yet action buttons.** `UNUserNotificationCenter` is wired with categories; routing the `[Merge all] [Open]` / `[Undo]` action callbacks needs a `UNUserNotificationCenterDelegate` (small follow-up).
7. **Repo-allowed merge methods are honored.** `Repository.{merge,squash,rebase}MergeAllowed` already reflects `requiresLinearHistory` (GitHub auto-flips `mergeCommitAllowed` to false). Plumbed through to `InboxPR.allowedMergeMethods` and the row's "⋯" menu hides forbidden methods. `PRPoller.mergePR` rejects disallowed methods server-side. Verified against `getsynq/cloud` (squash + rebase only).
8. **Per-PR refresh** — surfaced as a hover button + menu item in addition to the global poll. Cheaper than re-running `fetchInbox` (1 GraphQL point vs 25), wasn't in the original spec but obvious once you're babysitting one specific CI run.

---

## Context

**Why this exists.** I delegate work to Claude Code in worktrees and ask it to open PRs. After that I have to *remember* to come back and merge — which means tab-thrashing GitHub or polling notifications. Separately I get a steady stream of review requests where the right call is usually "approve" but I still pay the full context-switch tax to look at the diff. Both are interrupt-driven, low-value workflows that deserve to be batched and assisted.

**Why a native app, not a browser extension or web tool.** Menu-bar presence is the entire UX point — one icon glance to know "anything actionable?", one click for the action, no browser tab. Native lets me shell out to `gh` and `claude` (which a browser cannot) and reuse the user's existing CLI auth.

**Why now.** macOS 14+ (`MenuBarExtra` window style), Swift 6.2+ (`Subprocess` package, Sept 2025), and Claude Code's `--output-format json --json-schema` (which gives a parseable structured contract for AI verdicts) all reached production-quality recently. The pieces line up.

**Two firm design rules** (everything else flows from these):

- **The AI is a *judge*, not a *fixer*.** It gets read-only filesystem access scoped to a single monorepo subfolder, plus web fetch/search for validating external claims, plus whatever MCP tools that subfolder's `.mcp.json` provides. It cannot write files, run shell commands, or spawn subagents. The system prompt explicitly tells it to minimize exploration and prefer abstaining to speculating. Tool calls and dollar cost are hard-capped per review.
- **Monorepos are first-class, not retrofitted.** `getsynq/cloud` is a 60+ module monorepo (`kernel-*`, `lib/*`, `api`, `fe-app`, `dev-infra`, …) with per-module `CLAUDE.md` / `.mcp.json` / `AGENTS.md`. A PR touching three kernels gets three subfolder-scoped reviews, each running with that subfolder as cwd so Claude resolves per-module configs automatically, then verdicts aggregate into one overall outcome.

**Out of scope, deliberately.** No GitHub auth handling, no token storage, no SCM operations beyond what `gh` does, no full-page web UI, no team/multi-user features, no CI orchestration.

---

## Goals & Non-Goals

### Goals (MVP, ranked)
1. **Notice when my PRs become mergeable** (CI green + approved + no conflicts) and offer a one-click merge.
2. **Surface incoming review requests** in a queue; for each, run an AI review in the background and present a verdict + diff with flagged areas.
3. **Minimal-tools AI reviews by default**: AI runs with read-only access scoped to one monorepo subfolder, plus WebFetch/WebSearch, plus per-subfolder MCP tools. No Bash, no writes, no subagents. Hard caps on tool-call count and cost.
4. **Native monorepo support**: split the diff per subfolder, run a per-subfolder Claude review (so each picks up its own `CLAUDE.md` / `.mcp.json` / `.claude/settings.json` via cwd resolution), aggregate verdicts.
5. **Batch notifications** so I'm interrupted at most once per "settled" cycle, never per individual state transition.
6. **Reuse subscriptions, never store secrets.** The app shells out to `gh` and `claude` — both of which the user has already authenticated.
7. **Pluggable AI provider** via `ReviewProvider` protocol; ship Claude only in v1, design so adding `codex`/`gemini` is purely additive.

### Non-Goals
- No GitHub Web UI replacement. Drilling into a PR for serious review still goes to github.com via "Open in browser".
- No AI auto-actions by default. Auto-approve is opt-in, gated by per-repo + per-author rules.
- No backend. State lives on disk in `~/Library/Application Support/io.synq.prbar/`.
- No "fix the PR" mode. The AI is a reviewer, not a contributor.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│ MenuBarExtra (icon, badge counts: ⬢ 2 ready · 5 review) │
└─────────────────────────────────────────────────────────┘
                          │ click
                          ▼
┌─────────────────────────────────────────────────────────┐
│ Popover Window (segmented: My PRs | Inbox | History)    │
│  ┌─────────────────┐  ┌────────────────────────────┐   │
│  │ PR row (status, │  │ Detail pane                │   │
│  │ checks, reviews)│  │  - Aggregated AI verdict    │   │
│  │ [primary action]│  │  - Per-subfolder breakdown  │   │
│  └─────────────────┘  │  - Diff with annotations    │   │
│                       │  - Action buttons           │   │
│                       └────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                          │
   ┌──────────────────────┼─────────────────────────┐
   ▼                      ▼                         ▼
┌────────┐         ┌──────────────┐          ┌──────────┐
│ Poller │         │ ReviewQueue  │          │ Notifier │
│ (gh)   │         │ Worker       │          │ (UN…)    │
└────────┘         │  ├ Splitter  │          └──────────┘
   │               │  ├ Checkout  │                │
   │               │  ├ Assembler │                │
   │               │  ├ Provider* │                │
   │               │  └ Aggregator│                │
   │               └──────────────┘                │
   ▼                      │                        ▼
┌────────────────────────────────────────────────────────┐
│ SwiftData store (PRSnapshot, ReviewRun, Subreview, …)  │
└────────────────────────────────────────────────────────┘
                                 │
                                 ▼ (clones-of-record)
                  ~/Library/Application Support/io.synq.prbar/
                    ├── repos/getsynq/cloud.git       (bare)
                    ├── worktrees/<sha>/              (transient per-review)
                    ├── prompts/*.md
                    ├── schemas/review.json
                    └── store.sqlite
```

**Three concurrent actors, plus a managed clone pool:**
- **`PRPoller`** — every 60s (configurable) shells out to `gh api graphql` with one batched query for "PRs involving @me", diffs against the last snapshot, writes to SwiftData, signals state changes.
- **`ReviewQueueWorker`** — drains a serial queue of pending AI reviews. For each PR: `MonorepoSplitter` → N subdiffs → `RepoCheckoutManager` provisions a worktree at the PR's head SHA → `ContextAssembler` builds the prompt for each subdiff → `ReviewProvider` runs `claude` per subreview (concurrency-bounded) with cwd set to the subfolder → `ResultAggregator` produces one PR-level verdict.
- **`Notifier`** — translates state changes into user-visible signals. Coalesces: holds events in a 60s "settling window" before firing a single grouped notification. Suppresses while the popover is open.
- **`RepoCheckoutManager`** — maintains a single bare clone per repo, plus transient worktrees per (repo, headSha). On each review: `git fetch origin <headSha> --depth=50 --filter=blob:none`, then `git worktree add <tempdir> <headSha>`. After the review run completes (success or failure), `git worktree remove <tempdir>`. Worktrees for the same SHA are shared across that PR's subreviews. Sparse-checkout configured to only include the subfolders the splitter identified.

---

## Data Model

The original plan called for SwiftData `@Model`s end-to-end. The shipped design uses a hybrid: domain structs (`InboxPR`, `RepoConfig`, `ReviewState`, `[Hunk]`, …) stay as plain `Sendable` `Codable` values, and a thin layer of SwiftData `@Model` "entry" rows (`ActionLogEntry`, `ReviewStateEntry`, `RepoConfigEntry`, `InboxSnapshotEntry`, `DiffCacheEntry`, `FailureLogCacheEntry`) wraps each value with a JSON-encoded payload + a few projected query columns (timestamps, sort indexes, unique cache keys). Trade: we get persistence and `@Query`-friendly columns without paying SwiftData migration costs every time a domain struct gains or renames a field. The "planned (@Model end-to-end)" sketches below are kept as historical reference, not as work to do.

### Shipped (Phase 1)

```swift
struct InboxPR: Identifiable, Sendable, Hashable, Codable {
    var id: String { nodeId }
    let nodeId: String
    let owner: String; let repo: String; let number: Int
    let title: String; let body: String; let url: URL
    let author: String; let headRef: String; let baseRef: String
    let isDraft: Bool
    let role: PRRole                              // .authored | .reviewRequested | .both | .other
    let mergeable: String                         // MERGEABLE | CONFLICTING | UNKNOWN
    let mergeStateStatus: String                  // CLEAN | BLOCKED | DIRTY | …
    let reviewDecision: String?                   // APPROVED | REVIEW_REQUIRED | CHANGES_REQUESTED
    let checkRollupState: String                  // SUCCESS | PENDING | FAILURE | ERROR | EMPTY
    let totalAdditions: Int; let totalDeletions: Int; let changedFiles: Int
    let hasAutoMerge: Bool; let autoMergeEnabledBy: String?
    let allCheckSummaries: [CheckSummary]
    // Repo-level merge policy (mirrors GitHub branch-protection effects):
    let allowedMergeMethods: Set<MergeMethod>     // {.squash, .rebase} for getsynq/cloud
    let autoMergeAllowed: Bool
    let deleteBranchOnMerge: Bool
}

struct CheckSummary: Sendable, Hashable, Codable {
    let typename: String         // "CheckRun" | "StatusContext"
    let name: String
    let conclusion: String?      // CheckRun
    let status: String?          // CheckRun status or StatusContext state
    // isRequired deliberately absent — see Status §2
}
```

### Planned (Phase 2+ — SwiftData)

```swift
@Model final class PRSnapshot {
    @Attribute(.unique) var nodeId: String        // GraphQL global node ID
    var owner: String; var repo: String; var number: Int
    var title: String; var body: String; var url: URL
    var author: String; var headRef: String; var baseRef: String
    var headSha: String                           // for diff cache + monorepo checkout
    var isDraft: Bool
    var role: PRRole                              // .authored | .reviewRequested | .both
    var mergeStateStatus: String                  // MERGEABLE | CONFLICTING | UNKNOWN | BEHIND | …
    var reviewDecision: String?                   // APPROVED | REVIEW_REQUIRED | CHANGES_REQUESTED
    var checkRollup: String                       // SUCCESS | PENDING | FAILURE | ERROR
    var requiredChecks: [String]                  // names of *required* contexts (filtered)
    var failingChecks: [String]
    var pendingChecks: [String]
    var hasAutoMerge: Bool
    var unreadCommentCount: Int
    var lastSeenAt: Date
    var firstSeenReadyAt: Date?
    var totalAdditions: Int                       // for auto-approve gating
    var totalDeletions: Int
    var changedFiles: Int
}

@Model final class ReviewRun {                    // one row per PR review attempt
    @Attribute(.unique) var id: UUID
    var prNodeId: String
    var diffSha: String                           // commit SHA the review was against
    var providerName: String                      // "claude" | "codex" | "gemini"
    var modelName: String
    var triggeredAt: Date; var completedAt: Date?
    var status: ReviewStatus                      // .queued | .running | .completed | .failed | .skipped
    var aggregatedVerdict: ReviewVerdict?         // .approve | .comment | .requestChanges | .abstain
    var aggregatedConfidence: Double?
    var aggregatedSummaryMarkdown: String?
    var totalCostUsd: Double?
    var totalToolCalls: Int                       // sum across subreviews
    @Relationship(deleteRule: .cascade) var subreviews: [Subreview] = []
}

@Model final class Subreview {                    // one per monorepo subfolder
    @Attribute(.unique) var id: UUID
    var reviewRunId: UUID
    var subpath: String                           // e.g. "kernel-billing", "lib/auth", "" = repo root
    var verdict: ReviewVerdict?
    var confidence: Double?
    var summaryMarkdown: String?
    var annotations: [DiffAnnotation]             // {path, lineStart, lineEnd, severity, body}
    var rawProviderJson: Data?                    // includes tool-use trace for audit
    var costUsd: Double?
    var toolCallCount: Int                        // how many tool calls the AI made
    var toolNamesUsed: [String]                   // e.g. ["Read", "Grep", "WebFetch"] — for diagnostics
    var promptTemplateId: String
    var toolMode: ToolMode                        // .minimal (default) | .none (pure-prompt opt-in)
    var status: SubreviewStatus
}

@Model final class ActionLog {                    // every gh write the app made
    @Attribute(.unique) var id: UUID
    var at: Date
    var prNodeId: String
    var kind: ActionKind                          // .approve | .merge | .comment | .requestChanges | .autoApprove
    var initiator: ActionInitiator                // .user | .autoRule(ruleId)
    var ghCommand: String                         // exact command we ran, for audit
    var success: Bool; var stderr: String?
}

@Model final class AutoApproveRule {
    @Attribute(.unique) var id: UUID
    var name: String; var enabled: Bool
    var repoGlob: String                          // e.g. "getsynq/*", "!getsynq/cloud"
    var authorGlob: String                        // e.g. "dependabot[bot]", "*"
    var maxAdditions: Int
    var minConfidence: Double
    var requireZeroBlockingAnnotations: Bool      // ignore .info / .suggestion; block on .warning / .blocker
    var providerName: String
}

@Model final class MonorepoConfig {
    @Attribute(.unique) var id: UUID
    var repoGlob: String                          // e.g. "getsynq/cloud"
    var rootPatterns: [String]                    // ordered, fnmatch-style
    var unmatchedStrategy: UnmatchedStrategy      // .reviewAtRoot | .skipReview | .groupAsOther
    var minFilesPerSubreview: Int
    var toolModeOverride: ToolMode?               // nil = global default, else force per-repo (e.g. .none for security-sensitive repos)
    var maxParallelSubreviews: Int                // e.g. 4 — cap fanout for a single PR
    var maxToolCallsPerSubreview: Int             // overrides global default
    var maxCostUsdPerSubreview: Double            // overrides global default
}
```

`PRRole`, `ReviewVerdict`, `Severity` (info/suggestion/warning/blocker), `ToolMode` (`.minimal` | `.none`), `UnmatchedStrategy` etc. live in `Models/Enums.swift`. Glob matching uses `fnmatch`-style.

---

## GitHub Integration Layer

All access via `gh` CLI subprocess — never raw HTTPS. One file, `Services/GitHub/GHClient.swift`.

### Discovery (single GraphQL query)
```graphql
query Inbox {
  viewer { login }
  search(query: "is:pr is:open involves:@me archived:false", type: ISSUE, first: 50) {
    edges { node { ... on PullRequest { ...PRFields } } }
  }
  rateLimit { remaining cost resetAt }
}

fragment PRFields on PullRequest {
  id number title body url isDraft additions deletions changedFiles
  repository {
    nameWithOwner
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
    autoMergeAllowed deleteBranchOnMerge
  }
  author { login }
  headRefName baseRefName
  mergeable mergeStateStatus reviewDecision
  autoMergeRequest { enabledBy { login } }
  reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
  reviews(last: 20) { nodes { state author { login } submittedAt body } }
  comments(last: 10) { nodes { author { login } createdAt body } }
  commits(last: 1) {
    nodes { commit {
      oid
      statusCheckRollup {
        state
        contexts(first: 30) {
          nodes {
            __typename
            ... on CheckRun     { name conclusion status detailsUrl summary }
            ... on StatusContext { context state targetUrl description }
          }
        }
      }
    } }
  }
}
```

The same fragment is reused by `GraphQLQueries.singlePR` (per-PR refresh; ~1 point instead of ~25). `viewer { login }` rides along so role (`.authored` / `.reviewRequested` / `.both`) is computed client-side without a second roundtrip. `repository.{merge,squash,rebase}MergeAllowed` drives the row "⋯" menu. `CheckRun.isRequired` and `StatusContext.isRequired` are *not* queried — see Status §2 for the gh quirk.

Run via `gh api graphql -F login=@me -f query='…' --jq '.data'`. Cost ~25 GraphQL points/cycle for ≤50 PRs. **30s is the floor, default 60s, allow 15s burst while popover is open** and any PR is mid-CI. At 60s, full-day usage ≈ 1500 pts/hr (30% of the 5000 limit).

### Branch protection cache
Per-repo `gh api /repos/{owner}/{repo}/branches/{branch}/protection`, cached to disk (`Caches/branchProtection.json`) with 24h TTL. Used to filter `statusCheckRollup.contexts` down to *required* checks for the badge / "ready to merge" computation.

### Diff fetch (lazy, on-demand)
```bash
gh pr diff <num> --repo <owner>/<repo>
```
Cached per `(prNodeId, headSha)` in `Caches/diffs/<prNodeId>-<sha>.diff` — keyed by SHA so a force-push invalidates automatically.

### Failed-check log fetch (for prompt assembly)
For any `CheckRun` with `conclusion in [FAILURE, ERROR]`:
```bash
gh run view <run-id> --repo <owner>/<repo> --log-failed --job <job-id>
```
Tail to last ~200 lines per failed job (cap total budget at ~8KB across all failures) and include in the AI prompt under "## CI failures". This turns "the AI doesn't know why CI failed" into "the AI sees the actual stack trace".

### Write actions (always confirmed or rule-gated)
| Intent | Command |
|---|---|
| Approve | `gh pr review <n> --repo <owner>/<repo> --approve --body "<msg>"` |
| Comment | `gh pr review <n> --repo <owner>/<repo> --comment --body "<msg>"` |
| Request changes | `gh pr review <n> --repo <owner>/<repo> --request-changes --body "<msg>"` |
| Merge | `gh pr merge <n> --repo <owner>/<repo> --squash` |
| Enable auto-merge | `gh pr merge <n> --repo <owner>/<repo> --squash --auto` |

Every write is logged to `ActionLog` *before* execution begins (with `success=false`) and updated on completion.

### Auth check
On launch: `gh auth status --hostname github.com` — if not authenticated, the popover shows a single-screen onboarding pointing at `gh auth login` and the relevant scopes (`repo`, `read:org`).

---

## AI Review Pipeline

Five concerns, each its own component. The pipeline is the load-bearing piece of the app — the rest is plumbing.

```
PR appears → Splitter → Checkout → Assembler ⇄ Provider → Aggregator → ReviewRun persisted
                │           │           │          │
                │           │           │          └─ minimal tools by default,
                │           │           │             scoped to subpath (cwd + --add-dir),
                │           │           │             read-only, no Bash, no writes
                │           │           │
                │           │           └─ assembles prompt (diff slice + meta + comments
                │           │              + CI failure logs) — tools are escape hatch,
                │           │              not primary context
                │           │
                │           └─ shallow worktree at PR head SHA (one per repo,
                │              shared across that PR's subreviews)
                │
                └─ groups diff hunks by monorepo root (uses MonorepoConfig)
```

### 1. `MonorepoSplitter`

Input: `PRSnapshot` + raw diff. Output: `[Subdiff]` where each `Subdiff = { subpath, hunks, files }`.

Algorithm:
1. Look up `MonorepoConfig` matching `owner/repo`. If none, return one `Subdiff{ subpath: "", hunks: <all> }`.
2. Parse the diff into hunks (`DiffParser`); each hunk knows its file path.
3. For each hunk, find the *longest* matching `rootPattern` for its file path. (`kernel-billing/foo.go` matches `kernel-*`; `lib/auth/token.go` matches `lib/*`; `README.md` matches nothing.)
4. Group hunks by matched root. Hunks with no match go to the bucket dictated by `unmatchedStrategy`:
   - `.reviewAtRoot` — single "" subpath subreview with the unmatched hunks.
   - `.skipReview` — drop them (e.g. `.md` changes alone).
   - `.groupAsOther` — single subpath `"<other>"` subreview.
5. Drop subdiffs with fewer than `minFilesPerSubreview` files (fold into unmatched bucket per strategy).
6. Cap fanout at `maxParallelSubreviews`; if exceeded, sort by file count desc and merge tail subdiffs into the "<other>" bucket.

Default `MonorepoConfig` shipped for `getsynq/cloud`:
```swift
MonorepoConfig(
    repoGlob: "getsynq/cloud",
    rootPatterns: [
        "kernel-*", "lib/*",
        "api", "api_public", "app-slack", "fe-app",
        "dev-infra", "dev-tools", "dev-helpers",
        "proto", "proto_public", "playbooks", "Taskfiles"
    ],
    unmatchedStrategy: .reviewAtRoot,
    minFilesPerSubreview: 1,
    toolModeOverride: nil,        // use global default = .minimal
    maxParallelSubreviews: 4,
    maxToolCallsPerSubreview: 10,
    maxCostUsdPerSubreview: 0.30
)
```

### 2. `RepoCheckoutManager`

Maintains one bare clone per repo at `~/Library/Application Support/io.synq.prbar/repos/<owner>/<repo>.git`, with shallow history.

Provisioning a review worktree:
```bash
# First time for this repo (one-shot):
git clone --bare --depth=50 --filter=blob:none https://github.com/<owner>/<repo>.git <repos>/<owner>/<repo>.git

# Per review:
cd <repos>/<owner>/<repo>.git
git fetch --depth=50 --filter=blob:none origin <headSha>
git worktree add --no-checkout <worktrees>/<headSha> <headSha>
cd <worktrees>/<headSha>
git sparse-checkout init --cone
git sparse-checkout set <subpath1> <subpath2> ...      # only the subreviews' subpaths
git checkout
```

`--filter=blob:none` keeps the bare repo small; blobs fault in lazily as Read tools touch files. `--depth=50` covers nearly all real PRs while keeping clone size sane.

After all subreviews for a `(repo, headSha)` complete:
```bash
git worktree remove <worktrees>/<headSha>
```

Concurrent reviews of *different* SHAs in the same repo each get their own worktree (no contention). Concurrent subreviews of the *same* SHA share the worktree, with cwd pointing at different subpaths.

`gh repo clone` is a fine alternative for the first-time clone (uses `gh`'s auth for private repos), but plain `git clone` over HTTPS uses the user's existing git credential helper which already handles `gh`'s token.

Per-PR exclude list (sparse-checkout never includes): `.env*`, `*.pem`, `*.key`, `.token`, `secrets/**`. Belt-and-braces alongside `--permission-mode plan`.

### 3. `ContextAssembler`

Input: `PRSnapshot` + one `Subdiff` + `PromptTemplate` + checkout path. Output: a `PromptBundle = { systemMd, userMd, fileList, workdir }` ready to hand to a `ReviewProvider`.

The user-side prompt is a single Markdown blob with these sections (in order):

```markdown
# Pull Request Review

You are reviewing a pull request. You have read-only access to files under
`./` (this subfolder), plus WebFetch/WebSearch for verifying external claims.

**Use tools sparingly.** The diff and brief below should be enough for most
reviews. Reach for tools only to:
- look at how a changed identifier is used elsewhere in this subfolder,
- verify a specific external claim (e.g. an RFC or CVE referenced in the diff),
- consult a library doc when the diff uses an API you're unsure about.

If after a couple of targeted lookups the diff is still too opaque, return
`abstain` rather than guessing. **Never attempt to fix the PR.**

## PR
- **Repo**: getsynq/cloud
- **Number**: #4821
- **Title**: feat: add audit log to billing API
- **Author**: @somebody
- **Base → Head**: main → feat/audit-log
- **Size**: +312 / -47 across 8 files

## PR description
<full body>

## Subfolder under review
`kernel-billing` (1 of 3 subreviews for this PR; cwd is set here)

## Files changed in this subreview
- kernel-billing/audit/log.go (new, +120)
- kernel-billing/audit/log_test.go (new, +80)
- kernel-billing/api/handler.go (+12 / -5)
- …

## Existing review comments (do not repeat)
- @reviewer-a (2026-04-25): "Consider adding a benchmark for the hot path."
- @reviewer-b (2026-04-26): "LGTM modulo the test."

## CI status
- ✓ aggregate_status (SUCCESS)
- ✗ Test kernel-billing (FAILURE) — see logs below
- ⏳ Lint (PENDING)

## CI failures (last 200 lines per failed job)
```
<truncated tail of `gh run view --log-failed`>
```

## Diff
```diff
<unified diff sliced to this subfolder>
```
```

System prompt (from `prompts/system-base.md`, override-able by language and per-repo):

> You are a senior software engineer reviewing a pull request. Be terse. Focus on correctness, safety, concurrency, security, and clarity. Ignore style nits unless they affect readability. Output **strictly** the JSON matching the provided schema. Set `verdict` to `approve` only if you would press the merge button. Use `request_changes` only for blockers — for non-blocking improvements, use `comment`. Use `abstain` if the diff is too small/opaque to judge. Minimize tool use; you are budgeted for at most ~10 tool calls per review.

`prompts/golang.md`, `typescript.md`, `swift.md`, etc. are appended when the subdiff's majority file extension matches.

In `.minimal` mode, `<subpath>/CLAUDE.md` is **not** inlined in the prompt — Claude Code resolves it (and the root `CLAUDE.md`, walking up) automatically because cwd matches. In `.none` mode, the assembler does inline `<subpath>/CLAUDE.md` (capped at 8KB) since there's no cwd resolution path.

### 4. `ReviewProvider` (protocol)

```swift
protocol ReviewProvider {
    var id: String { get }                 // "claude"
    var displayName: String { get }
    func availability() async -> Availability   // .ready | .notInstalled | .notLoggedIn(reason)
    func review(bundle: PromptBundle, options: ProviderOptions) async throws -> ProviderResult
}

struct ProviderOptions {
    var model: String?                  // e.g. "opus"
    var toolMode: ToolMode              // .minimal (default) | .none
    var workdir: URL                    // always required — cwd for the subprocess
    var addDirs: [URL]                  // additional --add-dir paths (default: [workdir])
    var maxToolCalls: Int               // hard cap; default 10
    var maxCostUsd: Double              // hard cap; default 0.30
    var timeout: Duration               // default 120 s (more than pure-prompt because tools take time)
    var schema: Data                    // JSON Schema for structured_output
}

struct ProviderResult {
    let verdict: ReviewVerdict
    let confidence: Double
    let summaryMarkdown: String
    let annotations: [DiffAnnotation]
    let costUsd: Double?
    let toolCallCount: Int
    let toolNamesUsed: [String]
    let rawJson: Data
}
```

### v1 Claude implementation

File: `Services/Providers/ClaudeProvider.swift`. Two invocation modes share most of the call:

**Minimal-tools mode (default):**
```bash
cd "$workdir"            # the monorepo subfolder, e.g. .../worktrees/<sha>/kernel-billing
claude -p \
  --output-format stream-json \
  --verbose \
  --json-schema "$(cat schemas/review.json)" \
  --model opus \
  --append-system-prompt "$systemMd" \
  --add-dir "$workdir" \
  --permission-mode plan \
  --disallowedTools "Bash,Edit,Write,Task,Agent,NotebookEdit,TodoWrite" \
  <<< "$userMd"
```

Allowed tools end up being `Read, Glob, Grep, WebFetch, WebSearch` plus any MCP tools that resolve from `<workdir>/.mcp.json` (or from walking up the tree). `--permission-mode plan` is a hard backstop — even if a write tool sneaks through, it gets simulated.

The provider streams the JSONL output line by line, counting tool calls in real time. If `toolCallCount > maxToolCalls` or accumulated cost > `maxCostUsd`, send SIGTERM, wait 2s, SIGKILL. Final `result` event carries the `structured_output` (already validated by Claude against the JSON schema) and `total_cost_usd`.

**Pure-prompt mode (opt-in via `MonorepoConfig.toolModeOverride = .none` or per-rule):**
```bash
cd "$(mktemp -d)"        # fresh empty cwd — nothing to read
claude -p \
  --output-format json \
  --json-schema "$(cat schemas/review.json)" \
  --model opus \
  --append-system-prompt "$systemMd" \
  --disallowedTools "Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,Agent,NotebookEdit,TodoWrite" \
  --permission-mode plan \
  <<< "$userMd"
```

Single JSON object response, no streaming needed. Useful when reviewing a PR for a repo not yet cloned, or when the user wants strict reproducibility.

### Output schema (`Resources/schemas/review.json`)
```json
{
  "type": "object",
  "required": ["verdict", "confidence", "summary", "annotations"],
  "properties": {
    "verdict":    { "enum": ["approve", "comment", "request_changes", "abstain"] },
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
    "summary":    { "type": "string", "maxLength": 1200 },
    "annotations": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path", "line_start", "line_end", "severity", "body"],
        "properties": {
          "path":       { "type": "string" },
          "line_start": { "type": "integer", "minimum": 1 },
          "line_end":   { "type": "integer", "minimum": 1 },
          "severity":   { "enum": ["info", "suggestion", "warning", "blocker"] },
          "body":       { "type": "string", "maxLength": 800 }
        }
      }
    }
  }
}
```

Parse the wrapper JSON, pull `structured_output`, pull `total_cost_usd`, count tool-use events for `toolCallCount` / `toolNamesUsed`. Done.

### 5. `ResultAggregator`

Combines per-subreview `ProviderResult`s into one PR-level outcome:

| Field | Aggregation |
|---|---|
| `verdict` | Worst across subreviews. Order: `request_changes` > `comment` > `approve` > `abstain`. |
| `confidence` | `min` across subreviews (only those that returned a verdict). |
| `summary` | `## <subpath>\n<summary>\n\n` concatenated, in order. |
| `annotations` | All merged, with `path` rewritten to repo-relative (`kernel-billing/audit/log.go`, not `audit/log.go`). |
| `costUsd` | Sum across subreviews. |
| `toolCallCount` | Sum across subreviews. |
| `rawJson` | Wrapped object `{ subreviews: [...]}` for debugging. |

If *any* subreview failed (provider error, timeout, budget exceeded), the PR-level review status is `.failed` with a per-subreview breakdown — but partial successes are still surfaced in the UI.

### 6. `AutoApprovePolicy`

On every successful aggregated `ReviewRun`, evaluate enabled `AutoApproveRule`s in priority order. First match wins:
1. Repo glob matches `nameWithOwner`.
2. Author glob matches PR author.
3. PR additions ≤ `maxAdditions`.
4. Aggregated verdict == `.approve`.
5. Aggregated confidence ≥ `minConfidence`.
6. If `requireZeroBlockingAnnotations`, no annotation has severity `warning` or `blocker` (in *any* subreview).

If matched: enqueue an `Action(.autoApprove)` with a 30s user-visible "Undo" banner in the popover before actually running `gh pr review --approve`. Logged in `ActionLog` with `initiator = .autoRule(rule.id)`.

---

## UI Specification

### Menu bar icon
- Idle: monochrome glyph (use `text.bubble` SF Symbol initially).
- Has actionable items: tinted accent color + badge count, e.g. "2".
- Tooltip on hover: `"2 ready to merge · 5 awaiting review"`.

### Popover window (`MenuBarExtra` style `.window`, ~520 × 680)
Three tabs (`Picker` with segmented style):
1. **My PRs** — PRs I authored, sorted: ready-to-merge → has-comments → conflicting → failing → in-flight → draft.
2. **Inbox** — review requests for me, sorted: ready-with-verdict → in-progress → queued → skipped.
3. **History** — last 50 actions taken, with undo for recent auto-approves.

**Row layout (compact):**
```
●  feat: add audit log to billing API                getsynq/cloud #4821
   ✓ checks  ✓ approved  ⚠ 2 unread comments         [ Merge ▾ ]
```

**Detail pane (right of the row, 60% width):**
- Header: title, author, base→head, "Open in browser" link.
- Status strip: per-required-check chip (green/yellow/red), reviewer chips, mergeable state badge.
- AI section (Inbox tab only):
  - Aggregated verdict badge + confidence bar + cost + tool-call count.
  - **Per-subfolder breakdown** (collapsible) — for monorepo PRs, each subreview as a sub-row with its own verdict/summary/annotation count + tools used, click to focus.
  - Action buttons: `[Approve] [Comment] [Request changes] [Skip] [Re-run]`.
- Diff view: parsed unified diff rendered as `AttributedString` in a `ScrollView`; lines with annotations get a left-edge color bar (severity color) and a click-to-expand annotation balloon. Subreview filter chips at top of diff (click `kernel-billing` to scope view).

Diff renderer: pure Swift — split on `diff --git`, then per-hunk parse `@@` headers and prefix-color `+`/`-`/` ` lines. SF Mono, 12pt. No third-party syntax highlighter in MVP.

### Settings (separate full window, opened via `Settings` scene + Cmd+, / SettingsLink)
Six sections planned, two shipped:
- ✅ **General** — launch at login (`SMAppService.mainApp.register()`). *Planned: poll interval, popover hotkey.*
- ✅ **Diagnostics** — current `gh` / `claude` / `git` resolved paths + versions. *Planned: recent `ActionLog`, "Reveal data folder", disk usage.*
- ◌ **GitHub** — `gh auth status` output, list of orgs/repos detected, exclude list.
- ◌ **AI Provider** — current provider (Claude only in v1), model picker, default tool mode (`.minimal` / `.none`), prompt-template editor.
- ◌ **Monorepo configs** — table editor for `MonorepoConfig` rows; default `getsynq/cloud` ships pre-populated. Per-repo overrides for tool mode, tool-call cap, cost cap.
- ◌ **Auto-approve rules** — table editor for `AutoApproveRule` rows.

### Notifications (UNUserNotificationCenter)
- ✅ **Coalesced**: 60s settling window resets on every new event; one delivery summarizes everything (`"PRBar: 1 ready to merge, 2 reviews"`).
- ✅ **Suppressed** while popover is open; resumes ~500 ms after close.
- ✅ **Dedup** by `(kind, prNodeId)` — same PR flipping back and forth between polls only notifies once per state.
- ✅ **First-poll silence**: skip notifications on the very first successful poll after launch, so opening the app doesn't fire 5 "ready to merge" banners.
- ◌ **Action buttons** (`[Merge all] [Open]` / `[Undo] [Open]`): categories are set on the request but not yet routed. Needs a `UNUserNotificationCenterDelegate`.
- Respects system Focus modes natively; no extra logic.

---

## Concurrency, Polling, Cost Budget

| Knob | Default | Bound |
|---|---|---|
| Poll interval (popover closed) | 60 s | 30–600 s |
| Poll interval (popover open) | 15 s | 10–60 s |
| Subreviews in flight per PR | up to `MonorepoConfig.maxParallelSubreviews` (default 4) | 1–8 |
| AI reviews in flight (across PRs) | 2 | 1–4 |
| AI per-subreview timeout | 120 s | 30–600 s |
| Tool-call cap per subreview | 10 | 0 (= pure-prompt) – 50 |
| Cost cap per subreview | $0.30 | $0.05 – $2.00 |
| Notification coalescing window | 60 s | 0–300 s |
| Auto-approve undo window | 30 s | 0 disables auto |
| Branch-protection cache TTL | 24 h | 1–168 h |
| Daily AI spend cap | $5/day | 0 = unlimited |
| Worktree retention after review | 5 min | 0 (delete now) – 60 min |
| Bare clone retention | forever (LRU evict at 5 GB total) | — |

`PRPoller` backs off 2× when `ProcessInfo.processInfo.isLowPowerModeEnabled` is true. `ReviewQueueWorker` refuses to enqueue once the day's `Subreview.costUsd` sum exceeds the cap.

**Cost arithmetic.** Pure-prompt single-subreview: ~$0.02. Minimal-tools single-subreview with a few Read/Grep calls: ~$0.05–$0.15. A multi-root PR with 3 subreviews: ~$0.15–$0.45. Hard cap of $0.30/subreview keeps any single subreview from running away. Daily cap of $5 = ~30 reviews on a busy day, plenty.

---

## Tech Stack & Project Layout

- **Language**: Swift 6.0+, SwiftUI, async/await, strict concurrency.
- **Min OS**: macOS 14 (`MenuBarExtra` `.window`, `SMAppService`, `SwiftData`, `@Observable`).
- **Project tooling**: XcodeGen — `project.yml` is in git, `PRBar.xcodeproj` is generated and gitignored. Build/test/run via `bin/` wrappers (no direct `xcodegen` / `xcodebuild` in normal flow).
- **Subprocess** *(shipped)*: Foundation `Process` + temp-file redirection (avoids 64 KB Pipe-buffer deadlock). Migration to `swift-subprocess` is a follow-up.
- **Storage** *(shipped)*: SwiftData store at `~/Library/Application Support/io.synq.prbar/store.sqlite`. Inhabitants: `ActionLogEntry`, `ReviewStateEntry`, `RepoConfigEntry`, `InboxSnapshotEntry`, `DiffCacheEntry`, `FailureLogCacheEntry`. Each entry carries its domain object as a JSON-encoded payload alongside projected query columns (timestamps, sort indexes, unique cache keys), so the underlying structs can evolve without a SwiftData schema migration. Container construction lives in `Sources/PRBar/Persistence/PRBarModelContainer.swift`; an `inMemory()` factory backs unit tests.
- **No third-party deps** in MVP.
- **Distribution**: ad-hoc-signed local build for personal use; Developer ID + notarization later if shared. Not sandboxed (subprocess access required).

Project layout (current tree — see `tree Sources/PRBar` for an exact listing):

```
PRBar/
├── project.yml                                  # XcodeGen spec (PRBar.xcodeproj is gitignored)
├── bin/{regen,build,test,run,version,release-dmg}
├── docs/PLAN.md                                 # this file
├── Sources/PRBar/
│   ├── PRBarApp.swift                           # @main + Settings scene (popover lives in AppDelegate)
│   ├── AppDelegate.swift                        # NSStatusItem owner, service wiring
│   ├── Models/                                  # InboxPR, Enums, RepoConfig, ReviewTypes, Hunk,
│   │                                            #   Subdiff, ReviewTrace + the SwiftData @Model entries
│   │                                            #   (ActionLog, ReviewStateEntry, RepoConfigEntry,
│   │                                            #   InboxSnapshotEntry, DiffCacheEntry, FailureLogCacheEntry)
│   ├── Persistence/
│   │   └── PRBarModelContainer.swift            # shared SwiftData container + schema list
│   ├── Services/
│   │   ├── GitHub/                              # GHClient, GraphQLQueries, InboxResponse,
│   │   │                                        #   DiffStore, FailureLogStore
│   │   ├── Review/                              # MonorepoSplitter, RepoCheckoutManager,
│   │   │                                        #   ContextAssembler, ResultAggregator,
│   │   │                                        #   ReviewProvider (+ Claude/Codex), ReviewQueueWorker
│   │   ├── Providers/                           # ClaudeProvider + stream parser; CodexProvider
│   │   ├── PRPoller.swift                       # @MainActor @Observable: poll + delta + refresh + merge
│   │   ├── SnapshotCache.swift                  # actor over the SwiftData InboxSnapshotEntry
│   │   ├── ReviewCache.swift                    # SwiftData ReviewStateEntry wrapper
│   │   ├── RepoConfigStore.swift                # SwiftData RepoConfigEntry wrapper
│   │   ├── ActionLogStore.swift                 # SwiftData ActionLogEntry wrapper
│   │   ├── ReadinessCoordinator.swift           # AI-pending → ready-for-human bit
│   │   ├── BadgeCounter.swift                   # status-item badge text
│   │   ├── Notifier.swift + NotificationEvent.swift
│   │   ├── AutoApprovePolicy.swift              # pure function — gates auto-approve fire
│   │   └── LaunchAtLogin.swift                  # SMAppService wrapper
│   ├── UI/
│   │   ├── PopoverView.swift                    # tab container (Inbox / My PRs / History)
│   │   ├── MyPRsView, InboxView, HistoryView
│   │   ├── PRRowView, PRListView, PRDetailView
│   │   ├── DiffView, AnnotationsSummaryView, SubreviewBreakdownView
│   │   ├── CIStatusView, AutoApproveBanner, MarkdownText, ReviewTraceView
│   │   ├── ToolAvailabilityView
│   │   └── Settings/                            # SettingsRoot, General/Diagnostics/Repositories/About
│   └── Util/                                    # ExecutableResolver, ProcessRunner, ToolProbe,
│                                                #   DiffParser, GlobMatcher, DiffAnnotationCorrelator,
│                                                #   CIFailureLogTail
└── Resources/
    ├── schemas/review.json
    └── prompts/{system-base,golang,typescript,swift}.md
```

---

## Implementation Roadmap

### Phase 0 — Skeleton (½ day) ✅ shipped
- ✅ XcodeGen-driven project (`project.yml` is the source of truth; `PRBar.xcodeproj` is gitignored). App target, macOS 14+, no sandbox, `LSUIElement = true`.
- ✅ `MenuBarExtra(.window)` with the popover.
- ✅ `SMAppService.mainApp.register()` toggle (now in Settings → General).
- ✅ Tool-availability smoke: `gh` / `claude` / `git` resolved via `ExecutableResolver`.
- ✅ `bin/regen`, `bin/build`, `bin/test`, `bin/run` wrappers.

### Phase 1 — MVP loop, no AI (2 days) ✅ shipped
- ✅ `GHClient.fetchInbox()` runs the inbox GraphQL query, decodes via `InboxResponse`, maps to `[InboxPR]`. Plus `GHClient.fetchPR(...)` for cheap per-PR refresh.
- ✅ `PRPoller` (`@MainActor @Observable`) with 60s timer, delta detection (added/removed/changed), idempotent start/stop, fixture-injectable for tests.
- ✅ `SnapshotCache` persists the latest `[InboxPR]` via SwiftData (`InboxSnapshotEntry`); `loadCached()` seeds state on launch.
- ✅ Tabs: `MyPRsView` (role `.authored` / `.both`, sorted ready-to-merge first), `InboxView` (role `.reviewRequested` / `.both`, sorted not-yet-reviewed first), `HistoryView` (placeholder).
- ✅ Per-PR refresh button + global refresh button.
- ✅ Per-row "⋯" menu: Open in browser (`NSWorkspace.open`), Refresh, Squash/Merge/Rebase (filtered by `allowedMergeMethods`, with confirmation dialog).
- ✅ `Notifier` with 60s settling window, popover-open suppression, dedup by (kind, prNodeId). Title/body delivery via `UNUserNotificationCenter`.
- ✅ `EventDeriver` (pure function): turns `(PollDelta, oldPRs)` into `[NotificationEvent]` for `.readyToMerge`, `.newReviewRequest`, `.ciFailed`. Suppresses notifications on the very first poll after launch.
- ✅ Settings scene: General (launch at login), Diagnostics (tool availability).
- ⚠️ **Demo gate partially met**: notifications fire title/body but action buttons (Merge / Open inbox / Undo) aren't wired yet — small follow-up.

### Phase 2 — Minimal-tools AI review, single subreview (2.5 days)
- `DiffParser`, `MonorepoSplitter` (no monorepo configs yet, returns single subdiff for whole PR with `subpath = ""`).
- `RepoCheckoutManager` real implementation — bare clones, sparse worktrees, lifecycle.
- `ContextAssembler` building the prompt bundle (meta + diff + comments + CI failure logs; no inlined CLAUDE.md in `.minimal`).
- `ReviewProvider` protocol + `ClaudeProvider` (minimal-tools mode); `ClaudeStreamParser` doing JSONL event parsing, tool-call counting, budget enforcement, kill-on-overrun.
- `Resources/schemas/review.json` + ship default prompts.
- `ResultAggregator` (trivial: pass-through for single subreview).
- `ReviewQueueWorker` actor; auto-enqueues every new `.reviewRequested` PR; concurrency bound 2.
- `PRDetailView` AI section: verdict, summary, action buttons, cost, tool-call count.
- **Demo gate**: incoming review request shows a Claude verdict + summary within ~120s, with "used Read 2x, Grep 1x, $0.07" visible; clicking Approve posts the review.

### Phase 3 — Diff with annotations (1 day) ✅ shipped
- ✅ `DiffParser` already in place; `DiffView` renders hunks with SF-Mono colored prefixes (added/removed/context), file-group headers with collapsible chevrons + `+N/-N` counts, hunk header strip in purple.
- ✅ `DiffAnnotationCorrelator` (pure function, table-tested) maps `DiffAnnotation` (path + new-side line range) onto each hunk's line indices; `.removed` lines are never annotated.
- ✅ Severity-colored leading bar per line (info/suggestion/warning/blocker), click expands an inline annotation bubble with the body text.
- ✅ `DiffStore` (@MainActor @Observable) caches parsed `[Hunk]` per (prNodeId, headSha) — force-push invalidates automatically. `PRDetailView.onAppear` triggers lazy fetch via the shared `gh pr diff` fetcher.
- ✅ Subpath filter chips render when `AggregatedReview.perSubreview.count > 1` (no-op for single-subdiff PRs today, ready for Phase 4 multi-root).
- **Demo gate met**: AI annotations show inline in the diff at the right line ranges; the multi-subreview filter chips are wired but currently latent (single subdiff).

### Phase 4 — Monorepo splitting + per-subfolder reviews (1.5 days) ✅ shipped
- ✅ `MonorepoConfig` (struct, Codable) + `UnmatchedStrategy` enum + bundled default for `getsynq/cloud` (`kernel-*`, `lib/*`, `api`, `fe-app`, `dev-infra`, etc., `maxParallelSubreviews = 4`). Built-in registry via `MonorepoConfig.match(owner:repo:)` falls back to `.default`.
- ✅ `GlobMatcher` (fnmatch-style) supports `*`, `**`, `?`, escape of regex metachars, gitignore-style negation lists. Specificity ranking ensures `lib/auth` beats `lib/*` beats `*`.
- ✅ Real `MonorepoSplitter`: longest-match grouping per hunk, `unmatchedStrategy` (`.reviewAtRoot` / `.skipReview` / `.groupAsOther`), `minFilesPerSubreview` filter, fanout cap with tail-merge of smallest buckets into the unmatched bucket. Resolved subpath uses the literal file segment (`kernel-billing`, not `kernel-*`).
- ✅ `ReviewQueueWorker` picks the matching `MonorepoConfig` per PR, applies its `toolModeOverride`, and uses its per-subreview `maxToolCalls`/`maxCostUsd` caps. Worktree is shared across same-SHA subreviews; each subreview's cwd is `<worktree>/<subpath>` so per-subfolder `CLAUDE.md` / `.mcp.json` resolves automatically.
- ✅ `ResultAggregator` already worst-verdict + concat + annotation path-rewrite (Phase 2c).
- ✅ `SubreviewBreakdownView` collapsible per-subfolder list shown in `PRDetailView` when `agg.perSubreview.count > 1`. Diff-view subpath chips activate at the same threshold.
- ◌ Sparse-checkout per the splitter's identified subpaths is *not* yet enabled (`RepoCheckoutManager` checks out the full SHA today). Follow-up — small change but needs care around the per-PR exclude list.
- ◌ `MonorepoConfigsSettings` editor is still on the to-do list (configs ship as code-defined builtins for now).
- **Demo gate met**: a PR touching `kernel-billing` + `lib/auth` in `getsynq/cloud` produces 2 subreviews sharing one worktree, with two separate verdicts aggregated to one outcome and per-subfolder breakdown visible in the UI.

### Phase 5 — Pure-prompt mode (½ day)
- `ClaudeProvider` pure-prompt code path (already designed; just implement).
- `ContextAssembler` inlines `<subpath>/CLAUDE.md` when `toolMode == .none`.
- Setting toggle: per-`MonorepoConfig.toolModeOverride`, plus a global default in AI Provider settings.
- **Demo gate**: a `MonorepoConfig` with `toolModeOverride = .none` produces a review with `toolCallCount == 0`, `costUsd ≈ $0.02`, and the `<subpath>/CLAUDE.md` content visible in the assembled prompt's debug dump.

### Phase 6 — Auto-approve policy (½ day) ✅ shipped
- ✅ `AutoApprovePolicy.evaluate(pr:review:config:)` — pure function, table-tested across 8 cases (disabled, non-approve verdict, low confidence, blocking annotation, info-only annotation, too-big PR, unlimited additions, happy path).
- ✅ Per-repo `AutoApproveConfig` (enabled, minConfidence, requireZeroBlockingAnnotations, maxAdditions) lives inside `RepoConfig`; editor is a section of the Repositories settings tab.
- ✅ **Batched** 30-second undo banner in the popover. Critical design: the banner does *not* appear until **every** enqueued review has settled (`isInFlight == false` across the whole worker). Reduces context switches — N approvals → one banner, one timer, one undo button.
- ✅ Two actions on the banner: "Undo" cancels the whole batch; "Approve now" fires immediately. Otherwise the timer fires `gh pr review --approve` after 30 s with body "Auto-approved by PRBar (NN% confidence)."
- ◌ `auto_approved` UNUserNotificationCenter category — not yet routed (would land alongside the action-button work).
- **Demo gate met**: Dependabot-style PR with autoApprove enabled, high confidence, no blocking annotations → AI completes → batch undo banner appears once the inbox is settled → 30 s later the approval posts (or sooner via "Approve now"; never via "Undo").

### Phase 7 — Polish (rolling)
- `History` tab with action log + filtering.
- Cost dashboard (sum of `costUsd` per day/week, broken out by provider/subreview/tool-mode).
- ✅ Bare-clone disk usage view + manual Prune button (in Diagnostics).
- ◌ Automatic LRU eviction at the 5 GB cap.
- ◌ Sparse-checkout per the splitter's identified subpaths in `RepoCheckoutManager` — small, but tied to the per-PR exclude list (`.env*` etc.).
- Provider abstraction proven by stubbing `CodexProvider` (deferred until codex's headless contract is more mature).
- Diagnostics panel.

Total MVP (phases 0–4): ~7 days. Pure-prompt + auto-approve adds ~1 day.

---

## Verification

### Per-phase manual check
Each phase's demo gate (above) is the acceptance test — run it against a real PR I open in `getsynq/cloud` (the multi-root case) plus one in a single-root public repo (`getsynq/sqlparser-rs`).

### Automated tests (where they pay back)
- `DiffParser` — pure function, golden-file tests against captured `gh pr diff` outputs.
- `MonorepoSplitter` — table tests covering: single-root PR, multi-root PR, unmatched-only PR, mixed match+unmatched, fanout cap.
- `RepoCheckoutManager` — integration tests against a fixture bare repo (no network), verifying worktree provisioning, sharing across same-SHA reviews, cleanup on success and failure.
- `ContextAssembler` — snapshot test of one assembled prompt for a fixture PR (lock down the prompt shape so changes are intentional).
- `ClaudeStreamParser` — table tests on captured JSONL streams: normal completion, mid-stream tool-budget exceeded, mid-stream cost-budget exceeded, malformed event.
- `ResultAggregator` — table tests covering verdict precedence, confidence min, annotation path-rewriting.
- `GlobMatcher` — table tests.
- `AutoApprovePolicy.evaluate(_:)` — table tests covering every rule combination.
- `GHClient` GraphQL response parsing — fixture-based.

### `gh`, `claude`, `git` smoke checks on launch
On every cold start:
```bash
gh auth status --hostname github.com
gh api graphql -f query='query { viewer { login } }' --jq '.data.viewer.login'
claude --version
claude -p --output-format json --json-schema '{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}' "respond with {\"ok\":true}"
git --version
```
Surface failures as in-popover banners, not crashes.

### Cost guardrail
Daily spend cap in Settings (default $5). `ReviewQueueWorker` reads cumulative `Subreview.costUsd` from today's runs and refuses to enqueue past the cap. Per-subreview cost shown in the row footer. Overrun mid-review triggers SIGTERM via `ClaudeStreamParser`.

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `gh` rate limit (5k GraphQL pts/hr) blown by aggressive polling | Default 60s + cost-meter telemetry. Backoff on `rateLimit.remaining < 500`. |
| Claude CLI changes its JSON shape | Keep parser tolerant; pin to known `claude --version` and warn on mismatch. Provider returns `rawJson` for debugging. |
| `mergeStateStatus = UNKNOWN` on freshly pushed PRs | Treat as "computing", retry next poll, never surface as error. |
| Force-push on a PR after AI reviewed it | Cache key includes `headSha`; stale review invalidated, re-queued. New worktree provisioned automatically. |
| Auto-approve fires on something I'd have caught manually | 30s undo + `ActionLog` with exact `gh` command. Default `requireZeroBlockingAnnotations = true` and `minConfidence = 0.85`. |
| GUI app can't find `gh`/`claude`/`git` (PATH issue) | `ExecutableResolver` tries `/opt/homebrew/bin`, `/usr/local/bin`, `~/.claude/local/bin`, then a user-overridable absolute path in Settings. |
| `claude -p` hangs or runs away on tool calls | Hard 120s timeout per subreview + per-subreview tool-call cap (10) + cost cap ($0.30), enforced via streaming JSONL parse with SIGTERM-then-SIGKILL on overrun. |
| Sandboxing prevents subprocess use | Ship un-sandboxed; document in About. Mac App Store is out of scope. |
| Claude Max usage limits | Surface per-row cost; backoff in `ReviewQueueWorker` if `is_error == true && api_error_status == "rate_limited"`. |
| Monorepo splitter explodes on a PR touching 20 modules | `maxParallelSubreviews` cap + tail-merging into `<other>` bucket. |
| AI reads sensitive files (`.env`, `*.pem`, `*.key`, `.token`) in the worktree | (a) Sparse-checkout omits these patterns by default. (b) `--permission-mode plan` blocks writes. (c) Read access is scoped to the subpath via `--add-dir`, not the whole repo. (d) `rawProviderJson` includes the tool-use trace so the user can audit what was read. (e) Power user can flip the repo to `toolMode = .none` for paranoia. |
| AI uses WebFetch to exfiltrate something | WebFetch is GET-only, so payload exfil is limited to URL params. Tool-call cap (10) and cost cap ($0.30) bound the damage. Power user can flip the repo to `.none` mode where WebFetch is disabled. |
| Repo cache eats disk | Bare clones use `--filter=blob:none --depth=50`. LRU evict at 5 GB total. Worktrees auto-removed 5 min after the last subreview using them completes. Settings shows current usage. |
| Concurrent reviews of different SHAs in same repo race on git operations | Per-repo lock around `git fetch` + `git worktree add` (cheap). Different worktrees are isolated. |
| Context window blown by huge diffs | `ContextAssembler` truncates per-file diff at configurable threshold (default 1500 lines/file) with explicit "[truncated]" marker. Monorepo splitting alone shrinks the worst case dramatically. |
| AI ignores the "minimize tool use" directive | Hard tool-call cap (default 10) is the enforcement. Cost cap is the second backstop. Both are visible per row so I can tune them per-repo. |
| **(realized in Phase 1)** Foundation Pipe deadlocks on >64 KB output | `ProcessRunner` redirects stdout/stderr to temp files instead of `Pipe()`. Files have no buffer cap; gh's full inbox response (~110 KB) flows through unblocked. |
| **(realized in Phase 1)** gh CLI emits hundreds of "PR ID required" stderr lines on certain GraphQL fields | Identified via bisection: `CheckRun.isRequired` is the trigger (gh side, not GitHub API; raw curl works). Workaround: drop the field from the query; we'll get "required" from the REST branch-protection cache (canonical source anyway) when that lands. |
| **(realized in Phase 1)** `involves:@me` returns PRs where I'm a *past* commenter or reviewer, not currently assigned | These get `PRRole.other` and intentionally don't appear in My PRs or Inbox tabs. Integration test relaxed to allow `.other` (it's not an error). Could surface as a 4th "Watching" tab if there's appetite. |
| **(realized in Phase 1)** GitHub returns `null` for context entries the viewer can't see (e.g. private fork) | `InboxResponse.NullableNodeList<T>` allows `[T?]`; `InboxPR` mapping uses `compactMap` to drop nulls. |

---

## Open Items (decide during implementation)

- **Notification icon when only "comments" arrived but PR isn't mergeable**: badge or no? Lean: yes, lower priority than ready-to-merge.
- **Inbox sort tiebreaker**: by AI confidence desc, then PR age asc?
- **What "skip" means in the inbox**: hides the PR from the badge for 24h, but still polls. Re-appears if new commits land.
- **Per-PR re-run review**: keyboard shortcut `⌘R` in detail pane, with confirm if cost > $0.20.
- **Provider abstraction** for codex/gemini lands in v8 once Claude flow is solid; protocol is already designed for it.
- **Dependabot prompt variant**: should bot PRs use a stripped-down prompt (no "look for security issues, look for bugs" — only "did the version bump look sane")? Probably yes; pairs naturally with auto-approve rules for `dependabot[bot]`.
- **`AGENTS.md` vs `CLAUDE.md`**: `getsynq/cloud` has both at root. In `.minimal` mode, Claude Code resolves both natively. In `.none` mode, the assembler only inlines `CLAUDE.md` for now.
- **Cross-subfolder context** (e.g. `kernel-billing` reviewer wants to peek at `proto/audit.proto`): out of MVP. Future `MonorepoConfig.alwaysAccessibleSubpaths: [String]` could allow `--add-dir` for shared schemas.

---

## Critical files

- `project.yml` — XcodeGen spec; the only place project config can be edited.
- `Sources/PRBar/PRBarApp.swift` + `AppDelegate.swift` — scene composition + the live service objects (`PRPoller`, `Notifier`, `ReviewQueueWorker`, `DiffStore`, `FailureLogStore`, `RepoConfigStore`, `ReadinessCoordinator`, `ActionLogStore`).
- `Sources/PRBar/Persistence/PRBarModelContainer.swift` — the SwiftData container + schema list; new `@Model` types must be appended here.
- `Sources/PRBar/Services/GitHub/GHClient.swift` — single source of truth for all GitHub interaction (`fetchInbox`, `fetchPR`, `fetchDiff`, `mergePR`, `postReview`, `fetchJobLog`).
- `Sources/PRBar/Services/GitHub/{GraphQLQueries,InboxResponse}.swift` — the GraphQL query + Codable mirror.
- `Sources/PRBar/Services/GitHub/{DiffStore,FailureLogStore}.swift` — read-through caches over the SwiftData entries; force-push and job-rerun naturally invalidate via the cache key.
- `Sources/PRBar/Services/PRPoller.swift` — heartbeat actor; holds `[InboxPR]`, drives delta detection, dispatches refresh / merge / review-post; writes ActionLog entries on success and failure.
- `Sources/PRBar/Services/{SnapshotCache,ReviewCache,RepoConfigStore,ActionLogStore}.swift` — the SwiftData wrappers. Each opens its own `ModelContext` from the shared container.
- `Sources/PRBar/Services/{Notifier,NotificationEvent,ReadinessCoordinator,BadgeCounter}.swift` — actionable-state derivation + delivery.
- `Sources/PRBar/Services/Review/RepoCheckoutManager.swift` — bare clones + transient sparse worktrees; the only place that touches the real filesystem outside the SwiftData store; mistakes here cause data loss or disk bloat.
- `Sources/PRBar/Services/Review/ContextAssembler.swift` — defines the prompt shape; shapes the AI's behavior more than any other file.
- `Sources/PRBar/Services/Review/ReviewQueueWorker.swift` — drives the splitter → checkout → assembler → provider → aggregator pipeline; owns the auto-approve batch + ActionLog write-through on fire.
- `Sources/PRBar/Services/Providers/ClaudeProvider.swift` + `ClaudeStreamParser.swift` — exact `claude -p` invocation; the only place that enforces the tool-call and cost budgets in real time. Bug here = runaway costs.
- `Sources/PRBar/Services/AutoApprovePolicy.swift` — pure function; only place that can gate an unattended action.
- `Sources/PRBar/UI/DiffView.swift` + `AnnotationsSummaryView.swift` + `SubreviewBreakdownView.swift` + `PRDetailView.swift` + `HistoryView.swift` + `CIStatusView.swift` — the inbox + history UX.
- `Resources/schemas/review.json` — defines the AI output contract; changing it is breaking for users' custom prompts.
- `Resources/prompts/{system-base,golang,typescript,swift}.md` — bundled defaults; users override per-repo via `RepoConfig.customSystemPrompt`.

---

## Why this shape, not another

- **Minimal scoped tools by default, not zero tools** — the AI is a *judge*, but a useful judge sometimes needs to look at one adjacent file or verify an external claim. Scoping to the subfolder via `--add-dir`, blocking writes via `--permission-mode plan`, blocking exec/spawn via `--disallowedTools`, and capping tool-calls + cost gives the productivity of an agent with most of the safety of a pure prompt. The "AI tries to fix the PR" failure mode is removed by the system prompt directive plus the lack of `Edit`/`Write`/`Bash`.
- **Web tools left enabled** — verifying "this fixes CVE-2024-12345" or "matches the spec at <RFC link>" is exactly the kind of task an AI reviewer should handle. WebFetch is GET-only; risks are bounded by the same caps that bound everything else.
- **Per-subfolder cwd, not repo-root cwd** — so `<subpath>/CLAUDE.md`, `<subpath>/.mcp.json`, `<subpath>/.claude/settings.json` actually take effect (Claude Code walks up from cwd). Per-module MCP servers (e.g. a `gopls` MCP in a Go module) suddenly become free leverage.
- **Monorepo splitter as a separate component, not provider-internal** — keeps providers ignorant of repo layout; aggregator and splitter are both small pure functions easy to test.
- **Worst-verdict aggregation** — matches how a human treats multi-module PRs ("any module says block, the whole PR is blocked"). Cheap, predictable, no bespoke ML.
- **Bare clones + transient sparse worktrees** — gives every review a real filesystem path for `--add-dir` without ballooning disk usage. Sparse-checkout means we only materialize the subpaths under review (and never `.env*` / `*.pem` / `.token`).
- **One single GraphQL inbox query, not many REST polls** — fits in 25 GraphQL points so 60s polling is cheap, gives consistent snapshots, avoids the N+1 query trap.
- **Writes via `gh`, never raw HTTP** — reuses existing 2FA-protected auth; no token storage; no scope management UI.
- **Claude `--json-schema` over freeform prompt parsing** — server-side validation; if shape is wrong, explicit `is_error`, not a silent bad parse.
- **Streaming JSONL with budget enforcement** — the only safe way to give the AI tool access while keeping cost predictable. Hard kill when limits hit.
- **Auto-approve gated by 30s undo, not pure auto** — same speed for trivial PRs without losing the "I can stop it" property.
- **Vertical slice of both use cases in MVP** — the polling, snapshot, notification, and popover infrastructure is shared 90% between them.
- **No syntax highlighter dependency** — every option surveyed (Splash, Sourceful, Highlightr) hasn't seen meaningful updates in 3+ years.
