import CryptoKit
import XCTest
@testable import AccessKit

private final class FakeXrayHandle: AccessXrayProcessHandle {
    private(set) var isRunning: Bool = true
    private(set) var terminateCount = 0
    func terminate() {
        isRunning = false
        terminateCount += 1
    }
}

private final class FakeXrayController: AccessXrayProcessControlling {
    var lastConfig: Data?
    var lastExecutable: URL?
    var shouldFailLaunch = false
    private(set) var launchCount = 0

    func launch(executableURL: URL, configData: Data) throws -> AccessXrayProcessHandle {
        launchCount += 1
        lastExecutable = executableURL
        lastConfig = configData
        if shouldFailLaunch {
            throw AccessXrayRuntimeError.launchFailed("forced")
        }
        return FakeXrayHandle()
    }
}

private struct AcceptingDigestVerifier: AccessXrayDigestVerifying {
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

private struct MismatchDigestVerifier: AccessXrayDigestVerifying {
    func verify(
        fileURL: URL,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile
    ) throws {
        throw AccessXrayRuntimeError.digestMismatch(
            expected: AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex,
            actual: String(repeating: "0", count: 64)
        )
    }
}

final class AccessXrayRuntimeTests: XCTestCase {
    private func makeConfig() throws -> AccessRealityVisionOutboundConfig {
        let parameters = try AccessRealityVisionParameters(
            address: "198.51.100.20",
            port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000",
            serverName: "www.example.com",
            publicKey: "abcdefghijklmnopqrstuvwxyzABCDEFG",
            shortID: "abcd1234"
        )
        return try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
    }

    private func writeTempExecutable(contents: String = "xray-stub") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("access-xray-fake-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testPinnedVerifierRejectsDigestMismatch() throws {
        let executable = try writeTempExecutable(contents: "wrong-binary")
        defer { try? FileManager.default.removeItem(at: executable) }

        let verifier = AccessXrayPinnedDigestVerifier()
        XCTAssertThrowsError(
            try verifier.verify(
                fileURL: executable,
                architecture: .iosArm64,
                outboundProfile: .realityVision
            )
        ) { error in
            guard case let AccessXrayRuntimeError.digestMismatch(expected, actual)? =
                error as? AccessXrayRuntimeError
            else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
            XCTAssertEqual(expected, AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex)
            do {
                let data = try Data(contentsOf: executable)
                let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(actual, hex)
            } catch {
                XCTFail("failed to re-read fixture for digest check: \(error)")
            }
        }
    }

    func testRejectsDigestMismatchBeforeLaunch() throws {
        let controller = FakeXrayController()
        let runtime = try AccessXrayRuntime(
            processController: controller,
            digestVerifier: MismatchDigestVerifier()
        )
        let executable = try writeTempExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }

        XCTAssertThrowsError(try runtime.start(executableURL: executable, config: try makeConfig())) { error in
            XCTAssertEqual(
                error as? AccessXrayRuntimeError,
                .digestMismatch(
                    expected: AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex,
                    actual: String(repeating: "0", count: 64)
                )
            )
        }
        XCTAssertEqual(controller.launchCount, 0)
        XCTAssertEqual(runtime.state, .idle)
    }

    func testRejectsMissingExecutable() throws {
        let runtime = try AccessXrayRuntime(
            processController: FakeXrayController(),
            digestVerifier: AccessXrayPinnedDigestVerifier()
        )
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-xray-\(UUID().uuidString)")
        XCTAssertThrowsError(try runtime.start(executableURL: missing, config: try makeConfig())) { error in
            XCTAssertEqual(error as? AccessXrayRuntimeError, .executableMissing)
        }
    }

    func testStartStopLifecycle() throws {
        let controller = FakeXrayController()
        let runtime = try AccessXrayRuntime(
            processController: controller,
            digestVerifier: AcceptingDigestVerifier()
        )
        let executable = try writeTempExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }
        let config = try makeConfig()

        try runtime.start(executableURL: executable, config: config)
        XCTAssertEqual(runtime.state, .running)
        XCTAssertEqual(controller.launchCount, 1)
        XCTAssertEqual(controller.lastExecutable, executable)
        XCTAssertNotNil(controller.lastConfig)
        let text = String(data: controller.lastConfig!, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("xtls-rprx-vision"))
        XCTAssertFalse(text.contains("allowInsecure"))

        XCTAssertThrowsError(try runtime.start(executableURL: executable, config: config)) { error in
            XCTAssertEqual(error as? AccessXrayRuntimeError, .alreadyRunning)
        }

        try runtime.stop()
        XCTAssertEqual(runtime.state, .idle)
        XCTAssertThrowsError(try runtime.stop()) { error in
            XCTAssertEqual(error as? AccessXrayRuntimeError, .notRunning)
        }
    }
}
