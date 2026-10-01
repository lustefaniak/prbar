# Review rules redesign

Status: draft, working notes.

Goal: replace the per-repo settings model with a rule-based configuration that lives in files, is shared by
the app and the `prbar-review` CLI, can be exported/imported/versioned, and can explain for any repo + PR which
workflow will run and why. Add MCP so other coding agents can drive PRBar.

## Design goals

1. **One config, shared by every front end.** App, CLI and MCP all go through one server that loads the same
   files and evaluates them with the same code.
2. **A core engine of pure interfaces, separate from UI and CLI.** Reusing any piece (in the app, the CLI, an
   MCP server, a future GitHub Action, a test harness) should mean wiring adapters, not extracting code.
3. **Explainable.** For any repo + PR, the engine can say which workflow runs and why.
4. **Nothing executes or reads PR-controlled input by default.** Repo files that feed the prompt, rules from
   includes, agent writes: all opt-in.
5. **Fully standalone headless mode.** Everything the app does (poll, select, review, decide, post, keep
   history) runs without any UI framework, the way the CLI review already does. The menu-bar app is one front
   end over that runtime, not the place where the behaviour lives.
6. **State in plain files.** Config, history and caches are files under documented paths, written only by the
   server, readable with `cat` / `jq`. No SwiftData, no UserDefaults for anything the runtime needs.
7. **API parity.** Anything a front end can do is an API call or an event on the server's stream; no front end
   has a private path into the runtime.
8. **Observation separate from decision.** Polling GitHub only produces facts and events. Whether and when to
   review is decided later, at the moment a worker can actually start.
9. **Cooperate across instances.** Several people running PRBar on the same PR produce one review per
   (head SHA, configured agent), not one per person.
10. **Forge-neutral.** GitHub today, GitLab later, behind one interface.

### Core separation

Today `PRBarCore` is a source whitelist over the app tree, not a designed boundary:

- The CLI itself lives inside it (`Sources/PRBar/CLI/`).
- The review pipeline is `ReviewQueueWorker`, a 1,400-line `@MainActor @Observable` class that mixes view state,
  queueing, gating, staging behind the undo window and posting, with hooks (`enqueueAutoReview`,
  `enqueueResolveThreads`) left optional so an unwired one silently does nothing.
- `ReviewSinks.swift` is the one place where persistence already sits behind protocols.

Target layout:

```
PRBarEngine   pure: config model, loader + validation, rule evaluation, plan / decision / trace types,
              prompt assembly, splitter, aggregation, inline-comment mapping.
              Value types in, value types out. No Process, no FileManager, no clock, no MainActor.
PRBarRuntime  orchestration over protocols: PR source, diff source, checkout provider, agent runner,
              action sink, state store, notification sink, clock, file reader.
              Owns the poll loop, review queue, action queue (undo window, retries, per-PR dedup),
              readiness/notification policy and the file-backed stores.
              Concrete adapters (gh, claude, codex, git, file store) live here or in their own target.
PRBarAPI      the client-server contract: request / response / event types, versioned, plus the client
              library. Depends on nothing else; every front end depends only on this.
PRBarServer   hosts one runtime behind PRBarAPI. Transports: in-process and Unix socket.
Front ends    PRBar.app: SwiftUI views over API state, UNUserNotification delivery, menu-bar badge.
              prbar CLI: `serve` (headless server), `review`, `validate`, `explain`, `history`.
              prbar mcp: MCP tools mapped onto API calls.
```

See Client-server below for why front ends talk to the runtime only through `PRBarAPI`.

What moves out of the app into the runtime: `PRPoller`, `ActionQueue`, `ReadinessCoordinator`, the decision
half of `Notifier` (coalescing, settling window), and every `*Store`. The app keeps only rendering,
`UNUserNotificationCenter` delivery, launch-at-login and Sparkle.

Rules for the boundary:

- The engine never performs I/O. Anything it needs from outside arrives as a value (facts, file contents) or
  through a protocol passed in by the caller, so every decision is unit-testable without fixtures on disk.
- Front ends depend on the engine and runtime, never the other way round. `@Observable` view state wraps the
  runtime; it doesn't replace it.
- Every required hook is a non-optional protocol requirement. An optional-chained closure that silently no-ops
  is how `resolveThreads` and the verdict marker went missing in the CLI.
- The `linux-cli` CI job builds the engine and runtime targets, which keeps AppKit/SwiftData out by
  construction.
- No `@Observable` in engine or runtime. The runtime publishes state as snapshots + events through the API; the
  app adapts them into `@Observable` view models, the CLI prints them, MCP serves them.

### Client-server

Every front end (app, CLI, MCP, anything later) is a client of one server that hosts the runtime, and talks to it
only through `PRBarAPI`. The point is the guarantee: if the app can do something, there is an API call for it,
and any other front end can do it too. The compiler enforces it: the UI target depends on `PRBarAPI` only, never
on `PRBarRuntime`, so a view reaching into a queue doesn't build.

API shape (JSON-RPC 2.0, the same framing MCP and LSP use, types defined once in Swift with a generated JSON
schema):

- **Queries**: inbox, PR, review (with trace and matched rules), history, config + validation, explain(pr),
  server status.
- **Commands**: run review, cancel, post review, merge, resolve threads, undo / confirm a staged batch, retry /
  dismiss a failed action, reload config, poll now.
- **Subscriptions**: one event stream (inbox changed, review queued / progress / completed / failed, action
  staged / posted / failed, ready-for-review batch, cost-cap hit). A client gets a snapshot then events, so
  reconnecting is snapshot + resume. These are the same records the server appends to the history files.
- `hello` handshake carrying the API version, so a client and server from different builds fail clearly instead
  of misreading each other.

Transports:

- **In-process.** The app embeds the server (`PRBarServer` linked into a small composition-root target) and talks
  to it through the same client interface. Default on macOS, so installing PRBar stays one `.app` with no daemon.
- **Unix socket** (`~/.local/state/prbar/server.sock`, mode 0600, so filesystem permissions are the auth). The
  embedded server also listens here, which is how `prbar mcp` / `prbar review` reach the running app.
  `prbar serve` runs the same server headless, for Linux or a Mac without the app.
- Whoever binds the socket is the server. A client that finds no server either fails (`prbar history`) or
  starts an in-process one for the duration of the call (`prbar review`, `prbar mcp`).
- No TCP. A loopback WebSocket can be added if a browser front end ever appears (e.g. the rule editor talking to
  the server directly); it's another transport over the same API, not a new API.

Why not the alternatives:

- **XPC**: macOS only, rules out Linux.
- **gRPC (grpc-swift)**: works on Linux, but HTTP/2 + codegen + a protobuf schema beside the Swift types is a lot
  of machinery for one local socket.
- **MCP as the app protocol**: tool-shaped and request/response; a UI needs a typed state stream. MCP stays a
  front end that maps onto the API.

