//
//  VernacularReclaimedLLMClassifier.swift
//  Hourglass - Unified Vernacular Profile
//

import Foundation

enum VernacularReclaimedLLMClassifier {
    struct Result: Sendable, Equatable {
        let filtered: [VernacularProfileReclaimedWord]
        let verdicts: [String: Bool]
        let considered: [VernacularProfileReclaimedWord]
        let status: String
        let usedModel: Bool
    }

    private enum Failure: Error {
        case notReady
        case timeout
        case malformedJSON
    }

    private static let maxCandidates = 40
    private static let maxTokens = 300
    private static let timeoutNanoseconds: UInt64 = 45_000_000_000

    static let systemPrompt = """
    You are shown words pulled from one person's text messages. For EACH numbered word you get up to 5 real messages where they used it. Decide ONE thing per word: is the word being used in its NORMAL, literal, dictionary meaning — or is it REPURPOSED (used in a slang, in-joke, figurative, or otherwise non-standard sense)? Examples: "handoff" / "startup" / "vp" / "email" / "recruiting" / "snippet" used as ordinary work or tech terms = NORMAL. Calling a person a "traffic cone", saying you're "cooked" or "chalked", "aura farming", calling someone "my goat", "that's so peak" = REPURPOSED. Reply with ONLY a compact JSON array of the words used in their NORMAL/literal meaning (these get removed). Leave OUT (i.e. keep) any word that is repurposed, slang, figurative, an in-joke, or that you are unsure about — when in doubt, leave it out. Base this on the example MESSAGES.
    """

    static func classify(
        _ ranked: [VernacularProfileReclaimedWord],
        runtime: any LLMRuntime
    ) async -> Result {
        let considered = Array(ranked.prefix(maxCandidates))
        guard !considered.isEmpty else {
            return Result(filtered: [], verdicts: [:], considered: [],
                          status: "skipped-empty", usedModel: false)
        }
        guard await runtime.isReady else {
            return Result(filtered: ranked, verdicts: [:], considered: considered,
                          status: "fallback-runtime-not-ready", usedModel: false)
        }

        do {
            let user = userPrompt(for: considered)
            let raw = try await withTimeout {
                try await runtime.respond(systemPrompt: systemPrompt,
                                          userPrompt: user,
                                          maxTokens: maxTokens)
            }
            let dropSurfaces = try parseKeepSurfaces(raw)   // model now returns TOPIC/jargon surfaces to REMOVE
            let verdicts = Dictionary(uniqueKeysWithValues: considered.map {
                ($0.surface, !dropSurfaces.contains($0.surface.lowercased()))   // KEEP = NOT flagged for removal
            })
            let filtered = considered.filter { verdicts[$0.surface] == true }
            return Result(filtered: filtered, verdicts: verdicts, considered: considered,
                          status: "applied", usedModel: true)
        } catch Failure.timeout {
            return Result(filtered: ranked, verdicts: [:], considered: considered,
                          status: "fallback-timeout", usedModel: false)
        } catch Failure.malformedJSON {
            return Result(filtered: ranked, verdicts: [:], considered: considered,
                          status: "fallback-malformed-json", usedModel: false)
        } catch {
            return Result(filtered: ranked, verdicts: [:], considered: considered,
                          status: "fallback-error-\(String(describing: error).prefix(80))",
                          usedModel: false)
        }
    }

    private static func userPrompt(for candidates: [VernacularProfileReclaimedWord]) -> String {
        candidates.enumerated().map { index, item in
            let examples = item.examples.prefix(5).map { "\"\(cleanExample($0))\"" }
            let exampleText = examples.isEmpty ? "(no examples)" : examples.joined(separator: "; ")
            return "\(index + 1). \(item.surface) — \(exampleText)"
        }.joined(separator: "\n")
    }

    private static func cleanExample(_ example: String) -> String {
        let oneLine = example
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(140))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parseKeepSurfaces(_ raw: String) throws -> Set<String> {
        guard let lo = raw.firstIndex(of: "["),
              let hi = raw.lastIndex(of: "]"),
              lo <= hi,
              let data = String(raw[lo...hi]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw Failure.malformedJSON
        }
        let surfaces = array.compactMap { value -> String? in
            guard let string = value as? String else { return nil }
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return cleaned.isEmpty ? nil : cleaned
        }
        return Set(surfaces)
    }

    private static func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw Failure.timeout
            }
            guard let first = try await group.next() else { throw Failure.timeout }
            group.cancelAll()
            return first
        }
    }
}
