---
name: prbar
description: Work with PRBar, the app that reviews the user's GitHub pull requests with an AI reviewer and decides by rules what to review and what to post on its own. Covers reading PRBar's findings on a PR and getting it re-reviewed after a fix, explaining why PRBar reviewed, skipped, approved or posted something, and changing its review rules — the user's own rules (drafted, measured against past decisions, proposed for the user to accept) or a repository's team rules in .prbar/rules (drafted in a checkout, measured, shipped by pull request). Use when the user mentions PRBar, its review of a PR, auto-approval, which PRs get AI review, limiting approval to some authors or teams, code-owner approvals, or .prbar/rules.
---

# PRBar

PRBar runs on the user's machine (the menu-bar app, or `prbar-review serve`). It polls their
GitHub review requests, reviews them with an AI reviewer, and posts on its own only what the
user's settings and **rules** allow. You reach it two ways, which do the same things through the
same server:

- the **`prbar` MCP tools** (this plugin starts them), and
- the **`prbar-review` CLI**.

This skill says what to do and in what order. **Names and options come from the running PRBar,
not from here**, so they are never stale:

| What you need | Where it comes from |
|---|---|
| tools and their arguments | the MCP tool list and each tool's schema and description |
| CLI commands and flags | `prbar-review --help`, and `prbar-review rules` with no subcommand |
| facts a rule can read, their types | `rules_catalog` with `stage` (CLI `prbar-review rules catalog <stage>`) |
| output fields, allowed actions and values | the same |
| functions, the user's list names, example rules | `rules_catalog` without arguments; `example: <id>` prints one |
| what the user lets agents do | `status` |
| full reference, for anything left | `docs/rules.md` and `docs/configuration.md` in the PRBar repository |

If something this skill names isn't in the tool list or the usage text, the installed PRBar
differs: trust what it says, and tell the user if a tool you need is missing.

## Start: is PRBar there, and what may you do?

Call `status` (CLI `prbar-review status`). It says whether PRBar is polling, the config file and
rules directory, how many rules each stage has, problems loading either, and `agents:` — one
permission per capability (`off`, `allow`, `ask`). Respect them; PRBar enforces them anyway and
its refusal says which one.

No answer means PRBar isn't running: ask the user to start the app. The CLI starts a temporary
server on its own when none is running.

## Reviews of a PR you are working on

1. `get_review` with the PR: verdict, summary, every finding with file and lines. Works for PRs
   PRBar no longer tracks, from its history.
2. Fix what applies, push.
3. `run_review` with the PR (or `path`, for uncommitted work in a checkout). It costs money: run
   it when there is something new, never to poll.
4. `watch` with the same PR until the review finishes, passing back the cursor it returns.
5. `get_review` again.

## How rules decide

Rules are CEL conditions in YAML files. Three stages, each a directory of files run in
**file-name order**:

- `configure/` — per-repository settings (models, budgets, auto-approve gates); sees only the
  repository.
- `select/` — whether a PR is reviewed at all.
- `decide/` — what is posted once a review is in.

What each stage's output may say, and every fact it can read, is in `rules_catalog`.

- **First match wins; no match falls through** to the layer below, so a rule takes over one case
  and leaves the rest alone.
- **Layers**, bottom up: the `prbar.yaml` settings, then the repository's `.prbar/rules` (only
  where the user trusts that repository), then the user's own rules. Each sees the answer under
  it as **`below`**. Adjust that answer instead of restating the settings: "where the settings
  would approve, share instead unless the author is on a list" is a condition on `below`, not a
  copy of the approval thresholds.
- **Lists**: `lists.yaml` beside the stage directories names lists of logins, read as
  `lists.<name>`. Each layer has its own.
- **Lazy facts** cost a GitHub call and are fetched only when an answer depends on them; the
  catalog's help says which. Put cheap conditions first so most PRs never need the call.
- **Errors fall on the quiet side.** A file that doesn't compile is refused with
  `file:line:column` and the previous rules stay. At runtime a failing `select` condition skips
  the review and a failing `decide` condition posts nothing.

## Writing a rule file

