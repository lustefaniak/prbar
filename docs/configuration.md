# Configuring PRBar: `prbar.yaml`

PRBar's review settings live in one YAML file, read by both the menu-bar app and
the `prbar-review` CLI:

- **Location:** `~/.config/prbar/prbar.yaml`. `$PRBAR_CONFIG` overrides it, and
  `$XDG_CONFIG_HOME` moves it. The CLI also accepts `--config <path>`, and looks for
  `./prbar.yaml` / `./prbar.json` in the working directory before the app's file.
- **Format:** YAML. JSON is valid YAML, so an older `prbar.json` still loads.
- **Editing:** use Settings in the app, or edit the file by hand. The app picks up
  hand edits within about 2 seconds. Saving from Settings rewrites the file: your
  values are kept, comments and formatting are not. What differs per repository is
  not in this file: it is set by `configure` rules (see below).
- **Errors:**
  - A file that doesn't parse leaves the previous configuration in effect, and the
    error shows in Settings → Review defaults (stderr for the CLI). At launch, a
    broken file falls back to the last copy that loaded
    (`~/.local/state/prbar/config.last-good.yaml`).
  - Unknown keys (typos, or keys from a newer PRBar) are reported as warnings and
    ignored.

A complete example: [`prbar.example.yaml`](prbar.example.yaml).

## How a value is decided

Every review setting is resolved for a specific repository, in three layers. The
first layer that sets a value wins:

1. **What the `configure` rules set** for the repository: policies in
   `rules/configure/` beside this file, matched on the repository's name. Each
   file's first match applies; files run in name order, and a later file's
   fields replace an earlier one's. [rules.md](rules.md#configure-settings-per-repository)
   explains them.
2. **`defaults:`**
3. **PRBar's shipped default** for that setting.

```yaml
# prbar.yaml
defaults:
  maxCostUsdPerSubreview: 5      # every repository: $5, unless a rule says otherwise
```

```yaml
# rules/configure/10-repos.yaml
name: repos
rule:
  match:
    - condition: repo.full_name == "acme/monorepo"
      output:
        rule: monorepo
        max_cost_usd_per_subreview: 10   # acme/monorepo: $10
    - condition: repo.full_name == "acme/docs"
      output:
        rule: docs
        ai_review_enabled: false         # acme/docs: AI off, cost cap still $5
```

`reviewTimeoutSeconds` is set nowhere above, so every repository gets the shipped
600.

Older versions kept per-repository settings in a `repos:` list in this file.
**A `prbar.yaml` that still has `repos:` is refused** until it is converted, and
PRBar reviews nothing and posts nothing on its own meanwhile.
Convert with the button in Settings → Rules, or:

```sh
prbar-review rules convert --dry-run   # print the rule it would write
prbar-review rules convert
```

It writes `rules/configure/50-repos.yaml`, keeping the entries in their order
(the first that matches a repository sets its settings, as before), moves
`excluded` and `trustRepoRules` into the `repositories:` lists below, and keeps
the old file as `prbar.yaml.before-rules`. Before writing anything it checks
that every repository PRBar has seen (the inbox, the review and rule histories,
and a name for each pattern) resolves to the same settings both ways, and
writes nothing if one doesn't.

### In `defaults:`, a missing key means the shipped default

`defaults:` only contains settings you changed. The app writes a key there when its
value differs from PRBar's shipped default, and removes it when you set it back.
Two consequences:

- An empty or missing `defaults:` is valid and means "PRBar's defaults".
- A setting you never changed follows the shipped default, including when a newer
  PRBar version changes that default.

### Gate blocks override as a whole

`autoApprove`, `autoDeny` and `resolveThreads` are blocks of several fields that
inherit **as one unit**, not field by field:

- A configure rule with an `auto_approve:` block replaces `defaults.autoApprove`
  entirely for its repositories.
- Fields left out of a block take PRBar's **shipped** values for that block, not
  the values in `defaults:`.

```yaml
# prbar.yaml
defaults:
  autoApprove:
    enabled: true
    minConfidence: 0.9
    maxAdditions: 500
```

```yaml
# rules/configure/20-web.yaml
name: web
rule:
  match:
    - condition: repo.full_name == "acme/web"
      output:
        rule: web
        auto_approve:
          enabled: true
          # min_confidence is 0.85 and max_additions is 200 here: the shipped
          # values, not 0.9 / 500 from defaults. Repeat them if you want them.
```

This is deliberate: half-inherited gates on something that approves PRs on GitHub
are too easy to misread. Each block shows exactly what applies.

### How lists combine

- **`excludeTitlePatterns` combines:** a rule's `exclude_title_patterns` are
  **added** to the ones in `defaults:`. To exempt a repository from a pattern in
  `defaults:`, add the same pattern prefixed with `!` (`"!chore: bump *"`).
