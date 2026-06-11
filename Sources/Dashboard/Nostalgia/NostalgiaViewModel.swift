//
//  NostalgiaViewModel.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  Orchestrates every memory surface and the user-controlled hide model.
//
//  SURFACES
//    PER-CHAT TIMELINES (the current direction — DB-backed, detached):
//      • chatStories       ([ChatStory]) — per-conversation "notable moments"
//                          timelines (origin / longestConversation / biggestDay
//                          / peakReaction + group joins/leaves/renames). Built
//                          by `ChatStoryBuilder.loadStories`. Sorted by message
//                          count desc.
//      • onThisDayMoments  ([NotableMoment]) — EVENT-GATED anniversaries:
//                          only moments whose month/day == today (an origin's
//                          anniversary, a biggest-day on this date, a peak
//                          reaction on this date). Empty most days — correct.
//
//    LEGACY GENERIC SURFACES (still published so the not-yet-rebuilt
//    `NostalgiaPanel` compiles; the per-chat timelines SUPERSEDE these and the
//    design rebuild should retire them — see plans.md):
//      Pure (synchronous, from the all-time aggregate):
//        • dormantFriends  (DormancyDetector)
//        • milestones      (MilestonesBuilder)        [CUT — not in new UI]
//        • streaks         (StreakDetector)           [CUT — replaced by
//                                                       longestConversation]
//        • eras            (EraDetector)              [CUT — not in new UI]
//      DB-backed (detached):
//        • beloved         (BelovedMessagesLoader)    [folded into peakReaction]
//        • onThisDay       (OnThisDayLoader)          [superseded by
//                                                       onThisDayMoments]
//        • firstMessages   (FirstMessageLoader)       [folded into origin]
//        • funnyMoments    (FunnyMomentsLoader)       [folded into peakReaction]
//
//  HIDE MODEL (sensitivity guardrail — the user stays in control):
//    `hiddenFromNostalgia` is the ONE persisted, user-controlled set that
//    actually suppresses people. EVERY surface above filters on it. The user
//    can `hide(_:)` ANYONE and `unhide(_:)` anyone — persisted to UserDefaults
//    via `NostalgiaDismissals`. Nothing is ever hidden automatically, and the
//    app never suggests hiding anyone (the old advisory prompt was removed in
//    0.3.1 — people surface naturally; manual hide handles the rest).
//

import Foundation
import Observation

@MainActor
@Observable
public final class NostalgiaViewModel {

    // MARK: - Published state (all already hidden-set filtered)

    /// PER-CHAT "notable moments" timelines — the chats worth reminiscing
    /// about, sorted by message count desc. The current primary surface.
    public private(set) var chatStories: [ChatStory] = []
    /// EVENT-GATED anniversaries for today (month/day == today). Empty most
    /// days — that's correct; it is NOT a raw dump of today's messages.
    public private(set) var onThisDayMoments: [NotableMoment] = []
    /// REKINDLE reminders — heavy 1:1 correspondents (upper-quartile by volume)
    /// you've gone quiet with for ≥1 month. Heaviest first. Obeys the SAME hide
    /// controls as every other surface: SUPPRESSED for anyone in
    /// `hiddenFromNostalgia`
    /// (no "say hi?" nudge for an ex). Built by `RekindleBuilder`.
    public private(set) var rekindleReminders: [RekindleReminder] = []

    // --- Legacy generic surfaces (kept so the old panel compiles) ---
    public private(set) var onThisDay: [OnThisDayMemory] = []
    public private(set) var beloved: [BelovedMessage] = []
    public private(set) var dormantFriends: [DormantFriend] = []
    public private(set) var milestones: [ContactMilestones] = []
    public private(set) var streaks: [Streak] = []
    public private(set) var firstMessages: [FirstMessage] = []
    public private(set) var eras: [Era] = []
    public private(set) var funnyMoments: [FunnyMoment] = []

