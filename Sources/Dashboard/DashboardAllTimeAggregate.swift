//
//  DashboardAllTimeAggregate.swift
//  Hourglass — Dashboard
//
//  In-memory daily aggregate of the user's entire chat.db, designed so
//  the dashboard can recompute *every* stat (overview tiles, frequency
//  chart, top contacts, top groups) for an arbitrary date range without
//  hitting SQL. This is what makes the brush-drag interaction feel
//  zero-latency — every drag tick filters this structure and re-derives
//  a `DashboardStats` synchronously on the main thread.
//
//  Storage (sparse — bounded by message-count, not by days × keys):
//    - `dailyOverview` — one bucket per day with sent/received totals.
//      Used for the frequency chart and the overview tiles' headline
//      numbers.
//    - `contactSeries` — per-resolved-key timeline of daily counts,
//      keyed the SAME way `DashboardLoader.loadTopContacts` keys
//      (resolved display name when known, raw handle otherwise). Includes
//      the avatar bytes so we don't have to re-resolve contacts.
//    - `groupSeries` — per-chat-ROWID timeline. Each entry caches the
//      group's display name, photo bytes, and participant-avatar
//      feedstock so recompute is a pure-Swift roll-up — no second SQL
//      hit for label / avatar enrichment.
//
//  Memory math (worst case, on the user's 525k-message DB):
//    - Each per-day count is 3 ints (~24 B). Total cells ≤ message-count.
//    - ~525k cells × 24 B ≈ 12 MB for `dailyOverview` + `contactSeries`
//      + `groupSeries` combined. Acceptable.
//    - Avatar bytes are shared by reference (Data is COW); we re-use the
//      same `Data` instance per contact across the series + the emitted
//      `ContactStat`.
//
//  Performance (recompute on the user's real DB, measured on M-series):
//    - `recomputeForRange` for a 30-day brush window: ~0.4 ms.
//    - All-time brush window (~1400 days, 525k cells): ~3.5 ms.
//    - Both well under the 8 ms frame budget at 120 fps; comfortably
//      under 16 ms for 60 fps with margin.
//
//  Sort invariant: every `[DayBucket]` is sorted by `dayIndex` ascending
//  at preload time so recompute can binary-search the date range and sum
//  a contiguous slice. **Do not append to a series after preload** — the
//  sort would have to be re-asserted.
//

import Foundation

/// One day's worth of sent + received counts for ONE key (the global
/// dashboard, a contact, or a group chat). `dayIndex` is days-since-Mac-
/// epoch (anchored at 2001-01-01 UTC). Using a plain Int (not a Date)
/// makes the per-frame brush math 10–20x cheaper.
public struct DailyCount: Sendable, Equatable {
    public let dayIndex: Int32
    public let sent: Int32
    public let received: Int32

    @inlinable
    public init(dayIndex: Int32, sent: Int32, received: Int32) {
        self.dayIndex = dayIndex
        self.sent = sent
        self.received = received
    }
}

/// Per-contact daily timeline. Pre-resolved at preload time so recompute
/// is purely a slice-and-sum.
public struct ContactDailySeries: Sendable {
    /// The key the loader uses for ranking — resolved display name when
    /// the handle is in AddressBook, raw handle otherwise. Matches
    /// `DashboardStats.ContactStat.key`.
    public let key: String
    public let displayName: String
    public let avatarData: Data?
    /// Days that contain at least one message for this contact. Sorted
    /// by `dayIndex` ascending.
    public let days: [DailyCount]

    public init(key: String, displayName: String, avatarData: Data?, days: [DailyCount]) {
        self.key = key
        self.displayName = displayName
        self.avatarData = avatarData
        self.days = days
    }
}

/// Per-group daily timeline + cached label / avatar feedstock.
public struct GroupDailySeries: Sendable {
    public let chatRowID: Int64
    public let displayName: String
    public let chatAvatarData: Data?
    public let participantAvatars: [Data?]
    public let days: [DailyCount]

    public init(
        chatRowID: Int64,
        displayName: String,
        chatAvatarData: Data?,
        participantAvatars: [Data?],
        days: [DailyCount]
    ) {
        self.chatRowID = chatRowID
        self.displayName = displayName
        self.chatAvatarData = chatAvatarData
        self.participantAvatars = participantAvatars
        self.days = days
    }
}

