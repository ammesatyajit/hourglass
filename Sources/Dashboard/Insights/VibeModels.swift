//
//  VibeModels.swift
//  Hourglass — Vernacular Analysis (VIBE / dialect clustering)
//
//  Clusters the user's contacts by HOW they text — a per-contact "vernacular
//  fingerprint" over ~47 features (40 slang/abbreviation presence-rates + 7
//  style features) reduced to k=6 dialect clusters via deterministic k-means.
//
//  Faithful Swift port of the VALIDATED prototype `/tmp/vibe/main.swift` (run
//  against the real chat.db). The prototype's ground-truth (60 people, 47
//  features, k=6) is the contract this port reproduces EXACTLY:
//    - same slang list + style features, same rate math (avg-len normalized
//      by /60 and capped at 2.0),
//    - z-normalize each feature across the contact set,
//    - k-means k=6 with DETERMINISTIC farthest-point seeding (no RNG — the
//      first centroid is X[0], each next is the point maximizing its min
//      distance to the chosen centroids), 30 Lloyd iterations.
//
//  PURE: `VibeClusterer.cluster(messagesByContact:)` is a deterministic
//  function of its input. The chat.db read (a focused 1:1 / chat.style=45
//  query) lives in `VibeLoader`; this file does no I/O.
//
//  The per-contact lookup `clusterIdByContact` is keyed by the contact DISPLAY
//  NAME — the same string `VernacularLoader.resolveWho` produces for received
//  messages and `GraphNode.displayName` carries — so the social graph can color
//  a node by matching its `displayName`. "You" participates in the clustering
//  (it has its own fingerprint) and gets an entry in the lookup too.
//

import Foundation

// MARK: - Public Sendable result types

/// One dialect cluster: a group of contacts who text alike. `label` is built
/// from the cluster's top defining markers (highest mean z within the cluster),
/// e.g. "hella · cuz · bet"; `markers` are the top ~4 feature names; `memberNames`
/// are the contact display names in the cluster (sorted closest-to-centroid
/// first, matching the prototype's member ordering).
public struct VibeCluster: Identifiable, Sendable, Equatable {
    public let id: Int
    /// Human-readable label from the top defining markers, "·"-joined.
    public let label: String
    /// Top ~4 defining feature names (style features de-underscored, e.g.
    /// "len"/"emoji"/"laugh"; slang tokens as-is, e.g. "hella").
    public let markers: [String]
    /// Contact display names in this cluster, closest-to-centroid first.
    public let memberNames: [String]

    public init(id: Int, label: String, markers: [String], memberNames: [String]) {
        self.id = id
        self.label = label
        self.markers = markers
        self.memberNames = memberNames
    }
}

/// The full result of a vibe-clustering pass: the clusters plus a flat lookup
/// from contact display name → cluster id (so callers can color a node without
/// scanning `memberNames`). Both keyed/labeled by display name, including "You".
public struct VibeClustering: Sendable, Equatable {
    public let clusters: [VibeCluster]
    /// Contact display name → cluster id. Includes "You".
    public let clusterIdByContact: [String: Int]
    /// How many contacts were fingerprinted (passed the min-message gate).
    public let fingerprintedCount: Int

    public init(clusters: [VibeCluster], clusterIdByContact: [String: Int],
                fingerprintedCount: Int) {
        self.clusters = clusters
        self.clusterIdByContact = clusterIdByContact
        self.fingerprintedCount = fingerprintedCount
    }

    public static let empty = VibeClustering(clusters: [], clusterIdByContact: [:],
                                             fingerprintedCount: 0)
}

// MARK: - Per-contact raw aggregate (the loader fills this; the builder consumes it)

/// Raw per-contact tallies over their 1:1 messages, exactly the prototype's
/// `Agg`. The loader accumulates these (one per contact display name, plus
/// "You"); the pure builder turns them into feature vectors. `Sendable` value
/// type so the corpus can cross to a detached analysis task.
public struct VibeAggregate: Sendable, Equatable {
    public var messageCount: Int
    public var totalChars: Int
    public var lowercaseMessages: Int
    public var emojiMessages: Int
    public var exclaimMessages: Int
    public var questionMessages: Int
    public var laughMessages: Int
    public var stretchMessages: Int
    /// slang token → # of messages containing it (presence, not frequency).
    public var slangPresence: [String: Int]

    public init(messageCount: Int = 0, totalChars: Int = 0, lowercaseMessages: Int = 0,
                emojiMessages: Int = 0, exclaimMessages: Int = 0, questionMessages: Int = 0,
                laughMessages: Int = 0, stretchMessages: Int = 0,
                slangPresence: [String: Int] = [:]) {
        self.messageCount = messageCount
        self.totalChars = totalChars
        self.lowercaseMessages = lowercaseMessages
        self.emojiMessages = emojiMessages
        self.exclaimMessages = exclaimMessages
        self.questionMessages = questionMessages
        self.laughMessages = laughMessages
        self.stretchMessages = stretchMessages
        self.slangPresence = slangPresence
    }

