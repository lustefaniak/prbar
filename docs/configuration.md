# Configuring PRBar: `prbar.yaml`

PRBar's review settings live in one YAML file, read by both the menu-bar app and
the `prbar-review` CLI:

- **Location:** `~/.config/prbar/prbar.yaml`. `$PRBAR_CONFIG` overrides it, and
  `$XDG_CONFIG_HOME` moves it. The CLI also accepts `--config <path>`, and looks for
  `./prbar.yaml` / `./prbar.json` in the working directory before the app's file.
- **Format:** YAML. JSON is valid YAML, so an older `prbar.json` still loads.
- **Editing:** use Settings in the app, or edit the file by hand. The app picks up
  hand edits within about 2 seconds. Saving from Settings rewrites the file: your
  values are kept, comments and formatting are not.
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

1. **The first repo rule in `repos:` whose `repoGlobs` match** the repository
   (`owner/repo`). Rules are tried in file order and only one rule applies; a later
   matching rule is never consulted.
2. **`defaults:`**
3. **PRBar's shipped default** for that setting.

```yaml
defaults:
  maxCostUsdPerSubreview: 5      # every repo: $5, unless a rule says otherwise

repos:
  - repoGlobs: [acme/monorepo]
    maxCostUsdPerSubreview: 10   # acme/monorepo: $10
  - repoGlobs: [acme/docs]
    aiReviewEnabled: false       # acme/docs: AI off, cost cap still $5 (from defaults)
```

`reviewTimeoutSeconds` is set nowhere above, so every repository gets the shipped
600.

### A key present in a repo rule is an override; a missing key inherits

Inside a `repos:` entry, **the presence of a key is what makes it an override.**
Leave a key out and the repository follows `defaults:` (and, through it, the shipped
default) for that setting, including any later change you make there.

A key that is present pins its value for that repository, even when the value
happens to equal the current default:

```yaml
repos:
  - repoGlobs: [acme/api]
    reviewTimeoutSeconds: 600    # pinned: raising defaults.reviewTimeoutSeconds
                                 # later does NOT change acme/api
```

To make a repository follow the defaults again, delete the line, or untick the
checkbox next to the field in Settings → Repositories (unticked fields come from
Review defaults).

> **Rules migrated from older PRBar versions list almost every field.** Before
> settings could be inherited, a repo rule stored a value for every field, so
> migration kept them all as explicit overrides: dropping the ones that equal
> today's defaults would change what those rules do. Delete the lines you don't
> mean to pin.

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

- A repo rule with an `autoApprove:` block replaces `defaults.autoApprove`
  entirely.
- Fields left out of a block take PRBar's **shipped** values for that block, not
  the values in `defaults:`.

```yaml
defaults:
  autoApprove:
    enabled: true
    minConfidence: 0.9
    maxAdditions: 500

repos:
  - repoGlobs: [acme/web]
    autoApprove:
      enabled: true
      # minConfidence is 0.85 and maxAdditions is 200 here: the shipped values,
      # not 0.9 / 500 from defaults. Repeat them if you want them.
```

This is deliberate: half-inherited gates on something that approves PRs on GitHub
are too easy to misread. Each block shows exactly what applies.

The app writes only the fields of a block that differ from the shipped values, but
always writes `enabled` (or `action` for `autoDeny`), so a block is never empty.

### How lists combine

- **`excludeTitlePatterns` combines:** the repository's patterns are **added** to
  the ones in `defaults:`. To exempt one repository from a pattern in `defaults:`,
  add the same pattern prefixed with `!` to its rule (`"!chore: bump *"`).
- **`agentEnvironment` merges key by key:** a repository's variables are applied on
  top of the ones in `defaults:`. A key written as `!NAME` removes an inherited
  variable.
- **Every other list** (`rootPatterns`, `repoGlobs`) belongs to the rule and is
  not inherited.

### Settings that use a value for "off"

Two settings need a value that means "off", because leaving the key out already
means "inherit":

- `collapseAboveSubreviewCount: 0` turns collapsing off.
- `customSystemPrompt: ""` means no custom prompt.

## Top-level keys

| Key | Meaning |
|---|---|
| `version` | File format version, currently `1`. A file with a newer version than this PRBar understands is refused rather than half-read. |
| `defaultProvider` | `auto`, `claude` or `codex`. `auto` picks claude when it's installed, else codex. Missing means `auto`. A repo's `providerOverride` wins. |
| `defaultClaudeModel`, `defaultCodexModel` | Passed as `--model`. Missing means PRBar's default (`sonnet` for claude; none for codex). `""` passes no flag, so the CLI's own configured default applies. A repo's `claudeModelOverride` / `codexModelOverride` wins. |
| `defaultClaudeEffort`, `defaultCodexEffort` | Same, for effort. Missing or `""` passes no flag. |
| `defaults` | Review settings for every repository (see above). |
| `repos` | Repo rules, first match wins (see above). |
| `agents` | What coding agents may do through `prbar-review mcp` (see below). |

The review settings themselves (`defaults:` keys, and the same keys in a repo rule)
are the fields of
[`ReviewDefaults`](../Sources/PRBarCore/Models/ReviewDefaults.swift) and
[`RepoConfig`](../Sources/PRBarCore/Models/RepoConfig.swift), each with a comment
explaining it. A few keys exist only on repo rules: `repoGlobs` (required),
`excluded`, `rootPatterns`, `providerOverride`, the model and effort overrides, and
`skipMergeConfirmation`. The name `toolMode` in `defaults:` is
`toolModeOverride` in a repo rule.

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

- PRBar itself enforces it, for every client that connects as an agent, whether the
  app or `prbar-review serve` is running.
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
