//
//  RomanticDetector.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  ────────────────────────────────────────────────────────────────────────
//  PURPOSE: ADVISORY ONLY. IT HIDES NOTHING. READ THIS BEFORE TOUCHING IT.
//  ────────────────────────────────────────────────────────────────────────
//  This detector identifies 1:1 relationships that look ROMANTIC (a current
//  or former partner) from their two-way message history. It is purely
//  ADVISORY: it produces a list of flagged contact names that the UI may
//  gently OFFER to hide ("you two were very close — hide from reminders &
//  nostalgia?"). It NEVER hides, suppresses, ranks, or labels anyone on its
//  own. The user decides.
//
//  Resurfacing an ex with a cheerful "say hi?" nudge is exactly the kind of
//  thing the user told us would be hurtful — but auto-hiding the wrong person
//  is also wrong. So the flow is: detector SUGGESTS → user confirms (the name
//  enters the user-controlled `hiddenFromNostalgia` set, which is what every
//  surface actually filters on) OR declines (we record it and never re-ask).
//  See `NostalgiaDismissals` (the persisted sets) and
//  `NostalgiaViewModel.suggestedHides`.
//
//  HARD RULES — do not violate:
//    • ADVISORY ONLY. This type NEVER mutates the hidden set and NEVER filters
//      any list. Its output is a suggestion the user must confirm.
//    • It NEVER promotes, surfaces, ranks, or labels anyone as "romantic" /
//      "your ex" anywhere in the UI or models. The suggestion-prompt copy the
//      UI shows must stay neutral ("very close" — never "ex/partner").
//    • The output is a `[String]` of flagged contact NAMES. Nothing about WHY
//      a name is flagged (the signals, the score) ever leaves this type.
//    • It is read-only and runs off the main thread.
//
//  Detection rule (VALIDATED against the user's real chat.db via the
//  `/tmp/romance` prototype — tuned to flag the user's known ex while leaving
//  affectionate platonic friends, who in this friend group commonly say
//  "babe" / use hearts / say "i love you", untouched):
//
//      reciprocalLove >= 5                       // heavy MUTUAL love-declaration
//      AND ( miss >= 10
//            OR goodnightRoutine >= 15
//            OR (hearts >= 25 AND babe >= 3) )
//
//  The reciprocalLove >= 5 gate is REQUIRED first. A standalone "my love >= 3"
//  path was REMOVED — it false-flagged a friend (Keeshant) who says "my love"
//  platonically (recipLove only 2). Goodnight-routine alone is NOT romantic
//  either (platonic friends rack up 28–50 goodnights); it only counts once the
//  reciprocal-love gate is already satisfied. The flag == this rule EXACTLY,
//  with NO reciprocal-love safety net and NO top-N-by-volume auto-exclusion.
//
//  Verified outcomes on real data: flags "Shreya Shirsathe" (recipLove 11,
//  miss 20, gn 65) and "Beck Peterson" (recipLove 5, miss 22, gn 90); does
//  NOT flag "Mason Funaki" (babe×12 but recipLove 1) or "Venkat Chitturi"
//  (babe×7 but recipLove 0) — both platonic. Keeshant (myLove×3, recipLove 2)
//  also stays platonic, which an earlier `myLove >= 3` rule got wrong.
//
//  The DB scan lives in `flaggedContactNames`; the term/emoji counting and
//  the romantic decision are PURE (`Signals`, `accumulate`, `isRomantic`) so
//  they're unit-testable without chat.db.
//

import Foundation

public enum RomanticDetector {

    /// Tunable thresholds. Defaults mirror the validated prototype rule.
    public struct Config: Sendable, Equatable {
        /// Minimum total 1:1 messages for a relationship to even be scored —
        /// keeps the scan to substantial relationships (matches the prototype's
        /// `>= 300` floor; a fling/acquaintance with a couple hundred messages
        /// can't reach the reciprocal-love gate anyway).
        public var minTotalMessages: Int = 300
        /// Hard gate: BOTH people must have said "I love you" at least this many
        /// times. This is the anchor that isolates real partners from
        /// affectionate friends.
        public var minReciprocalLove: Int = 5
        /// Corroborating-signal thresholds (any ONE, combined with the
        /// reciprocal-love gate, flags romantic).
        public var minMiss: Int = 10
        public var minGoodnight: Int = 15
        public var minHeartsForCombo: Int = 25
        public var minBabeForCombo: Int = 3

        public init() {}
    }

    /// Per-contact accumulated romantic signals over the full two-way history
    /// of a 1:1 chat. PURE value type — the counting (`accumulate`) and the
    /// decision (`isRomantic`) operate only on this, so both are testable with
    /// synthetic data.
    public struct Signals: Sendable, Equatable {
        public var total = 0
        /// Messages YOU sent containing an "I love you" variant.
        public var myLoveYou = 0
        /// Messages THEY sent containing an "I love you" variant.
        public var theirLoveYou = 0
        /// "my love" / "mi amor" / "sweetheart" / "darling" (either party).
        public var myLove = 0
        /// "goodnight" / "good night" / the word "gn".
        public var goodnight = 0
        /// "miss you" / "miss u" / "missing you".
        public var miss = 0
        /// Messages carrying a heart/kiss emoji or "<3".
        public var hearts = 0
        /// The words "babe" / "bae" / "baby" / "bby".
        public var babe = 0

