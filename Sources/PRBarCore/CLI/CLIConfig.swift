import Foundation

/// How the CLI finds its config: the same `PRBarConfig` the app uses,
/// from the same file by default, with the rules directory beside it.
///
/// Note what the shipped defaults mean here: auto-approve, auto-deny and
/// share-findings are all off, so an unconfigured run reviews the PR and
/// posts nothing. That is the safe default, not a broken one — turn on at
/// least `shareFindings` to get anything onto the PR.
enum CLIConfig {
    /// `--config`, else `$PRBAR_CONFIG`, else `./prbar.yaml` / `./prbar.json`
    /// in the working directory, else the user config the app writes
    /// (`~/.config/prbar/prbar.yaml`). No file at all is a valid
    /// configuration; a file that was asked for explicitly must exist.
    static func load(
        path explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        warn: (String) -> Void = { FileHandle.standardError.write(Data("prbar-review: \($0)\n".utf8)) }
    ) throws -> PRBarConfig {
        let located = try locate(path: explicit, environment: environment, workingDirectory: workingDirectory, home: home)
        var config = PRBarConfig()
        if let located {
            let loaded = try ConfigFile.load(url: located)
            loaded.warnings.forEach(warn)
            config = loaded.config
        }
        // The rules directory sits beside the config file, or beside where
        // the app's would be when there is none.
        let configFile = located ?? ConfigLocation.userConfigURL(environment: environment, home: home)
        config.compiledRules = try RuleDirectory.load(RuleDirectory.url(configFile: configFile, environment: environment))
        return config
    }

    /// The file `load` reads, or nil when there is none.
    static func locate(
        path explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL? {
        let fm = FileManager.default
        let required: URL?
        if let explicit {
            required = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        } else if let env = environment["PRBAR_CONFIG"], !env.isEmpty {
            required = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            required = nil
        }

        let url: URL
        if let required {
            guard fm.fileExists(atPath: required.path) else {
                throw ConfigFile.Error.unreadable(path: required.path, reason: "no such file")
            }
            url = required
        } else {
            let candidates = [
                workingDirectory.appendingPathComponent("prbar.yaml"),
                workingDirectory.appendingPathComponent("prbar.json"),
                ConfigLocation.userConfigURL(environment: environment, home: home),
            ]
            guard let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
                return nil
            }
            url = found
        }
        return url
    }
}
