import XCTest
@testable import AccessKit

@MainActor
final class AccessEmbeddedProxyEntryFactoryTests: XCTestCase {
    func testMissingConfigStaysFailClosedEvenWithVerifiedLock() async {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(
            lockData: Data(json.utf8),
            configPath: nil,
            verifiedCore: RecordingEmbeddedCoreForFactory()
        )
        do {
            _ = try await publisher.prepare(
                AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(5))
            )
            XCTFail("missing config must stay fail-closed")
        } catch let error as AccessSiteSessionError {
            XCTAssertEqual(error, .nodeUnavailable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSourceCandidateStaysFailClosed() async {
        let json = """
        {"status":"source_candidate","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(
            lockData: Data(json.utf8),
            configPath: "/tmp/does-not-matter",
            verifiedCore: RecordingEmbeddedCoreForFactory()
        )
        do {
            _ = try await publisher.prepare(
                AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(5))
            )
            XCTFail("source_candidate must stay fail-closed")
        } catch let error as AccessSiteSessionError {
            XCTAssertEqual(error, .nodeUnavailable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private final class RecordingEmbeddedCoreForFactory: AccessEmbeddedCoreControlling, @unchecked Sendable {
    nonisolated(unsafe) private var running = false
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
