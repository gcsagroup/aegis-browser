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
        await manager.retryStorage()
        try await waitUntil { manager.isReady }
        let urls = [URL(string: "http://127.0.0.1:8768/missing")!, URL(string: "http://127.0.0.1:8768/download.bin")!]
        let id = try manager.start(DownloadPlan(urls: urls, filename: "mirror-result.bin", size: 44032))
        try await waitUntil { manager.items.first?.state == .completed }
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.id, id); XCTAssertEqual(item.mirrorIndex, 1)
        XCTAssertEqual(item.filename, "mirror-result.bin")
        XCTAssertEqual(item.sha512, try DownloadManager.hashFile(manager.fileURL(item), sha512: true))
        let recovered = DownloadManager(directory: folder, background: false)
        await recovered.retryStorage()
        try await waitUntil { recovered.isReady }
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
        await manager.retryStorage()
        try await waitUntil { manager.isReady }
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
        await restarted.retryStorage()
        try await waitUntil { restarted.isReady }
        try restarted.resume(slow)
        try await waitUntil { restarted.items.first { $0.id == slow }?.state == .completed }
        XCTAssertGreaterThan(restarted.items.first?.received ?? 0, 1_000_000)
    }


    func testUnreadableManifestDoesNotEnumerateCancelOrOverwriteAndCanRecover() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: .running)
        let manifest = folder.appendingPathComponent("downloads.json")
        let original = try JSONEncoder().encode([item])
        try original.write(to: manifest)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: item.url)
        task.taskDescription = item.id.uuidString
        var locked = true
        var writes = 0
        var enumerations = 0
        var storage = DownloadManifestStorage()
        storage.read = { url in
            if locked { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        storage.write = { items, url in
            writes += 1
            try JSONEncoder().encode(items).write(to: url)
        }
        let manager = DownloadManager(directory: folder, background: false, storage: storage,
                                      enumerateTasks: { _ in enumerations += 1; return [task] }, automaticallyRecover: false)
        await manager.retryStorage()
        XCTAssertFalse(manager.isReady)
        XCTAssertNotNil(manager.storageError)
        XCTAssertEqual(enumerations, 0)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(task.state, .suspended)
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertThrowsError(try manager.start(item.url.absoluteString))
        locked = false
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.items, [item])
        XCTAssertEqual(enumerations, 1)
        XCTAssertEqual(task.state, .suspended)
    }

    func testCorruptAndOversizedManifestArePreserved() async throws {
        for bytes in [Data("broken".utf8), Data(repeating: 32, count: 2_000_000)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("downloads.json")
            try bytes.write(to: url)
            let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                          enumerateTasks: { _ in XCTFail("invalid manifest must not reconcile"); return [] }, automaticallyRecover: false)
            await manager.retryStorage()
            XCTAssertFalse(manager.isReady)
            XCTAssertNotNil(manager.storageError)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testResumeWriteFailurePreservesAllRetryableStatesAndResumeBytes() async throws {
        for state in [BrowserDownload.State.paused, .failed, .cancelled] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: state)
            item.message = "preserve reason"
            item.mirrors = [item.url, URL(string: "http://127.0.0.1:1/mirror")!]
            item.mirrorIndex = 1
            let manifest = folder.appendingPathComponent("downloads.json")
            try JSONEncoder().encode([item]).write(to: manifest)
            let resume = folder.appendingPathComponent("\(item.id).resume")
            let bytes = Data("preserved resume bytes".utf8)
            try bytes.write(to: resume)
            var fail = false
            var runningWrites = 0
            var storage = DownloadManifestStorage()
            storage.write = { records, url in
                if records.contains(where: { $0.state == .running }) {
                    if fail { throw CocoaError(.fileWriteOutOfSpace) }
                    runningWrites += 1
                }
                try JSONEncoder().encode(records).write(to: url)
            }
            let manager = DownloadManager(directory: folder, background: false, storage: storage,
                                          enumerateTasks: { _ in [] }, automaticallyRecover: false)
            await manager.retryStorage()
            fail = true
            XCTAssertThrowsError(try manager.resume(item.id))
            XCTAssertEqual(manager.items, [item])
            XCTAssertEqual(try Data(contentsOf: resume), bytes)
            XCTAssertEqual(runningWrites, 0)
            fail = false
            await manager.retryStorage()
            XCTAssertTrue(manager.isReady)
            // Resume data is deliberately invalid; remove only after checking
            // the failed transaction preserved it, so this phase uses HTTP.
            try FileManager.default.removeItem(at: resume)
            try manager.resume(item.id)
            let transfer = manager.items[0].transferID
            try manager.resume(item.id)
            XCTAssertEqual(manager.items[0].transferID, transfer)
            XCTAssertEqual(runningWrites, 1)
            manager.cancel(item.id)
        }
    }

    func testCompletedFileCommitFailureSurvivesFreshManagerWithoutMirrorRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pending = folder.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: .running,
                                   mirrors: [URL(string: "http://127.0.0.1:1/file")!, URL(string: "http://127.0.0.1:1/mirror")!], mirrorIndex: 0)
        let manifest = folder.appendingPathComponent("downloads.json")
        try JSONEncoder().encode([item]).write(to: manifest)
        let file = folder.appendingPathComponent(item.id.uuidString).appendingPathComponent(item.filename)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("already verified payload".utf8)
        try bytes.write(to: file)
        var completed = item
        completed.state = .completed
        completed.received = Int64(bytes.count)
        completed.sha256 = try DownloadManager.hashFile(file)
        let receiptURL = pending.appendingPathComponent("completion.json")
        let receipt = PendingDownloadReceipt(taskDescription: item.id.uuidString, completed: completed)
        try JSONEncoder().encode(receipt).write(to: receiptURL)
        var storage = DownloadManifestStorage()
        storage.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let failed = DownloadManager(directory: folder, background: false, storage: storage,
                                     enumerateTasks: { _ in [] }, automaticallyRecover: false)
        await failed.retryStorage()
        XCTAssertNotNil(failed.storageError)
        XCTAssertFalse(failed.isReady)
        XCTAssertEqual(failed.items.first?.state, .running)
        XCTAssertEqual(failed.items.first?.mirrorIndex, 0)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        let recovered = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                        enumerateTasks: { _ in [] }, automaticallyRecover: false)
        await recovered.retryStorage()
        XCTAssertTrue(recovered.isReady)
        XCTAssertEqual(recovered.items, [completed])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        await recovered.retryStorage()
        XCTAssertEqual(recovered.items, [completed])
    }

    func testReadinessBlocksTransfersDuringEnumeration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: .paused)
        try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
        var release: CheckedContinuation<[URLSessionTask], Never>?
        let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                      enumerateTasks: { _ in await withCheckedContinuation { release = $0 } }, automaticallyRecover: false)
        let recovery = Task { await manager.retryStorage() }
        while release == nil { await Task.yield() }
        XCTAssertFalse(manager.isReady)
        XCTAssertThrowsError(try manager.start(item.url.absoluteString))
        XCTAssertThrowsError(try manager.resume(item.id))
        XCTAssertEqual(manager.items, [item])
        release?.resume(returning: [])
        await recovery.value
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.items, [item])
    }

    func testPausedCompletionAndLateErrorReplayOnceWithoutMirrorAdvance() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pending = folder.appendingPathComponent("Pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: .paused,
                                   mirrors: [URL(string: "http://127.0.0.1:1/file")!, URL(string: "http://127.0.0.1:1/mirror")!], mirrorIndex: 0,
                                   transferID: UUID())
        try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
        let name = item.id.uuidString + "|" + item.transferID!.uuidString
        let payload = Data("completion delivered before pause acknowledged".utf8)
        try payload.write(to: pending.appendingPathComponent("success.bin"))
        try JSONEncoder().encode(PendingDownloadReceipt(taskDescription: name, status: 200, finalURL: item.url))
            .write(to: pending.appendingPathComponent("success.json"))
        try JSONEncoder().encode(PendingDownloadReceipt(taskDescription: name, error: "late cancellation"))
            .write(to: pending.appendingPathComponent("error.json"))
        let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                      enumerateTasks: { _ in [] }, automaticallyRecover: false)
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        let completed = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.mirrorIndex, 0)
        XCTAssertEqual(try Data(contentsOf: manager.fileURL(completed)), payload)
        await manager.retryStorage()
        XCTAssertEqual(manager.items, [completed])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty)
    }

    func testPreparedCompletionReplaysBothSidesOfPayloadMove() async throws {
        for moved in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let pending = folder.appendingPathComponent("Pending")
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: .running, transferID: UUID())
            try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
            let receipt = pending.appendingPathComponent("prepared.json")
            let bytes = Data("payload moved before receipt phase update".utf8)
            if moved { try bytes.write(to: pending.appendingPathComponent("prepared.bin")) }
            try JSONEncoder().encode(PendingDownloadReceipt(taskDescription: item.id.uuidString + "|" + item.transferID!.uuidString,
                                                            status: 200, finalURL: item.url, payloadStaged: false)).write(to: receipt)
            let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                          enumerateTasks: { _ in [] }, automaticallyRecover: false)
            await manager.retryStorage()
            XCTAssertTrue(manager.isReady)
            XCTAssertEqual(manager.items[0].state, moved ? .completed : .paused)
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
            if moved { XCTAssertEqual(try Data(contentsOf: manager.fileURL(manager.items[0])), bytes) }
        }
    }

    func testIdentityNamedOrphanPreservesBytesWithoutBlockingDownloads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pending = folder.appendingPathComponent("Pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: .running, transferID: UUID())
        try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
        let name = item.id.uuidString + "|" + item.transferID!.uuidString + "--" + UUID().uuidString + ".bin"
        let bytes = Data("preserve unverified completion bytes".utf8)
        try bytes.write(to: pending.appendingPathComponent(name))
        let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                      enumerateTasks: { _ in [] }, automaticallyRecover: false)
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.items[0].state, .paused)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Unresolved").appendingPathComponent(name)), bytes)
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        // The same record remains actionable; no anonymous-file permanent barrier.
        try manager.resume(item.id)
        XCTAssertEqual(manager.items[0].state, .running)
        manager.cancel(item.id)
    }

    func testLateFailureDistinguishesEnumerationInterruptionFromUserPauseAndSurvivesWriteFailure() async throws {
        for userPaused in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: userPaused ? .paused : .running)
            try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
            let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                          enumerateTasks: { _ in [] }, automaticallyRecover: false)
            await manager.retryStorage()
            XCTAssertEqual(manager.items[0].state, .paused)
            XCTAssertEqual(manager.items[0].inferredInterruption == true, !userPaused)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.downloadTask(with: item.url)
            task.taskDescription = item.id.uuidString
            let pending = folder.appendingPathComponent("Pending")
            try FileManager.default.removeItem(at: pending)
            try Data("block receipt directory".utf8).write(to: pending)
            // Deliver the actual delegate method; no network, mock result or sleep.
            manager.urlSession(session, task: task, didCompleteWithError: URLError(.timedOut))
            XCTAssertFalse(manager.isReady)
            try FileManager.default.removeItem(at: pending)
            await manager.retryStorage()
            XCTAssertTrue(manager.isReady)
            XCTAssertEqual(manager.items[0].state, userPaused ? .paused : .failed)
            if !userPaused { XCTAssertEqual(manager.items[0].message, URLError(.timedOut).localizedDescription) }
        }
    }

    func testValidationFailureCannotRestartMirrorsAfterUserPause() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pending = folder.appendingPathComponent("Pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let url = URL(string: "http://127.0.0.1:1/file")!
        let item = BrowserDownload(id: UUID(), url: url, filename: "file", state: .paused,
                                   mirrors: [url, URL(string: "http://127.0.0.1:1/mirror")!], mirrorIndex: 0)
        try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
        try Data("failed response".utf8).write(to: pending.appendingPathComponent("failed.bin"))
        try JSONEncoder().encode(PendingDownloadReceipt(taskDescription: item.id.uuidString, status: 500, finalURL: url, payloadStaged: true))
            .write(to: pending.appendingPathComponent("failed.json"))
        let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                      enumerateTasks: { _ in [] }, automaticallyRecover: false)
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.items[0].state, .failed)
        XCTAssertEqual(manager.items[0].mirrorIndex, 0)
        XCTAssertEqual(manager.items[0].transferID, nil)
    }

    func testUserStopReceiptSurvivesFailedManifestWriteAndRestartWithoutMirrorRetry() async throws {
        for stop in [BrowserDownload.State.paused, .cancelled] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let restartedFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.removeItem(at: restartedFolder)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = URL(string: "http://127.0.0.1:1/file")!
            let item = BrowserDownload(id: UUID(), url: url, filename: "file", state: .running,
                                       mirrors: [url, URL(string: "http://127.0.0.1:1/mirror")!], mirrorIndex: 0, transferID: UUID())
            let original = try JSONEncoder().encode([item])
            let manifest = folder.appendingPathComponent("downloads.json")
            try original.write(to: manifest)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.downloadTask(with: url)
            task.taskDescription = item.id.uuidString + "|" + item.transferID!.uuidString
            var fail = false
            let scheduled = OfflineSchedule()
            var storage = DownloadManifestStorage()
            storage.write = { records, url in
                if fail { throw CocoaError(.fileWriteOutOfSpace) }
                try JSONEncoder().encode(records).write(to: url)
            }
            let manager = DownloadManager(directory: folder, background: false, storage: storage,
                                          enumerateTasks: { _ in [task] }, automaticallyRecover: false,
                                          recoveryScheduler: { scheduled.work.append($0) },
                                          cancelForResume: { task, callback in task.cancel(); scheduled.pause = callback },
                                          startTransfer: { _ in scheduled.starts += 1 })
            await manager.retryStorage()
            fail = true
            if stop == .paused { manager.pause(item.id) } else { manager.cancel(item.id) }
            XCTAssertFalse(manager.isReady)
            manager.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            // Exercise the actual queued recovery and a second manifest failure
            // before freezing crash inputs. Cancellation metadata must survive.
            try await scheduled.drain()
            let pending = folder.appendingPathComponent("Pending")
            let receipts = try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
            let receiptURL = try XCTUnwrap(receipts.first { $0.pathExtension == "json" })
            let receiptBytes = try Data(contentsOf: receiptURL)
            XCTAssertEqual(try JSONDecoder().decode(PendingDownloadReceipt.self, from: receiptBytes).userStopState, stop)
            XCTAssertEqual(try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: manifest))[0].state, .running)
            // Freeze the real disk only after that failed recovery has run.
            let restartedPending = restartedFolder.appendingPathComponent("Pending")
            try FileManager.default.createDirectory(at: restartedPending, withIntermediateDirectories: true)
            try original.write(to: restartedFolder.appendingPathComponent("downloads.json"))
            for receipt in receipts {
                try FileManager.default.copyItem(at: receipt, to: restartedPending.appendingPathComponent(receipt.lastPathComponent))
            }
            let restarted = DownloadManager(directory: restartedFolder, background: false, storage: DownloadManifestStorage(),
                                            enumerateTasks: { _ in [] }, automaticallyRecover: false)
            await restarted.retryStorage()
            XCTAssertTrue(restarted.isReady)
            XCTAssertEqual(restarted.items[0].state, stop)
            XCTAssertEqual(restarted.items[0].mirrorIndex, 0)
            XCTAssertEqual(restarted.items[0].transferID, item.transferID)
            XCTAssertNil(restarted.items[0].inferredInterruption)
            XCTAssertEqual(restarted.items[0].userStopState, stop)
            XCTAssertEqual(restarted.items[0].resumeDataUsable, false)
            XCTAssertEqual(scheduled.starts, 0)
        }
    }

    func testReceiptWriteFailureDuringEnumerationRequiresAnotherPassBeforeReady() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:1/file")!, filename: "file", state: .running)
        try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
        var releases: [CheckedContinuation<[URLSessionTask], Never>] = []
        let manager = DownloadManager(directory: folder, background: false, storage: DownloadManifestStorage(),
                                      enumerateTasks: { _ in await withCheckedContinuation { releases.append($0) } }, automaticallyRecover: false)
        let recovery = Task { await manager.retryStorage() }
        try await yieldUntil { !releases.isEmpty }
        let pending = folder.appendingPathComponent("Pending")
        try FileManager.default.removeItem(at: pending)
        try Data("block receipt directory".utf8).write(to: pending)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: item.url)
        task.taskDescription = item.id.uuidString
        manager.urlSession(session, task: task, didCompleteWithError: URLError(.timedOut))
        try FileManager.default.removeItem(at: pending)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        releases[0].resume(returning: [])
        await recovery.value
        try await yieldUntil { releases.count >= 2 }
        XCTAssertFalse(manager.isReady)
        XCTAssertNotNil(manager.storageError)
        releases[1].resume(returning: [])
        try await waitUntil { manager.isReady }
        XCTAssertEqual(manager.items[0].state, .failed)
        XCTAssertEqual(manager.items[0].message, URLError(.timedOut).localizedDescription)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty)
    }

    func testAllCompletionAndStopOrdersPreventMirrorAdvanceAfterRestart() async throws {
        for stop in [BrowserDownload.State.paused, .cancelled] {
            for badHash in [false, true] {
                for completionFirst in [false, true] {
                    for stopFilename in ["a-stop.json", "z-stop.json"] {
                        let fixture = try OfflineFixture(badHash: badHash)
                        defer { fixture.cleanup() }
                        let schedule = OfflineSchedule()
                        var fail = false
                        var storage = DownloadManifestStorage()
                        storage.write = { records, url in
                            if fail { throw CocoaError(.fileWriteOutOfSpace) }
                            try JSONEncoder().encode(records).write(to: url)
                        }
                        let manager = offlineManager(fixture, schedule, storage: storage, status: badHash ? 200 : 500)
                        await manager.retryStorage()
                        fail = true
                        let payload = try fixture.payload()
                        if completionFirst { manager.urlSession(fixture.session, downloadTask: fixture.task, didFinishDownloadingTo: payload) }
                        if stop == .paused { manager.pause(fixture.item.id) } else { manager.cancel(fixture.item.id) }
                        if !completionFirst {
                            manager.urlSession(fixture.session, downloadTask: fixture.task, didFinishDownloadingTo: payload)
                            let receipts = try FileManager.default.contentsOfDirectory(at: fixture.pending, includingPropertiesForKeys: nil)
                            let raw = try XCTUnwrap(receipts.first { $0.lastPathComponent != fixture.name + "--stop.json" && $0.pathExtension == "json" })
                            XCTAssertEqual(try JSONDecoder().decode(PendingDownloadReceipt.self, from: Data(contentsOf: raw)).userStopState, stop)
                        }
                        try FileManager.default.moveItem(at: fixture.pending.appendingPathComponent(fixture.name + "--stop.json"),
                                                         to: fixture.pending.appendingPathComponent(stopFilename))
                        try await schedule.drain() // Real automatic recovery; manifest still cannot commit.
                        XCTAssertFalse(manager.isReady)
                        XCTAssertEqual(schedule.starts, 0)
                        let restartFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: restartFolder) }
                        try FileManager.default.copyItem(at: fixture.folder, to: restartFolder)
                        let restartedSchedule = OfflineSchedule()
                        let restarted = DownloadManager(directory: restartFolder, background: false, storage: DownloadManifestStorage(),
                                                        enumerateTasks: { _ in [] }, automaticallyRecover: false,
                                                        recoveryScheduler: { restartedSchedule.work.append($0) },
                                                        startTransfer: { _ in restartedSchedule.starts += 1 })
                        await restarted.retryStorage()
                        XCTAssertTrue(restarted.isReady)
                        XCTAssertEqual(restarted.items[0].state, stop == .cancelled ? .cancelled : .failed)
                        XCTAssertEqual(restarted.items[0].userStopState, stop)
                        XCTAssertEqual(restarted.items[0].mirrorIndex, 0)
                        XCTAssertEqual(restarted.items[0].transferID, fixture.item.transferID)
                        XCTAssertEqual(restartedSchedule.starts, 0)
                    }
                }
            }
        }
    }

    func testPauseWaitsForResumeCallbackAndNilInvalidatesOldBytes() async throws {
        for data in [Data("new resume callback bytes".utf8), nil] as [Data?] {
            let fixture = try OfflineFixture()
            defer { fixture.cleanup() }
            let schedule = OfflineSchedule()
            let manager = offlineManager(fixture, schedule)
            await manager.retryStorage()
            let resume = fixture.folder.appendingPathComponent("\(fixture.item.id).resume")
            try Data("stale resume bytes".utf8).write(to: resume)
            manager.pause(fixture.item.id)
            manager.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
            try await schedule.drain()
            XCTAssertEqual(manager.items[0].state, .pausing)
            XCTAssertEqual(manager.items[0].resumeDataUsable, false)
            try manager.resume(fixture.item.id) // Must be a no-op until the callback is disposed.
            XCTAssertEqual(manager.items[0].transferID, fixture.item.transferID)
            let callback = try XCTUnwrap(schedule.pause)
            callback(data)
            try await yieldUntil { !schedule.work.isEmpty }
            try await schedule.drain()
            XCTAssertEqual(manager.items[0].state, .paused)
            XCTAssertEqual(manager.items[0].resumeDataUsable, data != nil)
            XCTAssertEqual(schedule.starts, 0)
            if let data { XCTAssertEqual(try Data(contentsOf: resume), data) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path)) }
            let stored = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: fixture.folder.appendingPathComponent("downloads.json")))
            XCTAssertEqual(stored, manager.items)
        }
    }

    func testReturnedResumeBytesSurviveStagingFailureUntilExplicitRetry() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.cleanup() }
        let schedule = OfflineSchedule()
        let manager = offlineManager(fixture, schedule)
        await manager.retryStorage()
        manager.pause(fixture.item.id)
        manager.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
        try await schedule.drain()
        try FileManager.default.removeItem(at: fixture.pending)
        try Data("block staging".utf8).write(to: fixture.pending)
        let data = Data("returned data retained through a write failure".utf8)
        let callback = try XCTUnwrap(schedule.pause)
        callback(data)
        try await yieldUntil { manager.storageError != nil }
        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(manager.items[0].state, .pausing)
        XCTAssertEqual(manager.items[0].resumeDataUsable, false)
        XCTAssertTrue(schedule.work.isEmpty)
        try FileManager.default.removeItem(at: fixture.pending)
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.items[0].state, .paused)
        XCTAssertEqual(manager.items[0].resumeDataUsable, true)
        XCTAssertEqual(try Data(contentsOf: fixture.folder.appendingPathComponent("\(fixture.item.id).resume")), data)
        XCTAssertEqual(schedule.starts, 0)
    }

    func testStopDuringEitherHashBoundaryIsReMergedBeforeCompletionCommit() async throws {
        for finalBoundary in [false, true] {
            for stop in [BrowserDownload.State.paused, .cancelled] {
                let fixture = try OfflineFixture()
                defer { fixture.cleanup() }
                let schedule = OfflineSchedule()
                var payloadRelease: CheckedContinuation<(String, String), Never>?
                var finalRelease: CheckedContinuation<String, Never>?
                var payloadHeld = false
                var finalHeld = false
                var savedHashes: (String, String)?
                var savedFinal: String?
                let manager = offlineManager(fixture, schedule,
                    payloadHashes: { url in
                        let hashes = (try DownloadManager.hashFile(url), try DownloadManager.hashFile(url, sha512: true))
                        if !finalBoundary && !payloadHeld {
                            payloadHeld = true; savedHashes = hashes
                            return await withCheckedContinuation { payloadRelease = $0 }
                        }
                        return hashes
                    }, finalHash: { url in
                        let hash = try DownloadManager.hashFile(url)
                        if finalBoundary && !finalHeld {
                            finalHeld = true; savedFinal = hash
                            return await withCheckedContinuation { finalRelease = $0 }
                        }
                        return hash
                    })
                await manager.retryStorage()
                manager.urlSession(fixture.session, downloadTask: fixture.task, didFinishDownloadingTo: try fixture.payload())
                let work = try XCTUnwrap(schedule.work.first)
                schedule.work.removeFirst()
                let recovery = Task { await work() }
                try await yieldUntil { finalBoundary ? finalRelease != nil : payloadRelease != nil }
                if stop == .paused { manager.pause(fixture.item.id) } else { manager.cancel(fixture.item.id) }
                if finalBoundary { finalRelease?.resume(returning: try XCTUnwrap(savedFinal)) }
                else { payloadRelease?.resume(returning: try XCTUnwrap(savedHashes)) }
                await recovery.value
                try await schedule.drain()
                XCTAssertTrue(manager.isReady)
                XCTAssertEqual(manager.items[0].state, stop == .paused ? .completed : .cancelled)
                XCTAssertEqual(manager.items[0].mirrorIndex, 0)
                XCTAssertEqual(manager.items[0].transferID, fixture.item.transferID)
                XCTAssertEqual(schedule.starts, 0)
                XCTAssertEqual(FileManager.default.fileExists(atPath: manager.fileURL(manager.items[0]).path), stop == .paused)
                schedule.pause?(Data("late resume data must not overwrite a terminal result".utf8))
                await Task.yield()
                XCTAssertTrue(schedule.work.isEmpty)
            }
        }
    }

    func testActualCompletionIngressSurvivesFinalManifestFailure() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.cleanup() }
        let schedule = OfflineSchedule()
        var storage = DownloadManifestStorage()
        storage.write = { records, url in
            if records.contains(where: { $0.state == .completed }) { throw CocoaError(.fileWriteOutOfSpace) }
            try JSONEncoder().encode(records).write(to: url)
        }
        let manager = offlineManager(fixture, schedule, storage: storage)
        await manager.retryStorage()
        manager.urlSession(fixture.session, downloadTask: fixture.task, didFinishDownloadingTo: try fixture.payload())
        try await schedule.drain()
        XCTAssertFalse(manager.isReady)
        XCTAssertNotNil(manager.storageError)
        XCTAssertEqual(manager.items[0].state, .running)
        XCTAssertEqual(schedule.starts, 0)
        let jsons = try FileManager.default.contentsOfDirectory(at: fixture.pending, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let receipt = try JSONDecoder().decode(PendingDownloadReceipt.self, from: Data(contentsOf: try XCTUnwrap(jsons.first)))
        let completed = try XCTUnwrap(receipt.completed)
        XCTAssertEqual(try DownloadManager.hashFile(manager.fileURL(completed)), completed.sha256)
        let restarted = DownloadManager(directory: fixture.folder, background: false, storage: DownloadManifestStorage(),
                                        enumerateTasks: { _ in [] }, automaticallyRecover: false,
                                        startTransfer: { _ in XCTFail("completion recovery must not restart transport") })
        await restarted.retryStorage()
        XCTAssertTrue(restarted.isReady)
        XCTAssertEqual(restarted.items[0].state, .completed)
        XCTAssertEqual(restarted.items[0].sha256, completed.sha256)
        XCTAssertEqual(restarted.items[0].mirrorIndex, 0)
    }

    func testBackgroundACKUsesDurableEventsWithoutWaitingForManifestUnlock() async throws {
        let previousOwner = DownloadManager.backgroundManager
        let previousHandler = DownloadManager.backgroundCompletion
        defer {
            DownloadManager.backgroundManager = previousOwner
            DownloadManager.backgroundCompletion = previousHandler
        }
        for registerFirst in [false, true] {
            for writeBlocked in [false, true] {
                let fixture = try OfflineFixture()
                defer { fixture.cleanup() }
                let schedule = OfflineSchedule()
                var storage = DownloadManifestStorage()
                storage.read = { _ in throw CocoaError(.fileReadNoPermission) }
                var enumerations = 0
                let manager = DownloadManager(directory: fixture.folder, background: false, storage: storage,
                                              enumerateTasks: { _ in enumerations += 1; return [fixture.task] }, automaticallyRecover: false,
                                              registersBackgroundEvents: true, recoveryScheduler: { schedule.work.append($0) })
                await manager.retryStorage()
                XCTAssertFalse(manager.isReady)
                var acknowledgements = 0
                if registerFirst { DownloadManager.backgroundCompletion = { acknowledgements += 1 } }
                if writeBlocked {
                    try FileManager.default.removeItem(at: fixture.pending)
                    try Data("unavailable event storage".utf8).write(to: fixture.pending)
                }
                manager.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.timedOut))
                manager.urlSessionDidFinishEvents(forBackgroundURLSession: fixture.session)
                if !registerFirst { DownloadManager.backgroundCompletion = { acknowledgements += 1 } }
                XCTAssertEqual(acknowledgements, writeBlocked ? 0 : 1)
                if writeBlocked {
                    try FileManager.default.removeItem(at: fixture.pending)
                    await manager.retryStorage() // Manifest is still locked; event staging can now succeed.
                }
                try await schedule.drain()
                XCTAssertEqual(acknowledgements, 1)
                XCTAssertFalse(manager.isReady)
                XCTAssertEqual(enumerations, 0)
                XCTAssertEqual(fixture.task.state, .suspended)
                manager.urlSessionDidFinishEvents(forBackgroundURLSession: fixture.session)
                XCTAssertEqual(acknowledgements, 1)
            }
        }
    }

    func testPersistentStorageFailureQuiescesAndStaleGenerationCallbacksAreIgnored() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.cleanup() }
        let schedule = OfflineSchedule()
        var fail = false
        var failures = 0
        var storage = DownloadManifestStorage()
        storage.write = { records, url in
            if fail { failures += 1; throw CocoaError(.fileWriteOutOfSpace) }
            try JSONEncoder().encode(records).write(to: url)
        }
        let manager = offlineManager(fixture, schedule, storage: storage)
        await manager.retryStorage()
        fail = true
        manager.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.timedOut))
        try await schedule.drain()
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(schedule.starts, 0)
        XCTAssertTrue(schedule.work.isEmpty)
        fail = false
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.items[0].mirrorIndex, 1)
        XCTAssertEqual(schedule.starts, 1)
        let current = manager.items
        manager.urlSession(fixture.session, downloadTask: fixture.task, didWriteData: 50, totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
        manager.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
        manager.urlSession(fixture.session, downloadTask: fixture.task, didFinishDownloadingTo: try fixture.payload())
        XCTAssertEqual(manager.items, current)
        XCTAssertTrue(schedule.work.isEmpty)
        XCTAssertEqual(schedule.starts, 1)
        manager.cancel(fixture.item.id)
        try await schedule.drain()
    }

    func testResumeCleanupFailurePreservesDependenciesAndReplaysAfterRestart() async throws {
        for legacyCleanupGap in [false, true] {
            let fixture = try OfflineFixture()
            defer { fixture.cleanup() }
            let schedule = OfflineSchedule()
            let bytes = Data("returned resume data".utf8)
            var blockedReceipt: URL?
            var cleanupAttempts = 0
            let manager = offlineManager(fixture, schedule, removeReceiptMetadata: { url in
                if url.lastPathComponent.contains("--resume-") {
                    cleanupAttempts += 1
                    blockedReceipt = url
                    XCTAssertEqual(try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("resume")), bytes)
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            })
            await manager.retryStorage()
            manager.pause(fixture.item.id)
            try XCTUnwrap(schedule.pause)(bytes)
            try await yieldUntil { !schedule.work.isEmpty }
            try await schedule.drain()
            XCTAssertFalse(manager.isReady)
            XCTAssertNotNil(manager.storageError)
            XCTAssertEqual(cleanupAttempts, 1)
            XCTAssertEqual(manager.items[0].state, .paused)
            XCTAssertEqual(manager.items[0].resumeDataUsable, true)
            let official = fixture.folder.appendingPathComponent("\(fixture.item.id).resume")
            XCTAssertEqual(try Data(contentsOf: official), bytes)
            let json = try XCTUnwrap(blockedReceipt)
            let staged = json.deletingPathExtension().appendingPathExtension("resume")
            XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
            XCTAssertEqual(try Data(contentsOf: staged), bytes)
            // Also replay a disk left by the former data-before-JSON cleanup.
            if legacyCleanupGap { try FileManager.default.removeItem(at: staged) }
            let restarted = DownloadManager(directory: fixture.folder, background: false, storage: DownloadManifestStorage(),
                                            enumerateTasks: { _ in [] }, automaticallyRecover: false,
                                            startTransfer: { _ in XCTFail("receipt cleanup must never start transport") })
            await restarted.retryStorage()
            XCTAssertTrue(restarted.isReady)
            XCTAssertNil(restarted.storageError)
            XCTAssertEqual(restarted.items[0].transferID, fixture.item.transferID)
            XCTAssertEqual(restarted.items[0].state, .paused)
            XCTAssertEqual(restarted.items[0].resumeDataUsable, true)
            XCTAssertEqual(try Data(contentsOf: official), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
            XCTAssertEqual(schedule.starts, 0)
        }
    }

    func testStaleResumeReceiptPreservesCurrentGenerationData() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.cleanup() }
        var current = fixture.item
        current.transferID = UUID()
        current.state = .paused
        current.userStopState = .paused
        current.resumeDataUsable = true
        try JSONEncoder().encode([current]).write(to: fixture.folder.appendingPathComponent("downloads.json"))
        try FileManager.default.createDirectory(at: fixture.pending, withIntermediateDirectories: true)
        let official = fixture.folder.appendingPathComponent("\(current.id).resume")
        let currentBytes = Data("current generation resume data".utf8)
        try currentBytes.write(to: official)
        let old = fixture.pending.appendingPathComponent(fixture.name + "--resume-stale.json")
        try JSONEncoder().encode(PendingDownloadReceipt(taskDescription: fixture.name, userStopState: .paused,
                                                       kind: .resume, resumeDataAvailable: true)).write(to: old)
        let staged = old.deletingPathExtension().appendingPathExtension("resume")
        try Data("stale generation bytes".utf8).write(to: staged)
        let manager = DownloadManager(directory: fixture.folder, background: false, storage: DownloadManifestStorage(),
                                      enumerateTasks: { _ in [] }, automaticallyRecover: false,
                                      startTransfer: { _ in XCTFail("stale receipt must not start transport") })
        await manager.retryStorage()
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.items[0], current)
        XCTAssertEqual(try Data(contentsOf: official), currentBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testStorageFailureKeepsActiveStopActionsAndBlocksNewTransfers() async throws {
        for cancel in [false, true] {
            let fixture = try OfflineFixture()
            defer { fixture.cleanup() }
            let schedule = OfflineSchedule()
            var blocked = false
            var storage = DownloadManifestStorage()
            storage.write = { records, url in
                if blocked { throw CocoaError(.fileWriteOutOfSpace) }
                try JSONEncoder().encode(records).write(to: url)
            }
            let manager = offlineManager(fixture, schedule, storage: storage)
            await manager.retryStorage()
            blocked = true
            await manager.retryStorage()
            XCTAssertFalse(manager.isReady)
            XCTAssertEqual(manager.items[0].state, .running)
            XCTAssertThrowsError(try manager.start(fixture.item.url.absoluteString))
            XCTAssertThrowsError(try manager.resume(fixture.item.id))
            if cancel { manager.cancel(fixture.item.id) } else { manager.pause(fixture.item.id) }
            XCTAssertTrue([URLSessionTask.State.canceling, .completed].contains(fixture.task.state))
            XCTAssertEqual(manager.items[0].state, cancel ? .cancelled : .pausing)
            XCTAssertEqual(manager.items[0].userStopState, cancel ? .cancelled : .paused)
            XCTAssertFalse(manager.isReady)
            blocked = false
            if !cancel {
                try XCTUnwrap(schedule.pause)(nil)
                try await yieldUntil { !schedule.work.isEmpty }
            }
            try await schedule.drain()
            XCTAssertTrue(manager.isReady)
            XCTAssertEqual(manager.items[0].state, cancel ? .cancelled : .paused)
            XCTAssertEqual(schedule.starts, 0)
        }
    }

    func testPendingReceiptFailureStillDiscoversTasksForAcceptedUserStops() async throws {
        for unreadable in [false, true] {
            for stop in [BrowserDownload.State.paused, .cancelled] {
                let fixture = try OfflineFixture()
                defer { fixture.cleanup() }
                try FileManager.default.createDirectory(at: fixture.pending, withIntermediateDirectories: true)
                let bad = fixture.pending.appendingPathComponent("unrelated-bad.json")
                if unreadable { try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false) }
                else { try Data("malformed receipt".utf8).write(to: bad) }
                let orphan = fixture.session.downloadTask(with: fixture.item.url)
                orphan.taskDescription = UUID().uuidString + "|" + UUID().uuidString
                let schedule = OfflineSchedule()
                var discoveries = 0
                var nativePauses = 0
                let manager = DownloadManager(directory: fixture.folder, background: false, storage: DownloadManifestStorage(),
                    enumerateTasks: { _ in discoveries += 1; return [fixture.task, orphan] }, automaticallyRecover: false,
                    recoveryScheduler: { schedule.work.append($0) },
                    cancelForResume: { task, callback in nativePauses += 1; task.cancel(); schedule.pause = callback },
                    startTransfer: { _ in XCTFail("incomplete recovery cannot start a mirror") })
                await manager.retryStorage()
                XCTAssertEqual(discoveries, 1)
                XCTAssertFalse(manager.isReady)
                XCTAssertNotNil(manager.storageError)
                XCTAssertEqual(manager.items[0].state, .running)
                XCTAssertEqual(fixture.task.state, .suspended)
                XCTAssertEqual(orphan.state, .suspended)
                if stop == .paused { manager.pause(fixture.item.id) }
                else { manager.cancel(fixture.item.id) }
                XCTAssertEqual(nativePauses, stop == .paused ? 1 : 0)
                XCTAssertTrue([URLSessionTask.State.canceling, .completed].contains(fixture.task.state))
                XCTAssertEqual(manager.items[0].userStopState, stop)
                let bytes = Data("user pause callback".utf8)
                if stop == .paused {
                    try XCTUnwrap(schedule.pause)(bytes)
                    try await yieldUntil { !schedule.work.isEmpty }
                }
                try await schedule.drain()
                XCTAssertFalse(manager.isReady)
                XCTAssertNotNil(manager.storageError)
                XCTAssertEqual(orphan.state, .suspended, "incomplete controls cannot authorize orphan disposal")
                XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
                let control = fixture.pending.appendingPathComponent(fixture.name + "--stop.json")
                XCTAssertEqual(try JSONDecoder().decode(PendingDownloadReceipt.self, from: Data(contentsOf: control)).userStopState, stop)
                try FileManager.default.removeItem(at: bad)
                await manager.retryStorage()
                XCTAssertTrue(manager.isReady)
                XCTAssertNil(manager.storageError)
                XCTAssertEqual(manager.items[0].state, stop)
                XCTAssertEqual(nativePauses, stop == .paused ? 1 : 0)
                XCTAssertEqual(manager.items[0].mirrorIndex, 0)
                if stop == .paused {
                    XCTAssertEqual(try Data(contentsOf: fixture.folder.appendingPathComponent("\(fixture.item.id).resume")), bytes)
                }
                let saved = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: fixture.folder.appendingPathComponent("downloads.json")))
                XCTAssertEqual(saved, manager.items)
            }
        }
    }

    func testRecoveredStopsExecuteBesideUnreadableReceiptWithoutOrphanCleanup() async throws {
        for unreadable in [false, true] {
            for stop in [BrowserDownload.State.paused, .cancelled] {
                let fixture = try OfflineFixture()
                defer { fixture.cleanup() }
                let crash = try await persistedStopBeforeDiscoveryCrashSnapshot(fixture, stop: stop)
                defer { try? FileManager.default.removeItem(at: crash) }
                let bad = crash.appendingPathComponent("Pending/unrelated-bad.json")
                if unreadable { try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false) }
                else { try Data("malformed receipt".utf8).write(to: bad) }
                let orphan = fixture.session.downloadTask(with: fixture.item.url)
                orphan.taskDescription = UUID().uuidString + "|" + UUID().uuidString
                let schedule = OfflineSchedule()
                var pauses = 0
                let manager = DownloadManager(directory: crash, background: false, storage: DownloadManifestStorage(),
                    enumerateTasks: { _ in [orphan, fixture.task] }, automaticallyRecover: false,
                    recoveryScheduler: { schedule.work.append($0) },
                    cancelForResume: { task, callback in pauses += 1; task.cancel(); schedule.pause = callback },
                    startTransfer: { _ in XCTFail("a recovered stop cannot start a mirror") })
                await manager.retryStorage()
                XCTAssertFalse(manager.isReady)
                XCTAssertNotNil(manager.storageError)
                XCTAssertEqual(manager.items[0].userStopState, stop)
                XCTAssertEqual(pauses, stop == .paused ? 1 : 0)
                XCTAssertTrue([URLSessionTask.State.canceling, .completed].contains(fixture.task.state))
                XCTAssertEqual(orphan.state, .suspended)
                if stop == .paused {
                    try XCTUnwrap(schedule.pause)(nil)
                    try await yieldUntil { !schedule.work.isEmpty }
                    try await schedule.drain()
                }
                let control = crash.appendingPathComponent("Pending").appendingPathComponent(fixture.name + "--stop.json")
                XCTAssertEqual(try JSONDecoder().decode(PendingDownloadReceipt.self, from: Data(contentsOf: control)).userStopState, stop)
                XCTAssertEqual(orphan.state, .suspended)
                XCTAssertFalse(manager.isReady)
                try FileManager.default.removeItem(at: bad)
                await manager.retryStorage()
                await manager.retryStorage()
                XCTAssertTrue(manager.isReady)
                XCTAssertNil(manager.storageError)
                XCTAssertEqual(manager.items[0].state, stop)
                XCTAssertEqual(manager.items[0].resumeDataUsable, false)
                XCTAssertEqual(pauses, stop == .paused ? 1 : 0)
                XCTAssertEqual(manager.items[0].transferID, fixture.item.transferID)
                XCTAssertEqual(manager.items[0].mirrorIndex, 0)
            }
        }
    }

    func testPendingWriteFailureBeforeDiscoveryStillStopsAcceptedOwnedTask() async throws {
        for stop in [BrowserDownload.State.paused, .cancelled] {
            let fixture = try OfflineFixture()
            defer { fixture.cleanup() }
            let schedule = OfflineSchedule()
            var release: CheckedContinuation<[URLSessionTask], Never>?
            var heldOnce = false
            var failManifest = false
            var pauses = 0
            let orphan = fixture.session.downloadTask(with: fixture.item.url)
            orphan.taskDescription = UUID().uuidString + "|" + UUID().uuidString
            var storage = DownloadManifestStorage()
            storage.write = { records, url in
                if failManifest { throw CocoaError(.fileWriteOutOfSpace) }
                try JSONEncoder().encode(records).write(to: url)
            }
            let manager = DownloadManager(directory: fixture.folder, background: false, storage: storage,
                enumerateTasks: { _ in
                    if !heldOnce { heldOnce = true; return await withCheckedContinuation { release = $0 } }
                    return [fixture.task, orphan]
                }, automaticallyRecover: false, recoveryScheduler: { schedule.work.append($0) },
                cancelForResume: { task, callback in pauses += 1; task.cancel(); schedule.pause = callback },
                startTransfer: { _ in XCTFail("no new transfer during storage failure") })
            let initial = Task { await manager.retryStorage() }
            try await yieldUntil { release != nil }
            let blockedWrite = fixture.pending.appendingPathComponent(fixture.name + "--stop.json")
            try FileManager.default.createDirectory(at: blockedWrite, withIntermediateDirectories: false)
            failManifest = true
            if stop == .paused { manager.pause(fixture.item.id) }
            else { manager.cancel(fixture.item.id) }
            release!.resume(returning: []); release = nil
            await initial.value
            XCTAssertEqual(fixture.task.state, .suspended)
            XCTAssertEqual(pauses, 0)
            failManifest = false
            await manager.retryStorage() // First pending-write flush still fails.
            XCTAssertFalse(manager.isReady)
            XCTAssertNotNil(manager.storageError)
            XCTAssertEqual(pauses, stop == .paused ? 1 : 0)
            XCTAssertTrue([URLSessionTask.State.canceling, .completed].contains(fixture.task.state))
            XCTAssertEqual(orphan.state, .suspended)
            if stop == .paused {
                try XCTUnwrap(schedule.pause)(nil)
                try await yieldUntil {
                    (try? FileManager.default.contentsOfDirectory(at: fixture.pending, includingPropertiesForKeys: nil))?
                        .contains { $0.lastPathComponent.hasPrefix(fixture.name + "--resume-") && $0.pathExtension == "json" } == true
                }
                try await schedule.drain()
            }
            try FileManager.default.removeItem(at: blockedWrite)
            await manager.retryStorage()
            try await schedule.drain()
            XCTAssertTrue(manager.isReady)
            XCTAssertNil(manager.storageError)
            XCTAssertEqual(manager.items[0].state, stop)
            XCTAssertEqual(manager.items[0].resumeDataUsable, false)
            XCTAssertEqual(pauses, stop == .paused ? 1 : 0)
            XCTAssertEqual(manager.items[0].mirrorIndex, 0)
        }
    }

    private func persistedStopBeforeDiscoveryCrashSnapshot(_ fixture: OfflineFixture, stop: BrowserDownload.State) async throws -> URL {
        let crash = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let schedule = OfflineSchedule()
        var release: CheckedContinuation<[URLSessionTask], Never>?
        var failManifest = false
        var copied = false
        var storage = DownloadManifestStorage()
        storage.write = { records, url in
            if failManifest {
                if !copied { try FileManager.default.copyItem(at: fixture.folder, to: crash); copied = true }
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try JSONEncoder().encode(records).write(to: url)
        }
        let manager = DownloadManager(directory: fixture.folder, background: false, storage: storage,
            enumerateTasks: { _ in await withCheckedContinuation { release = $0 } }, automaticallyRecover: false,
            recoveryScheduler: { schedule.work.append($0) },
            cancelForResume: { _, _ in XCTFail("native discovery is deliberately held") },
            startTransfer: { _ in XCTFail("no crash-fixture transport") })
        let initial = Task { await manager.retryStorage() }
        try await yieldUntil { release != nil }
        failManifest = true
        if stop == .paused { manager.pause(fixture.item.id) }
        else { manager.cancel(fixture.item.id) }
        release!.resume(returning: []); release = nil
        await initial.value
        XCTAssertTrue(copied)
        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(fixture.task.state, .suspended)
        let saved = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: crash.appendingPathComponent("downloads.json")))
        XCTAssertEqual(saved[0].state, .running)
        XCTAssertNil(saved[0].userStopState)
        let receipt = try JSONDecoder().decode(PendingDownloadReceipt.self,
            from: Data(contentsOf: crash.appendingPathComponent("Pending").appendingPathComponent(fixture.name + "--stop.json")))
        XCTAssertEqual(receipt.taskDescription, fixture.name)
        XCTAssertEqual(receipt.userStopState, stop)
        return crash
    }

    func testPersistedPauseRecoveryCollectsDataOnceAcrossCallbackOrdersAndSnapshots() async throws {
        for returnsData in [false, true] {
            for errorFirst in [false, true] {
                for synchronousCallback in [false, true] {
                    let fixture = try OfflineFixture()
                    defer { fixture.cleanup() }
                    try Data("old resume bytes".utf8).write(to: fixture.folder.appendingPathComponent("\(fixture.item.id).resume"))
                    let crash = try await persistedPauseCrashSnapshot(fixture)
                    defer { try? FileManager.default.removeItem(at: crash) }
                    let schedule = OfflineSchedule()
                    let bytes = returnsData ? Data("recovered callback bytes".utf8) : nil
                    var calls = 0
                    let restored = DownloadManager(directory: crash, background: false, storage: DownloadManifestStorage(),
                        enumerateTasks: { _ in [fixture.task] }, automaticallyRecover: false,
                        recoveryScheduler: { schedule.work.append($0) },
                        cancelForResume: { task, callback in
                            calls += 1
                            XCTAssertTrue(task === fixture.task)
                            // Leave this never-resumed task in later snapshots to
                            // verify logical operation ownership, not state filtering.
                            schedule.pause = callback
                            if synchronousCallback { callback(bytes) }
                        }, startTransfer: { _ in XCTFail("a recovered pause cannot start a mirror") })
                    await restored.retryStorage()
                    XCTAssertEqual(calls, 1)
                    if !synchronousCallback {
                        XCTAssertEqual(restored.items[0].state, .pausing)
                        await restored.retryStorage()
                        XCTAssertEqual(calls, 1)
                    }
                    if errorFirst {
                        restored.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
                        try await schedule.drain()
                        if !synchronousCallback { XCTAssertEqual(restored.items[0].state, .pausing) }
                    }
                    if !synchronousCallback { try XCTUnwrap(schedule.pause)(bytes) }
                    try await yieldUntil {
                        !schedule.work.isEmpty ||
                            (restored.items[0].state == .paused && restored.items[0].resumeDataUsable == returnsData)
                    }
                    try await schedule.drain()
                    if !errorFirst {
                        restored.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
                        try await schedule.drain()
                    }
                    await restored.retryStorage()
                    XCTAssertEqual(calls, 1, "returned/disposed pause transactions survive repeated snapshots")
                    XCTAssertTrue(restored.isReady)
                    XCTAssertNil(restored.storageError)
                    XCTAssertEqual(restored.items[0].state, .paused)
                    XCTAssertEqual(restored.items[0].userStopState, .paused)
                    XCTAssertEqual(restored.items[0].resumeDataUsable, returnsData)
                    XCTAssertEqual(restored.items[0].transferID, fixture.item.transferID)
                    XCTAssertEqual(restored.items[0].mirrorIndex, 0)
                    let saved = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: crash.appendingPathComponent("downloads.json")))
                    XCTAssertEqual(saved, restored.items)
                    let official = crash.appendingPathComponent("\(fixture.item.id).resume")
                    if let bytes { XCTAssertEqual(try Data(contentsOf: official), bytes) }
                    else { XCTAssertFalse(FileManager.default.fileExists(atPath: official.path)) }
                }
            }
        }
    }

    func testRecoveredPauseCandidateCannotOverwriteReentrantCancelAndRejectsOldCallback() async throws {
        for cancelDuringWrite in [false, true] {
            let fixture = try OfflineFixture()
            defer { fixture.cleanup() }
            let crash = try await persistedPauseCrashSnapshot(fixture)
            defer { try? FileManager.default.removeItem(at: crash) }
            let schedule = OfflineSchedule()
            var restored: DownloadManager!
            var cancelledOnce = false
            var calls = 0
            var storage = DownloadManifestStorage()
            storage.write = { records, url in
                if cancelDuringWrite && !cancelledOnce && records[0].state == .pausing {
                    cancelledOnce = true
                    restored.cancel(fixture.item.id)
                }
                try JSONEncoder().encode(records).write(to: url)
            }
            restored = DownloadManager(directory: crash, background: false, storage: storage,
                enumerateTasks: { _ in [fixture.task] + schedule.started }, automaticallyRecover: false,
                recoveryScheduler: { schedule.work.append($0) },
                cancelForResume: { _, callback in
                    calls += 1
                    schedule.pause = callback
                    restored.cancel(fixture.item.id) // Synchronous reentry before API returns.
                    callback(Data("cancelled old bytes".utf8))
                }, startTransfer: { task in schedule.starts += 1; schedule.started.append(task) })
            await restored.retryStorage()
            if !cancelDuringWrite { try await yieldUntil { !schedule.work.isEmpty } }
            try await schedule.drain()
            XCTAssertEqual(calls, cancelDuringWrite ? 0 : 1)
            XCTAssertEqual(restored.items[0].state, .cancelled)
            XCTAssertEqual(restored.items[0].userStopState, .cancelled)
            if cancelDuringWrite { XCTAssertTrue([URLSessionTask.State.canceling, .completed].contains(fixture.task.state)) }
            let saved = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: crash.appendingPathComponent("downloads.json")))
            XCTAssertEqual(saved, restored.items)
            try restored.resume(fixture.item.id)
            let current = restored.items
            let official = crash.appendingPathComponent("\(fixture.item.id).resume")
            let currentBytes = Data("current-generation bytes".utf8)
            try currentBytes.write(to: official)
            schedule.pause?(Data("late old callback bytes".utf8))
            await Task.yield()
            restored.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
            XCTAssertEqual(restored.items, current)
            XCTAssertEqual(try Data(contentsOf: official), currentBytes)
            XCTAssertEqual(schedule.starts, 1)
        }
    }

    func testRecoveredMultiPauseWritesFailWithoutSkippingNativeStopsOrCrossingTokens() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.cleanup() }
        let second = BrowserDownload(id: UUID(), url: fixture.item.url, filename: fixture.item.filename,
                                     state: .running, mirrors: fixture.item.mirrors, mirrorIndex: 0,
                                     transferID: UUID(), resumeDataUsable: false)
        let secondName = second.id.uuidString + "|" + second.transferID!.uuidString
        let secondTask = fixture.session.downloadTask(with: second.url)
        secondTask.taskDescription = secondName // Never resume either native fixture.
        try JSONEncoder().encode([fixture.item, second]).write(to: fixture.folder.appendingPathComponent("downloads.json"))
        let crash = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: crash) }
        var failOriginal = false
        var copied = false
        var originalStorage = DownloadManifestStorage()
        originalStorage.write = { records, url in
            if failOriginal {
                if !copied && records.allSatisfy({ $0.userStopState == .paused }) {
                    try FileManager.default.copyItem(at: fixture.folder, to: crash)
                    copied = true
                }
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try JSONEncoder().encode(records).write(to: url)
        }
        var originalCalls = 0
        let original = DownloadManager(directory: fixture.folder, background: false, storage: originalStorage,
            enumerateTasks: { _ in [fixture.task, secondTask] }, automaticallyRecover: false,
            cancelForResume: { _, _ in originalCalls += 1 }, startTransfer: { _ in XCTFail("no real transport") })
        await original.retryStorage()
        failOriginal = true
        original.pause(fixture.item.id)
        original.pause(second.id)
        XCTAssertEqual(originalCalls, 2)
        XCTAssertTrue(copied)
        let schedule = OfflineSchedule()
        var failRestored = true
        var restoredStorage = DownloadManifestStorage()
        restoredStorage.write = { records, url in
            if failRestored { throw CocoaError(.fileWriteOutOfSpace) }
            try JSONEncoder().encode(records).write(to: url)
        }
        let previousManager = DownloadManager.backgroundManager
        let previousCompletion = DownloadManager.backgroundCompletion
        defer { DownloadManager.backgroundManager = previousManager; DownloadManager.backgroundCompletion = previousCompletion }
        var callbacks: [String: DownloadManager.PauseCompletion] = [:]
        var calls = 0
        let restored = DownloadManager(directory: crash, background: false, storage: restoredStorage,
            enumerateTasks: { _ in [fixture.task, secondTask] }, automaticallyRecover: false, registersBackgroundEvents: true,
            recoveryScheduler: { schedule.work.append($0) },
            cancelForResume: { task, callback in
                calls += 1
                callbacks[task.taskDescription!] = callback
                task.cancel()
            }, startTransfer: { _ in XCTFail("a recovered stop cannot start transport") })
        await restored.retryStorage()
        XCTAssertEqual(calls, 2, "one failed manifest cannot skip the other native action")
        XCTAssertFalse(restored.isReady)
        XCTAssertTrue(restored.items.allSatisfy { $0.state == .pausing })
        var acknowledgements = 0
        DownloadManager.backgroundCompletion = { acknowledgements += 1 }
        restored.urlSessionDidFinishEvents(forBackgroundURLSession: fixture.session)
        XCTAssertEqual(acknowledgements, 0)
        failRestored = false
        let firstBytes = Data("first-generation callback bytes".utf8)
        try XCTUnwrap(callbacks[fixture.name])(firstBytes)
        try await yieldUntil { !schedule.work.isEmpty }
        try await schedule.drain()
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(restored.items.first { $0.id == fixture.item.id }?.state, .paused)
        XCTAssertEqual(restored.items.first { $0.id == second.id }?.state, .pausing)
        try XCTUnwrap(callbacks[secondName])(nil)
        try await yieldUntil { acknowledgements == 1 }
        try await schedule.drain()
        XCTAssertTrue(restored.isReady)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(try Data(contentsOf: crash.appendingPathComponent("\(fixture.item.id).resume")), firstBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crash.appendingPathComponent("\(second.id).resume").path))
        let saved = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: crash.appendingPathComponent("downloads.json")))
        XCTAssertEqual(saved, restored.items)
    }

    private func persistedPauseCrashSnapshot(_ fixture: OfflineFixture) async throws -> URL {
        let crash = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var fault = false
        var copied = false
        var storage = DownloadManifestStorage()
        storage.write = { records, url in
            if fault {
                if !copied {
                    // Production recordStop has written the receipt; the old
                    // manifest still describes a running native task.
                    try FileManager.default.copyItem(at: fixture.folder, to: crash)
                    copied = true
                }
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try JSONEncoder().encode(records).write(to: url)
        }
        var nativeCalls = 0
        let original = DownloadManager(directory: fixture.folder, background: false, storage: storage,
            enumerateTasks: { _ in [fixture.task] }, automaticallyRecover: false,
            cancelForResume: { _, _ in nativeCalls += 1 }, startTransfer: { _ in XCTFail("no transport in crash fixture") })
        await original.retryStorage()
        fault = true
        original.pause(fixture.item.id)
        XCTAssertEqual(nativeCalls, 1, "failed manifest still dispatches the real native-stop API seam")
        XCTAssertFalse(original.isReady)
        XCTAssertTrue(copied)
        XCTAssertEqual(fixture.task.state, .suspended)
        let manifest = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: crash.appendingPathComponent("downloads.json")))
        XCTAssertEqual(manifest[0].state, .running)
        XCTAssertNil(manifest[0].userStopState)
        let control = try JSONDecoder().decode(PendingDownloadReceipt.self,
            from: Data(contentsOf: crash.appendingPathComponent("Pending").appendingPathComponent(fixture.name + "--stop.json")))
        XCTAssertEqual(control.taskDescription, fixture.name)
        XCTAssertEqual(control.userStopState, .paused)
        return crash
    }

    func testPauseDuringInitialEnumerationCollectsSurvivingTaskResumeDataOnce() async throws {
        for returnsData in [false, true] {
            let fixture = try OfflineFixture()
            defer { fixture.cleanup() }
            let schedule = OfflineSchedule()
            let official = fixture.folder.appendingPathComponent("\(fixture.item.id).resume")
            try Data("old unusable resume bytes".utf8).write(to: official)
            var release: CheckedContinuation<[URLSessionTask], Never>?
            var heldOnce = false
            var cancellations = 0
            let manager = offlineManager(fixture, schedule, enumerateTasks: { _ in
                if !heldOnce {
                    heldOnce = true
                    return await withCheckedContinuation { release = $0 }
                }
                return [fixture.task]
            }, cancelForResume: { task, callback in
                cancellations += 1
                XCTAssertTrue(task === fixture.task)
                task.cancel()
                schedule.pause = callback
            })
            let recovery = Task { await manager.retryStorage() }
            try await yieldUntil { release != nil }
            manager.pause(fixture.item.id)
            XCTAssertEqual(manager.items[0].state, .paused)
            XCTAssertEqual(manager.items[0].userStopState, .paused)
            XCTAssertEqual(manager.items[0].resumeDataUsable, false)
            XCTAssertEqual(cancellations, 0)
            XCTAssertNil(schedule.pause, "discovery has not returned a native task yet")
            release?.resume(returning: [fixture.task])
            await recovery.value
            try await schedule.drain()
            XCTAssertEqual(cancellations, 1, "the enumerated task must use the resume-data API once")
            XCTAssertEqual(manager.items[0].state, .pausing)
            try manager.resume(fixture.item.id)
            XCTAssertEqual(schedule.starts, 0, "Continue must not start while the resume callback is pending")
            manager.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
            try await schedule.drain()
            XCTAssertEqual(manager.items[0].state, .pausing, "cancellation error cannot dispose the pending data callback")
            let bytes = returnsData ? Data("new returned resume bytes".utf8) : nil
            try XCTUnwrap(schedule.pause)(bytes)
            try await yieldUntil { !schedule.work.isEmpty }
            try await schedule.drain()
            await manager.retryStorage() // Repeated snapshots must not request another callback.
            XCTAssertEqual(cancellations, 1)
            XCTAssertTrue(manager.isReady)
            XCTAssertNil(manager.storageError)
            XCTAssertEqual(manager.items[0].state, .paused)
            XCTAssertEqual(manager.items[0].resumeDataUsable, returnsData)
            XCTAssertEqual(manager.items[0].transferID, fixture.item.transferID)
            XCTAssertEqual(manager.items[0].mirrorIndex, 0)
            XCTAssertEqual(schedule.starts, 0)
            let records = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: fixture.folder.appendingPathComponent("downloads.json")))
            XCTAssertEqual(records[0], manager.items[0])
            if let bytes { XCTAssertEqual(try Data(contentsOf: official), bytes) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: official.path)) }
        }
    }

    func testPauseWithoutLiveTaskDuringEnumerationBlocksHTTPFailureAndAllowsCompletion() async throws {
        for status in [200, 500] {
            let fixture = try OfflineFixture()
            defer { fixture.cleanup() }
            let schedule = OfflineSchedule()
            var release: CheckedContinuation<[URLSessionTask], Never>?
            var heldOnce = false
            let manager = offlineManager(fixture, schedule, status: status, enumerateTasks: { _ in
                if !heldOnce {
                    heldOnce = true
                    return await withCheckedContinuation { release = $0 }
                }
                return []
            })
            let recovery = Task { await manager.retryStorage() }
            try await yieldUntil { release != nil }
            XCTAssertFalse(manager.isReady)
            XCTAssertEqual(manager.items[0].state, .running)
            manager.pause(fixture.item.id) // No task has been attached during enumeration.
            XCTAssertEqual(manager.items[0].state, .paused)
            XCTAssertEqual(manager.items[0].userStopState, .paused)
            XCTAssertEqual(manager.items[0].resumeDataUsable, false)
            XCTAssertNil(schedule.pause)
            manager.urlSession(fixture.session, downloadTask: fixture.task, didFinishDownloadingTo: try fixture.payload())
            release?.resume(returning: [])
            await recovery.value
            try await schedule.drain()
            XCTAssertTrue(manager.isReady)
            XCTAssertEqual(manager.items[0].state, status == 200 ? .completed : .failed)
            XCTAssertEqual(manager.items[0].mirrorIndex, 0)
            XCTAssertEqual(manager.items[0].transferID, fixture.item.transferID)
            XCTAssertEqual(schedule.starts, 0)
            XCTAssertNil(schedule.pause)
        }
    }

    func testPauseAfterNativeCompletionDisappearsAtEitherHashBoundary() async throws {
        for (finalBoundary, badHash) in [(false, false), (false, true), (true, false)] {
            let fixture = try OfflineFixture(badHash: badHash)
            defer { fixture.cleanup() }
            let schedule = OfflineSchedule()
            var taskPresent = true
            var blocked = false
            var storage = DownloadManifestStorage()
            storage.write = { records, url in
                if blocked { throw CocoaError(.fileWriteOutOfSpace) }
                try JSONEncoder().encode(records).write(to: url)
            }
            var payloadRelease: CheckedContinuation<(String, String), Never>?
            var finalRelease: CheckedContinuation<String, Never>?
            var payloadHeld = false
            var finalHeld = false
            var savedHashes: (String, String)?
            var savedFinal: String?
            let manager = offlineManager(fixture, schedule, storage: storage,
                enumerateTasks: { _ in taskPresent ? [fixture.task] : [] },
                payloadHashes: { url in
                    let hashes = (try DownloadManager.hashFile(url), try DownloadManager.hashFile(url, sha512: true))
                    if !finalBoundary && !payloadHeld {
                        payloadHeld = true; savedHashes = hashes
                        return await withCheckedContinuation { payloadRelease = $0 }
                    }
                    return hashes
                }, finalHash: { url in
                    let hash = try DownloadManager.hashFile(url)
                    if finalBoundary && !finalHeld {
                        finalHeld = true; savedFinal = hash
                        return await withCheckedContinuation { finalRelease = $0 }
                    }
                    return hash
                })
            await manager.retryStorage()
            manager.urlSession(fixture.session, downloadTask: fixture.task, didFinishDownloadingTo: try fixture.payload())
            taskPresent = false // The real completed task is absent on the next allTasks snapshot.
            let work = try XCTUnwrap(schedule.work.first)
            schedule.work.removeFirst()
            let recovery = Task { await work() }
            try await yieldUntil { finalBoundary ? finalRelease != nil : payloadRelease != nil }
            blocked = true
            manager.pause(fixture.item.id)
            XCTAssertEqual(manager.items[0].state, .paused)
            XCTAssertEqual(manager.items[0].userStopState, .paused)
            XCTAssertEqual(manager.items[0].resumeDataUsable, false)
            XCTAssertNotNil(manager.storageError)
            XCTAssertNil(schedule.pause, "no native task means no resume callback to wait for")
            // A companion transport error must not defeat the accepted pause either.
            manager.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.badServerResponse))
            blocked = false
            if finalBoundary { finalRelease?.resume(returning: try XCTUnwrap(savedFinal)) }
            else { payloadRelease?.resume(returning: try XCTUnwrap(savedHashes)) }
            await recovery.value
            try await schedule.drain()
            XCTAssertTrue(manager.isReady)
            XCTAssertNil(manager.storageError)
            XCTAssertEqual(manager.items[0].state, badHash ? .failed : .completed)
            XCTAssertEqual(manager.items[0].transferID, fixture.item.transferID)
            XCTAssertEqual(manager.items[0].mirrorIndex, 0)
            XCTAssertEqual(schedule.starts, 0)
            XCTAssertNil(schedule.pause)
        }
    }

    @MainActor private final class OfflineSchedule {
        var work: [DownloadManager.RecoveryWork] = []
        var pause: DownloadManager.PauseCompletion?
        var starts = 0
        var started: [URLSessionDownloadTask] = []
        func drain() async throws {
            var passes = 0
            while !work.isEmpty && passes < 8 {
                let next = work.removeFirst()
                await next()
                passes += 1
            }
            XCTAssertTrue(work.isEmpty, "recovery must quiesce without a new event")
            if !work.isEmpty { throw CocoaError(.fileReadUnknown) }
        }
    }

    @MainActor private struct OfflineFixture {
        let folder: URL
        let session: URLSession
        let task: URLSessionDownloadTask
        let item: BrowserDownload
        var name: String { item.id.uuidString + "|" + item.transferID!.uuidString }
        var pending: URL { folder.appendingPathComponent("Pending") }
        init(badHash: Bool = false) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = URL(string: "http://127.0.0.1:1/file")!
            item = BrowserDownload(id: UUID(), url: url, filename: "file", state: .running,
                                   expectedSHA256: badHash ? String(repeating: "0", count: 64) : nil,
                                   mirrors: [url, URL(string: "http://127.0.0.1:1/mirror")!], mirrorIndex: 0, transferID: UUID())
            try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
            session = URLSession(configuration: .ephemeral)
            task = session.downloadTask(with: url) // Never resume this fixture task.
            task.taskDescription = item.id.uuidString + "|" + item.transferID!.uuidString
        }
        func payload() throws -> URL {
            let url = folder.appendingPathComponent("temporary-" + UUID().uuidString)
            try Data("verified callback payload".utf8).write(to: url)
            return url
        }
        func cleanup() {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func offlineManager(_ fixture: OfflineFixture, _ schedule: OfflineSchedule,
                                storage: DownloadManifestStorage = DownloadManifestStorage(), status: Int = 200,
                                enumerateTasks: ((URLSession) async -> [URLSessionTask])? = nil,
                                cancelForResume: ((URLSessionDownloadTask, @escaping DownloadManager.PauseCompletion) -> Void)? = nil,
                                payloadHashes: @escaping (URL) async throws -> (String, String) = {
                                    (try DownloadManager.hashFile($0), try DownloadManager.hashFile($0, sha512: true))
                                },
                                finalHash: @escaping (URL) async throws -> String = { try DownloadManager.hashFile($0) },
                                removeReceiptMetadata: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> DownloadManager {
        DownloadManager(directory: fixture.folder, background: false, storage: storage,
                        enumerateTasks: enumerateTasks ?? { _ in [fixture.task] + schedule.started }, automaticallyRecover: false,
                        recoveryScheduler: { schedule.work.append($0) },
                        cancelForResume: cancelForResume ?? { task, callback in task.cancel(); schedule.pause = callback },
                        payloadHashes: payloadHashes, finalHash: finalHash,
                        downloadResponse: { _ in HTTPURLResponse(url: fixture.item.url, statusCode: status, httpVersion: nil, headerFields: nil) },
                        startTransfer: { task in schedule.starts += 1; schedule.started.append(task) },
                        removeReceiptMetadata: removeReceiptMetadata)
    }

    private func yieldUntil(_ predicate: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(5)
        while !predicate() && Date() < limit { await Task.yield() }
        XCTAssertTrue(predicate(), "explicit callback boundary was not reached")
        if !predicate() { throw CocoaError(.fileReadUnknown) }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !predicate() && Date() < limit { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate())
    }
}
