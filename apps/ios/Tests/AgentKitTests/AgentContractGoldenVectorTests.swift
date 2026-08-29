import XCTest
@testable import AgentKit

final class AgentContractGoldenVectorTests: XCTestCase {
    func testValidatesEveryFrozenSharedVector() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(vectors["vector_version"] as? Int, 1)

        let valid = try XCTUnwrap(vectors["valid"] as? [[String: Any]])
        let actualTypes = try valid.map { vector -> AgentContractMessageType in
            let message = try XCTUnwrap(vector["message"])
            return try AgentContractCodec.validateJSONObject(message)
        }

        XCTAssertEqual(actualTypes, [
            .taskGrant,
            .documentLease,
            .actionDigestInput,
            .actionDigestInput,
        ])
    }

    func testRejectsEveryFrozenMutationWithExactErrorCode() throws {
        let vectors = try loadVectors()
        let valid = try XCTUnwrap(vectors["valid"] as? [[String: Any]])
        let bases = Dictionary(uniqueKeysWithValues: try valid.map { vector in
            (
                try XCTUnwrap(vector["name"] as? String),
                try XCTUnwrap(vector["message"])
            )
        })
        let mutations = try XCTUnwrap(vectors["invalid_mutations"] as? [[String: Any]])

        for mutation in mutations {
            let name = try XCTUnwrap(mutation["name"] as? String)
            let baseName = try XCTUnwrap(mutation["base"] as? String)
            let base = try XCTUnwrap(bases[baseName], "缺少基础向量：\(baseName)")
            let path = try XCTUnwrap(mutation["path"] as? [String])
            let replacement = try XCTUnwrap(mutation["value"])
            let expectedCode = try XCTUnwrap(mutation["expected_error"] as? String)
            let mutated = try replacingValue(in: base, path: path[...], with: replacement)

            do {
                _ = try AgentContractCodec.validateJSONObject(mutated)
                XCTFail("无效向量未被拒绝：\(name)")
            } catch let error as AgentContractWireValidationError {
                XCTAssertEqual(error.rawValue, expectedCode, name)
            } catch {
                XCTFail("错误类型不正确：\(name)，\(error)")
            }
        }
    }

    func testRejectsNonCanonicalUUIDTimestampAndNestedFields() throws {
        let vectors = try loadVectors()
        let valid = try XCTUnwrap(vectors["valid"] as? [[String: Any]])
        let grant = try XCTUnwrap(valid.first?["message"])

        let cases: [(path: [String], value: Any, expected: AgentContractWireValidationError)] = [
            (
                ["payload", "task_id"],
                "11111111-1111-4111-8111-11111111111A",
                .invalidValue
            ),
            (
                ["payload", "expires_at"],
                "2030-01-01T00:05:00Z",
                .invalidValue
            ),
            (
                ["payload", "allowed_top_origins"],
                ["https://research.aegis.test", "https://research.aegis.test"],
                .nonCanonicalSet
            ),
            (
                ["payload", "tab_scope", "unexpected"],
                true,
                .unknownField
            ),
            (
                ["payload", "tab_scope", "may_create_tabs"],
                1,
                .invalidValue
            ),
        ]

        for testCase in cases {
            let mutated = try replacingValue(
                in: grant,
                path: testCase.path[...],
                with: testCase.value
            )
            XCTAssertThrowsError(try AgentContractCodec.validateJSONObject(mutated)) { error in
                XCTAssertEqual(error as? AgentContractWireValidationError, testCase.expected)
            }
        }
    }

    func testRuntimeActionDigestEncoderMatchesSharedWireVector() throws {
        let vectors = try loadVectors()
        let valid = try XCTUnwrap(vectors["valid"] as? [[String: Any]])
        let vector = try XCTUnwrap(valid.first { $0["name"] as? String == "bookmark-action-r1" })
        let expected = try XCTUnwrap(vector["message"] as? [String: Any])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try AgentContractCodec.actionDigestData(
            taskID: try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            grantID: try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222")),
            profileID: try XCTUnwrap(UUID(uuidString: "33333333-3333-4333-8333-333333333333")),
            processInstanceID: try XCTUnwrap(UUID(uuidString: "55555555-5555-4555-8555-555555555555")),
            surface: .aegisBrowser,
            policyVersion: "ios-policy-v1",
            tool: "bookmarks.apply",
            normalizedParameters: #"{"fixture":"bookmarks-500","operation":"apply"}"#,
            callSequence: 1,
            target: .native(NativeActionTarget(
                resourceType: .bookmarkPlan,
                registryRevision: 1,
                resourceID: try XCTUnwrap(UUID(uuidString: "99999999-9999-4999-8999-999999999999"))
            )),
            confirmationDigest: "bookmark-tree-fixture-v1",
            expiresAt: try XCTUnwrap(formatter.date(from: "2030-01-01T00:00:30.000Z"))
        )
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
    }

    private func loadVectors() throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "agent-contract-v1.vectors", withExtension: "json"),
            "AegisTests 必须直接打包共享 Agent Contract v1 向量"
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func replacingValue(
        in value: Any,
        path: ArraySlice<String>,
        with replacement: Any
    ) throws -> Any {
        guard let component = path.first,
              var object = value as? [String: Any]
        else {
            throw TestVectorError.invalidMutationPath
        }
        if path.count == 1 {
            object[component] = replacement
            return object
        }
        guard let child = object[component] else {
            throw TestVectorError.invalidMutationPath
        }
        object[component] = try replacingValue(
            in: child,
            path: path.dropFirst(),
            with: replacement
        )
        return object
    }
}

private enum TestVectorError: Error {
    case invalidMutationPath
}
