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

    static func find(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