Start from the closest example (`rules_catalog`, then `example: <id>`), and check names against
`rules_catalog` with the stage. A file looks like this:

```yaml
# yaml-language-server: $schema=<the schema URL `prbar-review rules schema` and docs/rules.md give>
name: core-team-approves
rule:
  match:
    - condition: below.action == "approve" && !(pr.author in lists.core)
      output:
        rule: core-team-approves
        action: share
```

- `output:` is plain YAML, checked against the stage's fields when the rules load. `rule` is an
  id saying what it is for; it shows in PRBar and the history.
- Long conditions: `condition: >-`, then indented lines.
- A condition that starts with a quote is quoted whole: `'"security" in pr.labels'`.
- Types are strict: compare a double with `1.0`, not `1`.
- A fact that can be null (the catalog says which) needs `has(...)` before use.
- Several conditions in one file: the first that holds gives the output.
- File names with two-digit prefixes and gaps (`10-`, `25-`, `90-`), since order is by name as
  text; think about which existing file would match the same case first.

## Changing the user's own rules

Never write into the user's rules directory. Rules post under the user's name; a change is a
proposal the user accepts.

1. **Read what is there.** `status` gives the directory; read its files, so a new rule doesn't
   sit behind an earlier one matching the same case, and doesn't repeat one.
2. **Draft in a scratch directory** laid out like the rules directory, holding only the files you
   add or change. A file at the same path replaces the user's whole file: to edit one, or to add
   to `lists.yaml`, copy it and change the copy. Files to delete go in the remove option.
3. **Check** the draft (`check_rules`, CLI `rules check`): fix what it names.
4. **Explain** it on a PR or two it is about (`explain_rules` with the PR and the draft, CLI
   `rules explain <pr>`): every condition with the values it read, layer by layer, then the
   outcome. `decide` needs a completed review of the PR's current commit; without one it says
   there is nothing to decide yet.
5. **Measure** it (`rule_impact`, CLI `rules impact`): recorded decisions replayed with the
   draft, listing those whose answer changes. Decisions recorded before a lazy fact was fetched
   can't tell and are counted apart; explaining those PRs fetches the fact now.
6. Show the user the draft and its impact, then **propose** it (`propose_rules`, CLI
   `rules propose`) with a title and the reason: what they asked for, what the impact showed. It
   waits in PRBar's Settings → Rules (Try, Accept, Reject); the CLI's `rules proposals`,
   `accept` and `reject` do the same. Under `agents.rules: allow` it is saved at once; under
   `off` proposing is refused, so tell the user.

## Changing a repository's rules (`.prbar/rules`)

Team policy for everyone who trusts the repository in their PRBar. It changes through a pull
request, never through a proposal.

1. In a checkout, on a new branch, write `.prbar/rules/` in the same layout. Its `configure/`
   files are never applied: how a repository is reviewed (model, budgets) is each user's own
   setting.
2. Check, explain and measure with the repository-rules option pointing at the checkout (MCP
   `repo_rules`, CLI `--repo-rules`). It stands for the whole directory as it will be once
   merged, tried as if trusted. The repository comes from the checkout's `origin` remote, or
   name it explicitly.
3. Open the PR with the impact list in its description, so reviewers judge outcomes rather than
   CEL. Propose a CI step that runs the rules check with the repository-rules option on the
   checkout: rules that don't load make every trusting PRBar post nothing on that repository.
4. They apply from the default branch after merge, and only for users who trust the repository
   (`repositories.trustRules` in `prbar.yaml`, see `docs/configuration.md`). Say so if the user
   doesn't yet.
5. Team policy only. Preferences of one person, or rules naming colleagues to treat
   differently, go in that user's own rules.

## Why did PRBar do that?

- Now: `explain_rules` with only the PR — what the rules in effect decide for it and why, with
  the settings' answer where no rule matched.
- Past: `prbar-review rules history` lists recorded decisions (filter by PR or days);
  `prbar-review rules replay <id>` reruns one with every condition and says whether today's
  rules answer differently.
- A review that never happened: `get_review` gives the skip reason; a rule's skip names the rule.
