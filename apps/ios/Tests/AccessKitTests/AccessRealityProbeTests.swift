import XCTest
@testable import AccessKit

private final class FakeHandle: AccessXrayProcessHandle {
    var isRunning = true
    func terminate() { isRunning = false }
}

private final class FakeController: AccessXrayProcessControlling {
    func launch(executableURL: URL, configData: Data) throws -> AccessXrayProcessHandle {
        _ = executableURL
        _ = configData
        return FakeHandle()
    }
}

private struct AcceptingVerifier: AccessXrayDigestVerifying {
    func verify(
        fileURL: URL,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AccessXrayRuntimeError.executableMissing
        }
    }
}

private final class FixedProbeExecutor: AccessRealityProbeExecuting {
    let result: Bool
    init(result: Bool) { self.result = result }
    func probe(target: AccessRealityProbeTarget) throws -> Bool {
        _ = target
        return result
    }
}

final class AccessRealityProbeTests: XCTestCase {
    private func makeRunningRuntime() throws -> (AccessXrayRuntime, URL) {
        let runtime = try AccessXrayRuntime(
            processController: FakeController(),
            digestVerifier: AcceptingVerifier()
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-xray-\(UUID().uuidString)")
        try Data("stub".utf8).write(to: url)
        let parameters = try AccessRealityVisionParameters(
            address: "198.51.100.30",
            port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000",
            serverName: "www.example.com",
            publicKey: "abcdefghijklmnopqrstuvwxyzABCDEFG",
            shortID: "abcd1234"
        )
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
        try runtime.start(executableURL: url, config: config)
        return (runtime, url)
    }

    func testBlockedResourceWhenNoAuthorizedNode() throws {
        let result = try AccessRealityProbe.blockedResourceIfNoTarget(target: nil)
        XCTAssertEqual(
            result,
            .blockedResource(reason: AccessRealityProbe.missingAuthorizedNodeReason)
        )
    }

    func testRunWithoutTargetReturnsBlockedResource() throws {
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let result = try AccessRealityProbe.run(runtime: runtime, target: nil)
        XCTAssertEqual(
            result,
            .blockedResource(reason: AccessRealityProbe.missingAuthorizedNodeReason)
        )
    }

    func testTargetWithoutExecutorIsNotAPass() throws {
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let target = try AccessRealityProbeTarget(
            host: "probe.example.invalid",
            port: 443,
            authorizationID: "auth-controlled-1"
        )
        let result = try AccessRealityProbe.run(runtime: runtime, target: target, executor: nil)
        XCTAssertEqual(
            result,
            .blockedResource(reason: AccessRealityProbe.missingAuthorizedNodeReason)
        )
    }

    func testRejectsDirectConnectAsPassFlag() throws {
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertThrowsError(
            try AccessRealityProbe.run(
                runtime: runtime,
                target: nil,
                allowDirectConnectAsPass: true
            )
        ) { error in
            XCTAssertEqual(error as? AccessRealityProbeError, .directConnectNotAdmitted)
        }
    }

    func testFailedWhenRuntimeNotRunning() throws {
        let runtime = try AccessXrayRuntime(
            processController: FakeController(),
            digestVerifier: AcceptingVerifier()
        )
        let result = try AccessRealityProbe.run(runtime: runtime, target: nil)
        XCTAssertEqual(result, .failed(.runtimeNotRunning))
    }

    func testPassedOnlyWhenExecutorSucceeds() throws {
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let target = try AccessRealityProbeTarget(
            host: "probe.example.invalid",
            port: 443,
            authorizationID: "auth-controlled-1"
        )
        let passed = try AccessRealityProbe.run(
            runtime: runtime,
            target: target,
            executor: FixedProbeExecutor(result: true)
        )
        XCTAssertEqual(passed, .passed(authorizationID: "auth-controlled-1"))

        let failed = try AccessRealityProbe.run(
            runtime: runtime,
            target: target,
            executor: FixedProbeExecutor(result: false)
        )
        XCTAssertEqual(failed, .failed(.fieldNotCanonical("probeResult")))
    }
}