Costs to accept:

- Two processes once the app runs as a client of an external `prbar serve`: version skew (handled by `hello`)
  and, if the server becomes a LaunchAgent (`SMAppService.agent`), restarting it after a Sparkle update.
  Not needed for v1: the app embeds the server.
- macOS notifications need an app bundle. The server emits "notify" events; the app delivers them. A headless
  server has a notification sink of its own (stdout, webhook, nothing).
- Everything the UI shows has to be in the API, including things that today are a view reading a store
  directly. That is the intended cost, but it makes step 2 of the phasing bigger.

### State in files

Today's SwiftData store (`~/Library/Application Support/io.synq.prbar/store.sqlite`, 494 MB on this machine)
holds `ActionLogEntry`, `ReviewStateEntry`, `ReviewLogEntry` (1,583 rows, 134 MB of payload),
`RepoConfigEntry`, `InboxSnapshotEntry`, `DiffCacheEntry` (274 rows, 45 MB), `FailureLogCacheEntry`. Each is
already a JSON `payload` blob plus a few projected columns, so the database adds little beyond indexes, and it
ties all history to the app.

Layout (XDG paths on both platforms so the app, CLI and MCP share one tree; `$PRBAR_HOME` overrides all three):

```
~/.config/prbar/            prbar.yaml, included files cache, local overrides
~/.local/state/prbar/
  actions/2026-10.jsonl     append-only action log, one line per attempt (post, merge, resolve, re-request)
  reviews/2026-10.jsonl     append-only review index: PR, sha, verdict, cost, matched rules, path to full record
  reviews/<owner>/<repo>/<number>/<sha>.json   full review record (summary, annotations, trace, prompt parts used)
  current/<owner>/<repo>/<number>.json         live per-PR review state (queued/running/completed/failed)
  inbox.json                last inbox snapshot
  notified.json             (prNodeId, headSha) already notified
  server.sock               the API socket (0600); binding it is what makes a process the server
~/.cache/prbar/
  diffs/<sha>.json          parsed hunks; safe to delete
  ci-logs/<checkRunId>.txt
  repos/                    bare clones + worktrees (moved from Application Support)
```

- Appends are single `write(2)` calls on `O_APPEND` files, one JSON object per line, so concurrent writers from
  different processes don't interleave lines. Whole-file records are written temp-then-rename.
- Monthly log files make retention a file delete and keep the daily cost cap a read of one file.
- `ReviewCache`'s serialised-save problem (an older snapshot committing after a newer one) goes away: each PR's
  state is its own file, and writes to it go through the single runtime owner.
- Only the server writes the state tree. Front ends never touch these files directly; they go through the API
  (`history`, `get_review`), which keeps the file layout an implementation detail of the server.
- Migration: one-time export of the SwiftData store into this tree on first launch of the new version; the
  SQLite file is left in place for one release, then deleted.

## Review lifecycle

### Stages

```
observe ──events──▶ schedule ──candidate──▶ admit ──▶ claim ──▶ run ──▶ decide ──▶ deliver ──▶ release
(forge poller)      (intake queue)          (late    (cross-   (agent)  (rules)    (action    (claim →
                                             select)  instance)                    queue)      done)
```

- **observe**: the forge poller (today `PRPoller`) fetches and diffs snapshots and emits events: PR appeared,
  head SHA changed, review requested (with actor and time), review command posted, claim changed, review
  submitted, PR closed. It applies no review policy at all. Today the title filter lives in
  `PRPoller.applyTitleFilter` and `enqueueNewReviewRequests` runs straight after each poll; both move out.
  The poller is replaceable: webhooks, a GitLab poller, or an orchestrator pushing events all feed the same
  scheduler.
- **schedule**: turns events into candidates `(PR, head SHA, trigger)`. Cheap, no network. Dedups by
  `(PR, SHA)` and keeps the newest trigger. Orders newest-first as today.
- **admit**: runs when a worker slot frees up, not when the poll lands. Refreshes the single PR (one
  `fetchPR`), then evaluates the `select` rules on fresh facts: still requested? SHA unchanged? a live claim
  or a finished review by an equivalent agent at this SHA? reviewed by others? A candidate that waited behind
  others is judged on the state at start time, not on a 10-minute-old poll.
- **claim**: see Coordination. Losing the claim drops the candidate with a typed skip reason.
- **run / decide / deliver**: as today, with `decide` evaluated by the rules engine and `deliver` through the
  action queue.
- **release**: marks the claim done (or failed), whatever the outcome, so the next instance doesn't wait out a
  lease.

`trigger` is a fact the rules can see: `review_requested`, `new_commit`, `re_requested`, `command`, `manual`,
`agent`.

### Coordination across instances

Today: `skipAIIfReviewedByOthers` plus `PRBarVerdictMarker` in review bodies. The marker is written only after a
review posts, so every instance that starts within the same window reviews anyway. It is invisible beyond
`reviews(last: 20)`, and when nothing posts (all gates off) nothing coordinates.

Proposal: claim the review **before** starting it, on the PR itself, with a lease.

Channel options:

