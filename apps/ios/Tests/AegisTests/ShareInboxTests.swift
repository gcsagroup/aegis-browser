import XCTest
@testable import Aegis

final class ShareInboxTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-share-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    func testEnvelopeCanOnlyBeConsumedOnce() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inbox = try ShareInbox(baseURL: temporaryURL)
        let envelope = try inbox.makeEnvelope(from: "https://example.com/shared", now: now)
        try inbox.store(envelope)

        XCTAssertEqual(try inbox.consume(now: now.addingTimeInterval(1)), envelope)
        XCTAssertNil(try inbox.consume(now: now.addingTimeInterval(2)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporaryURL.path).isEmpty)
    }

    func testExpiredEnvelopeIsDeletedAndRejected() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inbox = try ShareInbox(baseURL: temporaryURL)
        try inbox.store(try inbox.makeEnvelope(from: "https://example.com", now: now))
        XCTAssertThrowsError(try inbox.consume(now: now.addingTimeInterval(61))) { error in
            XCTAssertEqual(error as? ShareInboxError, .expired)
        }
        XCTAssertNil(try inbox.consume(now: now.addingTimeInterval(62)))
    }

    func testRejectsFilesCredentialsCustomSchemesAndOversizeText() throws {
        let inbox = try ShareInbox(baseURL: temporaryURL)
        for value in [
            "file:///tmp/private.txt",
            "javascript:alert(1)",
            "https://user:secret@example.com/",
        ] {
            XCTAssertThrowsError(try inbox.makeEnvelope(from: value))
        }
        XCTAssertThrowsError(try inbox.makeEnvelope(from: String(repeating: "a", count: 8_193))) { error in
            XCTAssertEqual(error as? ShareInboxError, .payloadTooLarge)
        }
    }

    func testMaximumSizeURLSurvivesEnvelopeEncoding() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inbox = try ShareInbox(baseURL: temporaryURL)
        let prefix = "https://example.com/"
        let value = prefix + String(
            repeating: "a",
            count: ShareInbox.maximumPayloadBytes - prefix.utf8.count
        )

        try inbox.store(try inbox.makeEnvelope(from: value, now: now))
        XCTAssertEqual(try inbox.consume(now: now.addingTimeInterval(1))?.url.absoluteString, value)
    }

    func testRejectsFutureOrExtendedLifetimeEnvelope() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inbox = try ShareInbox(baseURL: temporaryURL)
        let invalid = ShareEnvelope(
            version: ShareEnvelope.currentVersion,
            nonce: UUID(),
            url: URL(string: "https://example.com")!,
            createdAt: now.addingTimeInterval(10),
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertThrowsError(try inbox.store(invalid)) { error in
            XCTAssertEqual(error as? ShareInboxError, .invalidEnvelope)
        }

        let future = try inbox.makeEnvelope(
            from: "https://example.com/future",
            now: now.addingTimeInterval(10)
        )
        try inbox.store(future)
        XCTAssertThrowsError(try inbox.consume(now: now)) { error in
            XCTAssertEqual(error as? ShareInboxError, .invalidEnvelope)
        }
    }

    func testStaleCrashClaimIsRemoved() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inbox = try ShareInbox(baseURL: temporaryURL)
        let stale = temporaryURL.appendingPathComponent(".consuming-stale-v1.json")
        try Data("{}".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-70)],
            ofItemAtPath: stale.path
        )

        XCTAssertNil(try inbox.consume(now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
}
