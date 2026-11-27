import Foundation
import Darwin
import Network
import Security
import UIKit
import WebKit
import XCTest
import AegisPolicyKit
@testable import AccessKit

/// Live Reality Vision path through the linked embedded core.
///
/// Opt-in: local fixture at `.local/access-service/test-reality-vision.json`
/// plus `AEGIS_ACCESS_LOCAL_V2RAY_LIVE=1` or `.local/access-service/ENABLE_LIVE`.
/// Never logs secrets.
@MainActor
final class AccessEmbeddedCoreLiveTests: XCTestCase {
    func testAdditionalTLSOutboundsTransferThroughControlledRelays() async throws {
        guard let input = ProcessInfo.processInfo.environment["AEGIS_EGRESS_LOOPBACK_FIXTURES"] else {
            throw XCTSkip("Requires local TLS/QUIC relay fixtures and an isolated simulator with their CA")
        }
        let links = try JSONDecoder().decode([String].self, from: Data(input.utf8))
        let nodes = try links.map(AccessOutboundNode.parseSingleShareURI)
        XCTAssertEqual(nodes.map(\.profileKey), [.trojanRawTLS, .vmessWsTls, .vmessHTTPUpgradeTLS, .hysteria2])
        let core = try AccessGoEmbeddedCore()
        for node in nodes {
            XCTAssertEqual(node.endpoint.address, "127.0.0.1")
            let config = try AccessOutboundConfigRegistry.embeddedInstanceJSONData(for: node)
            try await core.start(configData: config)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(10))
                await core.stop()
            }
            do {
                let stream = try await core.dial(host: "fixture-origin.invalid", port: 80)
                defer { stream.close() }
                try await stream.write(Data("GET / HTTP/1.1\r\nHost: fixture-origin.invalid\r\nConnection: close\r\n\r\n".utf8))
                var received = Data()
                while received.count < 4_096, let part = try await stream.read(maxBytes: 1_024), !part.isEmpty {
                    received.append(part)
                    if received.range(of: Data("aegis-egress-ok".utf8)) != nil { break }
                }
                XCTAssertNotNil(received.range(of: Data("aegis-egress-ok".utf8)), node.profileKey.rawValue)
            } catch {
                XCTFail("Fixture CONNECT and transfer failed for \(node.profileKey.rawValue)")
            }
            watchdog.cancel()
            let stopped = await core.stopAndConfirm()
            XCTAssertTrue(stopped)
        }
    }

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
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(configPath: path, retireDocuments: { _, finish in finish() })
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
    func testPhoneDirectedTLSTrace() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AEGIS_DIRECTED_PROBE"] == "1" else { throw XCTSkip("Directed device probe") }
        let run = try XCTUnwrap(environment["AEGIS_DIRECTED_RUN"].flatMap(UUID.init(uuidString:)))
        let comparisonResult = environment["AEGIS_COMPARISON_RESULT_NAME"]
        let uri = try XCTUnwrap(environment["AEGIS_BLOCKED_CN_NODE_URI"])
        let node: AccessInternalTestNode
        do { node = try AccessInternalTestNode.parseSingleShareURI(uri) }
        catch { XCTFail("Could not import directed test node"); return }

        struct Leg: Encodable {
            let target: BlockedCNTarget
            let proxy: BlockedCNRow
            let direct: BlockedCNRow
            let xray: [String]
        }
        struct Output: Encodable {
            var preflight = "pending"
            var egress: [AccessPhoneSample] = []
            var cssControl: BlockedCNRow?
            var resources: DirectedResourceWitness?
            var samples: [Leg] = []
        }
        var output = Output()
        let cache = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let result = cache.appendingPathComponent(comparisonResult ?? "\(run.uuidString.lowercased())-directed-tls.json")
        func save(_ stage: String) throws {
            output.preflight = stage
            try JSONEncoder().encode(output).write(to: result, options: .atomic)
            NSLog("AEGIS-COMPARISON-REACHABILITY %@", stage)
        }

        let defaults = UserDefaults.standard
        let key = AccessDiagnosticLog.preferenceKey
        let old = defaults.object(forKey: key)
        defaults.set(AccessLogLevel.debug.rawValue, forKey: key)
        defer { defaults.set(old, forKey: key) }

        let monitor = NWPathMonitor()
        monitor.start(queue: .global())
        defer { monitor.cancel() }
        for _ in 0..<25 where !monitor.currentPath.usesInterfaceType(.wifi) { try await Task.sleep(for: .milliseconds(200)) }
        guard monitor.currentPath.usesInterfaceType(.wifi) else {
            try save("wifi-unavailable")
            XCTFail("Directed device probe needs Wi-Fi")
            return
        }

        if comparisonResult != nil {
            let endpoint = try XCTUnwrap(URLComponents(string: uri))
            let address = try XCTUnwrap(endpoint.host)
            let port = try XCTUnwrap(endpoint.port.flatMap { UInt16(exactly: $0) }.flatMap(NWEndpoint.Port.init(rawValue:)))
            let candidate = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
            candidate.start(queue: .global())
            defer { candidate.cancel() }
            for _ in 0..<60 {
                if case .ready = candidate.state { break }
                if candidate.currentPath?.unsatisfiedReason == .localNetworkDenied { break }
                if case .failed = candidate.state { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let ready: Bool
            if case .ready = candidate.state { ready = true } else { ready = false }
            let reason = candidate.currentPath?.unsatisfiedReason
            let detail: String
            if ready { detail = "tcp-ready" }
            else if reason == .localNetworkDenied { detail = "local-network-denied" }
            else if case let .waiting(error) = candidate.state { detail = "waiting-code-\((error as NSError).code)" }
            else if case let .failed(error) = candidate.state { detail = "failed-code-\((error as NSError).code)" }
            else { detail = "tcp-not-ready" }
            try save(detail)
            guard ready else { XCTFail("Comparison LAN TCP preflight failed"); return }
        }

        let core = try AccessGoEmbeddedCore(isolated: true)
        let publisher = AccessEmbeddedProxyEntryFactory.makeInternalTestPublisher(
            verifiedCore: core, node: { node }, connectionAllowed: { true },
            retireDocuments: { _, finish in finish() }, transport: .http
        )
        let operation = UUID()
        defer { publisher.cancel(operationID: operation) }
        let prepared = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(25)))
        guard publisher.validateReady(prepared) else {
            try save("proxy-not-ready")
            XCTFail("Directed device proxy failed to start")
            return
        }
        let proxy = try Self.probeConfiguration(prepared)

        let trace = ["https://www.cloudflare.com/cdn-cgi/trace"]
        let directEgress = await Self.sampleHTTPS(trace, phase: "direct", round: 1, proxy: nil)
        let proxyEgress = await Self.sampleHTTPS(trace, phase: "proxy", round: 1, proxy: proxy)
        output.egress = directEgress + proxyEgress
        let expectedProxyCountry = environment["AEGIS_COMPARISON_PROXY_COUNTRY"] ?? "US"
        guard directEgress.contains(where: { $0.status == 200 && $0.country == "CN" && !$0.proxyObserved }),
              proxyEgress.contains(where: { $0.status == 200 && $0.country == expectedProxyCountry && $0.proxyObserved }) else {
            try save("egress-control-failed")
            XCTFail("Directed device egress control failed")
            return
        }

        let css = BlockedCNTarget(s: "directed", c: "control", h: "github.githubassets.com", k: "full",
                                  p: "/assets/light-3ee16b3ea60adc77.css")
        let cssControl = await Self.headerProbe(css, phase: "proxy", proxy: proxy)
        output.cssControl = cssControl
        guard cssControl.status == 200 && cssControl.usable && cssControl.transactions.last?.isProxy == true else {
            try save("css-control-failed")
            XCTFail("Known public asset control")
            return
        }
        try save("controls-passed")
        let comparisonHosts = [
            "githubassets.com", "ytimg.com", "googlevideo.com", "www.githubcopilot.com", "nflxvideo.net",
        ]
        let diagnosticHosts = comparisonResult == nil
            ? ["api.githubcopilot.com", "i.ytimg.com", "www.google.com", "www.google.com.hk"]
            : comparisonHosts
        for host in diagnosticHosts {
            let path = host == "i.ytimg.com" ? "/vi/M7lc1UVf-VE/hqdefault.jpg" : nil
            let target = BlockedCNTarget(s: "directed", c: "TLS", h: host, k: "full", p: path)
            let before = Set(AccessDiagnosticLog.shared.snapshot().split(separator: "\n").map(String.init))
            NSLog("AEGIS-DIRECTED-SAMPLE %@ begin", host)
            let collectTrust = comparisonResult != nil && ["googlevideo.com", "www.githubcopilot.com"].contains(host)
            let via = await Self.headerProbe(target, phase: "proxy", proxy: proxy, collectTrust: collectTrust)
            try await Task.sleep(for: .milliseconds(350))
            let xray = AccessDiagnosticLog.shared.snapshot().split(separator: "\n").map(String.init).filter { !before.contains($0) }
            NSLog("AEGIS-DIRECTED-SAMPLE %@ end", host)
            let direct = await Self.headerProbe(target, phase: "direct", proxy: nil)
            output.samples.append(.init(target: target, proxy: via, direct: direct, xray: xray))
            try JSONEncoder().encode(output).write(to: result, options: .atomic)
            if host == "api.githubcopilot.com" {
                XCTAssertNotNil(via.status, "Copilot API must return an HTTP response over verified HTTPS")
                XCTAssertEqual(via.transactions.last?.isProxy, true, "Copilot API must use the selected proxy")
            }
        }
        if comparisonResult != nil, let cssURL = css.url {
            let resources = try await Self.directedResourceWitness(cssURL: cssURL, proxy: proxy)
            output.resources = resources
            try JSONEncoder().encode(output).write(to: result, options: .atomic)
            XCTAssertTrue(resources.cssApplied, "GitHub stylesheet must apply in WKWebView")
            XCTAssertTrue(resources.thumbnailDecoded, "YouTube thumbnail must decode in WKWebView")
        }
        XCTAssertTrue(output.samples.allSatisfy { !$0.xray.isEmpty }, "Missing per-sample Xray diagnostics")
        publisher.cancel(operationID: operation)
        let stopped = await core.stopAndConfirm()
        XCTAssertTrue(stopped)
        XCTAssertTrue(monitor.currentPath.usesInterfaceType(.wifi))
    }

    private struct DirectedResourceWitness: Encodable {
        let cssApplied: Bool
        let thumbnailDecoded: Bool
    }

    private static func directedResourceWitness(cssURL: URL, proxy: ProxyConfiguration) async throws -> DirectedResourceWitness {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [proxy]
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        defer { view.stopLoading() }
        view.loadHTMLString("""
            <!doctype html>
            <html data-color-mode="light" data-light-theme="light">
            <head><link id="css" rel="stylesheet" href="\(cssURL.absoluteString)"></head>
            <body>
            <img id="thumbnail" src="https://i.ytimg.com/vi/M7lc1UVf-VE/hqdefault.jpg">
            <script>
                const thumbnail = document.getElementById('thumbnail');
                thumbnail.decode().then(() => {
                    document.documentElement.dataset.thumbnailDecoded = 'true';
                }, () => {
                    document.documentElement.dataset.thumbnailDecoded = 'false';
                });
            </script>
            </body>
            </html>
            """, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(15)
        var cssApplied = false
        var thumbnailDecoded = false
        while ContinuousClock.now < deadline {
            if let state = try? await view.evaluateJavaScript("""
                (() => {
                    const thumbnail = document.getElementById('thumbnail');
                    return {
                        css: getComputedStyle(document.documentElement).getPropertyValue('--button-primary-bgColor-active').trim() === '#197935',
                        thumbnail: document.documentElement.dataset.thumbnailDecoded === 'true' && thumbnail.naturalWidth > 0
                    };
                })()
                """) as? [String: Bool] {
                cssApplied = state["css"] == true
                thumbnailDecoded = state["thumbnail"] == true
                if cssApplied && thumbnailDecoded { break }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return .init(cssApplied: cssApplied, thumbnailDecoded: thumbnailDecoded)
    }

    func testPhoneWiFiBlockedCNPaired() async throws {
        guard let run = ProcessInfo.processInfo.environment["AEGIS_PAIRED_RUN"], UUID(uuidString: run) != nil else { throw XCTSkip("Opt-in paired device probe") }
        executionTimeAllowance = 14_400
        let originalIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let monitor = NWPathMonitor()
        monitor.start(queue: .global())
        defer {
            monitor.cancel()
            UIApplication.shared.isIdleTimerDisabled = originalIdleTimer
        }
        func usingWiFi() -> Bool {
            let path = monitor.currentPath
            return path.status == .satisfied && path.usesInterfaceType(.wifi)
        }
        for _ in 0..<25 where !usingWiFi() { try await Task.sleep(for: .milliseconds(200)) }
        guard usingWiFi() else { throw XCTSkip("Active Wi-Fi required") }

        let uri = try XCTUnwrap(ProcessInfo.processInfo.environment["AEGIS_BLOCKED_CN_NODE_URI"], "Missing node environment")
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "blocked-cn-rerun", withExtension: "json", subdirectory: "Fixtures")
        )
        let rerun = try JSONDecoder().decode(BlockedCNRerun.self, from: Data(contentsOf: fixture))
        let targets = rerun.targets
        let targetHosts = Set(targets.map(\.h))
        guard targets.count == 2_051, targets.count == targetHosts.count else {
            XCTFail("Expected 2,051 unique primary probe hosts")
            return
        }

        let cache = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let progress = cache.appendingPathComponent("\(run)-blocked-cn-paired-progress.json")
        let egressLog = cache.appendingPathComponent("\(run)-blocked-cn-paired-egress.json")
        var pairs: [BlockedCNPair] = []
        var egress: [AccessPhoneSample] = []
        func write<T: Encodable>(_ value: T, to url: URL) throws {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
        try write(pairs, to: progress)
        try write(egress, to: egressLog)

        let node: AccessInternalTestNode
        do {
            node = try AccessInternalTestNode.parseSingleShareURI(uri)
            _ = try AccessOutboundConfigRegistry.embeddedInstanceJSONData(for: node)
        } catch {
            XCTFail("Reality Vision fixture could not be parsed")
            return
        }
        let core = try AccessGoEmbeddedCore()
        let publisher = AccessEmbeddedProxyEntryFactory.makeInternalTestPublisher(
            verifiedCore: core, node: { node }, connectionAllowed: { true },
            retireDocuments: { _, finish in finish() }, transport: .http
        )
        let operation = UUID()
        defer { publisher.cancel(operationID: operation) }
        let prepared = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(25)))
        guard publisher.validateReady(prepared) else { throw URLError(.cannotConnectToHost) }
        let proxy = try Self.probeConfiguration(prepared)

        let trace = ["https://www.cloudflare.com/cdn-cgi/trace"]
        for round in 1...2 {
            let directTrace = await Self.sampleHTTPS(trace, phase: "direct", round: round, proxy: nil)
            let proxyTrace = await Self.sampleHTTPS(trace, phase: "proxy", round: round, proxy: proxy)
            egress += directTrace + proxyTrace
            try write(egress, to: egressLog)
            let directControlOK = directTrace.contains {
                $0.status == 200 && $0.country == "CN" && $0.proxyByTransaction == [false]
            }
            let proxyControlOK = proxyTrace.contains { $0.status == 200 && $0.country != nil && $0.proxyObserved }
            guard directControlOK, proxyControlOK, usingWiFi() else {
                XCTFail("Wi-Fi or egress controls failed at boundary \(round)")
                return
            }
            guard round == 1 else { break }

            // Known reachability controls are independent of the sampled corpus.
            let canaryHosts = ["youtube.com", "google.com", "wikipedia.org", "github.com", "t.me", "x.com", "openai.com"]
            let canaries = await withTaskGroup(of: BlockedCNRow.self) { group in
                for host in canaryHosts {
                    let target = BlockedCNTarget(s: "canary", c: "CANARY", h: host, k: "full", p: nil)
                    group.addTask { await Self.headerProbe(target, phase: "proxy", proxy: proxy) }
                }
                var rows: [BlockedCNRow] = []
                for await row in group { rows.append(row) }
                return rows
            }
            try write(canaries, to: cache.appendingPathComponent("\(run)-blocked-cn-paired-canaries.json"))
            let canaryOK = canaries.filter { $0.usable && $0.transactions.last?.isProxy == true }.count
            guard canaryOK >= 4 else {
                XCTFail("Reality Vision reached \(canaryOK)/7 known hosts, expected at least 4")
                return
            }

            // Each worker has one active request. Randomizing order per pair
            // reduces drift while keeping the two observations close in time.
            pairs = try await Self.runPairs(targets.shuffled(), proxy: proxy, progress: progress, label: "primary")
            XCTAssertEqual(Set(pairs.map(\.target.h)), targetHosts)
            XCTAssertEqual(pairs.count, targets.count)
            XCTAssertEqual(pairs.filter { $0.direct.phase == "direct" && $0.proxy.phase == "proxy" }.count, targets.count)
        }

        let fallbackTargets = pairs.compactMap { pair -> BlockedCNTarget? in
            let host = "www." + pair.target.h
            guard pair.target.k == "domain", RegisteredDomain.of(pair.target.h) == pair.target.h,
                  !targetHosts.contains(host), !pair.direct.usable || !pair.proxy.usable else { return nil }
            return .init(s: "www-followup", c: pair.target.c, h: host, k: "full", p: nil)
        }
        // DNS/TLS outcomes at an apex do not establish how its www host behaves.
        let followupURL = cache.appendingPathComponent("\(run)-blocked-cn-paired-www.json")
        let followup = try await Self.runPairs(fallbackTargets, proxy: proxy, progress: followupURL, label: "www")
        XCTAssertEqual(Set(followup.map(\.target.h)), Set(fallbackTargets.map(\.h)))

        // Repeat the direct control after the supplemental requests as well.
        if !followup.isEmpty {
            egress += await Self.sampleHTTPS(trace, phase: "direct", round: 3, proxy: nil)
            egress += await Self.sampleHTTPS(trace, phase: "proxy", round: 3, proxy: proxy)
            try write(egress, to: egressLog)
            XCTAssertTrue(egress.contains {
                $0.round == 3 && $0.phase == "direct" && $0.status == 200 && $0.country == "CN" && $0.proxyByTransaction == [false]
            })
            XCTAssertTrue(egress.contains {
                $0.round == 3 && $0.phase == "proxy" && $0.status == 200 && $0.country != nil && $0.proxyObserved
            })
        }
        publisher.cancel(operationID: operation)
        let stopped = await core.stopAndConfirm()
        XCTAssertTrue(stopped)
        XCTAssertTrue(usingWiFi())
    }

    nonisolated private static func runPairs(
        _ targets: [BlockedCNTarget], proxy: ProxyConfiguration, progress: URL, label: String
    ) async throws -> [BlockedCNPair] {
        try await withThrowingTaskGroup(of: BlockedCNPair.self) { group in
            var pending = targets.makeIterator()
            for _ in 0..<min(8, targets.count) {
                if let target = pending.next() {
                    group.addTask { await Self.probePair(target, proxy: proxy) }
                }
            }
            var results: [BlockedCNPair] = []
            let encoder = JSONEncoder()
            while let pair = try await group.next() {
                results.append(pair)
                if results.count.isMultiple(of: 16) {
                    try encoder.encode(results).write(to: progress, options: .atomic)
                }
                if results.count.isMultiple(of: 100) {
                    NSLog("blocked-cn-paired %@ %d/%d complete", label, results.count, targets.count)
                }
                if let target = pending.next() {
                    group.addTask { await Self.probePair(target, proxy: proxy) }
                }
            }
            try encoder.encode(results).write(to: progress, options: .atomic)
            return results
        }
    }

    nonisolated private static func probePair(_ target: BlockedCNTarget, proxy: ProxyConfiguration) async -> BlockedCNPair {
        let first = Bool.random() ? "direct" : "proxy"
        let direct: BlockedCNRow
        let proxied: BlockedCNRow
        if first == "direct" {
            direct = await headerProbe(target, phase: "direct", proxy: nil)
            proxied = await headerProbe(target, phase: "proxy", proxy: proxy)
        } else {
            proxied = await headerProbe(target, phase: "proxy", proxy: proxy)
            direct = await headerProbe(target, phase: "direct", proxy: nil)
        }
        return .init(target: target, first: first, direct: direct, proxy: proxied)
    }

    nonisolated private static func headerProbe(
        _ target: BlockedCNTarget, phase: String, proxy: ProxyConfiguration?, collectTrust: Bool = false
    ) async -> BlockedCNRow {
        let start = ProcessInfo.processInfo.systemUptime
        guard let url = target.url else {
            return .init(phase: phase, status: nil, finalURL: nil, stoppedDowngrade: false,
                         errors: [.init(domain: NSURLErrorDomain, code: NSURLErrorBadURL)], streamError: nil,
                         milliseconds: 0, redirects: [], transactions: [], serverTrust: nil)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.proxyConfigurations = proxy.map { [$0] } ?? []
        let collector = BlockedCNHeaderCollector(collectTrust: collectTrust)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        let result = await withCheckedContinuation { continuation in
            collector.attach(continuation, phase: phase, started: start)
            task.resume()
        }
        session.finishTasksAndInvalidate()
        return result
    }

    private static func probeConfiguration(_ prepared: AccessProxyEntryPrepareResult) throws -> ProxyConfiguration {
        var proxy = try AccessProxyConfigurationBuilder.makeConfiguration(from: .init(
            registrationId: prepared.operationID.uuidString,
            host: prepared.endpoint.loopbackHost,
            port: prepared.endpoint.port,
            usesTLSToProxy: false
        ))
        proxy.allowFailover = false
        return proxy
    }

    nonisolated private static func sampleHTTPS(_ urls: [String], phase: String, round: Int,
                                                proxy: ProxyConfiguration?) async -> [AccessPhoneSample] {
        await withTaskGroup(of: AccessPhoneSample.self, returning: [AccessPhoneSample].self) { group in
            for raw in urls {
                guard let url = URL(string: raw), let host = url.host else { continue }
                group.addTask {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.allowsCellularAccess = false
                    configuration.waitsForConnectivity = false
                    configuration.timeoutIntervalForRequest = 10
                    configuration.timeoutIntervalForResource = 12
                    configuration.urlCache = nil
                    configuration.httpCookieStorage = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.proxyConfigurations = proxy.map { [$0] } ?? []
                    let metrics = AccessPhoneMetrics()
                    let session = URLSession(configuration: configuration, delegate: metrics, delegateQueue: nil)
                    defer { session.finishTasksAndInvalidate() }
                    let start = ProcessInfo.processInfo.systemUptime
                    var bytes = 0
                    var country: String?
                    var tlsDomain: String?
                    var response: HTTPURLResponse?
                    var errorCode: Int?
                    do {
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                        request.setValue("AegisAccessAcceptance/1.1.0", forHTTPHeaderField: "User-Agent")
                        let (body, received) = try await session.data(for: request)
                        response = received as? HTTPURLResponse
                        bytes = body.count
                        if url.path == "/cdn-cgi/trace", let trace = String(data: body, encoding: .utf8) {
                            let lines = trace.split(separator: "\n")
                            let code = lines.first { $0.hasPrefix("loc=") }.map { String($0.dropFirst(4)) }
                            if let code, code.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) { country = code }
                            tlsDomain = lines.first { $0.hasPrefix("tls=") }.map { String($0.dropFirst(4)) }
                        }
                    } catch {
                        errorCode = (error as NSError).code
                    }
                    let routes = metrics.observedRoutes()
                    return AccessPhoneSample(phase: phase, round: round, host: host, status: response?.statusCode,
                                             finalHost: response?.url?.host,
                                             milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1_000),
                                             bytes: bytes, proxyObserved: routes.contains(true), proxyByTransaction: routes,
                                             country: country, tlsDomain: tlsDomain, errorCode: errorCode)
                }
            }
            var results: [AccessPhoneSample] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.host < $1.host }
        }
    }


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