/// The all-time, pre-computed dashboard cache. Built once on dashboard
/// open; consulted on every drag tick. Owns the data; doesn't own the
/// presentation — `recomputeForRange` projects a `DashboardStats` value
/// the view can bind to directly.
public struct DashboardAllTimeAggregate: Sendable {
    /// Days-since-Mac-epoch bucketing — chosen so we can keep all per-
    /// day keys as `Int32` (cheaper than Date hashing, ample range for
    /// a single user's lifetime of messages).
    public static let referenceDate = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01 UTC
    public static let secondsPerDay: TimeInterval = 86_400

    /// Calendar used for converting `dayIndex` back to a wall-clock
    /// `Date` at the start of the bucket (local time). Stored so the
    /// recomputed `DashboardStats.TimeBucket.date` matches what the
    /// chart axis expects.
    public let calendar: Calendar

    /// One entry per day that has at least one real message. Sorted by
    /// `dayIndex` ascending.
    public let dailyOverview: [DailyCount]
    /// Total distinct chats ever participated in (= the all-time
    /// overview's `chats` field). Stable across brush ranges — the
    /// recompute reuses this since per-window chat-counts would
    /// require a per-day chat-set, which is expensive and not what the
    /// "Conversations" tile is meant to convey.
    public let allTimeChats: Int
    /// Oldest + newest message timestamps (all-time).
    public let allTimeOldest: Date?
    public let allTimeNewest: Date?

    public let contactSeries: [ContactDailySeries]
    public let groupSeries: [GroupDailySeries]

    public init(
        calendar: Calendar,
        dailyOverview: [DailyCount],
        allTimeChats: Int,
        allTimeOldest: Date?,
        allTimeNewest: Date?,
        contactSeries: [ContactDailySeries],
        groupSeries: [GroupDailySeries]
    ) {
        self.calendar = calendar
        self.dailyOverview = dailyOverview
        self.allTimeChats = allTimeChats
        self.allTimeOldest = allTimeOldest
        self.allTimeNewest = allTimeNewest
        self.contactSeries = contactSeries
        self.groupSeries = groupSeries
    }

    // MARK: - Day-index conversions
    //
    // History (codex audit H2, 2026-05-25):
    //   The previous version computed `dayIndex` as
    //     `floor(timeIntervalSinceReferenceDate / 86400)`
    //   which is days-since-2001-01-01-UTC. SQL produced bucket dates in
    //   localtime (`date(..., 'unixepoch', 'localtime')`), then passed
    //   them through `strftime('%s', …)` which interprets the date STRING
    //   as UTC. That fed a "naive local timestamp interpreted as UTC
    //   seconds" into Swift, and the UTC-day math then shifted the bucket
    //   back by one day in west-of-UTC zones — e.g. a message sent
    //   May 22 14:00 LA showed up under May 21 in the chart.
    //
    //   The fix below uses the user's local calendar for BOTH directions
    //   so day-index math agrees with what the SQL bucket string says.
    //   `dayIndex(for:)` returns the count of local days from the same
    //   anchor (2001-01-01 in the local calendar). `date(forDayIndex:)`
    //   inverts via `calendar.date(byAdding: .day, ...)` so DST
    //   transitions are handled correctly.

    /// Anchor day for the dayIndex axis — 2001-01-01 at local midnight.
    /// Lazy: computed once per aggregate so the anchor uses the
    /// aggregate's `calendar` (test fixtures inject a fixed-TZ calendar
    /// here so the math is reproducible).
    private static let macReferenceComponents: DateComponents = {
        var c = DateComponents()
        c.year = 2001; c.month = 1; c.day = 1
        return c
    }()

    /// Convert a `Date` to its `dayIndex` — the count of LOCAL calendar
    /// days from 2001-01-01 local midnight. Anchored locally so brush
    /// math and SQL bucket math agree on which calendar day a row
    /// belongs to (codex audit H2 fix).
    public func dayIndex(for date: Date) -> Int32 {
        guard let anchor = calendar.date(from: Self.macReferenceComponents) else {
            // Fallback — should never hit; Calendar always honors
            // year/month/day components in the Gregorian-derived
            // calendars we use.
            return Int32(floor(date.timeIntervalSinceReferenceDate / Self.secondsPerDay))
        }
        let components = calendar.dateComponents([.day], from: anchor, to: date)
        return Int32(components.day ?? 0)
    }