| Channel | SHA-scoped | Notifies people | Carries metadata | Readable at no extra cost | Notes |
|---|---|---|---|---|---|
| **Commit status** `prbar/<agent>` on head SHA | yes, natively | no | description (140 chars), creator, createdAt, target URL | yes: `StatusContext` is already in the inbox query's rollup, needs `creator { login } createdAt` added | needs `repo:status` (in gh's default `repo` scope); GitLab has the same API |
| Issue comment with `<!-- prbar:claim ... -->` | via marker | **yes, every claim emails every participant** | anything | yes (`comments(last: 10)`) | edits don't notify, but creation does |
| 👀 reaction on the PR | no | no | user + createdAt only | needs a field | one per user per PR, can't express SHA; humans use 👀 too |
| Review body marker (today) | via marker | yes (it's the review) | anything | yes | only exists after the review, too late to prevent duplicates |

Recommendation: **commit status** on the head SHA.

- Context `prbar/<agent-id>`. The agent id comes from config (the shared team profile names it; default
  `prbar/review`). "The same configured agent" means the same context, so a deliberately different agent (say a
  security-focused profile) still runs.
- Claim protocol:
  1. Read the statuses for this SHA and context. A `success` means already reviewed: skip. A `pending` younger
     than its lease means someone is on it: skip.
  2. Otherwise post `pending` with the description `reviewing (@login)` and the lease expiry.
  3. Wait a short settle window (about 5 s), read again. The earliest live `pending` by createdAt wins (ties
     broken by login). A loser posts nothing further and drops the candidate.
  4. The winner posts `success` (`reviewed by @login: 3 findings`) or `error` on release. Because the shared
     context only displays its latest status, losers' pendings are hidden as soon as the winner completes.
- Lease: `pending` older than the review timeout plus a margin counts as dead, so a crashed instance blocks
  nobody for long.
- Risks to handle:
  - A `pending` status turns the PR's check rollup yellow while the review runs. PRBar's own ready-to-merge and
    CI-failed logic must ignore `prbar/*` contexts. Never required by branch protection unless a team chooses
    to, which would actually be a legitimate "AI review must complete" gate.
  - Fork PRs: statuses are set on the base repo against the head SHA, which works with write access to the
    base repo.
  - On GitLab, an external commit status attaches to a pipeline; with "pipelines must succeed" a `pending`
    status may hold the merge until release. Verify before enabling there.
- **Only coordinate when the winner posts something.** If an instance reviews privately (all posting gates
  off), its result is visible only to its owner. Letting it claim would leave everyone else with neither a
  review nor their own triage. So claiming is tied to the agent profile having a posting outcome
  (`share` / approve / request changes); private triage never claims and never skips because of a claim.
- Opt-in via config (`coordination: status | off`), since it writes to PRs where PRBar writes nothing today.
- `PRBarVerdictMarker` stays as the fallback for reading older instances, then goes.

### Re-review triggers

Today the only way to get a fresh review of the same SHA is to remove PRBar's user as reviewer and add it back.

- **Honour re-requests directly.** A `ReviewRequestedEvent` for the viewer that is newer than this instance's
  last review of the PR is a `re_requested` trigger, even at an unchanged SHA. That makes GitHub's own
  "re-request review" button (the circular arrow next to a reviewer) work, with no remove-and-add. Events whose
  actor is the viewer are ignored, so PRBar's own self-re-request after a share doesn't loop.
- **Review command in a comment**: `/prbar review` (optionally `/prbar review full`, `/prbar review <profile>`).
  - Who may trigger is a `select` rule over `actor` (default: PR author and requested reviewers), since a
    command spends the token budget of whoever picks it up.
  - Acknowledged with reactions on the command comment: 👀 when claimed, 🚀 when posted, 😕 when refused. That is
    where an emoji fits: it's on the specific request, so it's unambiguous.
  - Goes through the same claim, so five instances see the command and one runs it.
  - Comments are already fetched (`comments(last: 10)`); the scheduler only needs to remember which command
    comments it already handled.
- **Manual / agent**: Re-run in the app, `prbar review --force`, MCP `run_review`. Same pipeline, `trigger`
  says where it came from.

### Forges

GitHub-specific code today: `GHClient`, `GraphQLQueries`, `InboxResponse`, `InboxPR`, `RepoCheckoutManager`'s
`gh repo clone`, `InlineCommentMapper`'s GitHub position rules, `PRBarVerdictMarker`.

- `Forge` protocol in the runtime: list change requests for the viewer, fetch one, diff, discussion threads,
  post review (verdict + body + inline), merge, set / read commit status, react, re-request review, clone URL.
- A forge-neutral `ChangeRequest` replaces `InboxPR` in the engine. Rules, prompts and history see neutral facts
  (`forge: github | gitlab`, `repo`, `author`, ...); prompt templates use `{{change.title}}`, not "PR".
- GitLab mapping (via `glab` or the REST API, same "no OAuth, no backend" property as `gh`):
  - MR + reviewers + re-request review: native.
  - Approve: native. Request changes: GitLab 17.x has a reviewer "request changes" state; older versions fall
    back to a comment.
  - Inline findings: diff discussions with a position (`base_sha` / `head_sha` / `start_sha` + line).
  - Claims: commit statuses (`POST /projects/:id/statuses/:sha`, `name` = context), see the pipeline caveat above.
  - Award emoji for command acknowledgement.
- Not in v1. The point now is that nothing GitHub-shaped leaks into the engine, so the GitLab poller is an
  adapter, not a rewrite.

## Current state

### Storage (four places, app and CLI don't share)

- `ReviewDefaults`: one JSON blob in UserDefaults (`reviewDefaults` key).
- `RepoConfig` rules: SwiftData rows (`RepoConfigEntry`, JSON payload).
- About a dozen `@AppStorage` keys that also shape reviews: `defaultProviderId`, `defaultClaudeModel`,
  `defaultClaudeEffort`, `defaultCodexModel`, `defaultCodexEffort`, `dailyCostCapEnabled`, `dailyCostCapUsd`,
  `postIncludesAISummary`, `postIncludesInlineAnnotations`, `skipMergeConfirmation`, ...
- CLI: `prbar.json` decodes `ReviewDefaults` + `[RepoConfig]` plus its own `defaultProvider` / `default*Model`
  keys (`CLIConfig`). Overlaps with the app, but neither side can export to the other.

### Matching

First user rule whose `repoGlobs` match wins (`RepoConfigStore.rule(owner:repo:)` uses `userConfigs.first`;
the doc comment claims "most-specific match wins", the code is list order). Fields left `nil` inherit from
`ReviewDefaults`. No sharing between rules except through the defaults. Auto-approve / auto-deny inherit as
whole structs.

### Roughly 60 knobs across four implicit stages

| Stage | Facts available | Knobs |
|---|---|---|
| select (`ReviewQueueWorker.enqueueNewReviewRequests`) | PR metadata | `excluded`, `excludeTitlePatterns`, `aiReviewEnabled`, `reviewDrafts`, `skipAIIfReviewedByOthers`; failed-at-SHA and `PRBarVerdictMarker` skips are hardcoded |
| plan (how to run) | PR + diff | provider, model, effort, `toolMode`, 3 budgets, 6 splitter knobs, risk brief + churn, `customSystemPrompt` + `replaceBaseSystemPrompt`, `agentEnvironment`, `forceFullReview` |
| decide (`AutoReviewPolicy`) | completed review | `AutoApproveConfig` (12 fields), `AutoDenyConfig` (9), share (`shareFindings`, `shareMinConfidence`, `shareMaxComments`), `ResolveThreadsConfig` (2) |
| deliver / notify | | undo window, `notifyPolicy`, `skipMergeConfirmation` |

### Problems

- Verdict and attachments are tangled. Approve carries its own `postInlineAnnotations` +
  `postAttributionComment`; deny carries `postInlineAnnotations` and its `comment` action really means
  "no verdict + summary body"; share is a fourth pseudo-outcome with its own floor and cap. All of them fit
  `verdict ∈ {approve, request_changes, none}` × `attachments {inline(filter, cap), body(summary | attribution | none)}`
  (+ local `flag`).
- Duplicated, inconsistent conditions: per-provider confidence floors on both sides, three size caps on approve
  vs only `maxAdditions` on deny, separate share confidence.
- No condition on who authored the PR, so "auto-approve only for trusted people" can't be expressed.
- Knobs that are silently dead in the default mode: `MonorepoSplitter` returns before the collapse step when
  `toolMode == .sandboxed`, so `collapseAboveSubreviewCount: 8` in `docs/prbar.example.json` does nothing.
- `try?` decoding drops unknown or mistyped keys silently. Right for SwiftData payload upgrades, wrong for a file
  people share.
- Prompt customisation is one string per rule (append or replace). No reuse, no templating, no repo file.

## Proposed model

One config, two kinds of content:

- **Decisions** (`select`, `decide`, profile choice in `plan`): ordered rules, first match wins. Each rule is
  an `id`, a `when` condition written in CEL, and a typed `then` (see Engine options).
- **Everything else** (profiles, prompt parts, includes, lists, local settings): plain YAML.

The repo is just another condition, so one rule covers any number of repos and per-repo rules disappear.

The sketch below uses a compact `when` / `then` notation for readability. The actual decision blocks follow the
CEL Policy format (`rule.match[].condition` / `output`), see Engine options.

```yaml
version: 1
include:
  - github: getsynq/review-rules/prbar.yaml@v3   # pinned ref, read-only
lists:
  trusted: [alice, bob]

profiles:                      # reusable run settings
  base: { provider: claude, model: sonnet, tool_mode: sandboxed, budget: { cost_usd: 3 } }
  cloud-split:
    split: { mode: per_subfolder, roots: [kernel-*, lib/*, dev-tools], unmatched: review_at_root }

signals:                       # opt-in AI judgments, see "AI signals (Jev)"
  mechanical:
    stage: select
    type: noul
    ask: "Is this change purely mechanical: dependency bumps, generated code, renames or formatting only?"
    send: [title, body, file_list]

select:
  - id: skip-bumps
    when: 'pr.title.matches("^chore: bump ")'
    then: skip
  - id: skip-drafts
    when: pr.draft
    then: skip
  - id: skip-mechanical
    when: 'signals.mechanical > 0.9'
    then: skip
  - then: review

plan:
  - when: 'pr.repo == "getsynq/cloud"'
    use: [base, cloud-split]
  - when: 'pr.repo.startsWith("getsynq/")'
    use: [base]

prompt:
  - builtin: base
  - builtin: language
  - when: 'pr.repo == "getsynq/cloud"'
    file: repo:REVIEW.md           # explicit opt-in, local config only; read at the BASE sha
  - text: "Reviewing {{subpath}} of {{pr.repo}}."

decide:
  - id: trusted-approve
    when: >-
      pr.author in lists.trusted && review.verdict == "approve" && review.confidence >= 0.85
      && review.max_severity <= severity.suggestion && pr.additions <= 200
    then: { verdict: approve }
  - id: flag-blockers
    when: >-
      review.verdict == "request_changes" && review.confidence >= 0.9
      && review.findings.exists(f, f.severity >= severity.blocker)
    then: { verdict: none, flag: true }
  - id: share
    when: review.confidence >= 0.5
    then: { verdict: none, inline: { min_severity: warning, max: 20 }, body: none_if_inline }
  - then: nothing

local:                             # machine-specific, never shared
  agent_env: { CLAUDE_CONFIG_DIR: ~/.claude-work }
  daily_cost_cap_usd: 20
```

### Rules

- Each stage only sees facts that exist at that point. `select` / `plan`: repo, author, title, labels, base
  branch, draft, size, reviewed-by-others, marker. `decide` adds verdict, confidence, severities, counts,
  provider, `source` (auto / agent). The loader rejects e.g. `confidence` in `select`.
- Strict validation: unknown keys are errors, and every `when` is type-checked against that stage's fact
  schema, so `review.confidence` in a `select` rule or a misspelt field fails at load time, not at 2 am on a PR.
  Surfaced in the app and in `prbar validate`. Publish a JSON schema for the YAML itself.
- Rule `id`s are required for anything that posts. They are what History, the explain trace and the claim
  descriptions refer to, and they keep a rule's identity stable when rules are reordered.
- Every History row records the id of the rule that matched, so "why did it approve this" has an answer.
- Explain view: for a given repo + PR, show per stage which rule matched and why earlier ones didn't. Same
  evaluator backs the CLI `--explain <pr>`, the Settings view and the MCP `explain_rules` tool.

### Layering and editing

- `include` loads shared files (local path or `github: owner/repo/path@ref` via `gh api`, pinned). Included files
  are read-only; local rules come first so they win.
- The server watches the config files and reloads on change. Settings (through the API) writes only the local
  file; included files are never rewritten.
- The server never re-emits a user's file. Yams (and every Swift YAML library) drops comments and reflows on
  write. Edits are made by the editor front end with a comment-preserving YAML layer (see Editor) and sent to
  the server as the new file content plus the hash it was based on; the server validates and rejects stale or
  invalid writes.
- UI-only preferences (badges, launch at login, sequential focus) stay in UserDefaults.

### Prompts

- Prompt = ordered list of parts: `builtin`, `file`, `text`, each with optional `when`.
- Templating is variables only (`{{repo}}`, `{{subpath}}`, `{{language}}`, `{{pr.title}}`). Logic belongs in
  `when`, not in templates.
- Prompt text from the reviewed repository (`repo:REVIEW.md` or any other path) is **opt-in, never automatic**.
  No file is picked up because it exists; the config must name it explicitly in a `prompt` part, scoped by a
  `when` to the repos where the user trusts it. Included shared configs cannot enable it: only the local file
  can, so pulling in a team's rules never starts feeding their repos' files into your reviews.
- An opted-in repo file is read at the **base** SHA. At head, the PR author rewrites the reviewer's
  instructions, which combined with auto-approve is a way to get approved. The explain view and History show
  which repo files went into the prompt. Note the existing exposure:
  `.sandboxed` checks the worktree out at head and `claude` auto-loads `CLAUDE.md` from it, so a PR that edits
  `CLAUDE.md` already steers its own review.

### Trust caveat

`author` is the PR opener, not everyone who pushed. A trusted author's PR with commits from someone else still
passes. If that matters, add a `committers` fact (one more GraphQL field).

### getsynq/cloud split

Becomes one `plan` rule. To check it actually helps, add `prbar-review --profile <name> --review-json` and run
an A/B over N recently merged cloud PRs: compare findings against what humans flagged, and cost per PR. Today
collapse is a no-op in sandboxed mode, so cloud always runs fully split.

## Engine options

### Requirements (everything so far)

1. Embeddable in the pure Swift engine, macOS and the static Linux CLI, no service.
2. Human-readable YAML that reviews well in a PR: stable keys, meaningful names, no generated ids or layout
   coordinates.
3. A GUI that edits the file in place: comments survive, a one-rule change is a one-rule diff.
4. Type-checked per stage, so the loader rejects facts that don't exist yet.
5. Explain trace: which rule matched at each stage, and why earlier ones didn't.
6. Safe to include from someone else's repo: no code execution, bounded evaluation.
7. Works through the client-server API, so the editor is just another front end.
8. Can reference AI signals as ordinary facts.

### Comparison

| Option | 1 Embed | 2 Readable | 3 In-place edit | 4 Types | 6 Safe |
|---|---|---|---|---|---|
| **Own CEL-compatible engine** (modelled on CEL Policy) + react-querybuilder + `yaml` (eemeli) | pure Swift | `condition: pr.author in lists.trusted && ...` | yes, the editor only rewrites one `condition` / `output` | yes, typed env config + typed outputs | yes, CEL terminates, RE2, cost limits |
| CEL in our own YAML | own Swift subset, or cel-rust via FFI | same | yes | only what we build | yes |
| Cerbos (YAML + CEL) | Go server / embedded PDP | good | n/a | yes | yes, but an authorisation model (principal, resource, action, allow/deny), not ordered decisions with structured outputs |
| Kyverno (YAML + CEL) | Kubernetes controller | good | n/a | yes | Kubernetes-only |
| GoRules Zen + JDM editor | Rust via UniFFI | **no**: rule rows keyed by random column ids (`"xWauegxfG7": "> 10"`), UUID node ids, x/y positions | editor re-serialises the whole graph | partial (input/output schemas) | needs function nodes rejected |
| JsonLogic + react-querybuilder | trivial in Swift | verbose (`{">=": [{"var": "confidence"}, 0.85]}`) | yes | none | yes |
| Own structured YAML conditions | trivial | good | yes, but we build the editor | our own | yes |
| Pkl (Apple) / CUE | `pkl` binary / Go | good, typed, versioned packages | no editor, it's code | strong | yes |
| DMN, OPA/Rego, Cedar, Node-RED | JVM / Go / Rust / runtime | XML / code / JSON | no | varies | varies |

JSON is YAML, so Zen's files would load fine as YAML; the problem is what is in them. Opening the stock
`test-data/table.json` from the zen repo: a two-row table carries 6 generated ids and 3 coordinate pairs, and a
condition is stored under its column's random id rather than its field name. Hand edits and PR review of that
file are impractical, and dragging a node in the editor shows up as a diff.

The node graph was also more flexibility than this needs: PRBar's stages are fixed (observe, admit, plan,
decide), and what users author is the ordered rule list inside each stage. The "wiring" view can be rendered
read-only from the stages plus the explain trace.

