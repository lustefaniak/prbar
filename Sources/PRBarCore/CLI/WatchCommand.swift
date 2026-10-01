import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `prbar-review watch`: the menu-bar app's runtime without the menu bar.
/// Polls the inbox, reviews incoming review requests, posts whatever the
/// config's gates allow, keeps the shared history and state files, and
/// prints a line per event to stderr. Runs until interrupted.
///
/// It takes the runtime lock: with the app (or another watch) already
/// automating as the same user, it refuses to start rather than review and
/// post a second time.
enum WatchCommand {
    struct Options: Equatable {
        var configPath: String?
        /// Nil keeps the app's default cap; `0` turns it off.
        var dailyCapUsd: Double?

        init?(args: [String]) {
            var i = args.startIndex
            while i < args.endIndex {
                switch args[i] {
                case "--config":
                    i += 1
                    guard i < args.endIndex else { return nil }
                    configPath = args[i]
                case "--daily-cap":
                    i += 1
                    guard i < args.endIndex else { return nil }
                    if args[i] == "off" {
                        dailyCapUsd = 0
                    } else {
                        guard let value = Double(args[i]), value >= 0 else { return nil }
                        dailyCapUsd = value
                    }
                default:
                    return nil
                }
                i += 1
            }
        }
    }

    static let usage = """
    usage: prbar-review watch [--config <path>] [--daily-cap <usd>|off]

    Runs PRBar's review automation headless: polls your GitHub inbox, reviews
    requested PRs, posts what prbar.yaml allows, and records history in the
    same files the menu-bar app uses. One automating PRBar per machine: it
    refuses to start while the app (or another watch) holds the runtime lock.

      --config <path>     prbar.yaml to use; defaults to $PRBAR_CONFIG, then
                          ~/.config/prbar/prbar.yaml (the app's)
      --daily-cap <usd>   stop starting reviews once today's spend reaches
                          this; `off` disables it (default: 5.00)

    """

    @MainActor
    static func run(_ options: Options) async -> Int32 {
        let configURL: URL
        if let path = options.configPath {
            configURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                log("cannot read config \(configURL.path): no such file")
                return 2
            }
        } else {
            configURL = ConfigLocation.userConfigURL()
        }

        let env = RuntimeEnvironment.standard(configFile: configURL)
        let lock = RuntimeLock(stateDirectory: env.stateDirectory)
        guard lock.acquire(holder: "prbar-review watch") else {
            log("another PRBar is already automating (\(lock.currentHolder() ?? "unknown holder")); not starting")
            return 3
        }

        let runtime = PRBarRuntime.live(env, deliverer: StderrDeliverer())
        // Nobody is watching an undo banner.
        runtime.queue.undoWindow = 0
        if let cap = options.dailyCapUsd {
            runtime.queue.dailyCostCapEnabled = cap > 0
            if cap > 0 { runtime.queue.dailyCostCap = cap }
        }
        for issue in [runtime.repoConfigs.loadIssue].compactMap({ $0 }) + runtime.repoConfigs.warnings {
            log(issue)
        }

        let polled = runtime.poller.onPollSuccess
        runtime.poller.onPollSuccess = { prs in
            polled?(prs)
            let requested = prs.filter { $0.role == .reviewRequested || $0.role == .both }.count
            log("polled: \(prs.count) PRs, \(requested) awaiting your review")
        }
        let completed = runtime.actionQueue.onActionCompleted
        runtime.actionQueue.onActionCompleted = { pr in
            completed?(pr)
            log("posted to \(pr.nameWithOwner)#\(pr.number)")
        }
        let settled = runtime.queue.onReviewSettled
        runtime.queue.onReviewSettled = { [weak queue = runtime.queue] nodeId, idle in
            settled?(nodeId, idle)
            guard let state = queue?.reviews[nodeId] else { return }
            switch state.status {
            case .completed(let review):
                log("reviewed \(nodeId): \(review.verdict.rawValue), \(review.annotations.count) finding(s), $\(String(format: "%.2f", review.costUsd))")
            case .failed(let message):
                log("review failed \(nodeId): \(message)")
            default:
                break
            }
        }

        log("watching as configured in \(configURL.path); state in \(env.stateDirectory.path)")
        await waitForTermination()
        log("stopping")
        await runtime.queue.flushPendingSaves()
        lock.release()
        return 0
    }

    /// Suspends until SIGINT or SIGTERM. The main actor stays free in the
    /// meantime, which is where the poller and the queues run.
    @MainActor
    private static func waitForTermination() async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = SignalSources(continuation)
            for sig in [SIGINT, SIGTERM] {
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { box.fire() }
                source.resume()
                box.sources.append(source)
            }
        }
    }

    private final class SignalSources: @unchecked Sendable {
        var sources: [DispatchSourceSignal] = []
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func fire() {
            continuation?.resume()
            continuation = nil
            sources.forEach { $0.cancel() }
        }
    }

    static func log(_ message: String) {
        let stamp = HistoryDates.format(Date())
        FileHandle.standardError.write(Data("\(stamp) prbar-review: \(message)\n".utf8))
    }
}

/// Notifications for a terminal: one stderr line per batch.
struct StderrDeliverer: NotificationDeliverer {
    func requestAuthorization() async {}

    func deliver(_ events: [NotificationEvent]) async {
        for event in events {
            WatchCommand.log("\(event.kind): \(event.prRepo)#\(event.prNumber) \(event.prTitle) \(event.prURL.absoluteString)")
        }
    }
}
