import Foundation
import Darwin
import Network
import XCTest
@testable import AccessKit

/// Live Reality Vision path through the linked embedded core.
///
/// Opt-in: local fixture at `.local/access-service/test-reality-vision.json`
/// plus `AEGIS_ACCESS_LOCAL_V2RAY_LIVE=1` or `.local/access-service/ENABLE_LIVE`.
/// Never logs secrets.
@MainActor
final class AccessEmbeddedCoreLiveTests: XCTestCase {
    /// Bounded real-core ownership/footprint probe, separate from website acceptance.
    func testResidentCoreReleasesConcurrentStreamsAndStops() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_ACCESS_LIVE_MEMORY"] == "1" else {
            throw XCTSkip("Requires explicit real-core memory probe opt-in")
        }
        let path = try requireLiveConfig()
        let imported = try AccessLocalV2RayConfigLoader.load(path: path)
        let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        let core = try AccessGoEmbeddedCore()
        var samples: [[String: Any]] = []
        let started = Date()
        func sample(_ phase: String, completed: Int, retained: Int) {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            samples.append(["phase": phase, "completedStreams": completed, "retainedStreamWrappers": retained,
                "elapsedSeconds": Date().timeIntervalSince(started), "coreRunning": core.isRunning,
                "footprintReadSucceeded": result == KERN_SUCCESS, "physicalFootprintBytes": info.phys_footprint])
        }
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "resident-real-core-memory.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        sample("before-start", completed: 0, retained: 0)
        do { try await core.start(configData: outbound.embeddedInstanceJSONData()) }
        catch {
            await core.stop()
            sample("start-failed", completed: 0, retained: 0)
            XCTFail("real-core startup failed: \(Self.redacted(error))")
            return
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(240))
            await core.stop()
        }
        defer { watchdog.cancel() }
        do {
            for batch in 1...10 {
                let probes = try await withThrowingTaskGroup(of: WeakLiveStream.self) { group in
                    for _ in 0..<6 {
                        group.addTask { try await Self.exerciseLiveStream(core) }
                    }
                    var result: [WeakLiveStream] = []
                    for try await probe in group { result.append(probe) }
                    return result
                }
                // Cancellation of each stream deadline is asynchronous; observe
                // actual weak-reference release rather than assuming it is immediate.
                for _ in 0..<100 where probes.contains(where: { $0.value != nil }) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let retained = probes.filter { $0.value != nil }.count
                XCTAssertEqual(retained, 0)
                XCTAssertTrue(core.isRunning)
                sample("idle-after-batch", completed: batch * 6, retained: retained)
                if batch < 10 { try await Task.sleep(for: .seconds(10)) }
            }
            await core.stop()
            XCTAssertFalse(core.isRunning)
            sample("stopped", completed: 60, retained: 0)
        } catch {
            await core.stop()
            sample("failed-and-stopped", completed: 0, retained: 0)
            XCTFail("bounded real-core probe failed: \(Self.redacted(error))")
        }
    }

    private final class WeakLiveStream: @unchecked Sendable {
        weak var value: AnyObject?
        init(_ stream: any AccessRealityPathStream) { value = stream as AnyObject }
    }

    nonisolated private static func exerciseLiveStream(_ core: AccessGoEmbeddedCore) async throws -> WeakLiveStream {
        let stream = try await core.dial(host: "example.com", port: 80)
        let probe = WeakLiveStream(stream)
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            stream.close()
        }
        defer { deadline.cancel(); stream.close() }
        try await stream.write(Data("HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8))
        var response = Data()
        while response.count < 8_192 {
            guard let bytes = try await stream.read(maxBytes: 1_024), !bytes.isEmpty else { break }
            response.append(bytes)
            if response.range(of: Data("\r\n".utf8)) != nil { break }
        }
        guard response.starts(with: Data("HTTP/1.".utf8)) else { throw URLError(.badServerResponse) }
        return probe
    }

    func testLocalConfigImportsAsRealityVision() throws {
        let path = try requireLiveConfig()
        let imported = try AccessLocalV2RayConfigLoader.load(path: path)
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        XCTAssertEqual(config.profile, .realityVision)
        XCTAssertFalse(imported.parameters.address.isEmpty)
        XCTAssertGreaterThan(imported.parameters.port, 0)
        let embedded = try config.embeddedInstanceJSONData()
        XCTAssertGreaterThan(embedded.count, 32)
    }

    func testEmbeddedCoreStartsAndDialsCleartextHTTP() async throws {
        let path = try requireLiveConfig()
        let imported = try AccessLocalV2RayConfigLoader.load(path: path)
        let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        let configData = try outbound.embeddedInstanceJSONData()

        let core = try AccessGoEmbeddedCore()
        do {
            try await core.start(configData: configData)
        } catch {
            XCTFail("embedded core start failed: \(Self.redacted(error))")
            return
        }
        XCTAssertTrue(core.isRunning)

        let stream: any AccessRealityPathStream
        do {
            stream = try await core.dial(host: "example.com", port: 80)
        } catch {
            await core.stop()
            XCTFail("embedded dial failed: \(Self.redacted(error))")
            return
        }

        do {
            try await stream.write(
                Data("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8)
            )
            var buffer = Data()
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let chunk = try await stream.read(maxBytes: 4_096), !chunk.isEmpty {
                    buffer.append(chunk)
                    if let text = String(data: buffer, encoding: .utf8), text.contains("HTTP/1.") {
                        stream.close()
                        await core.stop()
                        return
                    }
                } else if buffer.isEmpty == false {
                    break
                }
            }
            let preview = String(data: buffer.prefix(64), encoding: .utf8) ?? "<non-utf8 \(buffer.count) bytes>"
            stream.close()
            await core.stop()
            XCTFail("no HTTP response through Reality dial; got \(preview)")
        } catch {
            stream.close()
            await core.stop()
            throw error
        }
    }

    func testProductPublisherStartsListenerAndConnectTunnel() async throws {
        let path = try requireLiveConfig()
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(configPath: path)
        let operationID = UUID()
        let prepared: AccessProxyEntryPrepareResult
        do {
            prepared = try await publisher.prepare(
                AccessProxyEntryPrepareRequest(operationID: operationID, deadline: .seconds(45))
            )
        } catch {
            XCTFail("publisher prepare failed: \(Self.redacted(error))")
            return
        }
        defer { publisher.cancel(operationID: operationID) }

        XCTAssertTrue(publisher.validateReady(prepared))
        XCTAssertEqual(prepared.endpoint.loopbackHost, AccessEndpoint.loopbackHost)
        XCTAssertGreaterThan(prepared.endpoint.port, 0)

        let established = expectation(description: "CONNECT established through embedded dial")
        let httpOK = expectation(description: "HTTP response through Reality tunnel")
        httpOK.assertForOverFulfill = false

        let connection = NWConnection(
            host: NWEndpoint.Host(prepared.endpoint.loopbackHost),
            port: NWEndpoint.Port(rawValue: prepared.endpoint.port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let connect = Data(
                "CONNECT example.com:80 HTTP/1.1\r\nHost: example.com:80\r\n\r\n".utf8
            )
            connection.send(content: connect, completion: .contentProcessed { _ in })
            Self.receiveUntil(
                connection,
                contains: "200 Connection Established",
                fulfill: established
            ) {
                let get = Data(
                    "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8
                )
                connection.send(content: get, completion: .contentProcessed { _ in })
                Self.receiveUntil(connection, contains: "HTTP/1.", fulfill: httpOK)
            }
        }
        connection.start(queue: .global())
        await fulfillment(of: [established, httpOK], timeout: 45)
        connection.cancel()
    }

    @discardableResult
    private func requireLiveConfig() throws -> String {
        let path = try resolveConfigPath()
        try requireLiveEnabled()
        return path
    }

    private func resolveConfigPath() throws -> String {
        if let configured = AccessLocalV2RayConfigLoader.configuredPath(),
           FileManager.default.fileExists(atPath: configured) {
            return configured
        }
        if let bundled = AccessLocalV2RayConfigLoader.productPath(),
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        let fallback = Self.localFixtureURL()
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw XCTSkip(
                "Set \(AccessLocalV2RayConfig.environmentVariable) or place Reality Vision flat JSON at \(fallback.path)"
            )
        }
        return fallback.path
    }

    private func requireLiveEnabled() throws {
        let live = ProcessInfo.processInfo.environment[
            AccessLocalV2RayConfig.liveProbeEnvironmentVariable
        ]
        let flag = Self.localFixtureURL()
            .deletingLastPathComponent()
            .appendingPathComponent("ENABLE_LIVE")
        guard live == "1" || FileManager.default.fileExists(atPath: flag.path) else {
            throw XCTSkip(
                "Set \(AccessLocalV2RayConfig.liveProbeEnvironmentVariable)=1 or touch .local/access-service/ENABLE_LIVE"
            )
        }
    }

    private static func localFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".local/access-service/test-reality-vision.json")
    }

    private static func redacted(_ error: Error) -> String {
        let text = String(describing: error)
        // Keep type / code; drop anything that looks like a UUID or long base64-ish token.
        let uuid = try! NSRegularExpression(pattern: #"[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}"#)
        let long = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-]{24,}"#)
        var out = uuid.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "<uuid>"
        )
        out = long.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..., in: out),
            withTemplate: "<redacted>"
        )
        return out
    }

    nonisolated private static func receiveUntil(
        _ connection: NWConnection,
        contains needle: String,
        fulfill: XCTestExpectation,
        then: (@Sendable () -> Void)? = nil
    ) {
        @Sendable func watch(_ connection: NWConnection, buffer: String) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, isComplete, error in
                var next = buffer
                if let data, let chunk = String(data: data, encoding: .utf8) {
                    next += chunk
                }
                if next.contains(needle) {
                    fulfill.fulfill()
                    then?()
                    return
                }
                if isComplete || error != nil {
                    return
                }
                watch(connection, buffer: next)
            }
        }
        watch(connection, buffer: "")
    }
}
