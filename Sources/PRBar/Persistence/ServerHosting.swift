import Foundation

/// Where the PRBar server runs for this app.
enum ServerHosting: Equatable {
    /// Inside the app, as it always has. The default.
    case inProcess
    /// `prbar-review serve`, the copy bundled in the app, as a process of
    /// its own that starts and stops with the app (or one the user started
    /// with `prbar-review serve`, which the app leaves alone). Opt-in while
    /// it is new: `defaults write dev.lustefaniak.prbar serverHosting
    /// external`, or `PRBAR_SERVER=external` in the environment.
    case external

    static let defaultsKey = "serverHosting"

    static var current: ServerHosting {
        if AppDelegate.isHostingTests || ScreenshotMode.isActive { return .inProcess }
        let chosen = ProcessInfo.processInfo.environment["PRBAR_SERVER"]
            ?? UserDefaults.standard.string(forKey: defaultsKey)
        return chosen == "external" ? .external : .inProcess
    }
}
