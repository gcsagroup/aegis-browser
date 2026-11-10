import XCTest
@testable import AccessKit

final class AccessEmbeddedCoreManifestTests: XCTestCase {
    func testFrozenLockIsAVerifiedBuildWithBothSliceDigests() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EmbeddedCore/embedded-core-lock.json")
        let data = try Data(contentsOf: url)
        let manifest = try AccessEmbeddedCoreManifest.load(from: data)
        XCTAssertEqual(manifest.status, .verifiedBuild)
        XCTAssertEqual(manifest.xrayTag, "v26.11.9")
        XCTAssertEqual(manifest.xrayCommit, "676eaf66f8f05d4d558ee7a74b4736623d3feeb9")
        XCTAssertEqual(manifest.libXrayCommit, "5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3")
        XCTAssertEqual(
            manifest.iosArm64Sha256,
            "4d23ef190459a63963a1df0beb2296cc3c9cd6614e701529c2105f624621e6d4"
        )
        XCTAssertEqual(
            manifest.iosArm64SimulatorSha256,
            "9264f94db8724dab5988d216497f695d0a45f78103f6418ee84a4b86a4207c93"
        )
        XCTAssertTrue(manifest.mayLink)
    }

    func testVerifiedBuildRequiresBothSliceDigests() throws {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let manifest = try AccessEmbeddedCoreManifest.load(from: Data(json.utf8))
        XCTAssertTrue(manifest.mayLink)
    }

    func testSourceCandidateStillMustNotLink() throws {
        let json = """
        {"status":"source_candidate","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let manifest = try AccessEmbeddedCoreManifest.load(from: Data(json.utf8))
        XCTAssertFalse(manifest.mayLink)
    }
}