private struct AccessPhoneSample: Codable {
    let phase: String
    let round: Int
    let host: String
    let status: Int?
    let finalHost: String?
    let milliseconds: Int
    let bytes: Int
    let proxyObserved: Bool
    let proxyByTransaction: [Bool]
    let country: String?
    let tlsDomain: String?
    let errorCode: Int?

    var receivedExpectedHost: Bool {
        guard let status, (200..<300).contains(status), let finalHost else { return false }
        return [host, host.replacingOccurrences(of: "www.", with: "m.")].contains(finalHost)
    }
}

private final class AccessPhoneMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [Bool] = []

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        routes = metrics.transactionMetrics.map(\.isProxyConnection)
        lock.unlock()
    }

    func observedRoutes() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return routes
    }
}

private struct BlockedCNRerun: Decodable {
    let targets: [BlockedCNTarget]
}

private struct BlockedCNTarget: Codable, Sendable {
    let s: String
    let c: String
    let h: String
    let k: String
    let p: String?

    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = h
        components.path = p ?? "/"
        return components.url
    }
}

private struct BlockedCNPair: Encodable, Sendable {
    let target: BlockedCNTarget
    let first: String
    let direct: BlockedCNRow
    let proxy: BlockedCNRow
}

private struct BlockedCNRow: Encodable, Sendable {
    struct ErrorCode: Encodable, Sendable {
        let domain: String
        let code: Int
    }