    /// Fold one message body into the tallies (the prototype's `update`). Body
    /// is the ORIGINAL-CASE trimmed message text (URL messages already excluded
    /// by the caller).
    public mutating func add(body: String) {
        messageCount += 1
        totalChars += body.count
        let low = body.lowercased()
        // lowercase rate: the message is all-lowercase AND has a letter.
        if body == low && body.contains(where: { $0.isLetter }) { lowercaseMessages += 1 }
        if VibeFeatures.emojiCount(body) > 0 { emojiMessages += 1 }
        if body.contains("!") { exclaimMessages += 1 }
        if body.contains("?") { questionMessages += 1 }
        if low.contains("lol") || low.contains("lmao") || low.contains("haha")
            || low.contains("lmfao") || body.contains("\u{1F480}") || body.contains("\u{1F62D}") {
            laughMessages += 1
        }
        if VibeFeatures.hasStretch(body) { stretchMessages += 1 }
        let w = VibeFeatures.wordSet(body)
        for t in VibeFeatures.slang where w.contains(t) { slangPresence[t, default: 0] += 1 }
    }
}

// MARK: - Feature definitions + primitives (ported verbatim from /tmp/vibe)

/// The fixed feature space + the body primitives that define it. Kept as a
/// standalone enum so it's trivially testable and shared between the loader's
/// accumulation and the pure builder's vectorization.
public enum VibeFeatures {

    /// The 40 slang / abbreviation tokens, presence-rate per contact. Order is
    /// load-bearing: it fixes the feature-vector layout (and thus the cluster
    /// seeding), so it must match the prototype exactly.
    public static let slang: [String] = [
        "u", "ur", "tho", "rn", "lmk", "abt", "smth", "cuz", "cos", "prob",
        "def", "lemme", "ima", "idk", "hella", "deadass", "lowkey", "lowk",
        "lock", "cooked", "crashout", "fr", "ngl", "tbh", "icl", "ts", "yuh",
        "bro", "bruh", "lil", "nah", "fam", "bet", "alr", "fs", "gng", "twin",
        "wyd", "sm", "ong",
    ]

    /// The 7 style features, in vector order AFTER the slang block. Underscore-
    /// prefixed names match the prototype (the label builder strips the "_").
    public static let styleFeatures: [String] = [
        "_len", "_lower", "_emoji", "_excl", "_ques", "_laugh", "_stretch",
    ]

    /// All 47 feature names in vector order (slang block then style block).
    public static let all: [String] = slang + styleFeatures

    /// Display name for a feature (style features de-underscored). Used to build
    /// cluster labels/markers.
    public static func displayName(_ feature: String) -> String {
        feature.hasPrefix("_") ? String(feature.dropFirst()) : feature
    }

    /// Lowercased letter/apostrophe word SET (the prototype's `words`). Only `'`
    /// is a word char here (the slang tokens are letters-only, so this is
    /// equivalent to the engine's tokenizer for the presence check).
    public static func wordSet(_ s: String) -> Set<String> {
        var out = Set<String>()
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch == "'" {
                cur.append(ch)
            } else {
                if !cur.isEmpty { out.insert(cur) }
                cur = ""
            }
        }
        if !cur.isEmpty { out.insert(cur) }
        return out
    }

    /// Count of emoji-ish scalars (the prototype's `emojiCount`): any scalar
    /// above U+1F000, or in the U+2600…U+27BF misc-symbols/dingbats band.
    public static func emojiCount(_ s: String) -> Int {
        var c = 0
        for u in s.unicodeScalars {
            if u.value > 0x1F000 || (0x2600...0x27BF).contains(Int(u.value)) { c += 1 }
        }
        return c
    }

    /// True if the body has a run of ≥3 of the SAME letter (the prototype's
    /// `hasStretch` — "sooo", "ahhh"). Case-insensitive.
    public static func hasStretch(_ s: String) -> Bool {
        var run = 1
        var prev: Character? = nil
        for ch in s.lowercased() {
            if ch == prev {
                run += 1
                if run >= 3 && ch.isLetter { return true }
            } else {
                run = 1
            }
            prev = ch
        }
        return false
    }

    /// Build the 47-d feature vector from a contact's aggregate (the prototype's
    /// `vec`). Slang features are presence-rates (msgs-containing / msgs); style
    /// features are the prototype's exact derivations (avg-len normalized by /60
    /// and capped at 2.0; the rest are per-message rates).
    public static func vector(_ a: VibeAggregate) -> [Double] {
        let n = Double(max(a.messageCount, 1))
        var v = slang.map { Double(a.slangPresence[$0] ?? 0) / n }
        v.append(min(Double(a.totalChars) / n / 60.0, 2.0))   // _len
        v.append(Double(a.lowercaseMessages) / n)             // _lower
        v.append(Double(a.emojiMessages) / n)                 // _emoji
        v.append(Double(a.exclaimMessages) / n)               // _excl
        v.append(Double(a.questionMessages) / n)              // _ques
        v.append(Double(a.laughMessages) / n)                 // _laugh
        v.append(Double(a.stretchMessages) / n)               // _stretch
        return v
    }
}

