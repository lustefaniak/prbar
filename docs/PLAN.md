# PRBar — Native macOS PR Co-Pilot

A menu-bar Swift app that closes the loop on two daily pain points: *(1) babysitting CI on PRs I authored* and *(2) burning context on shallow PR reviews other people send me*. It reuses my existing `gh` auth and my Claude Max subscription via the `claude` CLI — no GitHub OAuth, no API keys.

> Project codename: **PRBar**. Working dir: `/Users/lustefaniak/getsynq/prs`. App bundle id (proposed): `io.synq.prbar`.

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

## Data Model (SwiftData)

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
query Inbox($login: String!) {
  search(query: "is:pr is:open involves:@me archived:false", type: ISSUE, first: 50) {
    edges { node { ... on PullRequest { ...PRFields } } }
  }
  rateLimit { remaining cost resetAt }
}

fragment PRFields on PullRequest {
  id number title body url isDraft additions deletions changedFiles
  repository { nameWithOwner }
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
            ... on CheckRun     { name conclusion status workflowName detailsUrl summary }
            ... on StatusContext { context state targetUrl description }
          }
        }
      }
    } }
  }
}
```

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

### Settings (separate full window, opened via `Settings` scene)
Six sections:
- **General** — launch at login (`SMAppService.mainApp.register()`), poll interval, popover hotkey.
- **GitHub** — show `gh auth status` output, list of orgs/repos detected, exclude list.
- **AI Provider** — current provider (Claude only in v1), model picker, default tool mode (`.minimal` / `.none`), prompt-template editor (opens template file in default editor with reveal-in-Finder fallback).
- **Monorepo configs** — table editor for `MonorepoConfig` rows; new-config form. Default for `getsynq/cloud` ships pre-populated. Per-repo overrides for tool mode, tool-call cap, cost cap.
- **Auto-approve rules** — table editor for `AutoApproveRule` rows.
- **About / diagnostics** — versions of `gh`, `claude`; recent `ActionLog` viewer; "Reveal data folder" button; disk usage of repo cache.

### Notifications (UNUserNotificationCenter)
- **Coalesced**: a 60s settling window after any state change. After it elapses, fire one notification summarizing all actionable items: `"3 PRs ready: 2 to merge, 1 review verdict ready"`.
- **Suppressed** while popover is open.
- Categories with actions:
  - `merge_ready` → `[Merge all] [Open]`
  - `reviews_ready` → `[Open inbox]`
  - `auto_approved` → `[Undo] [Open]` (only when an auto-rule acted, with the 30s undo window)
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

- **Language**: Swift 6.0+, SwiftUI, async/await.
- **Min OS**: macOS 14 (`MenuBarExtra` `.window`, `SMAppService`, `SwiftData`).
- **Subprocess**: `swift-subprocess` (Apple, Swift 6.2+).
- **Storage**: SwiftData (`~/Library/Application Support/io.synq.prbar/store.sqlite`).
- **No third-party deps** in MVP.
- **Distribution**: ad-hoc-signed local build for personal use; Developer ID + notarization later if shared. Not sandboxed (subprocess access required).

```
PRBar/
├── Package.swift
├── PRBar.xcodeproj
├── Sources/PRBar/
│   ├── PRBarApp.swift                       # @main, MenuBarExtra scene, Settings scene
│   ├── Models/
│   │   ├── PRSnapshot.swift
│   │   ├── ReviewRun.swift
│   │   ├── Subreview.swift
│   │   ├── ActionLog.swift
│   │   ├── AutoApproveRule.swift
│   │   ├── MonorepoConfig.swift
│   │   ├── PromptTemplate.swift
│   │   └── Enums.swift
│   ├── Services/
│   │   ├── GitHub/
│   │   │   ├── GHClient.swift               # subprocess wrapper around `gh`
│   │   │   ├── GraphQLQueries.swift         # static query strings
│   │   │   ├── BranchProtectionCache.swift
│   │   │   ├── DiffCache.swift
│   │   │   └── CIFailureLogFetcher.swift    # `gh run view --log-failed`
│   │   ├── Review/
│   │   │   ├── MonorepoSplitter.swift       # diff → [Subdiff]
│   │   │   ├── RepoCheckoutManager.swift    # bare clones + transient worktrees
│   │   │   ├── ContextAssembler.swift       # Subdiff + PR meta → PromptBundle
│   │   │   ├── ResultAggregator.swift       # [ProviderResult] → PR-level outcome
│   │   │   └── ReviewQueueWorker.swift      # actor that drives the pipeline
│   │   ├── Providers/
│   │   │   ├── ReviewProvider.swift         # protocol
│   │   │   ├── ClaudeProvider.swift         # v1 only
│   │   │   ├── ClaudeStreamParser.swift     # JSONL event parser, tool-call counter, budget killer
│   │   │   └── ProviderRegistry.swift
│   │   ├── PRPoller.swift                   # actor that drives discovery
│   │   ├── AutoApprovePolicy.swift          # rule evaluation
│   │   └── Notifier.swift                   # UNUserNotificationCenter wrapper
│   ├── UI/
│   │   ├── PopoverRoot.swift                # tab container
│   │   ├── MyPRsView.swift
│   │   ├── InboxView.swift
│   │   ├── HistoryView.swift
│   │   ├── PRRowView.swift
│   │   ├── PRDetailView.swift
│   │   ├── SubreviewBreakdownView.swift     # per-subfolder chips + summaries + tools used
│   │   ├── DiffView.swift                   # AttributedString-based renderer
│   │   ├── AnnotationOverlay.swift
│   │   └── Settings/
│   │       ├── SettingsRoot.swift
│   │       ├── GeneralSettings.swift
│   │       ├── GitHubSettings.swift
│   │       ├── AIProviderSettings.swift
│   │       ├── MonorepoConfigsSettings.swift
│   │       └── AutoApproveRulesSettings.swift
│   └── Util/
│       ├── ExecutableResolver.swift          # finds gh/claude/git in /opt/homebrew/bin etc.
│       ├── DiffParser.swift                  # unified-diff → [Hunk]
│       ├── GlobMatcher.swift
│       └── CoalescedSignal.swift             # 60s settling window helper
└── Resources/
    ├── schemas/review.json
    ├── monorepo-configs/getsynq-cloud.json   # bundled default
    └── prompts/
        ├── system-base.md
        ├── golang.md
        ├── typescript.md
        └── swift.md