### Reference design: CEL Policy (cel-go)

[cel-go](https://github.com/cel-expr/cel-go) (Apache-2.0, the reference CEL implementation, used by Kubernetes)
ships a **CEL Policy** format in its `policy` package: YAML rules with CEL conditions, compiled into one CEL
program. It is close to what this doc was about to hand-write:

- `rule.match`: ordered `condition` / `output` pairs, **first match** by default. A `match` without a
  condition is the default.
- `rule.aggregate`: several first-match sub-rules evaluated side by side, outputs collected. That is the
  verdict-plus-attachments shape: one dimension picks the verdict, another the inline-comment policy, another
  the body.
- Nested rules with their own `variables`, and rule `id`s.
- `variables`: named sub-expressions, **lazily evaluated and memoised**.
- Typed outputs: every output in a policy must type-check to the same type, so a rule returning the wrong shape
  fails at compile time.
- An environment config in YAML declaring every input variable with its type, plus custom functions. That
  file *is* the per-stage fact schema.
- A YAML test format (`tests.yaml`: named inputs, expected output) with a runner (`tools/celtest`) and a policy
  conformance suite. Their own testdata includes an agent tool-execution governance policy, which is the
  same kind of problem as ours.

Shape for us (one policy per stage; `decide` shown):

```yaml
name: decide
rule:
  aggregate:
    - rule:
        id: verdict
        match:
          - condition: >-
              pr.author in lists.trusted && review.verdict == "approve"
              && review.confidence >= 0.85 && review.max_severity <= 1 && pr.additions <= 200
            output: '{"rule": "trusted-approve", "verdict": "approve"}'
          - condition: review.verdict == "request_changes" && review.confidence >= 0.9
            output: '{"rule": "flag-blockers", "verdict": "none", "flag": true}'
    - rule:
        id: inline
        match:
          - condition: review.confidence >= 0.5
            output: '{"rule": "share-warnings", "min_severity": 2, "max": 20}'
```

Everything around the decisions (profiles, prompt parts, includes, lists, `local`) stays in our own
`prbar.yaml`, which points at or inlines one policy per stage.

What this changes elsewhere in the doc:

- **Lazy AI signals come for free.** cel-go's partial evaluation takes inputs marked *unknown*: evaluate with
  every signal unknown; if the result is already decided, no signal was needed; otherwise the residual names
  exactly which ones are, fetch those (one Jev request), evaluate again.
- **Explain**: cel-go's state tracking records the value of every sub-expression, and the policy compiler
  keeps YAML source positions, so the trace can say "line 12, `pr.additions <= 200` was false (412)".
- **Editor**: unchanged. `condition` strings are CEL, so react-querybuilder still edits them; the `yaml`
  Document API still does the file edits.

### Recommendation: our own CEL-compatible engine

We don't need all of CEL, and no existing implementation is both complete and embeddable in Swift:

| Implementation | Conformance (cel-spec `tests/simple`) | Missing for us |
|---|---|---|
| cel-go | reference | it's Go |
| cel-rust | 1,225 of 2,507 generated tests on its ignore list (49%); core files (basic, logic, integer and float math, string, lists, conversions, fields) all pass; the failures are protobuf, the string / math / list / network extensions, and all of `type_deduction` | type checker, cost estimation, partial evaluation, policy format; plus Rust |
| cel-python (pure Python) | 1,184 of 2,430 scenarios still `@wip` (49%), same shape as cel-rust | same, plus Python |
| cel-expr-python | wraps cel-cpp | Python + cel-cpp's Bazel build |

So: write our own engine in Swift, **syntax-compatible with CEL** and **modelled on CEL Policy**, implementing
only what PRBar's rules need. Compatibility keeps three things working: people's existing CEL knowledge,
react-querybuilder's `parseCEL` in the editor, and the cel-spec conformance files as a test oracle for every
feature we do implement.

Scope:

- **Expressions**: literals, field access on maps and our fact objects, `&& || ! ?:`, comparisons, arithmetic
  with CEL's overflow errors, `in`, `size`, `has()`, string `startsWith` / `endsWith` / `contains`, list and
  map literals, the `exists` / `all` / `exists_one` / `map` / `filter` macros, plus our own functions
  (`glob(path, pattern)` over the existing `GlobMatcher`).
- **Type checker** over the declared per-stage fact schema: simpler than CEL's, since the schema is closed and
  there are no protobuf types. Rejects unknown fields and mismatched types at load.
- **Policy layer** modelled on CEL Policy: `match` (first match), `aggregate`, nested rules with `id`,
  lazily evaluated `variables`, typed outputs, and the `tests.yaml` format.
- **Unknown values** for lazy AI signals: reading an unfetched signal yields `unknown`; `&&` / `||` absorb it
  the way CEL specifies (`false && unknown` is `false`); a result that is still unknown names the signals it
  needs, which are fetched in one request before evaluating again.
- **Explain trace**: the interpreter records each condition's value and source position as it goes.
- **Out of scope**: protobuf, timestamps / durations beyond what PR facts need, the extension libraries,
  and regex at first. `glob` covers paths and titles; if `matches` is ever needed, port Go's `regexp`
  (RE2 semantics, linear time) rather than using Swift's backtracking engines.

Termination becomes simpler to guarantee than with cel-go, because we own the interpreter:

- The language has no loops or recursion; macros iterate finite lists.
- A **step budget** in the interpreter: every node evaluated costs one step, and an evaluation that exceeds the
  budget stops with an error (treated as "no match", reported). That is a hard bound regardless of input size.
- Load-time limits: maximum expression depth, maximum macro nesting, maximum policy size.
- No regex at first, so no backtracking exposure.

**Conformance contract: 100% on the accepted language, rejection outside it.** Every expression the loader
accepts evaluates exactly as cel-go evaluates it, including errors. Anything outside the implemented subset is
a load-time error ("`matches` is not supported"), never a parse that means something slightly different. Three
mechanisms enforce it:

1. **cel-spec suite, no ignore list.** Every test in the in-scope files passes; the CI job fails on any
   failure. A test is excluded only by excluding its whole feature, and then the checker must reject that
   feature.
2. **Differential testing against cel-go.** A grammar-based generator produces random expressions within our
   subset plus random fact values; a small Go harness (CI and dev only, never shipped) evaluates them with
   cel-go, and the results and errors must match ours exactly. This covers what the suite doesn't: overflow
   edges, Unicode, double formatting, short-circuit with errors, macro edge cases.
3. **Policy-level parity.** The same `tests.yaml` files run against our engine and against cel-go's
   `celtest`, so the policy semantics (first match, aggregate, nested fallthrough, variable scoping) are
   checked against the reference too.

Conformance oracle: the cel-spec files covering what we implement (`basic`, `logic`, `integer_math`,
`fp_math`, `string`, `lists`, `macros`, the non-protobuf parts of `comparisons`, `conversions`, `fields`,
`parse`): roughly 900 tests. The runner lists in-scope files explicitly, so the claim "conformant for this
subset" is checked rather than asserted. Everything specific to us (checker, unknowns, cost, policy) gets its
own tests, with the policy tests written in the `tests.yaml` format so they double as documentation.

**Decision: a separate library, `cel-swift`**, in its own GitHub repo, consumed as a SwiftPM dependency.
It is a full port of cel-go, not a PRBar-specific subset: first matching cel-rust's conformance, then
cel-cpp's. Its implementation plan lives outside this repo (`../cel-swift-plan.md`). PRBar uses its `CEL` and
`CELPolicy` targets; until the library covers a feature, PRBar's loader rejects it rather than evaluating
something different. The scope list above is what PRBar needs first, which is why the library's milestones
put it first.

### Termination and cost

The guarantee is layered, with the language doing most of it:

- CEL has no loops, recursion or user-defined functions; comprehension macros (`exists`, `all`, `map`, `filter`)
  iterate finite inputs. Every expression terminates.
- Regexes (`matches`) are RE2: linear time, no catastrophic backtracking.
- Load time: cel-go's static cost estimator, given size hints for lists (findings, files, comments), rejects a
  policy whose worst-case cost exceeds a limit. A pathological rule fails to load instead of failing on a PR.
- Run time: `CostLimit` aborts an evaluation that exceeds its budget; evaluation runs under a context
  deadline with `InterruptCheckFrequency` so long comprehensions check it.
- Server: each evaluation runs off the server's actor with a hard wall-clock deadline; a result that doesn't
  arrive in time is treated as "no match" (safe path) and reported.

(The bullets above describe cel-go. With our own engine, the step budget in the recommendation replaces
the cost estimator and `CostLimit`.)

### Fallback: embedding cel-go

Superseded by "Recommendation: our own CEL-compatible engine" below; kept as the fallback.

cel-go is Go, so it sits behind the engine's `PolicyEvaluator` protocol as an adapter. Requirement: the rules
engine is part of the app and the CLI binary, not an extra binary to install. External tools stay limited to
`gh`, `git`, `claude`, `codex`.

No Swift package wrapping CEL exists (searched GitHub, awesome-cel; the closest is a hand-written CEL subset
inside an unrelated app), so we build one.

**Recommended: statically linked cel-go, shipped as a prebuilt Swift binary target.**

- A separate package (e.g. `prbar-cel`): cel-go plus a few hundred lines of Go exporting a small C ABI
  (`compile(stage, policy, env) -> handle | errors`, `eval(handle, facts, unknowns, budget) -> output | residual`,
  `test(handle, tests) -> results`, all JSON in and out), built with `go build -buildmode=c-archive`.
- Release artifacts:
  - macOS: an XCFramework holding one universal static library (darwin-arm64 + darwin-amd64 via `lipo`).
  - Linux: a SwiftPM artifact bundle with a `staticLibrary` artifact for linux-amd64 and linux-arm64
    ([SE-0482](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0482-swiftpm-static-library-binary-target-non-apple-platforms.md),
    Swift 6.2+).
- PRBar depends on it with `.binaryTarget(url:checksum:)`. Building PRBar, the app or the CLI needs no Go;
  only bumping cel-go does, in that package's CI.
- The result: the Go runtime and cel-go are linked into `PRBar.app`'s main binary and into `prbar`. Nothing
  nested to sign separately, nothing extra to ship beside the CLI.
- Precedent for Go embedded this way in a shipping macOS app: Tailscale's apps link their Go core as a library.
- Safety without a process boundary: Kubernetes' API server evaluates user-supplied CEL (admission policies,
  CRD validation rules) in-process, relying on exactly the cost limits and deadlines described above. That is
  the same threat model as rules pulled in from someone else's repo.