// MARK: - Pure clusterer

/// The pure k-means dialect clusterer. Deterministic (no RNG): identical input
/// → identical clusters across runs and machines.
public enum VibeClusterer {

    /// Tunables. Defaults match the validated prototype.
    public struct Options: Sendable {
        /// A contact must have ≥ this many 1:1 messages to be fingerprinted.
        public var minMessages: Int
        /// Number of dialect clusters.
        public var k: Int
        /// Lloyd iterations.
        public var iterations: Int
        /// How many top markers define a cluster's label.
        public var labelMarkerCount: Int

        public init(minMessages: Int = 300, k: Int = 6, iterations: Int = 30,
                    labelMarkerCount: Int = 4) {
            self.minMessages = minMessages
            self.k = k
            self.iterations = iterations
            self.labelMarkerCount = labelMarkerCount
        }

        public static let `default` = Options()
    }

    /// Cluster contacts by their vernacular fingerprint. `messagesByContact` maps
    /// a contact display name (incl. "You") to their accumulated `VibeAggregate`
    /// over their 1:1 messages. Returns `.empty` if fewer than `k` contacts clear
    /// the `minMessages` gate (k-means is undefined otherwise). PURE.
    public static func cluster(
        messagesByContact: [String: VibeAggregate],
        options: Options = .default
    ) -> VibeClustering {
        // Build (name, vector) for contacts clearing the gate. SORT by name so
        // the row order — and therefore the farthest-point seed (which starts at
        // X[0]) — is deterministic regardless of dictionary iteration order.
        let kept = messagesByContact
            .filter { $0.value.messageCount >= options.minMessages }
            .sorted { $0.key < $1.key }
        let names = kept.map { $0.key }
        var X = kept.map { VibeFeatures.vector($0.value) }
        let N = names.count
        let D = VibeFeatures.all.count
        guard N >= options.k, N > 0 else { return .empty }

        // z-normalize each feature across the contact set (population sd, +eps).
        for j in 0..<D {
            let column = X.map { $0[j] }
            let mean = column.reduce(0, +) / Double(N)
            let sd = (column.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(N)).squareRoot() + 1e-9
            for i in 0..<N { X[i][j] = (X[i][j] - mean) / sd }
        }

        func dist(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for k in 0..<a.count { let d = a[k] - b[k]; s += d * d }
            return s
        }

        // Deterministic farthest-point seeding: c0 = X[0]; each next centroid is
        // the point maximizing its MIN distance to the already-chosen centroids.
        var centroids: [[Double]] = [X[0]]
        while centroids.count < options.k {
            var best = 0
            var bestD = -1.0
            for i in 0..<N {
                let dmin = centroids.map { dist(X[i], $0) }.min() ?? 0
                if dmin > bestD { bestD = dmin; best = i }
            }
            centroids.append(X[best])
        }

        // Lloyd iterations.
        var assign = [Int](repeating: 0, count: N)
        for _ in 0..<options.iterations {
            for i in 0..<N {
                var bc = 0
                var bd = Double.greatestFiniteMagnitude
                for c in 0..<options.k {
                    let d = dist(X[i], centroids[c])
                    if d < bd { bd = d; bc = c }
                }
                assign[i] = bc
            }
            for c in 0..<options.k {
                let members = (0..<N).filter { assign[$0] == c }
                if members.isEmpty { continue }
                var nc = [Double](repeating: 0, count: D)
                for i in members { for k in 0..<D { nc[k] += X[i][k] } }
                for k in 0..<D { nc[k] /= Double(members.count) }
                centroids[c] = nc
            }
        }

        // Materialize clusters: defining markers = highest mean-z within the
        // cluster; members sorted closest-to-centroid first (prototype order).
        var clusters: [VibeCluster] = []
        var byContact: [String: Int] = [:]
        for c in 0..<options.k {
            let members = (0..<N).filter { assign[$0] == c }
            if members.isEmpty { continue }
            var meanZ = [Double](repeating: 0, count: D)
            for i in members { for k in 0..<D { meanZ[k] += X[i][k] } }
            for k in 0..<D { meanZ[k] /= Double(members.count) }
            let topFeatures = (0..<D)
                .sorted { meanZ[$0] > meanZ[$1] }
                .prefix(options.labelMarkerCount)
                .map { VibeFeatures.displayName(VibeFeatures.all[$0]) }
            let orderedMembers = members
                .sorted { dist(X[$0], centroids[c]) < dist(X[$1], centroids[c]) }
                .map { names[$0] }
            for name in orderedMembers { byContact[name] = c }
            clusters.append(VibeCluster(
                id: c,
                label: topFeatures.joined(separator: " \u{00B7} "),   // " · "
                markers: Array(topFeatures),
                memberNames: orderedMembers))
        }
        return VibeClustering(clusters: clusters, clusterIdByContact: byContact,
                              fingerprintedCount: N)
    }
}
