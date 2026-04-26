# Repository Guidelines

## Project Structure & Module Organization
`Sources/PRBar/` contains the macOS app code, grouped by responsibility: `Models/`, `Services/`, `UI/`, and `Util/`. Unit tests live in `Tests/PRBarTests/` and generally mirror the production type they cover, for example `PRPoller.swift` and `PRPollerTests.swift`. Bundled assets and runtime data live under `Resources/`, including `Assets.xcassets`, prompt templates, and JSON schemas. Use `docs/` for design notes and screenshots, and `bin/` for the supported local workflow scripts.

## Build, Test, and Development Commands
Prefer the wrapper scripts over raw `xcodebuild` calls:

- `bin/regen` regenerates `PRBar.xcodeproj` from `project.yml` with XcodeGen.
- `bin/build` regenerates the project and builds a Debug app into `build/Debug/`.
- `bin/test` regenerates the project and runs the `PRBar` XCTest suite.
- `bin/run` builds, kills any existing `PRBar` process, and launches the app.
- `bin/screenshots` runs `ScreenshotTests` and writes images to `docs/screenshots/`.

CI runs `bin/build` and `bin/test` on macOS 14, so local changes should pass both before opening a PR.

## Coding Style & Naming Conventions
This is a Swift 6 codebase targeting macOS 14. Follow the existing style: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and focused extensions/helpers rather than oversized files. Keep SwiftUI view names noun-based (`PRDetailView`, `InboxView`) and service types action-oriented (`PRPoller`, `ReviewCache`). Use brief comments only where intent is not obvious from the code.

## Testing Guidelines
Tests use XCTest with async coverage where appropriate. Name test files `*Tests.swift` and test methods `test...`, describing the behavior under test, for example `testPollNowFetchesAndStoresPRs`. Add or update targeted tests whenever changing polling, provider integration, diff parsing, or review flow behavior. Run `bin/test` for the full suite and `bin/screenshots` when UI output changes.

## Commit & Pull Request Guidelines
Recent commits use short scoped subjects such as `ci: build + test workflow on push and PR` and `prbar: derive version from git, inject at build time`. Keep that pattern: lowercase scope, colon, concise imperative summary. PRs should explain user-visible impact, note test coverage, and include screenshots when menu bar or popover UI changes. Do not commit generated `*.xcodeproj/` or `build/` artifacts; `project.yml` is the source of truth.
