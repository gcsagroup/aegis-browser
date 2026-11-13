import Darwin
import Synchronization
import XCTest
@testable import AccessKit

final class AccessRealityVisionOutboundConfigTests: XCTestCase {
    func testDiagnosticDefaultsFollowTheProductChannel() {
        let expected: [AccessReleaseChannel: AccessLogLevel] = [
            .dev: .debug, .alpha: .info, .beta: .warning, .release: .warning, .unknown: .warning]
        let suite = "access.log-defaults." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for channel in AccessReleaseChannel.allCases {
            XCTAssertEqual(AccessDiagnosticLog.defaultLevel(for: channel), expected[channel])
            XCTAssertEqual(AccessDiagnosticLog.selectedLevel(defaults: defaults, channel: channel), expected[channel])
        }
        defaults.set("unrecognized", forKey: AccessDiagnosticLog.preferenceKey)
        XCTAssertEqual(AccessDiagnosticLog.selectedLevel(defaults: defaults, channel: .release), .warning)
    }

    func testEveryExplicitLogChoiceOverridesChannelDefaultsIncludingNone() {
        let suite = "access.log-overrides." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for level in AccessLogLevel.allCases {
            defaults.set(level.rawValue, forKey: AccessDiagnosticLog.preferenceKey)
            for channel in AccessReleaseChannel.allCases {
                XCTAssertEqual(AccessDiagnosticLog.selectedLevel(defaults: defaults, channel: channel), level)
            }
        }
        defaults.removeObject(forKey: AccessDiagnosticLog.preferenceKey)
        XCTAssertEqual(AccessDiagnosticLog.selectedLevel(defaults: defaults, channel: .alpha), .info)
    }

