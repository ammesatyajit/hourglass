//
//  VernacularSubject.swift
//  Hourglass - Unified Vernacular Profile
//

import Foundation

/// Whose visible chat language Phase 1 is profiling.
///
/// Data caveat for `.contact`: chat.db only contains conversations involving
/// the device owner. For a non-you subject, the profile covers that person's
/// messages as they appear in the user's 1:1 and shared group chats; it is not
/// that person's complete message history.
public enum VernacularSubject: Sendable, Equatable {
    case you
    case contact(String)

    public var displayName: String {
        switch self {
        case .you: return "You"
        case .contact(let name): return name
        }
    }

    public var isYou: Bool {
        if case .you = self { return true }
        return false
    }

    var idComponent: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ":", with: "_")
    }

    public static func fromDisplayName(_ raw: String?) -> VernacularSubject {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .you }
        if trimmed.caseInsensitiveCompare("you") == .orderedSame {
            return .you
        }
        return .contact(trimmed)
    }

    func isSpeaker(_ message: VernacularMessage) -> Bool {
        switch self {
        case .you:
            return message.fromMe
        case .contact(let name):
            return !message.fromMe && message.who.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}

struct VernacularSubjectContext: Sendable, Equatable {
    let subject: VernacularSubject
    let subjectChats: Set<Int64>
    let subjectMessageCount: Int
    let worldMessageCount: Int
    let otherMessageCount: Int
    let activeWorldChats: Int
    let activeWorldMonths: Int
    let activeSubjectDays: Int
    let activeSubjectChats: Int

    var visibleCorpusCaveat: String? {
        subject.isYou ? nil : "Contact profile is limited to this person's messages visible in the user's chat.db."
    }

    static func build(messages: [VernacularMessage], subject: VernacularSubject) -> VernacularSubjectContext {
        var subjectChats = Set<Int64>()
        var subjectMessageCount = 0
        var subjectDays = Set<Int>()
        var subjectActiveChats = Set<Int64>()

        for message in messages where !message.isPoll && !message.bodyLow.contains("http") && !message.words.isEmpty {
            if subject.isSpeaker(message) {
                subjectMessageCount += 1
                subjectChats.insert(message.chat)
                subjectDays.insert(dayKey(message.date))
                subjectActiveChats.insert(message.chat)
            }
        }

        if subject.isYou {
            for message in messages where !message.isPoll && !message.bodyLow.contains("http") && !message.words.isEmpty {
                subjectChats.insert(message.chat)
            }
        }

        var worldMessageCount = 0
        var otherMessageCount = 0
        var worldChats = Set<Int64>()
        var worldMonths = Set<Int>()

        for message in messages where !message.isPoll && !message.bodyLow.contains("http") && !message.words.isEmpty {
            guard subject.isYou || subjectChats.contains(message.chat) else { continue }
            worldMessageCount += 1
            worldChats.insert(message.chat)
            worldMonths.insert(monthKey(message.date))
            if !subject.isSpeaker(message) {
                otherMessageCount += 1
            }
        }

        return VernacularSubjectContext(
            subject: subject,
            subjectChats: subjectChats,
            subjectMessageCount: subjectMessageCount,
            worldMessageCount: worldMessageCount,
            otherMessageCount: otherMessageCount,
            activeWorldChats: worldChats.count,
            activeWorldMonths: worldMonths.count,
            activeSubjectDays: subjectDays.count,
            activeSubjectChats: subjectActiveChats.count
        )
    }

    func isSubjectMessage(_ message: VernacularMessage) -> Bool {
        subject.isSpeaker(message)
    }

    func isWorldMessage(_ message: VernacularMessage) -> Bool {
        subject.isYou || subjectChats.contains(message.chat)
    }

    func speakerLabel(_ message: VernacularMessage) -> String {
        message.fromMe ? "You" : message.who
    }

    static func dayKey(_ date: Double) -> Int {
        Int(floor(date / 86_400))
    }

    static func monthKey(_ date: Double) -> Int {
        let days = Int(floor(date / 86_400))
        return days / 30
    }
}
