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
            "12ac2d9b412857857f9afd9e9a25430e7b1fc42f3d8e27ed47cdf874e616d615"
        )
        XCTAssertEqual(
            manifest.iosArm64SimulatorSha256,
            "e0a7dd80da58b67d6a8d6735d7978c9b61bf722b3065ea85788b304b65bd4a5f"
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
