import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import PRBarCore

/// The server and client talking over a real Unix socket.
@MainActor
final class APIServerTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL!

    override func setUp() async throws {
        // Short on purpose: a Unix socket path must fit in ~104 bytes, and
        // the per-user temporary directory on macOS alone is ~50.
        dir = URL(fileURLWithPath: "/tmp/prbar-api-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        socketURL = dir.appendingPathComponent("server.sock")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func startServer(prs: [InboxPR] = []) throws -> (PRBarRuntime, APIServer) {
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: prs)
        let server = APIServer(runtime: runtime, holder: "test server", build: "1.2.3")
        try server.start(socketURL: socketURL)
        addTeardownBlock { @MainActor in server.stop() }
        return (runtime, server)
    }

    func testHelloStatusAndInbox() async throws {
        _ = try startServer(prs: [RuntimeFixtures.requestedPR()])
        let connected = try await ServerConnection.connect(socketURL: socketURL, client: "tests")
        defer { connected.client.close() }

        XCTAssertEqual(connected.hello.holder, "test server")
        XCTAssertEqual(connected.hello.build, "1.2.3")
        XCTAssertEqual(connected.hello.pid, getpid())

        let status = try await connected.client.call(.status, as: ServerStatus.self)
        XCTAssertEqual(status.prCount, 1)
        XCTAssertEqual(status.awaitingReview, 1)
        XCTAssertFalse(status.ownsAutomation)
        XCTAssertEqual(status.problems, [])

        let inbox = try await connected.client.call(.inbox, as: [InboxPR].self)
        XCTAssertEqual(inbox.map(\.nodeId), ["PR_1"])
    }

    func testSocketIsPrivateToTheUser() throws {
        _ = try startServer()
        let mode = try FileManager.default.attributesOfItem(atPath: socketURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testReviewLookupByOwnerRepoNumber() async throws {
        _ = try startServer(prs: [RuntimeFixtures.requestedPR(nodeId: "PR_7", number: 7)])
        let client = try await ServerConnection.connect(socketURL: socketURL, client: "tests").client
        defer { client.close() }

        let found = try await client.call(
            .review, PRReference(owner: "O", repo: "r", number: 7), as: ReviewResult.self)
        XCTAssertEqual(found.pr.nodeId, "PR_7")
        XCTAssertNil(found.review)

        do {
            _ = try await client.call(.review, PRReference(owner: "o", repo: "r", number: 8), as: ReviewResult.self)
            XCTFail("expected notFound")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.notFound)
        }
    }

    /// Clients see a change as it happens, not on their next request.
    func testSubscriberReceivesEvents() async throws {
        let (runtime, _) = try startServer()
        let client = try await ServerConnection.connect(socketURL: socketURL, client: "tests").client
        defer { client.close() }
        _ = try await client.call(.subscribe, as: ServerStatus.self)

        runtime.poller.onPollSuccess?([RuntimeFixtures.requestedPR(), RuntimeFixtures.requestedPR(nodeId: "PR_2", number: 2)])

        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, APIEvent(kind: .inboxChanged, count: 2))
    }

    func testIncompatibleClientIsRefused() async throws {
        _ = try startServer()
        let client = try APIClient.connect(socketURL: socketURL)
        defer { client.close() }
        do {
            _ = try await client.call(.hello, HelloParams(client: "future", protocolVersion: 99), as: HelloResult.self)
            XCTFail("expected incompatibleVersion")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.incompatibleVersion)
        }
    }

    func testNoServerIsReportedAsSuch() async throws {
        do {
            _ = try await ServerConnection.connect(socketURL: socketURL, client: "tests")
            XCTFail("expected noServer")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .noServer(socketURL.path))
        }
    }

    /// A server that died leaves its socket file behind; nothing answers
    /// it, and the next server binds over it.
    func testStaleSocketFile() async throws {
        let fd = try UnixSocket.listen(path: socketURL.path)
        _ = close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        do {
            _ = try await ServerConnection.connect(socketURL: socketURL, client: "tests")
            XCTFail("expected noServer")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .noServer(socketURL.path))
        }

        _ = try startServer()
        let connected = try await ServerConnection.connect(socketURL: socketURL, client: "tests")
        connected.client.close()
    }

    func testShutdownIsRefusedUnlessTheHostAllowsIt() async throws {
        let (_, server) = try startServer()
        let client = try await ServerConnection.connect(socketURL: socketURL, client: "tests").client
        defer { client.close() }
        do {
            _ = try await client.call(.shutdown, as: APIEmpty.self)
            XCTFail("expected refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.refused)
        }

        var asked = false
        server.onShutdown = { asked = true }
        _ = try await client.call(.shutdown, as: APIEmpty.self)
        // Not `fulfillment(of:)`: Linux XCTest can't await it from a
        // main-actor test.
        for _ in 0..<50 where !asked {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(asked)
    }

    func testStoppingTheServerEndsClientCalls() async throws {
        let (_, server) = try startServer()
        let client = try await ServerConnection.connect(socketURL: socketURL, client: "tests").client
        defer { client.close() }
        _ = try await client.call(.subscribe, as: ServerStatus.self)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event, "the event stream finishes when the server goes away")
        do {
            _ = try await client.call(.status, as: ServerStatus.self)
            XCTFail("expected disconnected")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .disconnected)
        }
    }

    func testMalformedAndUnknownRequests() async throws {
        let (_, server) = try startServer()
        func errorCode(_ text: String) async throws -> Int? {
            let reply = await server.handle(Data(text.utf8), from: nil)
            return try RPCLine.decode(RPCResponse<APIEmpty>.self, from: XCTUnwrap(reply)).error?.code
        }
        let parse = try await errorCode("not json")
        XCTAssertEqual(parse, RPCError.parseError)
        let unknown = try await errorCode(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#)
        XCTAssertEqual(unknown, RPCError.methodNotFound)
        let badParams = try await errorCode(#"{"jsonrpc":"2.0","id":2,"method":"review","params":{"number":"seven"}}"#)
        XCTAssertEqual(badParams, RPCError.invalidParams)
    }
}