```

---

## Implementation Roadmap

### Phase 0 — Skeleton (½ day)
- Create Xcode project (App target, macOS 14+, no sandbox, `LSUIElement = true`).
- `MenuBarExtra(.window)` showing a static "Hello" popover.
- `SMAppService.mainApp.register()` toggle wired to a `@AppStorage` boolean.
- Verify `Subprocess` package resolves; smoke `which gh && which claude && which git`.

### Phase 1 — MVP loop, no AI (2 days)
- `GHClient.fetchInbox()` running the GraphQL query above; map JSON → `PRSnapshot`s.
- `PRPoller` actor with 60s timer, persists snapshots, computes deltas.
- `MyPRsView` + `InboxView` rendering rows from SwiftData via `@Query`.
- "Open in browser" + "Merge" actions wired to `gh pr merge`.
- `Notifier` with coalesced firing + popover-open suppression.
- **Demo gate**: I push a PR, see it appear; CI goes green and I get one notification with a working merge button. Same flow for incoming review requests (no AI yet).

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

### Phase 3 — Diff with annotations (1 day)
- `DiffView` rendering hunks with `AttributedString`, color-coded prefixes.
- `AnnotationOverlay` correlating `DiffAnnotation` ranges to rendered lines, severity bars + click-to-expand bodies.
- **Demo gate**: AI annotations show inline in the diff at the right line ranges.

### Phase 4 — Monorepo splitting + per-subfolder reviews (1.5 days)
- `MonorepoConfig` model + bundled default for `getsynq/cloud`.
- `MonorepoSplitter` real implementation (root patterns, longest-match, unmatched strategy).
- `RepoCheckoutManager` sparse-checkout per the splitter's identified subpaths; worktree shared across same-SHA subreviews.
- `ReviewQueueWorker` fanout per subdiff with cwd set to subpath; `ResultAggregator` real implementation (worst-verdict, summary concat, annotation merge).
- `SubreviewBreakdownView` collapsible per-subfolder display.
- `MonorepoConfigsSettings` editor.
- **Demo gate**: a PR touching `kernel-billing` + `lib/auth` produces 2 subreviews in parallel sharing one worktree, with 2 separate verdicts (each having read its own per-subfolder `CLAUDE.md` via cwd resolution), aggregated to one outcome with per-subfolder breakdown visible in the UI.

### Phase 5 — Pure-prompt mode (½ day)
- `ClaudeProvider` pure-prompt code path (already designed; just implement).
- `ContextAssembler` inlines `<subpath>/CLAUDE.md` when `toolMode == .none`.
- Setting toggle: per-`MonorepoConfig.toolModeOverride`, plus a global default in AI Provider settings.
- **Demo gate**: a `MonorepoConfig` with `toolModeOverride = .none` produces a review with `toolCallCount == 0`, `costUsd ≈ $0.02`, and the `<subpath>/CLAUDE.md` content visible in the assembled prompt's debug dump.

### Phase 6 — Auto-approve policy (½ day)
- `AutoApprovePolicy.evaluate(_:)` with rule editor in Settings.
- 30s undo banner in the popover before the `gh` call fires.
- `auto_approved` notification category.
- **Demo gate**: a Dependabot PR appears, AI says approve with high confidence, app shows undo banner for 30s, then auto-approves.

### Phase 7 — Polish (rolling)
- `History` tab with action log + filtering.
- Cost dashboard (sum of `costUsd` per day/week, broken out by provider/subreview/tool-mode).
- Bare-clone disk usage view + manual prune.
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

## Critical files (planned, none exist yet)

The whole repo is greenfield. The most architecturally load-bearing files:

- `Sources/PRBar/PRBarApp.swift` — Scene composition (MenuBarExtra + Settings).
- `Sources/PRBar/Services/GitHub/GHClient.swift` — single source of truth for all GitHub interaction.
- `Sources/PRBar/Services/GitHub/GraphQLQueries.swift` — the inbox query (defines the data model implicitly).
- `Sources/PRBar/Services/PRPoller.swift` — the heartbeat actor.
- `Sources/PRBar/Services/Review/MonorepoSplitter.swift` — diff → [Subdiff]; the entire monorepo story lives here.
- `Sources/PRBar/Services/Review/RepoCheckoutManager.swift` — the only place that touches the real filesystem; mistakes here cause data loss or disk bloat.
- `Sources/PRBar/Services/Review/ContextAssembler.swift` — defines the prompt shape; shapes the AI's behavior more than any other file.
- `Sources/PRBar/Services/Review/ResultAggregator.swift` — single-PR verdict from N subreviews.
- `Sources/PRBar/Services/Providers/ReviewProvider.swift` — provider protocol; getting this shape right matters because v1 Claude implementation locks the contract.
- `Sources/PRBar/Services/Providers/ClaudeProvider.swift` — exact `claude -p` invocation (minimal + pure-prompt modes); ties us to the CLI's JSON contract.
- `Sources/PRBar/Services/Providers/ClaudeStreamParser.swift` — the only place that enforces the tool-call and cost budgets in real time. Bug here = runaway costs.
- `Sources/PRBar/Services/AutoApprovePolicy.swift` — only place that can enqueue an unattended action.
- `Sources/PRBar/UI/DiffView.swift` + `AnnotationOverlay.swift` + `SubreviewBreakdownView.swift` — the centerpiece of the inbox UX.
- `Resources/schemas/review.json` — defines the AI output contract; changing it is breaking for users' custom prompts.
- `Resources/prompts/system-base.md` — ships as default; users can edit in place.
- `Resources/monorepo-configs/getsynq-cloud.json` — bundled default for the most-used monorepo.

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