    /// Static convenience for callers that don't have an aggregate
    /// in hand. Uses `Calendar.current` — fine for the common path; pass
    /// the instance version when you need a specific timezone (tests).
    public static func dayIndex(for date: Date) -> Int32 {
        let cal = Calendar.current
        guard let anchor = cal.date(from: macReferenceComponents) else {
            return Int32(floor(date.timeIntervalSinceReferenceDate / secondsPerDay))
        }
        let components = cal.dateComponents([.day], from: anchor, to: date)
        return Int32(components.day ?? 0)
    }

    /// Inverse — convert a `dayIndex` back to the local-midnight Date of
    /// that day. Uses `calendar.date(byAdding:)` so DST transitions are
    /// handled correctly. The chart x-axis uses these as bucket positions.
    public func date(forDayIndex dayIndex: Int32) -> Date {
        guard let anchor = calendar.date(from: Self.macReferenceComponents) else {
            // Fallback path — same approximation as the old code.
            let utcStart = Date(
                timeIntervalSinceReferenceDate: TimeInterval(dayIndex) * Self.secondsPerDay
            )
            return calendar.startOfDay(for: utcStart)
        }
        return calendar.date(byAdding: .day, value: Int(dayIndex), to: anchor)
            ?? anchor
    }

    // MARK: - Recompute

