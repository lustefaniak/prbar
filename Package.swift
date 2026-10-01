// swift-tools-version: 6.0
import PackageDescription

// Second build system over the same sources, deliberately: XcodeGen +
// xcodebuild build the macOS app from Sources/PRBar *and* Sources/PRBarCore
// as one module, and this package builds Sources/PRBarCore alone as a
// library so a Linux CLI can reuse the review pipeline. `bin/build` and
// `bin/test` are unaffected by it.
//
// The directory is the portability boundary: anything under
// Sources/PRBarCore must build on Linux (the `linux-cli` CI job), so code
// that needs SwiftData, AppKit, UserNotifications, ServiceManagement or
// SwiftUI lives in Sources/PRBar.
let package = Package(
    name: "prbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRBarCore", targets: ["PRBarCore"]),
        .executable(name: "prbar-review", targets: ["prbar-review"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        // The rules engine. Pinned to a commit until cel-swift tags 0.1.0;
        // project.yml pins the same one.
        .package(url: "https://github.com/lustefaniak/cel-swift", revision: "cded182490b9aa36d55051c4519b2e238ec46f23"),
    ],
    targets: [
        .target(
            name: "PRBarCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "CEL", package: "cel-swift"),
                .product(name: "CELPolicy", package: "cel-swift"),
                .product(name: "CELSwift", package: "cel-swift"),
            ],
            path: "Sources/PRBarCore",
            // Compiled in as EmbeddedResources (bin/gen-resources), so the
            // CLI ships as one file.
            exclude: ["Resources"],
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
