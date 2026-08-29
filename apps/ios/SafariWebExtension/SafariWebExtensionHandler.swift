import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let gate = SafariReadOnlyGate(
        expectedExtensionID: Bundle.main.bundleIdentifier ?? "com.gcsa.aegis.ios.app.safari"
    )

    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        let input = context.inputItems.first as? NSExtensionItem
        do {
            guard let requestMessage = input?.userInfo?[SFExtensionMessageKey] as? [String: Any]
            else { throw SafariReadOnlyGateError.invalidMessage }
            let request = try SafariReadOnlyRequest(message: requestMessage)
            let profileID = try Self.profileID(from: input?.userInfo?[SFExtensionProfileKey])
            let payload: [String: Any]
            switch request.phase {
            case .authorize:
                let authorization = try Self.gate.authorize(request: request, profileID: profileID)
                payload = [
                    "ok": true,
                    "phase": "authorized",
                    "leaseID": authorization.leaseID.uuidString,
                    "documentToken": authorization.documentToken.uuidString.lowercased(),
                    "navigationEpoch": authorization.navigationEpoch,
                    "expiresAt": authorization.expiresAt.timeIntervalSince1970,
                ]
            case .consume:
                let authorization = try Self.gate.consume(request: request, profileID: profileID)
                payload = [
                    "ok": true,
                    "phase": "consumed",
                    "mode": "read_only",
                    "route": authorization.route,
                    "documentToken": authorization.documentToken.uuidString.lowercased(),
                    "navigationEpoch": authorization.navigationEpoch,
                ]
            }
            response.userInfo = [SFExtensionMessageKey: payload]
        } catch let error as SafariReadOnlyGateError {
            response.userInfo = [
                SFExtensionMessageKey: ["ok": false, "error": error.rawValue],
            ]
        } catch {
            response.userInfo = [SFExtensionMessageKey: ["ok": false, "error": "invalid_message"]]
        }
        context.completeRequest(returningItems: [response])
    }

    private static func profileID(from value: Any?) throws -> String {
        guard let value else { return SafariReadOnlyGate.defaultProfileID }
        if let uuid = value as? UUID { return uuid.uuidString.lowercased() }
        if let uuid = value as? NSUUID { return uuid.uuidString.lowercased() }
        if let text = value as? String,
           let uuid = UUID(uuidString: text) {
            return uuid.uuidString.lowercased()
        }
        throw SafariReadOnlyGateError.profileDenied
    }
}
