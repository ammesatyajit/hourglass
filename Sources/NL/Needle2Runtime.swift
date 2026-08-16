//
//  Needle2Runtime.swift
//  Hourglass
//
//  Tiny, grammar-constrained function router for AI Search. Needle2's
//  byte-level schema compiler constrains tool names, argument names, enums,
//  ranges, and JSON structure during decoding. Hourglass still validates the
//  semantic choice before touching chat.db; constrained JSON is not the same
//  thing as a correct interpretation of the user's request.
//

import Foundation
import Needle2

protocol NeedleRoutingRuntime: LLMRuntime {
    func route(userQuery: String, now: Date) async throws -> NeedleRoutingResult
}

struct NeedleRoutingResult: Sendable, Equatable {
    let call: NLToolCall?
    let callCount: Int
    let reasoning: String?
    let confidence: Double
    let rawJSON: String
}

enum Needle2RuntimeError: Error, CustomStringConvertible, Sendable {
    case initializationFailed(Int32)
    case completionFailed(Int32)
    case invalidUTF8
    case invalidResponse(String)

    var description: String {
        switch self {
        case .initializationFailed(let code): return "Needle2 initialization failed (\(code))"
        case .completionFailed(let code): return "Needle2 completion failed (\(code))"
        case .invalidUTF8: return "Needle2 returned invalid UTF-8"
        case .invalidResponse(let reason): return "Needle2 returned an invalid response: \(reason)"
        }
    }
}