    struct Redirect: Encodable, Sendable {
        let from: String?
        let to: String?
        let status: Int
    }

    struct Transaction: Encodable, Sendable {
        let url: String?
        let status: Int?
        let isProxy: Bool
        let remoteAddress: String?
    }

    let phase: String
    let status: Int?
    let finalURL: String?
    let stoppedDowngrade: Bool
    let errors: [ErrorCode]
    let streamError: ErrorCode?
    let milliseconds: Int
    let redirects: [Redirect]
    let transactions: [Transaction]
    let serverTrust: ServerTrust?

    struct ServerTrust: Encodable, Sendable {
        let host: String
        let error: ErrorCode?
        let leafDER: Data?
    }

    var usable: Bool {
        guard let status else { return false }
        return (200..<300).contains(status) && errors.isEmpty && !stoppedDowngrade
    }
}

private final class BlockedCNHeaderCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<BlockedCNRow, Never>
        let phase: String
        let started: TimeInterval
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var status: Int?
    private var finalURL: String?
    private var stoppedDowngrade = false
    private var stoppedAfterHeaders = false
    private var redirects: [BlockedCNRow.Redirect] = []
    private var transactions: [BlockedCNRow.Transaction] = []
    private var serverTrust: BlockedCNRow.ServerTrust?
    private let collectTrust: Bool

    init(collectTrust: Bool) {
        self.collectTrust = collectTrust
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if collectTrust, space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            var error: CFError?
            _ = SecTrustEvaluateWithError(trust, &error)
            let issue = error.map { BlockedCNRow.ErrorCode(domain: CFErrorGetDomain($0) as String, code: CFErrorGetCode($0)) }
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            let leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
            lock.withLock { serverTrust = .init(host: space.host, error: issue, leafDER: leaf) }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func attach(_ continuation: CheckedContinuation<BlockedCNRow, Never>, phase: String, started: TimeInterval) {
        lock.withLock { pending = .init(continuation: continuation, phase: phase, started: started) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let stop = request.url?.scheme?.lowercased() != "https"
        lock.withLock {
            redirects.append(.init(from: Self.safeURL(response.url), to: Self.safeURL(request.url), status: response.statusCode))
            stoppedDowngrade = stop
        }
        completionHandler(stop ? nil : request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            status = (response as? HTTPURLResponse)?.statusCode
            finalURL = Self.safeURL(response.url)
            stoppedAfterHeaders = true
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            transactions = metrics.transactionMetrics.map {
                .init(url: Self.safeURL($0.request.url), status: ($0.response as? HTTPURLResponse)?.statusCode,
                      isProxy: $0.isProxyConnection, remoteAddress: $0.remoteAddress)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: (Pending, BlockedCNRow)? = lock.withLock {
            guard let pending else { return nil }
            self.pending = nil
            var current = error as NSError?
            var errors: [BlockedCNRow.ErrorCode] = []
            var streamError: BlockedCNRow.ErrorCode?
            if stoppedAfterHeaders && current?.domain == NSURLErrorDomain && current?.code == NSURLErrorCancelled {
                current = nil
            }
            while let error = current, errors.count < 6 {
                errors.append(.init(domain: error.domain, code: error.code))
                if streamError == nil, let code = error.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber {
                    let domain = (error.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber)?.stringValue ?? ""
                    streamError = .init(domain: domain, code: code.intValue)
                }
                current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            return (pending, .init(phase: pending.phase, status: status, finalURL: finalURL,
                                   stoppedDowngrade: stoppedDowngrade, errors: errors, streamError: streamError,
                                   milliseconds: Int((ProcessInfo.processInfo.systemUptime - pending.started) * 1_000),
                                   redirects: redirects, transactions: transactions, serverTrust: serverTrust))
        }
        if let (pending, row) = result { pending.continuation.resume(returning: row) }
    }

    private static func safeURL(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }
}
