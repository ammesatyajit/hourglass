//
//  VernacularViewModel.swift
//  Hourglass — Vernacular Analysis
//
//  Drives `VernacularPage`. Owns the async lifecycle, caches the decoded corpus
//  for lazy per-person profile queries, and publishes the new Phase-1 profile
//  plus profile-backed spread overlay. The old parallel transmission/sense
//  unification path has been removed.
//

import Foundation
import Observation
import os

@MainActor
@Observable
public final class VernacularViewModel {

    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded(VernacularInsights)
        case failed(String)
        case empty
    }

    public private(set) var state: LoadState = .idle
    /// New unified Phase-1 profile. Nil unless the additive profile engine was
    /// enabled for this load (`vernacular.profile.enabled`) and produced output.
    public private(set) var profile: VernacularProfile?
    /// Additive profile-word spread summary for the Vocabulary lens chip bar.
    public private(set) var spreadProfile: SpreadProfile?
    /// Lazy per-person influence payload for the currently pinned graph person.
    public private(set) var pinnedInfluence: PersonInfluence?
    /// REACTED GEMS ("funny") — odd phrases of yours that made people LAUGH
    /// (😂 / assoc_type 2003 from others — NOT love/emphasize), URL + coordination
    /// excluded, ranked by laugh-rate (Fix #1). Populated in the same Phase-1
    /// pass. Nil until first load. Sorted by laugh-rate desc.
    public private(set) var reactedGems: [ReactedGem]?
    /// EMPHATIC CONSTRUCTIONS — the user's SHOUTED-for-emphasis words (Fix #3),
    /// case-sensitive over original-case sent text. De-noised (pronoun /
    /// sentence-initial false-positives like WE/OH/YOU/NO/ALL dropped); every
    /// item's `examples.first` contains the shouted word. Populated in the same
    /// Phase-1 pass. Nil until first load. Sorted by shouted-count (times-sent)
    /// DESC — the uniform order across every category.
    public private(set) var emphaticConstructions: [EmphaticItem]?
    /// NON-CAPS emphasis devices — word ELONGATION ("soooo") + repeated
    /// PUNCTUATION ("!!!"/"???"). Generalizes "how you emphasize" so a user who
    /// never shouts in caps still gets signal. Populated in the same Phase-1
    /// pass. Nil until first load. Sorted by count (sent messages) DESC.
    public private(set) var emphasisSignals: [EmphasisSignal]?
    /// DISCOVERED VOCABULARY — distinctive single tokens the user actually sends
    /// (clippings + slang + internet-speak), DISCOVERED from their own text (not
    /// a curated lexicon): tokens sent ≥N times that are NOT standard-English
    /// dictionary words and NOT contact-name fragments. The unified ranked list;
    /// `abbreviations` + `slangUsed` are a transparent length split of it. All
    /// ordered by times-sent DESC. Populated in the same Phase-1 pass. Nil until
    /// first load.
    public private(set) var distinctiveTokens: [VocabItem]?
    /// Clipping-shaped discovered vocab (short shorthand: u/ur/abt/rlly/ngl…),
    /// ordered by times-sent DESC. A length split of `distinctiveTokens`.
    public private(set) var abbreviations: [VocabItem]?
    /// Longer discovered slang (hella/deadass/lowkey/crashout…), ordered by
    /// times-sent DESC. A length split of `distinctiveTokens`.
    public private(set) var slangUsed: [VocabItem]?
    /// SHARED IN-GROUP VOCABULARY — the slang you AND ≥4 friends ALL use (the
    /// group dialect), distinct from `distinctiveTokens` (YOUR personal vocab)
    /// and the trade `graph` (1:1 hand-off). Each `SharedTerm` carries
    /// `peopleCount` (share width), `totalUses`, `yourUses`, and `topUsers` (top
    /// contacts by count). Ranked by `peopleCount` DESC (most widely shared
    /// first). Curated slang lexicon ∩ usage — NOT open discovery. Populated in
    /// the SAME off-main Phase-1 pass (pure stats, NOT gated behind the AI
    /// labeler). Nil until first load.
    public private(set) var sharedVocabulary: [SharedTerm]?
    /// VIBE / DIALECT CLUSTERS — your contacts (incl. "You") grouped by HOW they
    /// text: a per-contact ~47-feature vernacular fingerprint (slang/abbrev
    /// presence + style) reduced to k=6 deterministic k-means clusters. Built
    /// from a FOCUSED 1:1-only (chat.style=45) chat.db read in the SAME off-main
    /// pass as the insights — pure stats, NOT gated behind the AI labeler. Each
    /// cluster's `label` is its top defining markers (e.g. "hella · ong · bro").
    /// Nil until first load; nil/empty if too few contacts clear the 300-msg gate.
    public private(set) var vibeClusters: [VibeCluster]?
    /// Per-contact lookup: contact DISPLAY NAME (incl. "You") → vibe cluster id.
    /// Keyed by the same display name `GraphNode.displayName` carries, so the
    /// social graph can color a node by matching its `displayName`. Populated in
    /// the same off-main pass; nil until first load.
    public private(set) var vibeClusterByContact: [String: Int]?
    /// Retained for existing UI bindings; the old Phase-2 label path is purged,
    /// so these stay false on the profile-backed path.
    public private(set) var aiLabelsApplied = false
    public private(set) var aiLabeling = false
    public private(set) var usedPlaceholderBaseline = false

    private let database: ChatDatabase?
    private let contacts: ResolvedContacts?
    private let maxMessages: Int
    private var generation = 0
    private var cachedMessages: [VernacularMessage] = []
    private var cachedContacts: ResolvedContacts?
    private var cachedBaseline: LinguisticBaseline?
    private var cachedChatParticipants: [Int64: Set<String>] = [:]
    private var cachedTokenizedCorpus: VernacularTokenizedCorpus?
    private var influenceCache: [String: PersonInfluence] = [:]
    private var pendingInfluencePerson: String?

    private static let logger = Logger(subsystem: "com.satyajit.hourglass", category: "Vernacular")

    public init(
        database: ChatDatabase?,
        contacts: ResolvedContacts?,
        maxMessages: Int = 1_000_000,
        labelerProvider: @escaping @Sendable () -> (any VernacularAILabeling)? = { nil },
        vectorizerProvider: @escaping @Sendable () -> (any ContextVectorizing) = { NLContextEmbedder() }
    ) {
        self.database = database
        self.contacts = contacts
        self.maxMessages = maxMessages
        _ = labelerProvider
        _ = vectorizerProvider
    }

    /// Idempotent — safe to call from `.task`/`.onAppear`.
    public func loadIfNeeded() {
        guard case .idle = state else { return }
        guard let database else { state = .failed("Database unavailable"); return }
        // Contacts are needed for attribution naming; without them we still
        // run, attributing to the unknown sentinel (which the decisive rule
        // excludes), so the statistical sections still populate.
        let contacts = self.contacts ?? ResolvedContacts(byHandle: [:], allContacts: [])
        state = .loading
        let myGen = generation &+ 1
        generation = myGen
        let cap = maxMessages

        Task.detached(priority: .utility) { [weak self] in
            let baseline = LinguisticBaseline.load()
            do {
                // ONE chat.db read + ONE decode feeds EVERYTHING — insights,
                // graph, sections, discovered vocab, emphasis signals, AND the
                // vibe clustering (derived from the same in-memory corpus, no
                // second 1:1-only read/decode). This is the SPEED win. We hold
                // `messages` LOCAL to this detached task (never on the MainActor
                // VM) so the Phase-2 frame attribution can reuse the SAME corpus
                // — and it's freed when this task ends.
                let messages = try VernacularLoader.loadMessages(
                    database: database, contacts: contacts, maxMessages: cap)
                let oooContact = (try? VibeLoader.oneOnOneContactMap(
                    database: database, contacts: contacts)) ?? [:]
                let chatParticipants = (try? VernacularLoader.chatParticipantsMap(
                    database: database, contacts: contacts)) ?? [:]
                let profileConfig = VernacularConfig.fromUserDefaults()
                let all = VernacularLoader.buildAllSections(
                    messages: messages, contacts: contacts, baseline: baseline,
                    oneOnOneContact: oooContact, chatParticipants: chatParticipants,
                    profileConfig: profileConfig)
                _ = await self?.applyPhase1(
                    all, placeholder: baseline.isPlaceholder, generation: myGen,
                    messages: messages, contacts: contacts, baseline: baseline,
                    chatParticipants: chatParticipants)
            } catch {
                await self?.fail(error.localizedDescription, generation: myGen)
            }
        }
    }

    /// Lazily build the clicked person's profile/influence panel from the
    /// already-loaded corpus. V1 intentionally does this on demand; a shared
    /// all-speaker substrate can replace the cached-corpus path later.
    public func personInfluence(for name: String) {
        let person = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !person.isEmpty else {
            pinnedInfluence = nil
            return
        }
        if let cached = influenceCache[person] {
            pendingInfluencePerson = person
            pinnedInfluence = cached
            return
        }
        guard let you = profile, you.isEnabled, you.subject.isYou,
              let contacts = cachedContacts, let baseline = cachedBaseline,
              !cachedMessages.isEmpty else {
            pendingInfluencePerson = person
            pinnedInfluence = .empty(person: person)
            return
        }

        pendingInfluencePerson = person
        pinnedInfluence = nil
        let messages = cachedMessages
        let chatParticipants = cachedChatParticipants
        let tokenized = cachedTokenizedCorpus
        let generation = self.generation
        Task.detached(priority: .utility) { [weak self, messages, contacts, baseline, chatParticipants, tokenized, you] in
            let influence: PersonInfluence = autoreleasepool {
                let config = VernacularConfig.fromUserDefaults()
                let cache = config.useTokenizedCorpus ? tokenized : nil
                let them = VernacularEngine.buildProfile(
                    messages: messages,
                    baseline: baseline,
                    contacts: contacts,
                    subject: .contact(person),
                    config: config,
                    tokenized: cache
                )
                return VernacularAnalyzer.personInfluence(
                    person: person,
                    you: you,
                    them: them,
                    messages: messages,
                    baseline: baseline,
                    config: config,
                    chatParticipants: chatParticipants
                )
            }
            await MainActor.run {
                guard let self, self.generation == generation,
                      self.pendingInfluencePerson == person else { return }
                self.influenceCache[person] = influence
                self.pinnedInfluence = influence
            }
        }
    }

    public func reload() {
        state = .idle
        profile = nil
        spreadProfile = nil
        pinnedInfluence = nil
        reactedGems = nil
        emphaticConstructions = nil
        emphasisSignals = nil
        distinctiveTokens = nil
        abbreviations = nil
        slangUsed = nil
        sharedVocabulary = nil
        vibeClusters = nil
        vibeClusterByContact = nil
        cachedMessages = []
        cachedContacts = nil
        cachedBaseline = nil
        cachedChatParticipants = [:]
        cachedTokenizedCorpus = nil
        influenceCache = [:]
        pendingInfluencePerson = nil
        aiLabelsApplied = false
        aiLabeling = false
        loadIfNeeded()
    }

    // MARK: - publish

    /// Publish every profile-backed surface. Returns true iff `.loaded` was set
    /// (i.e. the categorized insights are non-empty).
    @discardableResult
    private func applyPhase1(_ all: VernacularLoader.AllSections,
                             placeholder: Bool, generation: Int,
                             messages: [VernacularMessage] = [],
                             contacts: ResolvedContacts? = nil,
                             baseline: LinguisticBaseline? = nil,
                             chatParticipants: [Int64: Set<String>] = [:]) -> Bool {
        guard generation == self.generation else { return false }
        let insights = all.insights
        usedPlaceholderBaseline = placeholder
        if all.profile.isEnabled {
            self.cachedMessages = messages
            self.cachedContacts = contacts
            self.cachedBaseline = baseline
            self.cachedChatParticipants = chatParticipants
            self.cachedTokenizedCorpus = all.tokenizedCorpus
        } else {
            self.cachedMessages = []
            self.cachedContacts = nil
            self.cachedBaseline = nil
            self.cachedChatParticipants = [:]
            self.cachedTokenizedCorpus = nil
        }
        self.influenceCache = [:]
        self.pendingInfluencePerson = nil
        self.pinnedInfluence = nil
        self.profile = all.profile.isEnabled ? all.profile : nil
        self.spreadProfile = all.spreadProfile.isEmpty ? nil : all.spreadProfile
        self.reactedGems = all.reactedGems
        self.emphaticConstructions = all.emphaticConstructions
        self.emphasisSignals = all.emphasisSignals.isEmpty ? nil : all.emphasisSignals
        self.distinctiveTokens = all.discoveredVocab.isEmpty ? nil : all.discoveredVocab
        self.abbreviations = all.abbreviations.isEmpty ? nil : all.abbreviations
        self.slangUsed = all.slangUsed.isEmpty ? nil : all.slangUsed
        self.sharedVocabulary = all.sharedVocabulary.isEmpty ? nil : all.sharedVocabulary
        // VIBE clusters (derived from the same corpus): publish whenever
        // clustering produced any (independent of `insights.isEmpty`); leave nil
        // when the gate left us with too few contacts so the UI can hide the
        // dialect coloring gracefully.
        let vibe = all.vibe
        self.vibeClusters = vibe.clusters.isEmpty ? nil : vibe.clusters
        self.vibeClusterByContact = vibe.clusterIdByContact.isEmpty ? nil : vibe.clusterIdByContact
        guard !insights.isEmpty else { state = .empty; return false }
        state = .loaded(insights)
        aiLabeling = false
        Self.logger.debug("Vernacular: profile-backed Phase-1 results loaded")
        return true
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        state = .failed(message)
    }
}