Things the first spike has to confirm:

- SE-0482 says the static library may depend only on the standard C library. A Go c-archive needs libc and
  pthreads (part of glibc since 2.34); confirm it links into `swift build --static-swift-stdlib` on Linux.
- CI moves from `swift:6.1` to 6.2+ for SE-0482, and `Package.swift`'s tools version follows.
- Size added to the app and CLI (Go runtime plus cel-go; expect several MB, measure it).
- Notarization of the app with the Go code linked in (hardened runtime, no extra entitlements expected).
- Only one Go c-archive per process. Fine while this is the only one; note it if a second Go library ever
  shows up.
- Go installs signal handlers on load (with `SA_ONSTACK`, designed to coexist with a host process); confirm
  nothing in the app's crash reporting or `ProcessRunner`'s SIGTERM handling is affected.

Alternatives, in order:

- `prbar-rules` sidecar (Go binary over JSON lines): hard kill on hang and the Go runtime out of the Swift
  process, but an extra binary to sign and ship, which this design rules out.
- A Swift port of cel-go, scoped and driven by the conformance suite: no Go anywhere, no SE-0482, no Swift 6.2
  bump. See "Swift port of cel-go" below for the size.
- [cel-rust](https://github.com/cel-rust/cel-rust) (MIT, active): parser and interpreter only, no type checker,
  cost estimation, partial evaluation or policy format, so most of the previous bullet still applies, plus a
  Rust toolchain.
- cel-cpp through Swift's C++ interop: Bazel build over abseil and protobuf.

### Swift port of cel-go

Size of what would be ported (cel-go, non-test, non-generated Go):

| Package | Lines | Port? |
|---|---|---|
| `parser` (+ 7.3k generated ANTLR) | 5.4k | yes, as a hand-written Pratt parser instead of ANTLR |
| `checker` | 2.5k | yes (gradual typing, type parameters) |
| `interpreter` (planner, attributes, unknowns / partial eval) | 8.3k | yes |
| `common/types` (values, of which ~1.5k is `pb`) | 13.5k | yes, minus protobuf |
| `common/ast`, `decls`, `env`, `stdlib`, `containers`, ... | 9.4k | yes |
| `common/cost` | 3.8k | yes |
| `cel` (public API, options, env) | 8.9k | partly, as a Swift-shaped API |
| `ext` (strings, math, lists, bindings, block, encoders, network, ...) | 9.8k | only what the rules use |
| `policy` | 2.6k | yes |

Roughly 25 to 35k lines of Swift for the useful scope, plus Go's `regexp` package (pure Go, RE2 semantics,
linear time) because Swift's `Regex` and `NSRegularExpression` are backtracking engines with ICU syntax.