- **`agentEnvironment` merges key by key:** a rule's `agent_environment` is applied
  on top of the one in `defaults:`. A key written as `!NAME` removes an inherited
  variable.
- **Every other list** (`root_patterns`) belongs to the rule and is not inherited.

### Settings that use a value for "off"

Two settings need a value that means "off", because leaving the key out already
means "inherit":

- `collapseAboveSubreviewCount: 0` (`collapse_above_subreview_count: 0` in a
  rule) turns collapsing off.
- `customSystemPrompt: ""` means no custom prompt.

## Which repositories: `repositories:`

Three lists of repository patterns (`owner/repo` globs, a later pattern winning,
`!` leaving one out). They are permissions rather than review settings, so they
stay in this file, where they can be read at a glance:

```yaml
repositories:
  triage: ["acme/*", "me/*"]     # review requests PRBar triages; leave out for all
  hide: ["*/infra-*"]            # never shown in PRBar
  trustRules: ["acme/monorepo"]  # whose own .prbar/rules are read
```

- **`triage`**: PRBar reviews review requests only from these. Leave it out to
  triage every repository.
- **`hide`**: these never appear in PRBar at all.
- **`trustRules`**: these repositories' own rules, `.prbar/rules/` on their
  default branch, decide between your rules and your settings. They decide what
  is posted under your name, so list only repositories whose maintainers you
  trust. See [rules.md](rules.md#repository-rules-one-policy-for-a-team).

Settings → Review defaults edits them, one pattern per line.

## Top-level keys

| Key | Meaning |
|---|---|
| `version` | File format version, currently `1`. A file with a newer version than this PRBar understands is refused rather than half-read. |
| `defaultProvider` | `auto`, `claude` or `codex`. `auto` picks claude when it's installed, else codex. Missing means `auto`. A configure rule's `provider` wins. |
| `defaultClaudeModel`, `defaultCodexModel` | Passed as `--model`. Missing means PRBar's default (`sonnet` for claude; none for codex). `""` passes no flag, so the CLI's own configured default applies. A configure rule's `claude_model` / `codex_model` wins. |
| `defaultClaudeEffort`, `defaultCodexEffort` | Same, for effort. Missing or `""` passes no flag. |
| `defaults` | Review settings for every repository (see above). |
| `repositories` | Which repositories PRBar triages, hides, and reads rules from (see above). |
| `agents` | What coding agents may do through `prbar-review mcp` (see below). |

The review settings in `defaults:` are the fields of
[`ReviewDefaults`](../Sources/PRBarCore/Models/ReviewDefaults.swift), each with a
comment explaining it. A configure rule sets the same settings in snake case
(`maxCostUsdPerSubreview` is `max_cost_usd_per_subreview`), plus a few that only
make sense per repository: `root_patterns`, `provider`, the model and effort
overrides, and `skip_merge_confirmation`. The JSON schema
[`configure.schema.json`](schema/rules/configure.schema.json) lists every one.

## Rules

Everything that differs per repository, and decisions the settings can't
express, live in rules: CEL policies in a directory of their own beside this
file (`rules/`), never in `prbar.yaml`. Settings → Rules edits and tries them.
[rules.md](rules.md) is the guide.

## Coding agents: `agents:`

`prbar-review mcp` lets a coding agent such as Claude Code or codex use PRBar.
`agents:` sets what such an agent may do, one capability per key, each `off`,
`allow` or `ask`:

```yaml
agents:
  read: allow      # inbox, reviews, history, status
  review: allow    # start an AI review
  post: ask        # comment, approve, request changes
  merge: off
```

Those are the shipped values, so a missing `agents:` means exactly this.

- PRBar enforces it for every client that connects as an agent (`prbar-review mcp`
  does), whether the app or `prbar-review serve` is running. It limits what PRBar
  does on an agent's behalf; it is not a sandbox. An agent with a shell runs as
  you and could run `gh pr merge` itself, or talk to PRBar's socket without saying
  it's an agent. Use your agent's own permission settings to restrict its shell.
- `review: allow` still respects the repository's own settings: an agent can't
  start a review where `aiReviewEnabled` is off, the repo is `excluded`, or the
  title matches `excludeTitlePatterns`. For drafts, already-reviewed PRs or a
  failed review at the same commit it gets the reason, and can pass `force`.
- `ask` means PRBar asks you before acting. Asking isn't built yet, so for now `ask`
  refuses, and the agent is told to have `allow` set if you want it.
- A value other than `off`, `allow` or `ask` turns that capability **off**, rather
  than falling back to its default: a typo in a permission must not grant more than
  you wrote.
- Your own use of PRBar (the app, `prbar-review status` and the other CLI commands)
  is never limited by it.

## Not in this file

Machine-local preferences stay in the app's own settings: launch at login, the
menu-bar badge, notification and inbox display options, the daily cost cap (the
CLI's `serve --daily-cap`), and whether merges ask for confirmation by default.
