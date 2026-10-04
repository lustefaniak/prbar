# Writing rules

Rules decide three things on top of the review defaults in `prbar.yaml`: **how
each repository is reviewed** (`configure`), **whether to review a pull
request** (`select`), and **what to post once the review is in** (`decide`).
The defaults can say "auto-approve"; a configure rule can say "but not in
acme/docs"; a decide rule can say "approve when everyone who pushed is on the
trusted list, CI passed, nothing sensitive changed and the review found nothing
worse than a suggestion".

Rules are written in [CEL](https://github.com/google/cel-spec), the expression
language Kubernetes and Google Cloud use for policies, in the YAML policy format
of [cel-go](https://github.com/cel-expr/cel-go). They are optional: with no
rules, every repository is reviewed with the defaults in `prbar.yaml`.

The quickest way to start is **Settings → Rules** in the app: pick a PR to see
what decides it now, add a rule with `+`, and see what it changes before you
save ([Trying rules in PRBar](#trying-rules-in-prbar-settings--rules)).

- [Your first rule](#your-first-rule)
- [How a decision is made](#how-a-decision-is-made)
- [configure: settings per repository](#configure-settings-per-repository)
- [Writing conditions](#writing-conditions)
- [Editor support: the JSON schemas](#editor-support-the-json-schemas)
- [Working on rules: check, explain, history, replay](#working-on-rules-check-explain-history-replay)
- [Repository rules: one policy for a team](#repository-rules-one-policy-for-a-team)
- [Cookbook](#cookbook)
- [Pitfalls](#pitfalls)
- [Reference: stages and outputs](#reference-stages-and-outputs)
- [Reference: facts](#reference-facts)
- [Reference: functions](#reference-functions)

## Your first rule

Rules live in a directory of their own beside `prbar.yaml`:
`~/.config/prbar/rules/`, or wherever `$PRBAR_RULES` points. PRBar writes there
only when you save a file in Settings → Rules or run `rules convert`, so your
comments and layout stay as you wrote them.

**1. Write a policy.** Skip pull requests that only touch documentation:

```yaml
# rules/select/10-docs.yaml
name: docs
rule:
  match:
    - condition: only(pr.files, "docs/**")
      output:
        rule: skip-docs
        action: skip
        reason: documentation only
```

`select/` is the stage (whether to review), `10-` orders it among that stage's
files, and the `output` is what the rule decides.

**2. Check it.** PRBar compiles rules when it loads them; you can do the same
without waiting for it:

```
$ prbar-review rules check
Rules in /Users/you/.config/prbar/rules compile.
select: 10-docs.yaml
decide: none
```

A mistake is refused with its file, line and column:

```
$ prbar-review rules check
prbar-review: rules don't compile:
ERROR: /Users/you/.config/prbar/rules/select/10-docs.yaml:4:22: undeclared reference to 'onyl' (in container '')
 |     - condition: onyl(pr.files, "docs/**")
 | .....................^
```

**3. Try it on a real pull request.** With PRBar running:

```
$ prbar-review rules explain acme/api#412
acme/api#412 Fix typos in the setup guide (head 1c9e2f0)

## select

/Users/you/.config/prbar/rules/select/10-docs.yaml:4:18 only(pr.files, "docs/**") -> true
  (pr.files = [prbar.File{path: "docs/setup.md", additions: 4, deletions: 2, kind: "docs", sensitive: false, risk: 0.0011}])
matched: skip-docs: skip (documentation only)

Outcome: skipped. The rule `skip-docs` skips it: documentation only.

## decide

PRBar holds no completed review of this commit, so there is nothing to decide yet.
```

**4. Let it run.** The running PRBar picks the file up within about 2 seconds.
From then on every decision is recorded with the facts it was made on. When an
outcome surprises you, find it with `prbar-review rules history`, then
`prbar-review rules replay <id> --watch` and edit the rule until the replay
answers the way you want. See [Working on rules](#working-on-rules-check-explain-history-replay).

## How a decision is made

```
review requested ─▶ select ──review──▶ AI review ─▶ decide ─▶ post, flag, or nothing
                      │
                      └──skip──▶ shown in PRBar with the rule's reason
```

```
rules/
  lists.yaml               # named lists: trusted: [alice, bob]
  configure/               # settings per repository
    50-repos.yaml
  select/                  # whether to review
    10-bots.yaml
    20-docs.yaml
  decide/                  # what to post
    10-trusted.yaml
    90-share.yaml
```

For `select` and `decide`:

1. The stage's files run **in file name order**; within a file, the `match`
   entries run top to bottom.
2. **The first entry whose condition holds decides**, and nothing after it runs.
3. **When nothing matches, the settings in `prbar.yaml` decide**, exactly as
   they did before you had rules. So rules can take over one case at a time: a
   rule for bots, a rule for docs, the settings for everything else.

`configure` works differently, since it sets values rather than deciding one
thing: see the next section.

### Adjusting the settings instead of restating them: `below`

Every rule can read `below`: what would be decided if no rule matched, with
`below.action` and `below.reason`. That lets a rule change one thing about the
settings' answer and leave the rest to them. Auto-approve stays on in
`prbar.yaml`, but only for the people on a list:

```yaml
# rules/decide/10-approve-only-oldest.yaml
name: approve-only-oldest
rule:
  match:
    - condition: below.action == "approve" && !(pr.author in lists.oldest)
      output:
        rule: approve-only-oldest
        action: share
```

```yaml
# rules/lists.yaml
oldest: [alice, bob]
```

A PR the settings would approve gets its findings shared instead when its
author isn't on the list. Every other case matches nothing, so the settings
decide as usual, thresholds and all, without a rule repeating them.

A `select` rule's `review` overrides the settings that would skip (drafts, AI
review off, title patterns). Two checks still follow it, because they only stop
a repeat: a review that already failed at this commit, and a verdict some PRBar
already posted for this commit.

## configure: settings per repository

Everything that used to be a `repos:` entry in `prbar.yaml` is a configure
rule: how a repository's PRs are split, which model reviews them, the budgets,
the auto-approve, auto-deny and share gates, drafts, title patterns. Conditions
see the repository only: `repo.full_name`, `repo.owner`, `repo.name`, and
`lists`.

```yaml
# rules/configure/10-monorepo.yaml
name: monorepo
rule:
  match:
    - condition: repo.full_name == "acme/monorepo"
      output:
        rule: monorepo
        split_mode: perSubfolder
        root_patterns: [services/*/, lib/*/]
        max_cost_usd_per_subreview: 3
        exclude_title_patterns: ["[Prod deploy]*"]
    - condition: glob(repo.full_name, "acme/*")
      output:
        rule: acme
        auto_approve:
          enabled: true
          max_additions: 400
```

- **Within a file, the first match applies**, like the other stages.
- **Every file applies**, in name order, and a later file's fields replace an
  earlier one's. So one file can hold the layout of each repository and another
  the budgets for all of them.
- **What no rule sets comes from the defaults** in `prbar.yaml`, then PRBar's
  shipped default.
- The gate blocks (`auto_approve`, `auto_deny`, `resolve_threads`) replace the
  defaults' block as a whole: a field left out takes its shipped value.
- A configure rule that fails to evaluate turns posting off for that
  repository: what it would have set may have been what kept a post back.

Every field, with what it does, is in
[`configure.schema.json`](schema/rules/configure.schema.json), which your editor
uses to complete them. In PRBar, picking a PR in Settings → Rules shows the
settings its repository gets and which rules set them.

Which repositories PRBar triages at all, hides, and reads repository rules from
are lists in `prbar.yaml` instead (`repositories:`, see
[configuration.md](configuration.md#which-repositories-repositories)): they are
permissions, not review settings.

**Converting from `repos:`.** PRBar converts the `repos:` of an older
`prbar.yaml` itself when it loads it, into `rules/configure/50-repos.yaml` in
their order, after checking that every repository PRBar has seen resolves to the
same settings as before ([details](configuration.md#how-a-value-is-decided)).
`prbar-review rules convert [--dry-run]` does the same by hand.

## Writing conditions

A condition is a CEL expression that is `true` or `false`. If you have written
an `if:` in GitHub Actions or a SQL `WHERE`, it will feel familiar. What rules
mostly use:

| | |
|---|---|
| comparison | `pr.additions <= 200`, `review.verdict == "approve"` |
| logic | `&&`, `\|\|`, `!`, `cond ? a : b` |
| membership | `pr.author in lists.trusted`, `"security" in pr.labels` |
| strings | `pr.title.startsWith("chore:")`, `pr.body.contains("BREAKING")`, `pr.title.matches("^\\[WIP\\]")`, `pr.title.lowerAscii()` |
| lists | `size(pr.labels) > 0`, `pr.files.exists(f, f.kind == "test")`, `pr.files.all(f, f.kind == "docs")`, `pr.files.filter(f, f.sensitive).map(f, f.path)` |
| severities | `review.max_severity <= severity.suggestion`, `f.severity >= severity.warning` |
| time | `pr.age > duration("72h")`, `now - pr.updated_at < duration("1h")` |
| facts that may be missing | `has(pr.created_at) && ...` |

Three things to know:

- **Types are strict.** `pr.additions > 1.5` is an error (an int compared with
  a double), and so is `review.confidence >= 1`; write `1.0`. The error says
  which, when the rules load.
- **Some facts can be null**: timestamps on a local review, `pr.files` when it
  couldn't be fetched. Reading a field of null, or comparing it, fails the
  evaluation. Guard with `has(...)`: `has(pr.idle) && pr.idle > duration("720h")`.
- **Severities are numbers**: `severity.info` is 0, `suggestion` 1, `warning` 2,
  `blocker` 3, so they compare with `<` and `>=`.

### Reusing a piece: variables

A policy can name sub-expressions and use them in several conditions:

```yaml
# rules/decide/20-small.yaml
name: small
rule:
  variables:
    - name: small
      expression: pr.additions + pr.deletions <= 100 && pr.changed_files <= 5
    - name: clean
      expression: review.max_severity <= severity.suggestion
  match:
    - condition: variables.small && variables.clean && review.confidence >= 0.9
      output:
        rule: small-and-clean
        action: approve
    - condition: variables.small && !variables.clean
      output:
        rule: small-with-findings
        action: share
```

### YAML around the expression

Conditions and outputs are YAML strings, and YAML has opinions:

- **A condition that starts with a quote must be quoted as a whole**, or YAML
  takes the quote as its own and the file doesn't parse:
  `condition: '"security" in pr.labels'`, or reorder it:
  `condition: pr.labels.exists(l, l == "security")`.
- **Long conditions**: use `>-`, which folds the lines into one:

  ```
  - condition: >-
      pr.author in lists.trusted
      && review.verdict == "approve"
  ```


### Outputs

An `output` is what the rule decides when its condition holds: a `rule` id and
an `action`, plus the stage's optional fields
([select](#select-review-or-not), [decide](#decide-what-to-post)):

```yaml
# rules/decide/60-docs-share.yaml
name: docs-share
rule:
  match:
    - condition: only(pr.files, "docs/**")
      output:
        rule: share-docs-findings
        action: share
        min_severity: warning
        max_comments: 5
```

Each field is checked when the rules load: a misspelt field (`acton`), a value
that isn't allowed (`action: sahre`) or a missing `action` is refused with its
line. Short outputs fit on one line: `output: {rule: drafts, action: skip}`.

When a value has to be computed, write the whole output as a quoted CEL map
instead; its fields are the same, and are checked the same way:

```yaml
# rules/decide/70-big.yaml
name: big
rule:
  match:
    - condition: review.max_severity >= severity.warning
      output: '{"rule": "big-or-small", "action": pr.additions > 500 ? "flag" : "share"}'
```

## Editor support: the JSON schemas

Each kind of file in the rules directory has a JSON schema, so an editor with
YAML support (VS Code's YAML extension, JetBrains IDEs, Neovim's yaml-language-server)
completes the keys, lists the allowed `action`s and severities with what each
does, and underlines a mistake as you type. Start each file with the line for
its kind:

```
# yaml-language-server: $schema=https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/select.schema.json
# yaml-language-server: $schema=https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/decide.schema.json
# yaml-language-server: $schema=https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/configure.schema.json
# yaml-language-server: $schema=https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/lists.schema.json
```

Or map them once in VS Code's settings and skip the line:

```json
"yaml.schemas": {
  "https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/select.schema.json": "**/prbar/rules/select/*.yaml",
  "https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/decide.schema.json": "**/prbar/rules/decide/*.yaml",
  "https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/configure.schema.json": "**/prbar/rules/configure/*.yaml",
  "https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/lists.schema.json": "**/prbar/rules/lists.yaml"
}
```

`prbar-review rules schema select|decide|configure|lists` prints the schema of the
version you run, for offline use. The schema covers the file's shape and the
outputs; the conditions are CEL, which it can't check, so `rules check` stays
the final word.

## Trying rules in PRBar: Settings → Rules

The Rules tab in PRBar's Settings is the quickest way to write a rule and see
what it does before it decides anything:

- **Start from an example or the builder** (`+`). Examples cover the common
  cases (skip drafts or bots, approve only some authors, settings for one
  repository); the builder puts a rule together from choices: a fact, a
  comparison and a value per condition, then the outcome.
- **The files** of your rules directory, by stage, with an editor that colours
  the YAML and the CEL, numbers the lines, and completes as you type: facts
  after `pr.` (or `review.`, `below.`, `repo.`), your list names after
  `lists.`, severities, functions, output fields and their allowed values.
  **Facts** lists everything the file's stage can read with what it means; a
  click inserts it. A line that doesn't compile is marked. A new file
  (`+`) starts from a rule that compiles. An edit is held unsaved, and the dot
  beside the file name says so. **Open in Editor** opens a saved file in your
  editor, where the JSON schema completes it; saves there show in the tab.
- **Try on** a PR from your inbox, or a recent recorded decision. The settings
  its repository gets come first, with the configure rules that set them. Every
  condition is shown with whether it held, each part of it, and the facts it
  read, for each layer of rules, with what `below` was for that layer. This
  is `rules explain` as a tree, and it is evaluated against your unsaved edits
  as you type.
- **What the edits change**: the decisions of the last 60 days, replayed with
  your edits and with the rules as saved, and every one whose answer would
  differ. Pick one to see its conditions.
- **Save** writes the file and the rules load at once. A save is refused when
  the rules wouldn't compile with it, so the editor never leaves you with
  broken rules, and when the file changed on disk since you opened it.

Decisions are recorded even before you have any rules, so a first rule can be
tried against everything PRBar decided lately. The tab edits your own rules;
a repository's rules show in the trace but are edited in that repository.

## Working on rules: check, explain, history, replay

| Command | Needs PRBar running | What it answers |
|---|---|---|
| `prbar-review rules check` | no | Do the rules compile? Which files are in effect? |
| `prbar-review rules explain <pr>` | yes | For the PR as it is now: every condition, the value of each part, the facts it read, and the outcome, including what the settings decide when no rule matched. `decide` uses the review PRBar holds for the PR's current commit. |
| `prbar-review rules history` | no | What your rules decided recently, newest first. `--pr`, `--days` (7), `--limit` (20), `--json`. |
| `prbar-review rules replay <id>` | no | One recorded decision, run again with the rules as they are now: every condition, and whether the answer changed. A prefix of the id from `history` is enough. |
| `prbar-review rules replay` | no | Every decision from the last 7 days (`--days`, `--pr`), run again: which answers your edits would change. |
| `prbar-review rules catalog [stage]` | yes | Every fact, output field, function and example, from the PRBar that runs them. `--example <id>` prints one example. |
| `prbar-review rules check --draft <dir>` | yes | Does a draft compile, laid over your rules? |
| `prbar-review rules explain <pr> --draft <dir>` | yes | What the draft would decide for the PR, nothing saved. |
| `prbar-review rules impact --draft <dir>` | yes | Every decision recorded in the last 30 days (`--days`) replayed with the draft, listing the ones it changes. |
| `prbar-review rules propose --draft <dir> --title <text>` | yes | Hands the draft to PRBar to accept in Settings → Rules; `rules proposals`, `rules accept <id>`, `rules reject <id>`. |

A draft is a directory of rule files at their paths (`decide/50-x.yaml`,
`lists.yaml`), laid over yours; `--remove <path>` drops one of yours. With
`--repo-rules <checkout>` instead, it is a repository's `.prbar/rules` as it
would be once merged ([below](#repository-rules-one-policy-for-a-team)).
| `... replay --watch` | no | Replay again each time a rule file changes. |

**Every decision is recorded with the exact facts it was made on**, in
`~/.local/state/prbar/history/rules/YYYY-MM.jsonl`: the stage, the PR and its
head commit, every fact the rules could read, which rule matched (or that none
did), and a digest that identifies the rules that made it. Decisions are
recorded with no rules too, so there is something to replay a first rule
against. A record is written when the answer changes, not on every poll. Records are kept for 60 days. They
hold PR titles and bodies, and stay on your machine like the rest of PRBar's
history; `jq` reads them.

The loop for tuning a rule:

```
$ prbar-review rules history --pr acme/api#412
7f3a9c21  2026-10-01 14:02  decide  acme/api#412  share-warnings: share, from warning
4b1e0d77  2026-10-01 13:41  select  acme/api#412  no rule matched; the settings decide

$ prbar-review rules replay 7f3a --watch
decide of acme/api#412 Rework token refresh (head 9d2c4e1), recorded 2026-10-01 14:02

recorded: share-warnings: share, from warning   [rules 5c0e1b2a7d9f3e01]
now:      share-warnings: share, from warning   [rules 5c0e1b2a7d9f3e01]

/Users/you/.config/prbar/rules/decide/10-trusted.yaml:4:9 pr.author in lists.trusted && review.verdict == "approve" && ... -> false
  true   pr.author in lists.trusted   (pr.author = "alice", lists.trusted = ["alice", "bob"])
  true   review.verdict == "approve"   (review.verdict = "approve")
  false  review.max_severity <= severity.suggestion   (review.max_severity = 2)
...
```

Edit the rule in another window. Each save prints the replay again, with
`CHANGED` on the `now:` line when the answer differs from the recorded one.
Before leaving it, see what else the edit changes:

```
$ prbar-review rules replay
Replayed 38 evaluations from the last 7 days with the rules in /Users/you/.config/prbar/rules: 2 would change.

7f3a9c21  2026-10-01 14:02  decide  acme/api#412  share-warnings: share, from warning
    now: trusted-approve: approve
...
```

How to read them:

- Under each condition are its parts, the value of each, and in parentheses the
  facts it read. A part shown as `not evaluated` was never needed.
- `error:` means a condition failed to evaluate, which for `select` skips the
  review and for `decide` posts nothing.
- A replay runs on the recorded facts, not on the PR as it is now: that is what
  makes it repeatable. `pr.files`, `pr.committers` and `pr.codeowners` are in a record only if
  some rule needed them at the time ([lazy facts](#lazy-facts)); a replay that
  needs one the record lacks says `undecided: needs pr.files, which this
  snapshot doesn't have`. `rules explain <pr>` uses the PR's current state and
  fetches what it needs.
- A replay reads the lists of the rules it replays, so an edit to
  `lists.yaml` shows in it.
- Replays answer for the rules only. When no rule matches, the settings decide,
  and the record holds what the rules saw, not the settings, so a replay says
  `no rule matched; the settings decide` rather than guessing their answer.

## Repository rules: one policy for a team

A repository can keep rules for everyone who reviews it with PRBar, in
`.prbar/rules/` on its default branch, laid out like your own directory
(`select/`, `decide/`, `lists.yaml`). They apply only in your PRBar when you
trust that repository in `prbar.yaml`:

```yaml
repositories:
  trustRules: [acme/monorepo]
```

Its `configure/` files are not read: how a repository is reviewed on your
machine (the model, the budgets) stays yours to set.

They sit between your rules and the settings:

```
1. your rules           ~/.config/prbar/rules/      only you, decide first
2. the repository's     .prbar/rules/ on its default branch, the team's
3. prbar.yaml settings  when no rule matches
```

- **The highest layer that matches decides.** Each layer sees the answer of the
  layers under it as `below`; when the team's rule decided, `below.source` is
  `repo` and `below.rule` its id. So a private rule can adjust the team's
  answer without repeating it, as in [`below`](#adjusting-the-settings-instead-of-restating-them-below):

  ```yaml
  # rules/decide/05-no-auto-approve-for-some.yaml
  name: no-auto-approve-for-some
  rule:
    match:
      - condition: >-
          pr.repo == "acme/monorepo" && below.action == "approve"
          && pr.author in lists.reviewed_by_hand
        output:
          rule: no-auto-approve-for-some
          action: share
  ```

- **Read at the default branch, never the PR's head.** A PR that edits
  `.prbar/rules/` can't change how it is itself reviewed or approved; the change
  applies to everyone's PRBar once it is merged.
- **Each layer has its own lists.** The repository's rules read its
  `.prbar/rules/lists.yaml`, yours read yours, so neither can change what the
  other's names mean.
- **Fetched only when needed:** one GitHub call per repository, again only when
  the default branch's `.prbar/rules` changes, and nothing for repositories you
  don't trust.
- **When they don't load** (they don't compile, a file is too large to read, or
  they can't be fetched after three tries five minutes apart), nothing is posted
  on its own for that repository until they do; your rules still apply above them.
  The reason shows in `prbar-review status`.
- **Checking a change before it merges:** `rules check --repo-rules <checkout>`
  compiles the checkout's `.prbar/rules`; `rules explain <pr> --repo-rules
  <checkout>` shows what they would decide for a PR, as if trusted, each layer
  under its own heading; `rules impact --repo-rules <checkout>` replays the
  decisions recorded for that repository with them (the repository comes from
  the checkout's `origin`, or `--repo owner/name`), which is the list to put in
  the pull request. `rules history` marks decisions the repository's rules made,
  and `rules replay --repo-rules <checkout>/.prbar/rules` replays them against the
  rules in your checkout.

What belongs where: the team's agreed policy goes in the repository; anything
about specific colleagues, or your own preferences, stays in your directory.
Local reviews (`prbar-review <dir>`) use your rules only.

## Coding agents writing rules

`prbar-review mcp` gives a coding agent the same tools as the commands above:
`rules_catalog`, `check_rules`, `explain_rules` and `rule_impact` take a draft
(`draft_dir`, `remove`, or `repo_rules` for a repository's rules), and
`propose_rules` hands a draft of your rules to PRBar. It never saves on its own
unless you set `agents.rules: allow` ([configuration](configuration.md#coding-agents-agents)):
the proposal shows at the top of Settings → Rules with what it writes, why, and
how many recorded decisions it changes. Try opens its files as unsaved edits, to
see what they decide on PRs before you accept. A change of the file since it was
proposed refuses the accept, so it can't overwrite an edit you made meanwhile.

The loop an agent follows: the catalog for the stage, a draft in a scratch
directory, `check_rules`, `explain_rules` on a PR or two, `rule_impact`, then
`propose_rules` with the impact in its reason. For a repository's rules it
writes `.prbar/rules` in a checkout instead, checks and measures them the same
way with `repo_rules`, and opens a pull request with the impact list in its
description: the rules apply to everyone once it is merged.

## Cookbook

Skip dependency bumps opened by bots:

```yaml
# rules/select/10-bots.yaml
name: bots
rule:
  match:
    - condition: >-
        pr.author_is_bot && pr.title.startsWith("chore(deps)")
      output:
        rule: skip-dependency-bumps
        action: skip
        reason: dependency bump
```

Review drafts in one repository:

```yaml
# rules/select/20-drafts.yaml
name: drafts
rule:
  match:
    - condition: pr.draft && pr.repo == "acme/api"
      output:
        rule: review-api-drafts
        action: review
```

Skip documentation-only changes:

```yaml
# rules/select/30-docs.yaml
name: docs
rule:
  match:
    - condition: only(pr.files, "**.md") || only(pr.files, "docs/**")
      output:
        rule: skip-docs
        action: skip
        reason: documentation only
```

Leave first-time contributors and stale PRs to people:

```yaml
# rules/select/40-people.yaml
name: people
rule:
  match:
    - condition: pr.author_association in ["FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER"]
      output:
        rule: first-timers
        action: skip
        reason: 'first contribution, a person reviews it'
    - condition: has(pr.idle) && pr.idle > duration("720h")
      output:
        rule: stale
        action: skip
        reason: untouched for 30 days
```

A group of rules for some repositories only: nest them under one condition,
so the scope is written once. When none of the inner rules matches, the next
file decides:

```yaml
# rules/select/45-acme.yaml
name: acme
rule:
  match:
    - condition: glob(pr.repo, lists.acme_repos)
      rule:
        match:
          - condition: pr.draft
            output: {rule: acme-drafts, action: skip}
          - condition: has(pr.idle) && pr.idle > duration("336h")
            output: {rule: acme-stale, action: skip, reason: untouched for two weeks}
```

Review only what your team was asked about, not requests through other teams:

```yaml
# rules/select/50-team.yaml
name: team
rule:
  match:
    - condition: >-
        !(viewer in pr.requested_reviewers) && !("platform" in pr.requested_teams)
      output:
        rule: not-platform
        action: skip
        reason: requested through another team
```

Approve small changes from trusted people:

```yaml
# rules/decide/10-trusted.yaml
name: trusted
rule:
  match:
    - condition: >-
        pr.author in lists.trusted
        && review.verdict == "approve"
        && review.confidence >= 0.85
        && review.max_severity <= severity.suggestion
        && pr.additions <= 200
      output:
        rule: trusted-approve
        action: approve
```

```yaml
# rules/lists.yaml
trusted: [alice, bob]
```

Approve only when everyone who pushed is trusted, CI passed and nothing
sensitive changed:

```yaml
# rules/decide/20-trusted-commits.yaml
name: trusted-commits
rule:
  match:
    - condition: >-
        review.verdict == "approve" && review.confidence >= 0.85
        && pr.checks_state == "passed"
        && pr.committers.all(c, c in lists.trusted)
        && !pr.files.exists(f, f.sensitive && f.kind == "source")
      output:
        rule: trusted-commits-approve
        action: approve
```

Approve when the author owns every changed file in CODEOWNERS and the review
found nothing above a suggestion:

```yaml
# rules/decide/25-codeowner.yaml
name: codeowner
rule:
  match:
    - condition: >-
        review.verdict == "approve" && review.confidence >= 0.85
        && review.max_severity <= severity.suggestion
        && pr.codeowners.all(f, pr.author in f.owners)
      output:
        rule: codeowner-approves
        action: approve
```

Never act on infrastructure on its own:

```yaml
# rules/decide/30-infra.yaml
name: infra
rule:
  match:
    - condition: touches(pr.files, "infra/**") || pr.repo.endsWith("-infra")
      output:
        rule: hands-off-infra
        action: flag
```

Say so when a push fixed the blockers an earlier review found:

```yaml
# rules/decide/40-fixed.yaml
name: fixed
rule:
  match:
    - condition: >-
        review.prior.exists(p, p.max_severity == severity.blocker)
        && review.max_severity <= severity.suggestion
      output:
        rule: blockers-fixed
        action: comment
```

Approve a PR too big for the auto-approve caps once the author has dealt with
every finding PRBar shared on it: each thread replied to, or its code changed,
and none raised again. `below.held` holding only size gates means every other
gate passed (verdict, confidence, severity), so the rule doesn't restate them. A
PR PRBar never commented on still waits for a human.

```yaml
# rules/decide/50-follow-up.yaml
name: follow-up
rule:
  match:
    - condition: >-
        below.held.size() > 0
        && below.held.all(g, g in ["additions", "deletions", "files"])
        && review.threads.total > 0
        && review.threads.unaddressed == 0 && review.threads.raised_again == 0
      output:
        rule: follow-up-approve
        action: approve
```

Share warnings and blockers with the author, at most ten, for everything else:

```yaml
# rules/decide/90-share.yaml
name: share
rule:
  match:
    - condition: review.confidence >= 0.5
      output:
        rule: share-warnings
        action: share
        min_severity: warning
        max_comments: 10
```

## Pitfalls

- **Files are ordered by name, as text.** `9-x.yaml` runs after `10-y.yaml`,
  since "1" sorts before "9". Use two digits and leave gaps: `10-`, `20-`, `90-`.
- **A rule that matches decides, even when it says "nothing".** A `decide` rule
  with `"action": "none"` stops the settings from posting. That's the way to
  switch auto-approve off for some PRs, and also the way to do it by accident
  with an entry that has no condition.
- **`share` with no findings at `min_severity` posts nothing.** A summary on its
  own would have PRBar commenting on every PR it looks at.
- **Errors fall on the quiet side.** A `select` rule that fails skips the
  review; a `decide` rule that fails posts nothing. The reason is in the review
  row, in `rules explain`, and in the history.
- **`pr.files`, `pr.committers` and `pr.codeowners` can cost a GitHub call**, made only when a
  rule's answer depends on them. Put the cheap condition first,
  `pr.draft || only(pr.files, ...)`, and a draft is decided without the call.
- **Coding agents can't override a rule's `skip`**, even with `force`. You can,
  with Re-run in the app or `prbar-review --force`.

## Reference: stages and outputs

### `select`: review or not

Runs for each PR where you are a requested reviewer, before any money is spent;
also for `prbar-review <pr>` without `--force` and for a coding agent's
`run_review`.

| `output` field | Values |
|---|---|
| `rule` | the rule's id, shown in PRBar and in the history |
| `action` | `review` or `skip` |
| `reason` | optional, shown with a skip |

### `decide`: what to post

Runs once a review completes, with the review's result as facts.

| `output` field | Values | Default |
|---|---|---|
| `rule` | the rule's id | |
| `action` | `approve`, `request_changes`, `comment`, `share`, `flag`, `none` | |
| `inline` | post findings as inline comments: `true` or `false` | off for `approve`, on otherwise |
| `min_severity` | only findings at or above this go inline: `info`, `suggestion`, `warning`, `blocker` | `info` |
| `max_comments` | at most this many inline comments, worst first | 20 for `share`, no cap otherwise |
| `attribution` | `approve` with a one-line body naming PRBar | off |

- **`approve`**: a GitHub approval, with an empty body unless `attribution`.
- **`request_changes`**: a "request changes" review with the summary as its body.
- **`comment`**: a comment review with the summary, no verdict.
- **`share`**: the findings as inline comments, no verdict and no body, and your
  review request restored so the next push is reviewed again.
- **`flag`**: shown in PRBar as a request for changes, nothing posted.
- **`none`**: nothing posted.

Posts wait out the same 30-second undo window as the settings' auto-reviews.

### When the rules don't load

- An edit that breaks the rules leaves the previous ones in effect. The error
  shows in Settings, in `prbar-review status` and in the `serve` log.
- If the rules don't compile when PRBar starts, nothing is posted on its own
  until they do (every `decide` answers "nothing"). PRBar still reviews.
- Evaluation is bounded: a cost limit, and one second per decision.

### `configure`: settings per repository

Runs whenever a repository's settings are needed, with `repo` and `lists` as
facts. Its output fields are the settings; see
[configure: settings per repository](#configure-settings-per-repository) and the
[schema](schema/rules/configure.schema.json).

## Reference: facts

Field names are snake case. `configure` sees `repo` (`owner`, `name`,
`full_name`) and `lists`. `select` sees `pr`, `trigger`, `viewer`, `lists`
and `now`; `decide` sees the same with `review` in place of `trigger`. Using
`review` in a select rule is a load error, since no review exists yet.

### `pr`

| Field | Type | |
|---|---|---|
| `repo` | string | `owner/name` |
| `owner`, `name` | string | |
| `number` | int | 0 for a local review |
| `title`, `body` | string | |
| `author` | string | login |
| `author_association` | string | GitHub's: `OWNER`, `MEMBER`, `COLLABORATOR`, `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER`, `NONE`; empty when unknown |
| `author_is_bot` | bool | a GitHub App or a `[bot]` account |
| `labels` | list of strings | |
| `base_ref`, `head_ref` | string | branch names |
| `draft` | bool | |
| `additions`, `deletions`, `changed_files` | int | |
| `created_at`, `updated_at`, `head_committed_at` | timestamp, may be null | |
| `age`, `idle` | duration, may be null | since it was opened, since it last changed |
| `requested` | bool | you are a requested reviewer |
| `authored` | bool | you opened it |
| `requested_reviewers`, `requested_teams` | list of strings | logins and team slugs with a pending request |
| `reviews` | list | people's reviews: `author`, `state` (`approved`, `changes_requested`, `commented`, `dismissed`), `submitted_at`, `by_viewer` |
| `reviewed_by_others` | bool | another person approved or requested changes |
| `prbar_verdict_at_head` | bool | some PRBar already posted a verdict for this commit |
| `checks_state` | string | `passed`, `failed`, `pending`, or `none` with no checks |
| `checks` | list | each with `name` and `state` (`passed`, `failed`, `pending`, `unknown`) |
| `files` | list, may be null | the changed files, from the PR's diff ([lazy](#lazy-facts)) |
| `committers` | list of strings, may be null | everyone who authored or committed a commit, by login ([lazy](#lazy-facts)) |
| `codeowners` | list, may be null | every changed file with its code owners: `path`, `owners` (logins, teams expanded to their members), `teams` (`org/team`), `pattern` (the deciding CODEOWNERS line, null when none) ([lazy](#lazy-facts)) |
| `local` | bool | a local review (`prbar-review <dir>`), not a pull request |

Each of `pr.files`:

| Field | Type | |
|---|---|---|
| `path` | string | |
| `additions`, `deletions` | int | lines |
| `kind` | string | `source`, `test`, `manifest` (config and schema files: SQL, protobuf, YAML, JSON, Terraform, Dockerfiles, Makefiles, …), `generated` (lockfiles, generated or vendored code), `docs` |
| `sensitive` | bool | the path names an area like auth, secrets, tokens, sessions, crypto or permissions |
| `risk` | double | 0 to 1: size, a source file changed without its test, a sensitive area; damped for generated files and docs |

`kind`, `sensitive` and `risk` are the reading PRBar routes its review prompt
with, without the part that needs commit history.

### `review` (decide only)

| Field | Type | |
|---|---|---|
| `verdict` | string | `approve`, `comment` (approve with notes), `request_changes`, `abstain` |
| `confidence` | double | 0 to 1 |
| `provider` | string | `claude` or `codex` |
| `findings` | list | each with `path`, `line_start`, `line_end`, `severity`, `title`, `body` |
| `max_severity` | severity | the worst finding's, `severity.info` when there are none |
| `cost_usd` | double | |
| `subreviews` | list | per monorepo folder: `path` (empty for the root), `verdict`, `confidence`, `findings` (a count) |
| `prior` | list | reviews of earlier commits of this PR that were never posted, oldest first: `head_sha`, `verdict`, `confidence`, `findings` (a count), `max_severity` |
| `threads` | object | PRBar's inline threads already on the PR, posted by anyone's PRBar: `total`, `resolved`, and of the unresolved ones `outdated` (the code changed since), `answered` (the PR author replied), `unaddressed` (neither) and `raised_again` (this review reports the same finding). Null when the threads couldn't be read |

### `below`

What the layers under a rule would decide: the `prbar.yaml` settings' answer, or
the [repository's rules'](#repository-rules-one-policy-for-a-team) when they
matched.

| Field | Type | |
|---|---|---|
| `action` | string | `select`: `review` or `skip`. `decide`: `approve`, `request_changes`, `comment`, `share`, `flag` or `none` |
| `reason` | string | why, in words, when there is a reason: why the settings skip, why they post nothing, or why they share instead of approving (for example `confidence 0.72 below Claude threshold 0.85`, `PR has +3468 lines, cap is 200`) |
| `rule` | string | the id of the rule that decided, empty when the settings did |
| `source` | string | `settings`, or `repo` when the [repository's rules](#repository-rules-one-policy-for-a-team) decided |
| `held` | list | `decide`: every auto-approve gate in the settings this review fails, whichever layer decided below: `disabled`, `verdict`, `confidence`, `severity`, `count`, `additions`, `deletions`, `files`. Empty when the settings would approve, null in `select`. Use it instead of matching `reason`, whose wording can change |

### Others

| Name | Type | |
|---|---|---|
| `trigger` | string | select only: `review_requested`, `command` (`prbar-review <pr>`), `agent` (MCP) |
| `viewer` | string | your GitHub login |
| `lists` | map of string lists | from `rules/lists.yaml` |
| `now` | timestamp | when the rule runs |
| `severity.info` … `severity.blocker` | int | 0 to 3 |

### Lazy facts

`pr.files`, `pr.committers` and `pr.codeowners` can cost a GitHub call, so **PRBar gets them
only when a rule's answer depends on them**. The rules first run without them;
if they decide, nothing is fetched. Otherwise PRBar fetches exactly what the
undecided rule reads and runs the rules again. Meanwhile the PR is neither
reviewed nor skipped, usually for a second or two.

- `pr.files` comes from the PR's diff, which the review needs anyway: when a
  rule fetched it, the review uses the same copy. In `decide` the files are
  those of the diff the review read, so they are always there.
- `pr.committers` comes from the PR's commit list: one call per head commit.
- `pr.codeowners` reads CODEOWNERS (`.github/`, the root, then `docs/`, as
  GitHub does) from the PR's base branch, matches every changed file to its
  last matching line, and expands the teams that line names, which needs the
  `read:org` scope `gh auth login` asks for. Team members are kept for an
  hour. A file no line owns has no owners, so with no CODEOWNERS file
  `pr.codeowners.all(f, pr.author in f.owners)` is false.
- Each is kept for the PR's head commit; after a push they are fetched again
  only if a rule needs them again.
- A failed fetch (a GitHub rate limit, say) holds the PR back and is tried again
  by a later poll, five minutes apart, three times. Only then is the fact null:
  `has(pr.files)` is false, and a rule that reads it anyway fails, which skips
  the review or posts nothing.

## Reference: functions

- CEL's standard library: `size`, `in`, `startsWith`, `endsWith`, `contains`,
  `matches` (RE2 regular expressions, linear time), `exists`, `all`,
  `exists_one`, `filter`, `map`, `has`, `duration("72h")`, `timestamp(...)`,
  arithmetic on timestamps and durations; the [language
  definition](https://github.com/google/cel-spec/blob/master/doc/langdef.md) has
  the rest.
- cel-go's extension libraries: [strings](https://pkg.go.dev/github.com/google/cel-go/ext#Strings)
  (`lowerAscii`, `upperAscii`, `split`, `replace`, `trim`, `format`, …),
  [lists](https://pkg.go.dev/github.com/google/cel-go/ext#Lists) (`sort`,
  `distinct`, `flatten`, `slice`, …), [sets](https://pkg.go.dev/github.com/google/cel-go/ext#Sets)
  (`sets.contains`, `sets.intersects`, `sets.equivalent`) and
  [math](https://pkg.go.dev/github.com/google/cel-go/ext#Math) (`math.greatest`,
  `math.least`, …).
- `glob(path, pattern)`: the patterns `repoGlobs` use. `*` stays inside one
  folder, `**` crosses folders, `?` is one character.
- `glob(path, patterns)`: a list of patterns, read the way `repoGlobs` reads
  them: later patterns win, and `!` excludes. `glob(pr.repo, lists.team_repos)`
  with `team_repos: ["acme/*", "!acme/legacy"]` in `lists.yaml`.
- `touches(pr.files, pattern)`: some changed file matches.
- `only(pr.files, pattern)`: every changed file matches. False when there are
  no files, so "only docs changed" never holds for a change PRBar knows nothing
  about.

Coding agents get `rules explain` as the MCP tool `explain_rules`.
