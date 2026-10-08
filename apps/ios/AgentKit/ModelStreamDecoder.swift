import Foundation

/// 按字节解析 SSE，避免分片切开 UTF-8 字符；结束标记和正文分别校验。
struct ModelStreamDecoder {
    let provider: ModelProvider
    private(set) var text = ""
    private(set) var terminal = false
    private var stopped = false
    private var line = Data()
    private var dataLines: [String] = []
    private var event = ""
    private var receivedBytes = 0
    private var eventBytes = 0
    private var previousCR = false
    private var firstLine = true
    private var textBlocks: Set<Int> = []

    mutating func consume(_ byte: UInt8) throws -> Bool {
        receivedBytes += 1
        guard receivedBytes <= 1_000_000 else { throw ModelClientError.tooLarge }
        if byte == 10, previousCR { previousCR = false; return false }
        previousCR = byte == 13
        if byte == 10 || byte == 13 {
            guard var value = String(data: line, encoding: .utf8) else { throw ModelClientError.invalidResponse }
            line.removeAll(keepingCapacity: true)
            if firstLine { value = value.replacingOccurrences(of: "\u{feff}", with: ""); firstLine = false }
            return try consumeLine(value)
        }
        guard line.count < 128_000 else { throw ModelClientError.tooLarge }
        line.append(byte)
        return false
    }

    private mutating func consumeLine(_ line: String) throws -> Bool {
        if line.isEmpty {
            defer { dataLines = []; event = ""; eventBytes = 0 }
            guard !dataLines.isEmpty else { return false }
            return try consumeEvent(dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return false }
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if fields[0] == "data" {
            eventBytes += value.utf8.count
            guard eventBytes <= 128_000 else { throw ModelClientError.tooLarge }
            dataLines.append(value)
        } else if fields[0] == "event" { event = value }
        return false
    }

    private mutating func consumeEvent(_ data: String) throws -> Bool {
        guard !terminal else { throw ModelClientError.invalidResponse }
        let alreadyStopped = stopped
        if data == "[DONE]" {
            guard provider == .compatible, stopped else { throw ModelClientError.incompleteResponse }
            terminal = true; return false
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else {
            throw ModelClientError.invalidResponse
        }
        if object["error"] != nil || event == "error" { throw ModelClientError.serviceUnavailable }
        var addition = ""
        switch provider {
        case .compatible:
            let choices = object["choices"] as? [[String: Any]] ?? []
            guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return false }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            guard delta["tool_calls"] == nil, delta["function_call"] == nil,
                  (delta["refusal"] as? String)?.isEmpty != false else { throw ModelClientError.invalidResponse }
            addition = delta["content"] as? String ?? ""
            if stopped, !addition.isEmpty { throw ModelClientError.invalidResponse }
            if let reason = choice["finish_reason"] as? String {
                guard reason == "stop" else { throw ModelClientError.incompleteResponse }
                stopped = true
            }
        case .anthropic:
            let kind = object["type"] as? String ?? event
            switch kind {
            case "content_block_start":
                guard let block = object["content_block"] as? [String: Any],
                      let index = object["index"] as? Int else { throw ModelClientError.invalidResponse }
                let type = block["type"] as? String
                guard type == "text" || type == "thinking" || type == "redacted_thinking" else { throw ModelClientError.invalidResponse }
                if type == "text" { textBlocks.insert(index); addition = block["text"] as? String ?? "" }
            case "content_block_delta":
                guard let delta = object["delta"] as? [String: Any] else { throw ModelClientError.invalidResponse }
                if delta["type"] as? String == "text_delta" {
                    guard let index = object["index"] as? Int, textBlocks.contains(index) else { throw ModelClientError.invalidResponse }
                    addition = delta["text"] as? String ?? ""
                } else if delta["type"] as? String == "input_json_delta" { throw ModelClientError.invalidResponse }
            case "message_delta":
                if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String {
                    guard reason == "end_turn" else { throw ModelClientError.incompleteResponse }
                    stopped = true
                }
            case "message_stop":
                guard stopped else { throw ModelClientError.incompleteResponse }
                terminal = true
            case "error": throw ModelClientError.serviceUnavailable
            default: break
            }
        case .gemini:
            if (object["promptFeedback"] as? [String: Any])?["blockReason"] != nil { throw ModelClientError.invalidResponse }
            let candidates = object["candidates"] as? [[String: Any]] ?? []
            guard let candidate = candidates.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return false }
            let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for part in parts {
                guard part["functionCall"] == nil, part["executableCode"] == nil, part["functionResponse"] == nil else {
                    throw ModelClientError.invalidResponse
                }
                if part["thought"] as? Bool != true { addition += part["text"] as? String ?? "" }
            }
            if let reason = candidate["finishReason"] as? String {
                guard reason == "STOP" else { throw ModelClientError.incompleteResponse }
                stopped = true; terminal = true
            }
        }
        guard !alreadyStopped || addition.isEmpty else { throw ModelClientError.invalidResponse }
        guard text.utf8.count + addition.utf8.count <= 1_000_000 else { throw ModelClientError.tooLarge }
        text += addition
        return !addition.isEmpty
    }

    func finish() throws -> String {
        guard stopped, terminal else { throw ModelClientError.incompleteResponse }
        guard line.isEmpty, dataLines.isEmpty else { throw ModelClientError.incompleteResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelClientError.invalidResponse }
        return text
    }
}
