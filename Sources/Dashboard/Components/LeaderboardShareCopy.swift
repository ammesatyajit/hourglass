//
//  LeaderboardShareCopy.swift
//  Hourglass — Dashboard components
//

import Foundation

/// Pure copy builder for Overview leaderboard shares. Kept outside the view so
/// ordinal grammar and the exact public URL are deterministic and testable.
enum LeaderboardShareCopy {
    enum Kind {
        case person
        case groupChat
    }

    static let hourglassURL = "https://ammesatyajit.github.io/hourglass/"

    static func message(rank: Int, kind: Kind, timeframe: String) -> String {
        let ranking = ordinal(max(1, rank))
        let sentence: String
        switch kind {
        case .person:
            sentence = "you were my \(ranking) most texted person of \(timeframe) :)"
        case .groupChat:
            sentence = "yall were my \(ranking) most texted group chat of \(timeframe) :)"
        }
        return "\(sentence)\n\n\(hourglassURL)"
    }

    static func ordinal(_ number: Int) -> String {
        let value = max(1, number)
        let lastTwo = value % 100
        let suffix: String
        if 11...13 ~= lastTwo {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }
}
