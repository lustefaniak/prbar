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
            exclude: [
                // SwiftData @Model rows — app-only persistence.
                "Models/ActionLogEntry.swift",
                "Models/DiffCacheEntry.swift",
                "Models/InboxSnapshotEntry.swift",
                "Models/RepoConfigEntry.swift",
                "Models/ReviewLogEntry.swift",
                "Models/ReviewStateEntry.swift",
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