    /// The user-controlled hidden set (resolved contact names / series keys).
    /// Observable so the UI reflects hides/un-hides live.
    public private(set) var hiddenFromNostalgia: Set<String> = []
    public private(set) var isLoading: Bool = false
    public private(set) var hasLoadedOnce: Bool = false
    /// Non-fatal error string (e.g. a loader threw). The panel degrades
    /// gracefully — sections that did load still render.
    public private(set) var loadError: String?

    // MARK: - Dependencies

    private let database: ChatDatabase
    private let contacts: ResolvedContacts
    private let aggregate: DashboardAllTimeAggregate
    private let dismissals: NostalgiaDismissals
    private let nowProvider: @Sendable () -> Date

    // MARK: - Unfiltered caches (so re-filtering after a hide is cheap)

    private var allChatStories: [ChatStory] = []
    private var allRekindle: [RekindleReminder] = []
    private var allOnThisDay: [OnThisDayMemory] = []
    private var allBeloved: [BelovedMessage] = []
    private var allDormant: [DormantFriend] = []
    private var allMilestones: [ContactMilestones] = []
    private var allStreaks: [Streak] = []
    private var allFirstMessages: [FirstMessage] = []
    private var allEras: [Era] = []
    private var allFunnyMoments: [FunnyMoment] = []

    private var generation = 0

