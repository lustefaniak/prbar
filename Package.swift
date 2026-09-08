// swift-tools-version: 6.0
import PackageDescription

// Second build system over the same sources, deliberately: XcodeGen +
// xcodebuild still build the macOS app from Sources/PRBar as before, and
// this package exposes the platform-independent half of it as a library so
// a Linux CLI can reuse the review pipeline. Nothing here is used by the
// .app build — `bin/build` and `bin/test` are unaffected.
//
// The `sources` whitelist *is* the portability boundary: anything reaching
// for SwiftData, AppKit, UserNotifications, ServiceManagement or SwiftUI
// stays out and lives app-side.
let package = Package(
    name: "prbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRBarCore", targets: ["PRBarCore"]),
        .executable(name: "prbar-review", targets: ["prbar-review"]),
    ],
    targets: [
        .target(
            name: "PRBarCore",
            path: "Sources/PRBar",
            // `sources` below already decides what compiles, but SwiftPM
            // warns once per file it finds under the target path and can't
            // account for — 48 warnings that would bury a real one. Naming
            // the app-only half here keeps the build quiet, and keeps this
            // list readable as the inventory of what stays macOS-side.
            exclude: [
                "AppDelegate.swift",
                "PRBarApp.swift",
                "UI",
                "Screenshots",
                "Persistence",
                // SwiftData @Model rows — app-only persistence.
                "Models/ActionLogEntry.swift",
                "Models/DiffCacheEntry.swift",
                "Models/InboxSnapshotEntry.swift",
                "Models/RepoConfigEntry.swift",
                "Models/ReviewLogEntry.swift",
                "Models/ReviewStateEntry.swift",
                // SwiftData-backed stores; the CLI runs with these nil and
                // reaches them through the ReviewSinks protocols.
                "Services/ActionLogStore.swift",
                "Services/ReviewCache.swift",
                "Services/ReviewLogStore.swift",
                "Services/RepoConfigStore.swift",
                "Services/SnapshotCache.swift",
                "Services/GitHub/DiffStore.swift",
                "Services/GitHub/FailureLogStore.swift",
                // Polling, notifications, the write queue and launch-at-login:
                // the orchestrator's job, or AppKit-only.
                "Services/Actions",
                "Services/BadgeCounter.swift",
                "Services/LaunchAtLogin.swift",
                "Services/NotificationActions.swift",
                "Services/Notifier.swift",
                "Services/PRPoller.swift",
                "Services/ReadinessCoordinator.swift",
                // Reaches into UI/Settings for a "fix this setting" link.
                "Services/Review/ReviewFailureHint.swift",
            ],
            sources: [
                "CLI",
                "Models",
                "Util",
                "Services/AutoReviewPolicy.swift",
                "Services/GitHub/GHClient.swift",
                "Services/GitHub/GraphQLQueries.swift",
                "Services/GitHub/InboxResponse.swift",
                // EventDeriver — the ready-to-merge / CI-failed predicates,
                // shared with MyPRsScope's badge counting.
                "Services/NotificationEvent.swift",
                "Services/Providers",
                "Services/Review",
            ],
            resources: [
                .copy("Resources/schemas"),
                .copy("Resources/prompts"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PRBarCLITests",
            dependencies: ["PRBarCore"],
            path: "Tests/PRBarCLITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "prbar-review",
            dependencies: ["PRBarCore"],
            path: "Sources/prbar-review",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
