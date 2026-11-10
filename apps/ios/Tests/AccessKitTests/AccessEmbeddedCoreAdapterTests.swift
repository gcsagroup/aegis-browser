import XCTest
@testable import AccessKit

@MainActor
final class AccessEmbeddedCoreAdapterTests: XCTestCase {
    func testFrozenLockStillNeedsInjectedCoreToDial() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EmbeddedCore/embedded-core-lock.json")
        let adapter = try AccessEmbeddedCoreAdapter(lockData: Data(contentsOf: url))
        XCTAssertTrue(adapter.manifest.mayLink)
        XCTAssertFalse(adapter.mayDial)
        XCTAssertFalse(adapter.core.isRunning)
        do {
            try await adapter.core.start(configData: Data("{}".utf8))
            XCTFail("verified digests without a linked core must not start")
        } catch AccessEmbeddedCoreError.unverifiedAsset {
        }
        let dialer = AccessEmbeddedRealityDialer(core: adapter.core)
        do {
            _ = try await dialer.dial(host: "example.invalid", port: 443)
            XCTFail("unverified dialer must not open a path")
        } catch AccessEmbeddedCoreError.unverifiedAsset {
        }
    }

    func testVerifiedManifestCanSelectInjectedCore() async throws {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let stub = RecordingEmbeddedCore()
        let adapter = try AccessEmbeddedCoreAdapter(lockData: Data(json.utf8), verifiedCore: stub)
        XCTAssertTrue(adapter.mayDial)
        try await adapter.core.start(configData: Data("{}".utf8))
        XCTAssertTrue(stub.started)
        let stream = try await adapter.core.dial(host: "example.invalid", port: 443)
        XCTAssertTrue(stream.isOpen)
        await adapter.core.stop()
        XCTAssertFalse(stub.started)
    }
}

private final class RecordingEmbeddedCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    nonisolated(unsafe) private var running = false

    var started: Bool { running }
    var isRunning: Bool { running }

    func start(configData: Data) async throws {
        _ = configData
        running = true
    }

    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        _ = host
        _ = port
        guard running else { throw AccessEmbeddedCoreError.unverifiedAsset }
        return AccessMemoryRealityStream()
    }

    func stop() async {
        running = false
    }
}
