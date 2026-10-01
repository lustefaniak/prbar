import Foundation
import Observation

/// A front end's view of the PRBar server: one API connection, the state
/// it renders kept up to date from the server's `state` updates, and the
/// commands it sends back. The app's views read the models here instead of
/// the runtime, so they work the same whether the server runs in the app's
/// own process or elsewhere.
@MainActor
final class ServerSession {
    let inbox: InboxModel

    private let client: APIClient
    private var listener: Task<Void, Never>?

    init(client: APIClient) {
        self.client = client
        inbox = InboxModel()
        inbox.session = self
    }

    /// Subscribes, applies the snapshot, then follows updates until the
    /// connection closes.
    func start() async throws {
        let result = try await client.call(.subscribe, SubscribeParams(state: true), as: SubscribeResult.self)
        if let snapshot = result.state { apply(snapshot) }
        let updates = client.stateUpdates
        listener = Task { [weak self] in
            for await update in updates {
                self?.apply(update)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        client.close()
    }

    func apply(_ update: StateUpdate) {
        inbox.apply(update)
    }

    /// Fire-and-forget command; a failure is logged, since the state the
    /// UI shows comes back through `state` updates anyway.
    func send<P: Codable & Sendable>(_ method: APIMethod, _ params: P) {
        let client = self.client
        Task {
            do {
                _ = try await client.call(method, params, as: APIEmpty.self)
            } catch {
                PRBarLog.lifecycle.error("API \(method.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The inbox as the server reports it: the PR list and the polling state.
/// Same names as `PRPoller`, which it mirrors.
@MainActor
@Observable
final class InboxModel {
    private(set) var prs: [InboxPR] = []
    private(set) var lastFetchedAt: Date?
    private(set) var lastError: String?
    private(set) var isFetching = false
    private(set) var refreshingPRs: Set<String> = []

    @ObservationIgnored
    weak var session: ServerSession?

    func apply(_ update: StateUpdate) {
        if let prs = update.prs { self.prs = prs }
        if let polling = update.polling {
            lastFetchedAt = polling.lastFetchedAt
            lastError = polling.lastError
            isFetching = polling.isFetching
            refreshingPRs = polling.refreshingPRs
        }
    }

    func pollNow() {
        session?.send(.poll, APIEmpty())
    }

    func refreshPR(_ pr: InboxPR, force: Bool = false) {
        session?.send(.refreshPR, RefreshParams(pr: PRReference(nodeId: pr.nodeId), force: force))
    }
}