/// Actor isolation is required because the standalone Needle C API owns one
/// global session. It also makes concurrent dashboard/panel requests queue
/// instead of corrupting the model state.
public actor Needle2Runtime: NeedleRoutingRuntime {
    public nonisolated let modelLabel = "Needle2 · 45M local"
    public var isReady: Bool { get async { true } }

    private var initializedDay: String?
    private let outputCapacity = 64 * 1024

    public init() {}

    func route(userQuery: String, now: Date = Date()) async throws -> NeedleRoutingResult {
        try initializeIfNeeded(now: now)
        needle_reset()

        var output = [CChar](repeating: 0, count: outputCapacity)
        let code: Int32 = userQuery.withCString { input in
            output.withUnsafeMutableBufferPointer { buffer in
                needle_complete(input, 256, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard code >= 0 else { throw Needle2RuntimeError.completionFailed(code) }
        let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let raw = String(bytes: bytes, encoding: .utf8) else {
            throw Needle2RuntimeError.invalidUTF8
        }
        return try Self.parse(raw)
    }

    /// Compatibility with the old `LLMRuntime` surface. Production AI Search
    /// calls `route` directly and never asks Needle to synthesize prose.
    public func respond(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        let result = try await route(userQuery: userPrompt, now: Date())
        guard let call = result.call else { return #"{"tool":"search","args":{"query":""}}"# }
        let args = call.args.mapValues(FoundationValue.init).mapValues(\.value)
        let object: [String: Any] = ["tool": call.tool, "args": args]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw Needle2RuntimeError.invalidUTF8
        }
        return json
    }

    public func releaseResources() async {
        // The tiny CPU runtime intentionally stays warm. Its bounded working
        // set is dramatically smaller than reloading a model for every query.
    }

    private func initializeIfNeeded(now: Date) throws {
        let day = Self.dayString(now)
        guard initializedDay != day else { return }
        let facts = "date: \(Self.systemDateString(now)); locale: \(Locale.current.identifier); device: Mac; assistant: Hourglass"
        let tools = NeedleToolCatalog.json
        let indexPath = Self.toolIndexPath()
        let code: Int32 = facts.withCString { factsPointer in
            tools.withCString { toolsPointer in
                if let indexPath {
                    return indexPath.withCString { indexPointer in
                        needle_init(factsPointer, toolsPointer, indexPointer)
                    }
                } else {
                    return needle_init(factsPointer, toolsPointer, nil)
                }
            }
        }
        guard code >= 0 else { throw Needle2RuntimeError.initializationFailed(code) }
        initializedDay = day
    }

    private static func parse(_ raw: String) throws -> NeedleRoutingResult {
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Needle2RuntimeError.invalidResponse("not a JSON object")
        }
        let calls = root["function_calls"] as? [[String: Any]] ?? []
        let parsedCalls: [NLToolCall] = calls.compactMap { object in
            guard let name = object["name"] as? String else { return nil }
            let rawArgs = object["arguments"] as? [String: Any] ?? [:]
            var args: [String: NLToolArg] = [:]
            for (key, value) in rawArgs {
                if let string = value as? String { args[key] = .string(string) }
                else if let bool = value as? Bool { args[key] = .bool(bool) }
                else if let int = value as? Int { args[key] = .int(int) }
                else if let number = value as? NSNumber { args[key] = .int(number.intValue) }
                else if value is NSNull { args[key] = .null }
            }
            return NLToolCall(tool: name, args: args)
        }
        return NeedleRoutingResult(
            call: parsedCalls.count == 1 ? parsedCalls[0] : nil,
            callCount: parsedCalls.count,
            reasoning: root["reasoning"] as? String,
            confidence: (root["confidence"] as? NSNumber)?.doubleValue ?? 0,
            rawJSON: raw
        )
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func systemDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd E HH:mm"
        return formatter.string(from: date)
    }

    /// Needle retrieves the best five tools before constrained decoding. Its
    /// tiny catalogue embeddings are fingerprinted by schema/model, so this
    /// cache remains correct when the catalogue changes and avoids rebuilding
    /// the retrieval index on every app launch.
    private static func toolIndexPath() -> String? {
        guard let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = cacheRoot
            .appendingPathComponent("com.satyajit.hourglass", isDirectory: true)
            .appendingPathComponent("Needle2", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory.appendingPathComponent("hourglass-tools.idx").path
        } catch {
            return nil
        }
    }
}

private struct FoundationValue {
    let value: Any

    init(_ arg: NLToolArg) {
        switch arg {
        case .string(let string): value = string
        case .int(let int): value = int
        case .bool(let bool): value = bool
        case .null: value = NSNull()
        }
    }
}

enum NeedleToolCatalog {
    /// The production tool schemas. Keeping filters as separate typed fields
    /// means media/reaction enums and argument names are grammar-constrained;
    /// the model never writes SQL or Hourglass's compact operator language.
    static var json: String {
        let media = ["image", "video", "audio", "sticker", "link", "file"]
        let reactions = ["love", "laugh", "like", "dislike", "emphasize", "question"]

        func string(_ description: String, max: Int = 100) -> [String: Any] {
            ["type": "string", "description": description, "maxLength": max]
        }
        func enumeration(_ values: [String]) -> [String: Any] {
            ["type": "string", "enum": values]
        }
        func integer(_ low: Int, _ high: Int) -> [String: Any] {
            ["type": "integer", "minimum": low, "maximum": high]
        }
        func dateWindow(_ description: String) -> [String: Any] {
            [
                "type": "string",
                "description": description,
                "maxLength": 40,
                "pattern": #"^(?:all_time|today|yesterday|this_week|last_week|this_month|last_month|last_24h|last_7d|last_14d|last_30d|last_3mo|last_6mo|last_1y|[0-9]{4}-[0-9]{2}-[0-9]{2}(?:\.\.[0-9]{4}-[0-9]{2}-[0-9]{2})?)$"#,
            ]
        }
        func tool(
            _ name: String,
            _ description: String,
            _ properties: [String: Any],
            required: [String] = []
        ) -> [String: Any] {
            [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ],
            ]
        }
        func messageProperties(includeLimit: Bool) -> [String: Any] {
            var properties: [String: Any] = [
                "query": string("Literal topic words expected inside message bodies. Exclude request verbs, function names, people, dates, and date-range words.", max: 120),
                "retrieval": enumeration(["literal", "hybrid"]),
                "with": string("Contact whose conversations to search", max: 80),
                "from": string("Sender contact name, or me for messages sent by the user", max: 80),
                "chat": string("Named group chat", max: 100),
                "type": enumeration(media),
                "reaction": enumeration(reactions),
                "in": dateWindow("Date only. Never infer a date from topic words."),
            ]
            if includeLimit { properties["limit"] = integer(1, 50) }
            return properties
        }

        let tools: [[String: Any]] = [
            tool("search_messages", "Default function for iMessage recall and topic questions. Use when words like plan, group, contact, top, liked, or link are merely part of the topic rather than an explicit operation.", messageProperties(includeLimit: false)),
            tool("read_conversation", "Read a one-to-one conversation chronologically. Use only when the user explicitly asks to catch up, inspect, or recall what a conversation was about.", [
                "with": string("Contact name", max: 80),
                "in": dateWindow("Optional date window from the request"),
            ], required: ["with"]),
            tool("count_messages", "Return the exact number of matching iMessages. Use only for how-many, how-often, and number-of questions.", messageProperties(includeLimit: false)),
            tool("first_message", "Return the earliest matching iMessage. Use for first, earliest, or when-did-I-first questions.", messageProperties(includeLimit: false)),
            tool("top_contacts", "Rank people by iMessage volume. Use only when the request explicitly asks to rank contacts or who the user texts most; a contact name or the word top alone is insufficient.", [
                "chat": string("Optional group whose members should be ranked", max: 100),
                "in": dateWindow("Date window; omit for all history"),
                "limit": integer(1, 20),
            ]),
            tool("top_groups", "Rank group chats by iMessage volume. Use only for an explicit most-active, biggest, or top-groups ranking request; do not use for a topic or named group.", [
                "in": dateWindow("Date window; omit for all history"),
                "limit": integer(1, 20),
            ]),
            tool("overview_stats", "Return total, sent, received, and chat counts for overall iMessage activity in a date window.", [
                "in": dateWindow("Date window from the request"),
            ]),
            tool("friends_made_since", "Find people whose iMessage relationship began after a date. Use for new-friend and who-did-I-meet questions.", [
                "since": [
                    "type": "string", "description": "Start date as YYYY-MM-DD", "maxLength": 10,
                    "pattern": #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
                ],
                "limit": integer(1, 30),
            ], required: ["since"]),
            tool("plans_in_window", "Find commitments the user made in sent iMessages. Use only when explicitly asked what plans or commitments the user made; do not use when plan/plans is merely a message topic.", [
                "in": dateWindow("Date window from the request"),
                "limit": integer(1, 80),
            ], required: ["in"]),
            tool("search_contacts", "Search the user's iMessage contacts by name. Do not use for message-body searches.", [
                "name": string("Full or partial contact name", max: 80),
            ], required: ["name"]),
        ]
        let data = try! JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
