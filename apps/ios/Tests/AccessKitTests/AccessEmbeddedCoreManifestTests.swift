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
            "b478fcf73ce919fd4494ac96e6035e4e2879ab5847db4276a142b5259b4f9bdf"
        )
        XCTAssertEqual(
            manifest.iosArm64SimulatorSha256,
            "7aa12ce96111a8910cc3eb17692b9de0a025f31f41ebce8a18a4ec7f032f5887"
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