    public init(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        aggregate: DashboardAllTimeAggregate,
        dismissals: NostalgiaDismissals = NostalgiaDismissals(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.contacts = contacts
        self.aggregate = aggregate
        self.dismissals = dismissals
        self.nowProvider = now
        self.hiddenFromNostalgia = dismissals.hiddenKeys()
    }

    // MARK: - Loading

    /// Kick off a full refresh. Pure detectors run immediately (synchronously,
    /// cheap) so dormancy / milestones / streaks / eras paint right away; the
    /// DB-backed loaders run detached and fill in after. Safe to call
    /// repeatedly — a newer call supersedes an in-flight one via `generation`.
    public func load() {
        let now = nowProvider()
        let calendar = aggregate.calendar

        // Always re-read the hidden set in case it changed out from under us.
        self.hiddenFromNostalgia = dismissals.hiddenKeys()

        // ---- Synchronous, pure: from the aggregate ----
        self.allDormant = DormancyDetector.detect(
            series: aggregate.contactSeries, now: now, calendar: calendar
        )
        self.allMilestones = MilestonesBuilder.build(
            series: aggregate.contactSeries, now: now, calendar: calendar
        )
        self.allStreaks = StreakDetector.detect(
            series: aggregate.contactSeries, calendar: calendar
        )
        self.allEras = EraDetector.detect(
            series: aggregate.contactSeries, calendar: calendar
        )
        refilter()

        // ---- Async, DB-backed: beloved, on-this-day, first messages, funny ----
        let myGen = generation &+ 1
        generation = myGen
        isLoading = true
        loadError = nil

        let database = self.database
        let contacts = self.contacts
        let series = aggregate.contactSeries
        let oldest = aggregate.allTimeOldest
        let newest = aggregate.allTimeNewest
        let loaderCalendar = calendar

        Task.detached(priority: .utility) { [weak self] in
            let search = MessageSearch(database: database, contacts: contacts)

            var loadedStories: [ChatStory] = []
            var loadedRekindle: [RekindleReminder] = []
            var loadedBeloved: [BelovedMessage] = []
            var loadedOnThisDay: [OnThisDayMemory] = []
            var loadedFirst: [FirstMessage] = []
            var loadedFunny: [FunnyMoment] = []
            var errors: [String] = []

            // PER-CHAT timelines (the primary surface).
            do {
                loadedStories = try ChatStoryBuilder.loadStories(
                    database: database, contacts: contacts, calendar: loaderCalendar
                )
            } catch { errors.append("Chat stories: \(error.localizedDescription)") }

            // REKINDLE reminders (full eligible list — suppression in refilter).
            do {
                loadedRekindle = try RekindleBuilder.load(
                    database: database, contacts: contacts, now: now
                )
            } catch { errors.append("Rekindle: \(error.localizedDescription)") }

            // Legacy generic surfaces (still fed so the old panel compiles).
            do {
                loadedBeloved = try BelovedMessagesLoader(search: search).load()
            } catch { errors.append("Beloved: \(error.localizedDescription)") }
            do {
                loadedOnThisDay = try OnThisDayLoader(search: search, calendar: loaderCalendar)
                    .load(now: now, historyOldest: oldest, historyNewest: newest)
            } catch { errors.append("On this day: \(error.localizedDescription)") }
            do {
                loadedFirst = try FirstMessageLoader(database: database, contacts: contacts)
                    .load(series: series)
            } catch { errors.append("First messages: \(error.localizedDescription)") }
            do {
                loadedFunny = try FunnyMomentsLoader(database: database, contacts: contacts).load()
            } catch { errors.append("Funny moments: \(error.localizedDescription)") }

            await self?.apply(
                chatStories: loadedStories,
                rekindle: loadedRekindle,
                beloved: loadedBeloved,
                onThisDay: loadedOnThisDay,
                firstMessages: loadedFirst,
                funnyMoments: loadedFunny,
                error: errors.isEmpty ? nil : errors.joined(separator: "; "),
                generation: myGen
            )
        }
    }

    private func apply(
        chatStories: [ChatStory],
        rekindle: [RekindleReminder],
        beloved: [BelovedMessage],
        onThisDay: [OnThisDayMemory],
        firstMessages: [FirstMessage],
        funnyMoments: [FunnyMoment],
        error: String?,
        generation: Int
    ) {
        guard generation == self.generation else { return }
        self.allChatStories = chatStories
        self.allRekindle = rekindle
        self.allBeloved = beloved
        self.allOnThisDay = onThisDay
        self.allFirstMessages = firstMessages
        self.allFunnyMoments = funnyMoments
        self.loadError = error
        self.isLoading = false
        self.hasLoadedOnce = true
        refilter()
    }

    // MARK: - Hide model

    /// Hide a contact everywhere in Nostalgia + reminders. Persists immediately
    /// and re-filters every live surface so the person disappears at once. The
    /// user can hide ANYONE — not just flagged people.
    public func hide(_ name: String) {
        dismissals.hide(name)
        hiddenFromNostalgia = dismissals.hiddenKeys()
        refilter()
    }

    /// Un-hide a contact — the user changed their mind. Persists + re-filters,
    /// so the person can reappear in the relevant surfaces.
    public func unhide(_ name: String) {
        dismissals.unhide(name)
        hiddenFromNostalgia = dismissals.hiddenKeys()
        refilter()
    }

    /// Backward-compatible affordance: the dormant-friend card's "hide" button.
    /// Hiding a dormant friend == hiding them everywhere now.
    public func dismissDormant(_ friend: DormantFriend) {
        hide(friend.key)
    }

    // MARK: - Filtering

    /// Re-derive every published surface from its unfiltered cache, dropping
    /// anyone in `hiddenFromNostalgia`. Single chokepoint so the hidden set is
    /// honored uniformly. Also recomputes the advisory suggestions.
    private func refilter() {
        let hidden = hiddenFromNostalgia

        // --- Per-chat timelines (primary surface) ---
        // Drop a whole 1:1 story when its partner is hidden; within any story,
        // drop moments about a hidden person (a hidden member's join/leave/peak
        // shouldn't resurface), but keep the chat itself.
        chatStories = allChatStories.compactMap { story in
            if !story.isGroup && hidden.contains(story.title) { return nil }
            let kept = story.moments.filter { moment in
                guard let person = moment.person else { return true }
                return !hidden.contains(person)
            }
            if kept.count == story.moments.count { return story }
            return story.withMoments(kept)
        }

        // --- On This Day: EVENT-GATED anniversaries (month/day == today) ---
        onThisDayMoments = Self.eventGatedMoments(
            from: chatStories, now: nowProvider(), calendar: aggregate.calendar
        )

        // --- Rekindle reminders ---
        // Only the user-controlled hidden set suppresses people (0.3.1: the
        // automatic romantic-flag suppression was removed with the detector —
        // people surface naturally and one tap hides anyone, permanently).
        rekindleReminders = allRekindle.filter { !hidden.contains($0.name) }

        // --- Legacy generic surfaces ---
        dormantFriends = allDormant.filter { !hidden.contains($0.key) }
        streaks = allStreaks.filter { !hidden.contains($0.key) }
        eras = allEras.filter { !hidden.contains($0.topContactKey) }
        firstMessages = allFirstMessages.filter { !hidden.contains($0.displayName) }
        milestones = allMilestones.filter { !hidden.contains($0.key) }

        // Per-message surfaces: drop a row when the person it surfaces (the 1:1
        // partner, or the sender) is hidden. Group messages stay unless the
        // sender is hidden — hiding a person shouldn't nuke whole group chats,
        // but their own messages within them shouldn't resurface either.
        beloved = allBeloved.filter { !messageInvolvesHidden($0.message, hidden: hidden) }
        funnyMoments = allFunnyMoments.filter { fm in
            if hidden.contains(fm.senderName) { return false }
            if !fm.isGroup && hidden.contains(fm.partnerName) { return false }
            return true
        }
        // On This Day: filter messages within each day; drop a memory that
        // empties out.
        onThisDay = allOnThisDay.compactMap { memory in
            let kept = memory.messages.filter { !messageInvolvesHidden($0, hidden: hidden) }
            guard !kept.isEmpty else { return nil }
            if kept.count == memory.messages.count { return memory }
            return OnThisDayMemory(window: memory.window, messages: kept, totalThatDay: memory.totalThatDay)
        }
    }

    /// A surfaced message "involves" a hidden person if it's a 1:1 with them
    /// (partner hidden) or they sent it (sender hidden). Group rows survive
    /// unless the sender themselves is hidden.
    private func messageInvolvesHidden(_ m: MemoryMessage, hidden: Set<String>) -> Bool {
        if hidden.contains(m.senderName) { return true }
        if !m.isGroup && hidden.contains(m.partnerName) { return true }
        return false
    }

    /// Select the moments across all (already hide-filtered) chat stories whose
    /// calendar month+day equals today's — the true "on this day" anniversaries.
    /// EVENT-GATED: only origin / biggestDay / peakReaction qualify (membership
    /// admin events aren't anniversaries), and a moment from TODAY's own year is
    /// excluded (it's not yet a memory). PURE static so it's unit-testable.
    ///
    /// Sorted oldest-first so the longest-ago anniversary reads as the headline
    /// ("3 years ago today" before "1 year ago today").
    ///
    /// `nonisolated` — it's a pure function of its arguments (no `self`), so it
    /// can be called off the main actor and directly from synchronous tests.
    nonisolated static func eventGatedMoments(
        from stories: [ChatStory],
        now: Date,
        calendar: Calendar
    ) -> [NotableMoment] {
        let today = calendar.dateComponents([.month, .day, .year], from: now)
        guard let todayMonth = today.month, let todayDay = today.day else { return [] }
        let anniversaryKinds: Set<NotableMoment.Kind> = [.origin, .biggestDay, .peakReaction]

        var out: [NotableMoment] = []
        for story in stories {
            for moment in story.moments where anniversaryKinds.contains(moment.kind) {
                let c = calendar.dateComponents([.month, .day, .year], from: moment.date)
                guard c.month == todayMonth, c.day == todayDay else { continue }
                // Skip events from the current year — same date, this year isn't
                // an anniversary yet.
                if let y = c.year, let ty = today.year, y == ty { continue }
                out.append(moment)
            }
        }
        out.sort { $0.date < $1.date }
        return out
    }

    // MARK: - Convenience

    /// True iff there's nothing to show in any section. Only meaningful after
    /// `hasLoadedOnce`. Considers the primary per-chat surface AND the legacy
    /// surfaces (the old panel still renders the latter).
    public var isEmpty: Bool {
        chatStories.isEmpty && onThisDayMoments.isEmpty && rekindleReminders.isEmpty
            && onThisDay.isEmpty && beloved.isEmpty && dormantFriends.isEmpty
            && milestones.isEmpty && streaks.isEmpty && firstMessages.isEmpty
            && eras.isEmpty && funnyMoments.isEmpty
    }
}
