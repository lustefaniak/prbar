import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `prbar-review serve`: the PRBar server without the menu bar. Polls the
/// inbox, reviews incoming review requests, posts whatever the config's
/// gates allow, keeps the shared history and state files, serves the API
/// socket for other clients, and prints a line per event to stderr. Runs
/// until interrupted or asked to shut down. `watch` is the older name.
///
/// It takes the runtime lock before anything else: with the app (or another
/// server) already running as the same user, it refuses to start rather
/// than review and post a second time.
enum ServeCommand {
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

    static let holder = "prbar-review serve"

    static let usage = """
    usage: prbar-review serve [--config <path>] [--daily-cap <usd>|off]

    Runs the PRBar server headless: polls your GitHub inbox, reviews
    requested PRs, posts what prbar.yaml allows, records history in the
    same files the menu-bar app uses, and serves the API socket that
    `prbar-review status`, `inbox` and `history` talk to. One server per
    machine: it refuses to start while the app (or another server) holds
    the runtime lock.

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
        guard lock.acquire(holder: holder) else {
            log("another PRBar is already running (\(lock.currentHolder() ?? "unknown holder")); not starting")
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

        runtime.observe { [weak runtime] event in
            switch event {
            case .inboxChanged(let prs):
                let requested = prs.filter { $0.role == .reviewRequested || $0.role == .both }.count
                log("polled: \(prs.count) PRs, \(requested) awaiting your review")
            case .actionCompleted(let pr):
                log("posted to \(pr.nameWithOwner)#\(pr.number)")
            case .reviewSettled(let nodeId):
                guard let state = runtime?.queue.reviews[nodeId] else { return }
                switch state.status {
                case .completed(let review):
                    log("reviewed \(nodeId): \(review.verdict.rawValue), \(review.annotations.count) finding(s), $\(String(format: "%.2f", review.costUsd))")
                case .failed(let message):
                    log("review failed \(nodeId): \(message)")
                default:
                    break
                }
            case .configChanged:
                log("config reloaded")
            }
        }

        let stop = StopSignal()
        let server = APIServer(runtime: runtime, holder: holder)
        server.onShutdown = {
            log("shutdown requested by a client")
            stop.fire()
        }
        let socketURL = ServerLocation.socketURL(stateDirectory: env.stateDirectory)
        do {
            try server.start(socketURL: socketURL)
        } catch {
            log("cannot serve the API on \(socketURL.path): \(error.localizedDescription)")
            lock.release()
            return 2
        }

        log("serving \(socketURL.path); config \(configURL.path); state in \(env.stateDirectory.path)")
        await stop.wait()
        log("stopping")
        server.stop()
        await runtime.queue.flushPendingSaves()
        lock.release()
        return 0
    }

    static func log(_ message: String) {
        let stamp = HistoryDates.format(Date())
        FileHandle.standardError.write(Data("\(stamp) prbar-review: \(message)\n".utf8))
    }
}

/// Resolves once, on SIGINT, SIGTERM or `fire()`. The main actor stays
/// free while waiting, which is where the runtime and the server run.
@MainActor
final class StopSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.fire() }
            }
            source.resume()
            sources.append(source)
        }
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        sources.forEach { $0.cancel() }
        continuation?.resume()
        continuation = nil
    }
}

/// Notifications for a terminal: one stderr line per batch.
struct StderrDeliverer: NotificationDeliverer {
    func requestAuthorization() async {}

    func deliver(_ events: [NotificationEvent]) async {
        for event in events {
            ServeCommand.log("\(event.kind): \(event.prRepo)#\(event.prNumber) \(event.prTitle) \(event.prURL.absoluteString)")
        }
    }
}