Conformance (cel-spec `tests/simple`, about 2,400 tests): roughly 700 depend on protobuf messages
(`proto2`, `proto3`, `enums`, `wrappers`, all of `dynamic`, parts of `comparisons`, `parse`, `type_deduction`).
Out of scope: our facts are JSON-shaped, and swift-protobuf has no descriptor-driven reflection comparable to Go's
`protoreflect`, so protobuf parity would be the expensive part for no benefit. The runner marks those files
skipped; the target is every non-protobuf test passing.

Not covered by the conformance suite, ported from cel-go's own tests instead: the cost estimator and runtime
cost tracking, partial evaluation / unknowns (`unknowns.textproto` is effectively empty), and the policy
compiler (cel-go has its own policy conformance runner and testdata, which port directly).

Where the time goes beyond translation:

- Strings: CEL counts Unicode code points; Swift `String` counts grapheme clusters. Every `size`, index and
  substring function works on `unicodeScalars`.
- Numbers: int64 / uint64 overflow is an error in CEL, double-to-string formatting has to match Go's
  `strconv`, and `uint` is a distinct type.
- Timestamps and durations with named time zones (Foundation on Linux needs tzdata present).
- Fuzzing: rules come from other people's repos, so the parser and cost accounting get fuzzed (libFuzzer on
  Linux, `-sanitize=fuzzer`), as cel-go does.

