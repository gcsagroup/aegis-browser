import XCTest
@testable import AgentKit

final class WorkflowTests: XCTestCase {
    func testFourDeterministicWorkflowsRespectSafetyBoundary() {
        let engine = AgentWorkflowEngine()
        let results = AgentWorkflowKind.allCases.map { engine.run($0) }

        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.first { $0.kind == .research }?.citations.count, 10)
        XCTAssertEqual(results.first { $0.kind == .browserManager }?.undoAvailable, false)
        XCTAssertTrue(results.first { $0.kind == .safeDownload }?.evidence.contains("发布者签名：未提供") == true)

        let shopping = results.first { $0.kind == .shopping }
        XCTAssertEqual(shopping?.requiresUserHandoff, true)
        XCTAssertTrue(shopping?.evidence.contains("最终提交 0 次") == true)
    }

    func testPersistenceSchemasRoundTripWithoutRawPageFields() throws {
        let taskID = UUID()
        let checkpoint = Checkpoint(
            checkpointID: UUID(),
            taskID: taskID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            state: .recovering,
            redactedGoalSummary: "整理收藏夹",
            lastActionID: UUID(),
            reconciliationReference: "bookmark-tree-hash:abc",
            undoRecordID: UUID()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("documentNonce"))
        XCTAssertFalse(json.contains("formValue"))
        XCTAssertFalse(json.contains("rawPrompt"))
        XCTAssertEqual(try JSONDecoder().decode(Checkpoint.self, from: data), checkpoint)
    }
}