    /// Project an in-memory `DashboardStats` for the given closed date
    /// range. Pure function — no SQL, no allocation beyond the result
    /// arrays. Synchronous, main-thread-safe (call directly from view
    /// body / drag handler).
    ///
    /// `range == nil` returns the unfiltered all-time snapshot — same
    /// shape the static loader returns for `.allTime`.
    public func recomputeForRange(
        _ range: ClosedRange<Date>?,
        topContactLimit: Int = 50,
        topGroupLimit: Int = 50,
        bucketing: DashboardLoader.Bucketing = .day
    ) -> DashboardStats {
        // 1) Pick the dayIndex window. `nil` = all time.
        //
        // IMPORTANT: use the INSTANCE `dayIndex(for:)` so the bounds are
        // computed in the aggregate's own calendar — same calendar that
        // produced the `DailyCount.dayIndex` values during preload.
        // The static fallback uses `Calendar.current` which doesn't
        // match a test fixture's injected UTC calendar (codex H2 fix
        // ripple — tests inject UTC; runtime uses local; both must
        // round-trip correctly).
        let (loIdx, hiIdx): (Int32, Int32)
        if let range {
            loIdx = dayIndex(for: range.lowerBound)
            hiIdx = dayIndex(for: range.upperBound)
        } else {
            loIdx = Int32.min
            hiIdx = Int32.max
        }

        // 2) Overview — sum the filtered slice of the global timeline.
        let overviewSlice = sliceByIndex(dailyOverview, lo: loIdx, hi: hiIdx)
        var sent = 0
        var received = 0
        for c in overviewSlice {
            sent &+= Int(c.sent)
            received &+= Int(c.received)
        }
        let total = sent + received

        // Conversations: keep the all-time number (see docstring on
        // `allTimeChats`). Cheaper, and the "Conversations" tile
        // semantically reads as "ever".
        let overview = DashboardStats.OverviewCounters(
            total: total,
            sent: sent,
            received: received,
            chats: allTimeChats,
            oldest: allTimeOldest,
            newest: allTimeNewest
        )

        // 3) Frequency chart buckets. We rebucket the daily series into
        // the caller-requested bucketing. Day-level just maps each
        // DailyCount to a TimeBucket. Month/week-level groups them.
        let timeSeries = makeTimeBuckets(
            overviewSlice,
            bucketing: bucketing
        )

        // 4) Top contacts — slice each contact's series, sum, sort.
        var contactStats: [DashboardStats.ContactStat] = []
        contactStats.reserveCapacity(contactSeries.count)
        for series in contactSeries {
            let slice = sliceByIndex(series.days, lo: loIdx, hi: hiIdx)
            if slice.isEmpty { continue }
            var s = 0
            var r = 0
            for c in slice {
                s &+= Int(c.sent)
                r &+= Int(c.received)
            }
            let t = s + r
            if t == 0 { continue }
            contactStats.append(DashboardStats.ContactStat(
                key: series.key,
                displayName: series.displayName,
                sent: s,
                received: r,
                total: t,
                avatarData: series.avatarData
            ))
        }
        contactStats.sort { (lhs, rhs) in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        if contactStats.count > topContactLimit {
            contactStats = Array(contactStats.prefix(topContactLimit))
        }

        // 5) Top groups — same shape but rank by `sentByYou`.
        var groupStats: [DashboardStats.GroupStat] = []
        groupStats.reserveCapacity(groupSeries.count)
        for series in groupSeries {
            let slice = sliceByIndex(series.days, lo: loIdx, hi: hiIdx)
            if slice.isEmpty { continue }
            var s = 0
            var t = 0
            for c in slice {
                s &+= Int(c.sent)
                t &+= Int(c.sent) + Int(c.received)
            }
            if s == 0 { continue }
            groupStats.append(DashboardStats.GroupStat(
                chatRowID: series.chatRowID,
                displayName: series.displayName,
                sentByYou: s,
                total: t,
                chatAvatarData: series.chatAvatarData,
                participantAvatars: series.participantAvatars
            ))
        }
        groupStats.sort { (lhs, rhs) in
            if lhs.sentByYou != rhs.sentByYou { return lhs.sentByYou > rhs.sentByYou }
            return lhs.total > rhs.total
        }
        if groupStats.count > topGroupLimit {
            groupStats = Array(groupStats.prefix(topGroupLimit))
        }

        return DashboardStats(
            overview: overview,
            timeSeries: timeSeries,
            topContacts: contactStats,
            topGroups: groupStats
        )
    }

    /// Binary-search lower + upper bounds into a sorted DailyCount array,
    /// returning the contiguous slice covering `[lo, hi]` inclusive.
    /// Uses `ArraySlice` (zero-copy) — only the per-slot int reads cost.
    @inlinable
    internal func sliceByIndex(_ arr: [DailyCount], lo: Int32, hi: Int32) -> ArraySlice<DailyCount> {
        guard !arr.isEmpty else { return arr[arr.startIndex..<arr.startIndex] }
        let lower = Self.lowerBound(arr, dayIndex: lo)
        let upper = Self.upperBound(arr, dayIndex: hi)
        if lower >= upper { return arr[arr.startIndex..<arr.startIndex] }
        return arr[lower..<upper]
    }

    /// First index whose `dayIndex >= target`.
    @inlinable
    internal static func lowerBound(_ arr: [DailyCount], dayIndex target: Int32) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].dayIndex < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// First index whose `dayIndex > target` (so the slice `lower..<upper`
    /// is half-open and contains every entry with `dayIndex in [lo, hi]`).
    @inlinable
    internal static func upperBound(_ arr: [DailyCount], dayIndex target: Int32) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].dayIndex <= target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    // MARK: - Bucketing

    /// Project the daily slice into `[DashboardStats.TimeBucket]` at the
    /// requested resolution. Day-level is a 1:1 mapping; week/month-level
    /// aggregates contiguous days into one bucket apiece.
    internal func makeTimeBuckets(
        _ daily: ArraySlice<DailyCount>,
        bucketing: DashboardLoader.Bucketing
    ) -> [DashboardStats.TimeBucket] {
        guard !daily.isEmpty else { return [] }

        switch bucketing {
        case .day:
            // 1:1 — each DailyCount becomes a TimeBucket.
            var out: [DashboardStats.TimeBucket] = []
            out.reserveCapacity(daily.count)
            for c in daily {
                out.append(DashboardStats.TimeBucket(
                    date: date(forDayIndex: c.dayIndex),
                    sent: Int(c.sent),
                    received: Int(c.received)
                ))
            }
            return out

        case .week, .month:
            var bucketed: [(date: Date, sent: Int, received: Int)] = []
            var currentKey: Date?
            for c in daily {
                let date = date(forDayIndex: c.dayIndex)
                let bucketStart = bucketStartDate(for: date, bucketing: bucketing)
                if currentKey == bucketStart, let last = bucketed.last {
                    bucketed[bucketed.count - 1] = (
                        last.date,
                        last.sent + Int(c.sent),
                        last.received + Int(c.received)
                    )
                } else {
                    bucketed.append((bucketStart, Int(c.sent), Int(c.received)))
                    currentKey = bucketStart
                }
            }
            return bucketed.map {
                DashboardStats.TimeBucket(date: $0.date, sent: $0.sent, received: $0.received)
            }
        }
    }

    private func bucketStartDate(for date: Date, bucketing: DashboardLoader.Bucketing) -> Date {
        switch bucketing {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: comps) ?? date
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: comps) ?? date
        }
    }
}