    @MainActor
    func testChannelDefaultReachesTheCoreWithoutChangingTheOutbound() async throws {
        let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: makeParameters())
        let suite = "access.log-core-defaults." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for channel in AccessReleaseChannel.allCases {
            let diagnostics = AccessDiagnosticLog()
            defer { diagnostics.stop() }
            let core = PersistenceRecordingCore()
            let level = AccessDiagnosticLog.selectedLevel(defaults: defaults, channel: channel)
            _ = try await AccessEmbeddedProxyEntrySession.startCoreWithDiagnostics(
                core: core, outbound: outbound, diagnostics: diagnostics, level: level)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(core.configs.first)) as? [String: Any])
            XCTAssertEqual((root["log"] as? [String: String])?["loglevel"], level.rawValue)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: root["outbounds"]!, options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: outbound.jsonObject["outbounds"]!, options: .sortedKeys))
        }
    }

    func testEmbeddedLogLevelsRequireExplicitSinkAndKeepAccessLogOff() throws {
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: makeParameters())
        for level in AccessLogLevel.allCases {
            let root = try config.embeddedInstanceJSONObject(logLevel: level, errorLogPath: "/tmp/test-log")
            let log = try XCTUnwrap(root["log"] as? [String: String])
            XCTAssertEqual(log["loglevel"], level.rawValue)
            XCTAssertEqual(log["access"], "none")
            XCTAssertEqual(log["error"], level == .none ? "none" : "/tmp/test-log")
            XCTAssertEqual((root["outbounds"] as? [[String: Any]])?.count, 1)
        }
        XCTAssertThrowsError(try config.embeddedInstanceJSONObject(logLevel: .debug))
        XCTAssertThrowsError(try config.embeddedInstanceJSONObject(logLevel: .warning, errorLogPath: "relative"))
    }

    func testEmbeddedLoggingDefaultsRemainQuiet() throws {
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: makeParameters())
        let log = try XCTUnwrap(config.embeddedInstanceJSONObject()["log"] as? [String: String])
        XCTAssertEqual(log["loglevel"], "none")
        XCTAssertEqual(log["access"], "none")
        XCTAssertEqual(log["error"], "none")
    }

    func testDiagnosticPipeCapturesRedactsAndDisables() throws {
        let diagnostics = AccessDiagnosticLog()
        let capture = try XCTUnwrap(diagnostics.start(level: .info, secrets: ["test-secret-123"]))
        defer { diagnostics.stop() }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        defer { try? writer.close() }
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 [Warning] proxy/http: userID=test-secret-123 https://user:pw@example.com/path?token=abc\n".utf8))
        let deadline = Date().addingTimeInterval(2)
        while diagnostics.snapshot().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let snapshot = diagnostics.snapshot()
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertFalse(snapshot.contains("test-secret-123"))
        XCTAssertFalse(snapshot.contains("user:pw"))
        XCTAssertFalse(snapshot.contains("token=abc"))
        XCTAssertTrue(snapshot.contains("details withheld"))
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 [Info] proxy/vless/outbound: tunneling request to tcp:example.com:443 via node.example:443\n".utf8))
        let targetDeadline = Date().addingTimeInterval(2)
        while !diagnostics.snapshot().contains("example.com:443") && Date() < targetDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(diagnostics.snapshot().contains("tunneling request to tcp:example.com:443 via node.example:443"))
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //diagnostic.invalid:443\n".utf8))
        let accessDeadline = Date().addingTimeInterval(2)
        while !diagnostics.snapshot().contains("accepted diagnostic.invalid:443") && Date() < accessDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(diagnostics.snapshot().contains("accepted diagnostic.invalid:443"))
        diagnostics.disableAndClear()
        try writer.write(contentsOf: Data("ignored\n".utf8))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(diagnostics.snapshot(), "")
    }

    func testArchiveContainsCompressedSnapshotAndCanBeRemoved() throws {
        let input = "access diagnostic event\n"
        let file = try AccessDiagnosticArchive.createTemporary(snapshot: input)
        defer { AccessDiagnosticArchive.removeTemporary(file) }
        let zip = try Data(contentsOf: file)
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        let compressedLength = zip[18..<22].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        let filenameLength = Int(zip[26]) | Int(zip[27]) << 8
        let offset = 30 + filenameLength
        let deflate = zip.subdata(in: offset..<(offset + compressedLength))
        let decoded = try (deflate as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(String(data: decoded, encoding: .utf8), input)
        AccessDiagnosticArchive.removeTemporary(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStopDrainsFinalCompleteRecordsBeforeTheFirstPollAndPersistsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-final-record-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info, pollInterval: .seconds(60))
        let capture = try XCTUnwrap(log.start(level: .info, secrets: ["synthetic-secret"]))
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //final.example:443/path?token=synthetic-secret\nunfinished".utf8))
        try writer.close()
        XCTAssertTrue(log.stop(capture: capture))
        XCTAssertTrue(log.snapshot().contains("accepted final.example:443"))
        XCTAssertFalse(log.snapshot().contains("synthetic-secret"))
        XCTAssertFalse(log.snapshot().contains("unfinished"))
        try await log.flush()
        let restored = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info)
        try await restored.flush()
        XCTAssertEqual(restored.snapshot(), log.snapshot())
        restored.markUnavailable()
        XCTAssertTrue(restored.unavailable)
        XCTAssertTrue(restored.snapshot().contains("final.example:443"))
    }

    func testStopDrainPreservesClearAndNoneDiscardBoundaries() throws {
        for disable in [false, true] {
            let log = AccessDiagnosticLog(pollInterval: .seconds(60))
            let capture = try XCTUnwrap(log.start(level: .info, secrets: []))
            let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
            try writer.write(contentsOf: Data("2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //before-clear.example:443\npartial".utf8))
            if disable { log.disableAndClear() } else { log.clear() }
            try writer.write(contentsOf: Data("-tail\n2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //after-clear.example:443\n".utf8))
            try writer.close()
            XCTAssertTrue(log.stop(capture: capture))
            XCTAssertFalse(log.snapshot().contains("before-clear"))
            XCTAssertFalse(log.snapshot().contains("partial"))
            if disable { XCTAssertEqual(log.snapshot(), "") }
            else { XCTAssertTrue(log.snapshot().contains("after-clear.example:443")) }
        }
    }

    func testStartupCleanupRemovesAbandonedArchivesWithoutFollowingLinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("access-archive-recovery-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp")
        let outside = root.appendingPathComponent("outside")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: kept)
        let abandoned = temporary.appendingPathComponent("aegis-access-share-" + UUID().uuidString)
        try manager.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data("private.example".utf8).write(to: abandoned.appendingPathComponent("aegis-access-diagnostics.zip"))
        let link = temporary.appendingPathComponent("aegis-access-share-" + UUID().uuidString)
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let unrelated = temporary.appendingPathComponent("aegis-access-share-not-an-archive")
        try Data("unrelated".utf8).write(to: unrelated)
        try AccessDiagnosticArchive.removeAbandonedTemporaryArchives(in: temporary)
        XCTAssertFalse(manager.fileExists(atPath: abandoned.path))
        XCTAssertFalse(manager.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: kept), Data("keep".utf8))
        XCTAssertTrue(manager.fileExists(atPath: unrelated.path))
        XCTAssertThrowsError(try AccessDiagnosticArchive.removeAbandonedTemporaryArchives(in: root.appendingPathComponent("missing")))
    }

    func testOldCaptureCannotStopNewCaptureAndWarningOmitsAccess() throws {
        let diagnostics = AccessDiagnosticLog(capacity: 512)
        let old = try XCTUnwrap(diagnostics.start(level: .info, secrets: []))
        let current = try XCTUnwrap(diagnostics.start(level: .warning, secrets: []))
        defer { diagnostics.stop() }
        diagnostics.stop(capture: old)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: current.path))
        defer { try? writer.close() }
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //hidden.invalid:443\n2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n".utf8))
        let deadline = Date().addingTimeInterval(2)
        while diagnostics.snapshot().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(diagnostics.snapshot().contains("Xray 26.11.9 started"))
        XCTAssertFalse(diagnostics.snapshot().contains("hidden.invalid"))
        let repeated = String(repeating: "2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n", count: 30)
        try writer.write(contentsOf: Data(repeated.utf8))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertLessThanOrEqual(diagnostics.snapshot().utf8.count, 512)
    }

    func testWholeEventParsingDoesNotRetainAuthFromDialerInput() throws {
        let diagnostics = AccessDiagnosticLog()
        let capture = try XCTUnwrap(diagnostics.start(level: .debug, secrets: []))
        defer { diagnostics.stop() }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        defer { try? writer.close() }
        let input = """
        2026/11/11 00:00:00 [Info] transport/internet/tcp: dialing TCP to node.invalid accepted //alice:password@example.invalid
        2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //alice:password@example.invalid
        2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started
        """ + "\n"
        try writer.write(contentsOf: Data(input.utf8))
        let deadline = Date().addingTimeInterval(2)
        while !diagnostics.snapshot().contains("Xray 26.11.9") && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(diagnostics.snapshot().contains("Xray 26.11.9"))
        XCTAssertFalse(diagnostics.snapshot().contains("alice"))
        XCTAssertFalse(diagnostics.snapshot().contains("password"))
    }

    func testMultilineNodeFieldCannotInjectSecretAsVersion() throws {
        let malicious = "node.invalid\n2026/11/11 00:00:00 [Warning] core: Xray 12345678.1 started\nnode.invalid"
        XCTAssertThrowsError(try makeParameters(address: malicious, shortID: "12345678")) { error in
            XCTAssertEqual(error as? AccessRealityVisionOutboundConfigError, .fieldNotCanonical("address"))
        }
        XCTAssertThrowsError(try makeParameters(serverName: "example.com\rspoof"))
        XCTAssertThrowsError(try makeParameters(publicKey: "public\u{7f}key"))
        let diagnostics = AccessDiagnosticLog()
        let capture = try XCTUnwrap(diagnostics.start(level: .debug, secrets: ["12345678"]))
        defer { diagnostics.stop() }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        defer { try? writer.close() }
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 [Warning] core: Xray 12345678.1 started\n2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n".utf8))
        let deadline = Date().addingTimeInterval(2)
        while !diagnostics.snapshot().contains("Xray 26.11.9") && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(diagnostics.snapshot().contains("Xray 26.11.9"))
        XCTAssertFalse(diagnostics.snapshot().contains("12345678"))
        XCTAssertTrue(diagnostics.stop(capture: capture))
        let late = open(capture.path, O_WRONLY | O_CREAT | O_NONBLOCK, 0o600)
        if late >= 0 { close(late); XCTFail("configured log pathname still writable after stop") }
        XCTAssertEqual(late, -1)
    }

    func testRetirementRemovesConfiguredParentBeforeDeletion() throws {
        let diagnostics = AccessDiagnosticLog()
        let capture = try XCTUnwrap(diagnostics.start(level: .warning, secrets: []))
        defer { diagnostics.stop() }
        let parent = URL(fileURLWithPath: capture.path).deletingLastPathComponent()
        let retired = try XCTUnwrap(AccessDiagnosticLog.retireDirectory(parent))
        defer { try? FileManager.default.removeItem(at: retired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        let lateWriter = open(capture.path, O_CREAT | O_WRONLY | O_NONBLOCK, 0o600)
        if lateWriter >= 0 { close(lateWriter); XCTFail("late writer recreated configured sink") }
        XCTAssertEqual(lateWriter, -1)
    }

    @MainActor
    func testCoreRetriesLoggerFailureWithSameOutboundAndNoLogs() async throws {
        let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: makeParameters())
        let diagnostics = AccessDiagnosticLog()
        defer { diagnostics.stop() }
        let core = LogInitializationFailingCore(message: "failed to initialize error logger")
        let capture = try await AccessEmbeddedProxyEntrySession.startCoreWithDiagnostics(
            core: core, outbound: outbound, diagnostics: diagnostics, level: .warning)
        XCTAssertNil(capture)
        XCTAssertTrue(diagnostics.unavailable)
        XCTAssertEqual(core.configs.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: core.configs[0]) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: core.configs[1]) as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: first["outbounds"]!, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: second["outbounds"]!, options: .sortedKeys))
        XCTAssertEqual((second["log"] as? [String: String])?["loglevel"], "none")
        let unrelated = LogInitializationFailingCore(message: "invalid outbound configuration")
        do {
            _ = try await AccessEmbeddedProxyEntrySession.startCoreWithDiagnostics(
                core: unrelated, outbound: outbound, diagnostics: diagnostics, level: .warning)
            XCTFail("unrelated failure was hidden")
        } catch { XCTAssertEqual(unrelated.configs.count, 1) }
    }

    func testDisableIsResponsiveDuringSustainedOutput() throws {
        let diagnostics = AccessDiagnosticLog()
        let capture = try XCTUnwrap(diagnostics.start(level: .warning, secrets: []))
        defer { diagnostics.stop() }
        let fd = open(capture.path, O_WRONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(String(repeating: "2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n", count: 32).utf8)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            }
            group.leave()
        }
        Thread.sleep(forTimeInterval: 0.15)
        let before = Date()
        diagnostics.disableAndClear()
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.5)
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(diagnostics.snapshot(), "")
    }

    func testDiskHistoryRestoresAndClearDeletesBothCopies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-persist-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AccessDiagnosticLog(capacity: 1024, storageDirectory: directory, initialLevel: .info)
        let capture = try XCTUnwrap(log.start(level: .info, secrets: ["private-token"]))
        defer { log.stop() }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        let events = String(repeating: "2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //private.example:443\n", count: 30)
        try writer.write(contentsOf: Data(events.utf8))
        try writer.close()
        let deadline = Date().addingTimeInterval(2)
        while log.snapshot().isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(log.snapshot().contains("private.example:443"))
        XCTAssertLessThanOrEqual(log.snapshot().utf8.count, 1024)
        try await log.flush()
        log.stop()
        let file = directory.appendingPathComponent("history.json")
        XCTAssertLessThanOrEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? Int.max, 4096)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let restarted = AccessDiagnosticLog(capacity: 1024, storageDirectory: directory, initialLevel: .info)
        try await restarted.flush()
        XCTAssertEqual(restarted.snapshot(), log.snapshot())
        try await restarted.clearStoredLogs()
        XCTAssertEqual(restarted.snapshot(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let afterClear = AccessDiagnosticLog(storageDirectory: directory)
        try await afterClear.flush()
        XCTAssertEqual(afterClear.snapshot(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testClearAndNoneCannotBeUndoneByCoalescedWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-clear-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AccessDiagnosticLog(storageDirectory: directory)
        let capture = try XCTUnwrap(log.start(level: .warning, secrets: []))
        defer { log.stop() }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        defer { try? writer.close() }
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n".utf8))
        let deadline = Date().addingTimeInterval(2)
        while log.snapshot().isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(log.snapshot().isEmpty)
        try await log.clearStoredLogs()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n".utf8))
        let nextDeadline = Date().addingTimeInterval(2)
        while log.snapshot().isEmpty && Date() < nextDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try await log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        log.disableAndClear()
        try await log.flush()
        let disabledRestart = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .none)
        try await disabledRestart.flush()
        XCTAssertTrue(disabledRestart.snapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRedactedGrammarAndTargetsRoundTripWithoutLosingRecords() async throws {
        for secret in ["ac", "2026", "26.11", "pre-connect", "private"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-redacted-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info)
            let capture = try XCTUnwrap(log.start(level: .info, secrets: [secret]))
            defer { log.stop() }
            let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
            let events = """
            2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //private.example:443
            2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started
            2026/11/11 00:00:00 [Warning] app/dispatcher: pre-connect failed
            """ + "\n"
            try writer.write(contentsOf: Data(events.utf8)); try writer.close()
            let deadline = Date().addingTimeInterval(2)
            while log.snapshot().split(separator: "\n").count < 3 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let beforeRestart = log.snapshot()
            XCTAssertEqual(beforeRestart.split(separator: "\n").count, 3)
            XCTAssertFalse(beforeRestart.replacingOccurrences(of: "[redacted]", with: "").localizedCaseInsensitiveContains(secret))
            try await log.flush()
            log.stop()
            let restarted = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info)
            try await restarted.flush()
            XCTAssertEqual(restarted.snapshot(), beforeRestart, "secret collision: \(secret)")
            XCTAssertFalse(restarted.persistenceUnavailable)
        }
    }

    func testClearDiscardsUnreadPipePrefixAndPartialEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-buffered-clear-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Keep the first poll in the future so Clear encounters unread bytes.
        let log = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info, pollInterval: .seconds(1))
        let capture = try XCTUnwrap(log.start(level: .info, secrets: []))
        defer { log.stop() }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        defer { try? writer.close() }
        try writer.write(contentsOf: Data((
            "2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //before-clear.invalid:443\n" +
            "2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //partial-before").utf8))
        XCTAssertTrue(log.snapshot().isEmpty)
        try await log.clearStoredLogs()
        try writer.write(contentsOf: Data((
            "-clear.invalid:443\n" +
            "2026/11/11 00:00:00 from 127.0.0.1:1234 accepted //after-clear.invalid:443\n").utf8))
        let deadline = Date().addingTimeInterval(3)
        while !log.snapshot().contains("after-clear.invalid") && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(log.snapshot().contains("after-clear.invalid"))
        XCTAssertFalse(log.snapshot().contains("before-clear"))
        XCTAssertFalse(log.snapshot().contains("partial-before"))
        try await log.flush()
        log.stop()
        let restarted = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info)
        try await restarted.flush()
        XCTAssertEqual(restarted.snapshot(), log.snapshot())
    }

    func testShortRedactedRecordsRespectTheDiskRecordLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-record-limit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AccessDiagnosticLog(storageDirectory: directory)
        let capture = try XCTUnwrap(log.start(level: .warning, secrets: ["2026"]))
        defer { log.stop() }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        let events = String(repeating: "2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n", count: 8193)
        try writer.write(contentsOf: Data(events.utf8)); try writer.close()
        let deadline = Date().addingTimeInterval(5)
        while log.snapshot().split(separator: "\n").count < 8192 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(log.snapshot().split(separator: "\n").count, 8192)
        try await log.flush()
        log.stop()
        let restarted = AccessDiagnosticLog(storageDirectory: directory)
        try await restarted.flush()
        XCTAssertEqual(restarted.snapshot(), log.snapshot())
        XCTAssertFalse(restarted.persistenceUnavailable)
        let storage = AccessDiagnosticLogStorage(directory: directory)
        let rejected: Result<Void, Error> = await withCheckedContinuation { continuation in
            storage.save(Array(repeating: "[redacted]", count: 8193)) { continuation.resume(returning: $0) }
        }
        if case .success = rejected { XCTFail("writer accepted history that its reader rejects") }
    }

    func testDelayedRestoreRedactsChangedCredentialsIntoRestartSafeRecords() async throws {
        for secret in ["2026", "ac", "private"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-late-restore-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let history = [
                "2026/11/11 00:00:00 [Access] accepted private.example:443",
                "2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started"]
            try JSONSerialization.data(withJSONObject: ["version": 1, "lines": history])
                .write(to: directory.appendingPathComponent("history.json"))
            let storageQueue = DispatchQueue(label: "access.delayed.restore.test")
            storageQueue.suspend()
            let log = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info, storageQueue: storageQueue)
            do { _ = try log.start(level: .info, secrets: [secret]) }
            catch { storageQueue.resume(); throw error }
            defer { log.stop() }
            storageQueue.resume()
            try await log.flush()
            let redacted = log.snapshot()
            XCTAssertEqual(redacted.split(separator: "\n").count, 2)
            XCTAssertFalse(redacted.replacingOccurrences(of: "[redacted]", with: "").localizedCaseInsensitiveContains(secret))
            log.stop()
            let restarted = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info)
            try await restarted.flush()
            XCTAssertEqual(restarted.snapshot(), redacted)
            XCTAssertFalse(restarted.persistenceUnavailable)
        }
    }

    func testChangingCredentialsResanitizesHistoryThatAlreadyRestored() async throws {
        for secret in ["2026", "ac", "private"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-restored-before-start-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let history = [
                "2026/11/11 00:00:00 [Access] accepted private.example:443",
                "2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started"]
            try JSONSerialization.data(withJSONObject: ["version": 1, "lines": history])
                .write(to: directory.appendingPathComponent("history.json"))
            let log = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info)
            try await log.flush()
            XCTAssertEqual(log.snapshot(), history.joined(separator: "\n"))
            _ = try log.start(level: .info, secrets: [secret])
            defer { log.stop() }
            let sanitized = log.snapshot()
            XCTAssertEqual(sanitized.split(separator: "\n").count, 2)
            XCTAssertFalse(sanitized.replacingOccurrences(of: "[redacted]", with: "").localizedCaseInsensitiveContains(secret))
            try await log.flush()
            log.stop()
            let restarted = AccessDiagnosticLog(storageDirectory: directory, initialLevel: .info)
            try await restarted.flush()
            XCTAssertEqual(restarted.snapshot(), sanitized)
            XCTAssertFalse(restarted.persistenceUnavailable)
        }
    }

    func testDiskWriterClearOrdersBehindQueuedSaveAndRejectsUnsafeFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("access-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = DispatchQueue(label: "access.disk.test.order")
        let storage = AccessDiagnosticLogStorage(directory: directory, queue: work)
        let writeOK = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            work.suspend()
            storage.save(["2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started"]) { result in
                if case .success = result { writeOK.withLock { $0 = true } }
            }
            storage.clear { continuation.resume(with: $0) }
            work.resume()
        }
        XCTAssertTrue(writeOK.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appendingPathComponent("history.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let result: Result<[String], Error> = await withCheckedContinuation { continuation in
            storage.load { continuation.resume(returning: $0) }
        }
        if case .success = result { XCTFail("non-regular history file accepted") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storage.clear { continuation.resume(with: $0) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 1024 * 1024 + 1).write(to: fifo)
        let oversized: Result<[String], Error> = await withCheckedContinuation { continuation in
            storage.load { continuation.resume(returning: $0) }
        }
        if case .success = oversized { XCTFail("oversized history accepted") }
    }

    @MainActor
    func testDiskFailureDoesNotBreakCoreAndRestoredTextIsSanitized() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("access-errors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let invalidDirectory = parent.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: invalidDirectory)
        let log = AccessDiagnosticLog(storageDirectory: invalidDirectory)
        let core = PersistenceRecordingCore()
        let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: makeParameters())
        _ = try await AccessEmbeddedProxyEntrySession.startCoreWithDiagnostics(core: core, outbound: outbound, diagnostics: log, level: .warning)
        defer { log.stop() }
        XCTAssertTrue(core.isRunning)
        // Queue a real filtered event so flush must attempt a write.
        let capture = try XCTUnwrap(log.start(level: .warning, secrets: []))
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: capture.path))
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started\n".utf8)); try writer.close()
        let deadline = Date().addingTimeInterval(2)
        while log.snapshot().isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        do { try await log.flush(); XCTFail("disk error hidden") } catch { }
        XCTAssertTrue(log.persistenceUnavailable)
        XCTAssertTrue(core.isRunning)
        XCTAssertFalse(log.snapshot().isEmpty)
        do { try await log.clearStoredLogs(); XCTFail("delete error hidden") } catch { }
        let directory = parent.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "lines": [
            "2026/11/11 00:00:00 [Warning] arbitrary password=leak-me",
            "2026/11/11 00:00:00 [Warning] core: Xray 26.11.9 started"]])
        try data.write(to: directory.appendingPathComponent("history.json"))
        let restored = AccessDiagnosticLog(storageDirectory: directory)
        try await restored.flush()
        XCTAssertTrue(restored.snapshot().contains("Xray 26.11.9"))
        XCTAssertFalse(restored.snapshot().contains("leak-me"))
    }

    private func makeParameters(
        address: String = "198.51.100.10",
        port: UInt16 = 443,
        userID: String = "550e8400-e29b-41d4-a716-446655440000",
        serverName: String = "www.example.com",
        publicKey: String = "abcdefghijklmnopqrstuvwxyzABCDEFG",
        shortID: String = "abcd1234"
    ) throws -> AccessRealityVisionParameters {
        try AccessRealityVisionParameters(
            address: address,
            port: port,
            userID: userID,
            serverName: serverName,
            publicKey: publicKey,
            shortID: shortID
        )
    }

    func testBuildsRealityVisionOutboundMatrix() throws {
        let parameters = try makeParameters()
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
        XCTAssertEqual(config.profile, .realityVision)

        let root = config.jsonObject
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        let outbound = try XCTUnwrap(outbounds.first)
        XCTAssertEqual(outbound["protocol"] as? String, "vless")
        XCTAssertEqual(outbound["tag"] as? String, "reality_vision")

        let settings = try XCTUnwrap(outbound["settings"] as? [String: Any])
        let vnext = try XCTUnwrap(settings["vnext"] as? [[String: Any]])
        let server = try XCTUnwrap(vnext.first)
        XCTAssertEqual(server["address"] as? String, "198.51.100.10")
        XCTAssertEqual(server["port"] as? Int, 443)
        let users = try XCTUnwrap(server["users"] as? [[String: Any]])
        let user = try XCTUnwrap(users.first)
        XCTAssertEqual(user["id"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(user["encryption"] as? String, "none")
        XCTAssertEqual(user["flow"] as? String, "xtls-rprx-vision")

        let stream = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "tcp")
        XCTAssertEqual(stream["security"] as? String, "reality")
        XCTAssertNil(stream["wsSettings"])
        XCTAssertNil(stream["allowInsecure"])
        let reality = try XCTUnwrap(stream["realitySettings"] as? [String: Any])
        XCTAssertEqual(reality["serverName"] as? String, "www.example.com")
        XCTAssertEqual(reality["publicKey"] as? String, "abcdefghijklmnopqrstuvwxyzABCDEFG")
        XCTAssertEqual(reality["shortId"] as? String, "abcd1234")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
        XCTAssertNil(reality["allowInsecure"])

        let text = try config.jsonUTF8String()
        XCTAssertFalse(text.contains("allowInsecure"))
        XCTAssertFalse(text.contains("ws_tls_compat"))
        XCTAssertFalse(text.contains("wsSettings"))
        XCTAssertTrue(text.contains("xtls-rprx-vision"))
    }

    func testRejectsWsTlsCompatProfileString() throws {
        let parameters = try makeParameters()
        XCTAssertThrowsError(
            try AccessRealityVisionOutboundConfigBuilder.build(
                profileRawValue: "ws_tls_compat",
                parameters: parameters
            )
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .wsTlsCompatNotAdmitted)
        }
    }

    func testRejectsMalformedParameters() throws {
        XCTAssertThrowsError(try makeParameters(address: "")) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .emptyField("address")
            )
        }
        XCTAssertThrowsError(try makeParameters(port: 0)) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .invalidPort(0)
            )
        }
        XCTAssertThrowsError(try makeParameters(userID: "not-a-uuid")) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .invalidUserID
            )
        }
        XCTAssertThrowsError(try makeParameters(shortID: "zzzz")) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .fieldNotCanonical("shortID")
            )
        }
    }

    func testAssertFailClosedCatchesAllowInsecureAndWs() throws {
        XCTAssertThrowsError(
            try AccessRealityVisionOutboundConfigBuilder.assertFailClosed([
                "allowInsecure": true,
            ])
        ) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .allowInsecureRejected
            )
        }
        XCTAssertThrowsError(
            try AccessRealityVisionOutboundConfigBuilder.assertFailClosed([
                "streamSettings": ["wsSettings": ["path": "/"]],
            ])
        ) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .unsupportedNetwork("ws")
            )
        }
    }
}

private final class LogInitializationFailingCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    let message: String
    var configs: [Data] = []
    private var running = false
    init(message: String) { self.message = message }
    var isRunning: Bool { running }
    func start(configData: Data) async throws {
        configs.append(configData)
        if configs.count == 1 { throw NSError(domain: "SyntheticLogInit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        running = true
    }
    func stop() async { running = false }
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream { throw AccessEmbeddedCoreError.unverifiedAsset }
}

private final class PersistenceRecordingCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    private var running = false
    var configs: [Data] = []
    var isRunning: Bool { running }
    func start(configData: Data) async throws { configs.append(configData); running = true }
    func stop() async { running = false }
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream { throw AccessEmbeddedCoreError.unverifiedAsset }
}