Effort: the conformance suite is a precise oracle and the Go source a line-by-line reference, which is the
case where agent-driven porting works well. Estimate: a few weeks of focused, agent-heavy work with review as
the bottleneck; months by hand. Then ongoing ownership of a language implementation: low churn (the CEL spec
moves slowly), but bugs in the cost accounting are a denial-of-service risk for whoever runs shared rules.

De-risk with a time-boxed spike before committing: parser plus core evaluator passing `basic`, `logic`,
`integer_math`, `string`, `lists` and `macros`. The pass rate after a few days says more about the real
velocity than this estimate. The static c-archive route stays as the fallback.

No Swift CEL package exists today, so this would be worth publishing as its own open-source package.

### Hot reload, keeping the last good rules

Independent of the library; owned by the server.

1. Watch the config files (FSEvents on macOS, inotify on Linux, or a 1 to 2 s mtime + content-hash poll on
   both). Debounce about 300 ms; ignore saves whose content hash didn't change (editors that save via rename
   fire twice).
2. Build a **candidate snapshot**: parse every file, resolve includes, compile every stage policy, check costs,
   run the policy test files.
3. Any failure: the candidate is discarded, the active snapshot stays, and the server emits `config.rejected`
   with file:line errors. The app shows it, `prbar serve` logs it, MCP can read it.
4. Success: atomic swap, `config.applied` with the snapshot hash.
5. In-flight work keeps the snapshot it started with. History records the snapshot hash and rule id for
   every decision.
6. Every applied snapshot is also copied to `~/.local/state/prbar/config.last-good/`. Starting with a broken
   config loads that copy and reports the error. With no last-good copy either, the server starts with built-in
   defaults that post nothing.

### Docs and JSON schema

What we write versus what comes from upstream:

