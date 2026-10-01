import Foundation

enum ExecutableResolver {
    static let searchPaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.claude/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    /// `dirs` is injectable so tests can resolve against a fixture
    /// directory instead of the machine's real tool locations.
    static func find(_ name: String, in dirs: [String] = searchPaths) -> String? {
        let fm = FileManager.default
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
