# Rules: deciding what PRBar reviews and posts

The settings in `prbar.yaml` decide per repository: auto-approve on or off,
drafts reviewed or not. Rules decide on anything PRBar knows about a pull
request: who wrote it, its size, its title, the review's verdict, each finding
and where it is. They are written in [CEL](https://github.com/google/cel-spec),
the expression language Kubernetes and Google Cloud use for policies, in the
YAML policy format of [cel-go](https://github.com/cel-expr/cel-go).

Rules are optional. Without them, PRBar does exactly what `prbar.yaml` says.

## Where they live

A directory of their own, beside `prbar.yaml` (`~/.config/prbar/rules/`), or
wherever `$PRBAR_RULES` points. Settings never writes to it, so comments and
layout stay as you wrote them.

```
rules/
  lists.yaml               # named lists the rules can read
  select/                  # whether to review a PR at all
    10-skip-bots.yaml
  decide/                  # what to post once it is reviewed
    10-trusted.yaml
    50-share.yaml
```

- Every `*.yaml` / `*.yml` file in `select/` and `decide/` is one policy.
- They run in file name order, and the first policy whose rules match decides.
  A numeric prefix (`10-`, `50-`) sets the order.
- **When no rule matches, the settings in `prbar.yaml` decide**, as they did
  before. Rules can take over one case at a time.
- PRBar picks up an added, edited or removed file within about 2 seconds.

## A policy

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
      output: '{"rule": "trusted-approve", "action": "approve"}'
```

```yaml
# rules/lists.yaml
trusted: [alice, bob]
```

`match` is a list of `condition` / `output` pairs. The first condition that
holds produces its output. An entry without a condition always matches, so
put it last if you want a policy to decide every case. cel-go's policy format
also has `variables` (named sub-expressions) and nested rules; see its
[policy documentation](https://github.com/cel-expr/cel-go/tree/master/policy).

Every `output` carries a `rule` id. It is what `rules explain` and the review
row show, so make it say what the rule is for.

## Checked when they load

PRBar compiles the rules when it loads them. A misspelt fact, a fact the stage
doesn't have, a comparison of the wrong types or an output of the wrong shape
is refused with its file, line and column:

```
$ prbar-review rules check
prbar-review: rules don't compile:
ERROR: ~/.config/prbar/rules/decide/10-trusted.yaml:7:18: undefined field 'confidense'
 |         && review.confidense >= 0.85
 | .................^
```

- An edit that breaks the rules leaves the previous ones in effect. The error
  shows in Settings, in `prbar-review status` and in the `serve` log.
- If the rules don't compile when PRBar starts, nothing is posted on its own
  until they do (every `decide` answers "nothing"). PRBar still reviews.
- `prbar-review rules check` compiles them without a running PRBar, so you can
  check an edit before it is picked up.

Evaluation is bounded (a cost limit and one second per decision). A `select`
rule that fails to evaluate skips the review; a `decide` rule that fails posts
nothing. Both say why.

## The `select` stage: review or not

Runs for each PR where you are a requested reviewer, before any money is
spent. It also runs for `prbar-review <pr>` without `--force` and for a coding
agent's `run_review`.

Output:

| Field | Values |
|---|---|
| `rule` | the rule's id |
| `action` | `review` or `skip` |
| `reason` | optional, shown with a skip |

A `review` from a rule overrides the settings that would skip (drafts, AI
review off, title patterns). Two checks still apply after it, since they only
save repeating a run: a review that already failed at this commit, and a
verdict some PRBar already posted for this commit.

A coding agent can't override a rule's `skip`, even with `force`. You still
can, with Re-run in the app or `prbar-review --force`.

## The `decide` stage: what to post

Runs once a review completes, with the review's result as facts.

Output:

| Field | Values | Default |
|---|---|---|
| `rule` | the rule's id | |
| `action` | `approve`, `request_changes`, `comment`, `share`, `flag`, `none` | |
| `inline` | post findings as inline comments | off for `approve`, on otherwise |
| `min_severity` | only findings at or above this go inline, e.g. `severity.warning` | `severity.info` |
| `max_comments` | at most this many inline comments, worst first | 20 for `share`, no cap otherwise |
| `attribution` | `approve` with a one-line body naming PRBar | off |

What each action does:

- **`approve`**: a GitHub approval, with an empty body unless `attribution`.
- **`request_changes`**: a "request changes" review with the summary as its body.
- **`comment`**: a comment review with the summary, no verdict.
- **`share`**: the findings as inline comments, no verdict and no body, and
  your review request restored so the next push is reviewed again. With no
  findings at `min_severity` it posts nothing.
- **`flag`**: shown in PRBar as a request for changes, nothing posted.
- **`none`**: nothing posted.

Posts wait out the same 30-second undo window as the settings' auto-reviews.

## Facts

Field names are snake case. `select` sees `pr`, `trigger`, `viewer` and `lists`;
`decide` sees `pr`, `review`, `viewer` and `lists`. Using `review` in a select
rule is a load error, since no review exists yet.

`pr`:

| Field | Type | |
|---|---|---|
| `repo` | string | `owner/name` |
| `owner`, `name` | string | |
| `number` | int | 0 for a local review |
| `title`, `body`, `author` | string | |
| `base_ref`, `head_ref` | string | branch names |
| `draft` | bool | |
| `additions`, `deletions`, `changed_files` | int | |
| `requested` | bool | you are a requested reviewer |
| `authored` | bool | you opened it |
| `reviewed_by_others` | bool | another person approved or requested changes |
| `prbar_verdict_at_head` | bool | some PRBar already posted a verdict for this commit |
| `local` | bool | a local review (`prbar-review <dir>`), not a pull request |

`review` (decide only):

| Field | Type | |
|---|---|---|
| `verdict` | string | `approve`, `comment` (approve with notes), `request_changes`, `abstain` |
| `confidence` | double | 0 to 1 |
| `provider` | string | `claude` or `codex` |
| `findings` | list | each with `path`, `line_start`, `line_end`, `severity`, `title` |
| `max_severity` | severity | the worst finding's, `severity.info` when there are none |
| `cost_usd` | double | |

Others:

| Name | Type | |
|---|---|---|
| `trigger` | string | `review_requested`, `command` (`prbar-review <pr>`), `agent` (MCP) |
| `viewer` | string | your GitHub login |
| `lists` | map of string lists | from `rules/lists.yaml` |
| `severity.info` … `severity.blocker` | int | severities compare by rank: `info < suggestion < warning < blocker` |

Functions: CEL's standard library (`size`, `startsWith`, `endsWith`, `contains`,
`matches`, `in`, `exists`, `all`, `filter`, `map`, …), plus
`glob(path, pattern)` with the same patterns as `repoGlobs` (`*`, `**`).

## Examples

Skip dependency bumps opened by bots:

```yaml
# rules/select/10-bots.yaml
name: bots
rule:
  match:
    - condition: >-
        pr.author.endsWith("[bot]") && pr.title.startsWith("chore(deps)")
      output: '{"rule": "skip-dependency-bumps", "action": "skip", "reason": "dependency bump"}'
```

Review drafts in one repository:

```yaml
# rules/select/20-drafts.yaml
name: drafts
rule:
  match:
    - condition: pr.draft && pr.repo == "acme/api"
      output: '{"rule": "review-api-drafts", "action": "review"}'
```

Never let PRBar act on infrastructure on its own, share warnings elsewhere:

```yaml
# rules/decide/10-infra.yaml
name: infra
rule:
  match:
    - condition: review.findings.exists(f, glob(f.path, "infra/**")) || pr.repo.endsWith("-infra")
      output: '{"rule": "hands-off-infra", "action": "flag"}'
```

```yaml
# rules/decide/50-share.yaml
name: share
rule:
  match:
    - condition: review.confidence >= 0.5
      output: >-
        {"rule": "share-warnings", "action": "share",
         "min_severity": severity.warning, "max_comments": 10}
```

## Seeing why

```sh
prbar-review rules check                 # do they compile, which files
prbar-review rules explain acme/api#123  # why this PR is reviewed or not,
                                         # and what its review leads to
```

`explain` asks the running PRBar, which holds the PR and its review. It prints
every condition it evaluated with the value of each part and the facts it
read, then the outcome, including what the `prbar.yaml` settings decide when no
rule matched:

```
rules/select/10-bots.yaml:4:18 pr.author in lists.bots && pr.additions < 10 -> true
  true  pr.author in lists.bots   (pr.author = "renovate", lists.bots = ["renovate"])
  true  pr.additions < 10   (pr.additions = 4)
matched: small-bot-changes: skip (a bot, and small)

Outcome: skipped. The rule `small-bot-changes` skips it: a bot, and small.
```

Coding agents get the same through the MCP tool `explain_rules`.