| Piece | Source | Effort |
|---|---|---|
| CEL language reference | upstream [cel-spec langdef](https://github.com/google/cel-spec/blob/master/doc/langdef.md), linked | none |
| Policy format (`match`, `aggregate`, `variables`, tests) | upstream `policy/README.md`, linked; we document only our conventions (`rule` field in outputs, one policy per stage) | small |
| Facts reference per stage (names, types, descriptions) | **generated** from the environment config the compiler loads, so the docs can't describe a field the compiler doesn't have | one generator |
| Output shapes per stage | generated from the same declarations | part of the generator |
| Condition-builder field list in the editor | generated from the same declarations | part of the generator |
| JSON schema for `prbar.yaml` (profiles, prompts, includes, signals, local) | hand-written once, plus tests: every example file validates, and every key in the schema is decoded by the loader and vice versa | medium, then small per new field |
| Examples | the policy `tests.yaml` files double as worked examples in the docs | free |

The schema makes VS Code and others complete the outer file with a
`# yaml-language-server: $schema=...` first line. Inside `condition` strings, completion comes from the editor
(react-querybuilder's field list), not from JSON schema.

On flexibility: owning the format would be the most flexible option, but the flexibility that matters is in
the conditions and the rule structure, and CEL Policy already has nesting, aggregation, variables and custom
functions (we would register helpers like `glob(path, pattern)`). What we'd give up is control over the
YAML syntax of the decision blocks, and that is also what we'd otherwise have to document and maintain.

### Editor

- A web front end: the rule list per stage, a
  [react-querybuilder](https://github.com/react-querybuilder/react-querybuilder) condition builder (it has
  `parseCEL` and CEL export, so a `when` round-trips between text and the visual builder), typed forms for
  `then`, and an explain panel fed with a real PR.
- File edits go through [`yaml`](https://github.com/eemeli/yaml)'s Document API (ISC, active), which keeps
  comments, blank lines and key order, so only the edited node changes.
- Hosted in a WKWebView in Settings, and reachable from a browser through a loopback WebSocket transport if one
  is ever added. Talks to the server only through the API (load, validate, explain, write with base hash).
- **Shape check** (needs a test, not a promise): golden config files with comments; for each editor operation
  (add, edit condition, edit outcome, reorder, delete, toggle), apply it and assert the unified diff touches only
  that rule's lines and every comment survives. Runs in the editor package's CI. If a condition that came in
  as hand-written CEL can't be represented in the visual builder, the editor keeps it as text rather than
  normalising it.

## AI signals (Jev)

[Jev](https://docs.typesafe.ai) (TypeSafe's System One model) returns typed judgments rather than text: a
`noul` (probability of yes), a `choice` (one of a set, with a distribution) or a `score` (position on described
levels). One request evaluates many questions against one `state` in parallel. It is priced on input tokens
only (`jev-1.13.0`: $0.042 per million), with a 64k-token context (32k for state plus the longest question).
A 30k-token diff costs about $0.001, against $0.05 to $3 for an agent review. HTTP API
(`POST /v1/systemone`), so `URLSession` on both platforms; no Swift SDK needed.

It fits as a source of **facts for the rules**, never as the policy itself: the rule still says what happens
at which threshold, and the explain trace shows the number it used.

Candidate uses, by stage:

- **admit** (before spending on an agent):
  - "Is this change purely mechanical?" (noul) to skip bumps, regenerated code and renames, replacing title
    globs that only catch the PRs whose authors follow a naming convention.
  - Risk (score over levels like "touches auth, billing, migrations, concurrency") to pick a stronger profile
    or skip auto-approve outright.
  - Which profile fits (choice), e.g. route to a security-focused agent.
  - Whether a free-text comment is asking for a re-review (noul), so "can PRBar take another look?" works
    alongside `/prbar review`.
- **decide** (after the agent, before posting):
  - Per finding: "Does the cited code support this finding?" (noul, the citation-check pattern). Drop
    unsupported findings before they reach the author. This is the most direct fix for noisy shares.
  - Per finding against existing human comments: "Does this repeat comment X?" to avoid restating what a
    reviewer already said.
  - Per open thread: "Does the author's reply say this was fixed, or argue it was intentional?" to sharpen
    `ReviewThreadResolver` and the prior-discussion prompt, which today rely on `isOutdated` plus the finding
    disappearing.

Config shape (see `signals:` in Proposed model): a named question, its stage, its type and criteria, and an
explicit `send:` list of which facts go into `state`. Rules reference `signals.<name>`.

- **Lazy**: a signal is requested only if a rule that could still match references it; all signals needed at a
  stage go in one request.
- **Cached** per (PR, head SHA, question hash), stored with the review record.
- **Missing is not false**: on an API error or timeout the signal is absent, CEL's `has(signals.x)` is false,
  and a rule depending on it doesn't match. Write rules so that the fallthrough is the safe path (no
  auto-approve).
- **Opt-in and data handling**: it sends PR content to a third party (zero data retention only on enterprise
  plans). Enabled only in the local config, per repo, with `send:` naming exactly what leaves the machine;
  included files can define signals but cannot enable them. Same rule as repo prompt files.
- **Measure before trusting**: the local history (1,583 stored reviews plus the action log) gives labelled
  outcomes for some of these, e.g. which findings got resolved vs pushed back on. Thresholds come from that, and
  the model version is pinned (`jev-1.13.0`, not `jev-latest`) so a model update can't move them silently.

## MCP

[modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk): server support, stdio +
HTTP server transports, macOS and Linux.

MCP is another front end over `PRBarRuntime`, at the same level as the app and the CLI. Every tool maps to a
runtime call or a file read; no MCP-specific logic beyond argument parsing and the write gate.

### Transport

- `prbar mcp` over stdio; `claude mcp add prbar -- prbar mcp`.
- A plain API client: connects to the server socket, or starts an in-process server when none is running, so it
  works on a Linux box with no app.
- Each MCP tool is one API call plus the write gate. If a tool needs something the API lacks, the API grows;
  MCP never reaches around it.

### Tools

- Read: `list_inbox`, `get_pr`, `get_review` (summary, findings, matched rules), `explain_rules(pr)`,
  `validate_config`, `get_action_log`.
- Run: `run_review(pr, profile?, force?)` with progress notifications.
- Write: `post_review`, `merge` through `ActionQueue` + undo window, new `ActionSource.agent(clientName)`.
  Gated by `mcp.writes: none | comment | all`, default `none`.

Main loop it enables: agent working on a PR in Claude Code calls `get_review`, fixes findings, pushes,
`run_review`, repeats.

### Open questions

- Agent-initiated approvals go through `decide` with `source: agent`? (Leaning yes, otherwise MCP bypasses the
  trust rules.)
- Do agent-posted reviews carry `PRBarVerdictMarker`? If yes, other instances skip their own review of that SHA
  because of an agent's post.
- Can agents edit rules? Leaning: read / validate / explain only; changes returned as a proposed diff for the
  user to apply.
- Does Settings need a full rule editor in v1, or is viewer + explain + external editor enough?

## Phasing

1. Split targets: `PRBarEngine` (pure) and `PRBarRuntime` (protocols + adapters) out of today's `PRBarCore`,
   CLI moved to its own target. Behaviour unchanged; this is what makes every later step reusable.
2. Move poller, action queue, readiness and stores into the runtime; replace SwiftData / UserDefaults with the
   file layout plus a one-time migration.
3. `PRBarAPI` + `PRBarServer` with the in-process transport; move the app's views onto the API client. Then the
   Unix socket transport and `prbar serve`.
4. Split observe / schedule / admit: poller emits events only, gates run at admit time on a fresh fetch.
   `Forge` protocol with the GitHub adapter; `ChangeRequest` replaces `InboxPR` in the engine.
5. Re-review triggers: honour re-request events, `/prbar review` comment command.
6. Commit-status claims (opt-in), verdict marker kept as read-only fallback.
7. Depend on `cel-swift` (its milestones M0 to M8: parser, checker, cost limits, unknowns, policy), `PolicyEvaluator` protocol in the engine, hot reload
   with last-good snapshots. Current behaviour expressed as generated stage policies, equivalence tests against
   `AutoReviewPolicy` on the same fixtures.
8. YAML loader + validation + CLI `explain` / `validate`; `prbar.json` deprecated. Facts-reference generator,
   JSON schema for `prbar.yaml` with its round-trip tests.
9. App reads the file; one-time export from `ReviewDefaults` + `RepoConfig`; Settings becomes viewer + explain +
   open in editor.
10. Includes from git, prompt parts, opt-in repo prompt files read at base SHA.
11. MCP (`prbar mcp`: read tools first, then run, then gated writes).
12. Web rule editor (react-querybuilder + `yaml` Document API) with the shape-check tests, in a WKWebView.
13. getsynq/cloud split A/B.
14. GitLab forge adapter.
15. Jev signals: finding-support check first (measurable against history), then admit-stage signals.
