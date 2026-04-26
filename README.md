# PRBar

A native macOS menu-bar app that closes the PR review/merge feedback loop. Polls GitHub via the `gh` CLI, runs AI reviews via the `claude` CLI on incoming review requests, and surfaces "ready to merge" / "ready to review" notifications. No GitHub OAuth, no API keys — reuses authenticated CLI tools.

Full design: [docs/PLAN.md](docs/PLAN.md).

## Status

Phase 0 — skeleton. The app launches, sits in the menu bar, smoke-tests that `gh` / `claude` / `git` are reachable from a sandbox-free subprocess.

## Requirements

- macOS 14 or later
- **Xcode 15+** (full Xcode, not just Command Line Tools — `xcodebuild` needs it)
- Homebrew
- `gh` authenticated: `gh auth login`
- `claude` logged in (Claude Code Max subscription)

## First-time setup

```sh
brew install xcodegen
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer  # if Xcode just installed
bin/regen     # generate PRBar.xcodeproj from project.yml
bin/build     # compile
bin/run       # launch
```

After launch, look for the `text.bubble` icon in the menu bar (top-right of the screen). Click it to see the popover.

## Daily workflow

```sh
bin/build     # regenerates project + builds
bin/test      # regenerates project + runs unit tests
bin/run       # build + launch (kills any prior instance)
```

For SwiftUI Previews, the Xcode debugger, or visual project inspection: `open PRBar.xcodeproj`.

**Don't commit `PRBar.xcodeproj/`** — it's regenerated from `project.yml` and is gitignored.

## Layout

```
project.yml         XcodeGen spec — source of truth for project config
Sources/PRBar/      Swift sources, organized by responsibility
Resources/          Bundled assets (prompts, schemas, monorepo configs)
Tests/PRBarTests/   XCTest cases
bin/                Wrapper scripts (build, test, run, regen)
docs/               Plan + architecture notes
```
