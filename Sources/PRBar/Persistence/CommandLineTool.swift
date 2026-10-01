import Foundation

/// Puts the `prbar-review` that ships inside the app on the user's PATH,
/// the way editors install their shell command: a symlink into the bundle,
/// so Sparkle updating the app updates the command too.
///
/// `~/.local/bin` rather than `/usr/local/bin`: no admin prompt, and it is
/// already on PATH for anyone who installed Claude Code natively, which is
/// who runs `prbar-review mcp`.
enum CommandLineTool {
    enum State: Equatable {
        case notInstalled
        /// The link points at this app's copy.
        case installed
        /// A link to some other copy, e.g. a dev build or an older location.
        case linkedElsewhere(String)
        /// A real file PRBar didn't put there. Never overwritten.
        case otherFile
    }

    enum InstallError: Error, LocalizedError {
        case notOurs(String)
        case missingBinary(String)

        var errorDescription: String? {
            switch self {
            case .notOurs(let path):
                return "\(path) already exists and isn't a link PRBar made, so it was left alone."
            case .missingBinary(let path):
                return "This copy of PRBar has no command-line tool at \(path)."
            }
        }
    }

    static var bundledBinary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/prbar-review")
    }

    static func defaultLink(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/prbar-review")
    }

    static func state(link: URL = defaultLink(), binary: URL = bundledBinary) -> State {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            return resolved.path == binary.standardizedFileURL.path ? .installed : .linkedElsewhere(resolved.path)
        }
        return (try? fm.attributesOfItem(atPath: link.path)) == nil ? .notInstalled : .otherFile
    }

    /// Links `link` to `binary`, replacing a link that points elsewhere.
    static func install(link: URL = defaultLink(), binary: URL = bundledBinary) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binary.path) else { throw InstallError.missingBinary(binary.path) }
        switch state(link: link, binary: binary) {
        case .installed:
            return
        case .otherFile:
            throw InstallError.notOurs(link.path)
        case .linkedElsewhere:
            try fm.removeItem(at: link)
        case .notInstalled:
            break
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: binary)
    }

    /// Removes the link; a real file at that path is left alone.
    static func uninstall(link: URL = defaultLink()) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try FileManager.default.removeItem(at: link)
    }
}