        public init() {}

        /// min(yourCount, theirCount) of "I love you" — BOTH sides said it.
        public var reciprocalLove: Int { Swift.min(myLoveYou, theirLoveYou) }
    }

    // MARK: - Pure counting

    /// Fold one decoded message body into the running signals for a contact.
    /// `isFromMe` routes the "I love you" count to your side vs theirs. PURE.
    public static func accumulate(
        into signals: inout Signals,
        body: String,
        isFromMe: Bool
    ) {
        signals.total += 1
        let low = body.lowercased()

        let loveYou =
            low.contains("i love you") || low.contains("i love u")
            || low.contains("love you so") || low.contains("love u so")
            || low.contains("luv u") || wordPresent(low, "ily")
        if loveYou {
            if isFromMe { signals.myLoveYou += 1 } else { signals.theirLoveYou += 1 }
        }
        if wordPresent(low, "babe") || wordPresent(low, "bae")
            || wordPresent(low, "baby") || wordPresent(low, "bby") {
            signals.babe += 1
        }
        if low.contains("my love") || low.contains("mi amor")
            || wordPresent(low, "sweetheart") || wordPresent(low, "darling") {
            signals.myLove += 1
        }
        if low.contains("miss you") || low.contains("miss u") || low.contains("missing you") {
            signals.miss += 1
        }
        if containsHeart(body) {
            signals.hearts += 1
        }
        if low.contains("goodnight") || low.contains("good night") || wordPresent(low, "gn") {
            signals.goodnight += 1
        }
    }

    /// The romantic decision. PURE — depends only on the accumulated signals
    /// and the config. See the file header for the rationale + validated
    /// outcomes.
    public static func isRomantic(_ s: Signals, config: Config = Config()) -> Bool {
        guard s.reciprocalLove >= config.minReciprocalLove else { return false }
        if s.miss >= config.minMiss { return true }
        if s.goodnight >= config.minGoodnight { return true }
        if s.hearts >= config.minHeartsForCombo && s.babe >= config.minBabeForCombo { return true }
        return false
    }

    /// Reduce a per-contact signal map to the SORTED FLAGGED NAMES. PURE — the
    /// DB adapter (`RomanticDetector+DB`) builds the map, this applies the
    /// thresholds. Split out so the decision logic is testable without GRDB.
    public static func flagged(
        from byContact: [String: Signals],
        config: Config = Config()
    ) -> [String] {
        var flagged: [String] = []
        for (name, sig) in byContact {
            guard sig.total >= config.minTotalMessages else { continue }
            if isRomantic(sig, config: config) {
                flagged.append(name)
            }
        }
        // Sorted for deterministic suggestion ordering.
        return flagged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Text helpers (ported from the validated prototype)

    /// Crude word-boundary containment — `word` appears in `lowercasedBody`
    /// not flanked by letters. Catches "gn" / "ily" / "babe" as standalone
    /// words without matching "begin" / "family" / "babies". Mirrors the
    /// prototype's `wordIn`. Expects `lowercasedBody` already lowercased.
    static func wordPresent(_ lowercasedBody: String, _ word: String) -> Bool {
        guard !word.isEmpty, let r = lowercasedBody.range(of: word) else { return false }
        let beforeIsLetter: Bool
        if r.lowerBound == lowercasedBody.startIndex {
            beforeIsLetter = false
        } else {
            let c = lowercasedBody[lowercasedBody.index(before: r.lowerBound)]
            beforeIsLetter = c.isLetter
        }
        let afterIsLetter: Bool
        if r.upperBound == lowercasedBody.endIndex {
            afterIsLetter = false
        } else {
            afterIsLetter = lowercasedBody[r.upperBound].isLetter
        }
        return !beforeIsLetter && !afterIsLetter
    }

    /// True if the string carries a heart/kiss emoji or the "<3" ASCII heart.
    /// Scalar set mirrors the validated prototype's `hasHeart`.
    static func containsHeart(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x2764,            // ❤
                 0x2763,            // ❣
                 0x1F495,           // 💕
                 0x1F496,           // 💖
                 0x1F497,           // 💗
                 0x1F498,           // 💘
                 0x1F49A,           // 💚
                 0x1F49B,           // 💛
                 0x1F49C,           // 💜
                 0x1F49D,           // 💝
                 0x1F49E,           // 💞
                 0x1F49F,           // 💟
                 0x1F970,           // 🥰
                 0x1F60D,           // 😍
                 0x1F618,           // 😘
                 0x1F617,           // 😗
                 0x1F61A,           // 😚
                 0x1F963,           // 🥣 (kept to match prototype's set)
                 0x1F979:           // 🥹
                return true
            default:
                break
            }
        }
        return s.contains("<3")
    }
}
