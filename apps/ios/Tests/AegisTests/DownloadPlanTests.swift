import XCTest
@testable import BrowserKit

@MainActor final class DownloadPlanTests: XCTestCase {
    private let expectedDigest = String(repeating: "a", count: 64)
    private func xml(_ body: String) -> Data { Data("<metalink xmlns=\"urn:ietf:params:xml:ns:metalink\">\(body)</metalink>".utf8) }
    func testMetalinkOrdersMirrorsAndRejectsAmbiguity() throws {
        let body = "<file name=\"report.bin\"><size>42</size><hash type=\"sha-256\">\(expectedDigest)</hash><url priority=\"2\">https://b.example/report.bin</url><url priority=\"1\">https://a.example/report.bin</url></file>"
        let plan = try DownloadPlan.metalink(xml(body))
        XCTAssertEqual(plan.urls.map(\.host), ["a.example", "b.example"])
        XCTAssertEqual(plan.size, 42)
        XCTAssertEqual(plan.sha256, expectedDigest)
        for invalid in [body + body, body.replacingOccurrences(of: "report.bin\"", with: "../report.bin\""),
                        body.replacingOccurrences(of: "https://a.example", with: "http://127.0.0.1"),
                        body.replacingOccurrences(of: "priority=\"1\"", with: "priority=\"0\""),
                        body.replacingOccurrences(of: expectedDigest, with: "nohash"),
                        body.replacingOccurrences(of: "<size>42</size>", with: "<size>1000000001</size>")] {
            XCTAssertThrowsError(try DownloadPlan.metalink(xml(invalid)))
        }
        XCTAssertThrowsError(try DownloadPlan.metalink(Data("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>".utf8) + xml(body)))
        XCTAssertThrowsError(try DownloadPlan.metalink(Data(repeating: 32, count: 1_048_577)))
    }
    func testMirrorFallbackAndPersistentRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = DownloadManager(directory: folder, background: false)
        let urls = [URL(string: "http://127.0.0.1:8768/missing")!, URL(string: "http://127.0.0.1:8768/download.bin")!]
        let id = try manager.start(DownloadPlan(urls: urls, filename: "mirror-result.bin", size: 44032))
        try await waitUntil { manager.items.first?.state == .completed }
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.id, id); XCTAssertEqual(item.mirrorIndex, 1)
        XCTAssertEqual(item.filename, "mirror-result.bin")
        XCTAssertEqual(item.sha512, try DownloadManager.hashFile(manager.fileURL(item), sha512: true))
        let recovered = DownloadManager(directory: folder, background: false)
        XCTAssertEqual(recovered.items.first?.mirrors, urls)
        let bad = try manager.start(DownloadPlan(urls: urls, size: 1))
        try await waitUntil { manager.items.first { $0.id == bad }?.state == .failed }
        XCTAssertEqual(manager.items.first?.mirrorIndex, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(manager.items.first!).path))
        let offline = try manager.start(DownloadPlan(urls: [URL(string: "http://127.0.0.1:1/file")!, urls[1]]))
        try await waitUntil { manager.items.first { $0.id == offline }?.state == .completed }
    }
    func testSHA512MismatchFallsBackAndRestartCanResumePausedDownload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = DownloadManager(directory: folder, background: false)
        // 此值由独立的 Python hashlib 对验收原始字节计算。
        let expected = "d6b4a64ad03b6cb52216292f2cf78c378811562e5914f1c5f6b92ac5fa3854183da49641e8ca249a0c25ff9eb3334380732395f6cdb041c17c97558d4069024a"
        let id = try manager.start(DownloadPlan(urls: [URL(string: "http://127.0.0.1:8768/article")!, URL(string: "http://127.0.0.1:8768/download.bin")!], sha512: expected))
        try await waitUntil { manager.items.first { $0.id == id }?.state == .completed }
        XCTAssertEqual(manager.items.first?.mirrorIndex, 1)
        XCTAssertEqual(manager.items.first?.sha512, expected)
        let slow = try manager.start("http://127.0.0.1:8768/slow.bin")
        try await waitUntil { (manager.items.first?.received ?? 0) > 0 }
        manager.pause(slow)
        try await waitUntil { manager.items.first?.state == .paused }
        let restarted = DownloadManager(directory: folder, background: false)
        try restarted.resume(slow)
        try await waitUntil { restarted.items.first { $0.id == slow }?.state == .completed }
        XCTAssertGreaterThan(restarted.items.first?.received ?? 0, 1_000_000)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !predicate() && Date() < limit { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate())
    }
}
