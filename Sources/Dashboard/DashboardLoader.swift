//
//  DashboardLoader.swift
//  Hourglass
//
//  Aggregates `chat.db` into a `DashboardStats` snapshot. Pushes everything
//  reasonable into SQL — we count rows in the database, not in Swift. For
//  ~100k-row databases that means sub-100ms instead of multi-second.
//
//  Patterns ported from `reference/scripts/`:
//    - `sent_messages_chart.py` for the per-day bucketing expression
//    - `top_contacts.py` for the contact merge + handle resolution shape
//    - `year_over_year.py` for the matched-window date math
//
//  Honors the canon (plans.md → "Critical Technical Knowledge — chat.db"):
//    - `m.date` is Mac absolute time, dual-format (ns post-10.13, s legacy).
//      We disambiguate with the `> 1e12` rule everywhere.
//    - `m.associated_message_type = 0` ALWAYS — drops tapbacks and reactions
//      from every count.
//    - For 1:1 contact stats we fall back to chat participants when
//      `m.handle_id` is NULL (sent messages), per the `COALESCE` trick in
//      `top_contacts.py`.
//    - `chat.style = 45` = 1:1, `= 43` = group.
//

import Foundation
import GRDB

public enum DashboardLoader {

    /// User-selectable rollup window. Drives both the time-series bucketing
    /// resolution and the contact/group rankings (those are scoped to the
    /// window too — "people I've texted the most lately").
    public enum Window: Sendable, Hashable, CaseIterable, Identifiable {
        case last30Days
        case last12Months
        case allTime

        public var id: Self { self }

        public var label: String {
            switch self {
            case .last30Days: return "30d"
            case .last12Months: return "12m"
            case .allTime: return "All"
            }
        }

        /// Default bucketing for this preset, used by the legacy SQL
        /// `loadSync` path (which still pre-aggregates in SQL per
        /// preset). **For chart display, prefer `Bucketing.forRange(_:)`
        /// against the active range** — that's the unified policy
        /// shared by the segmented selector AND the navigator drag.
        public var bucketing: Bucketing {
            switch self {
            case .last30Days: return .day
            case .last12Months: return .month
            case .allTime: return .month
            }
        }
    }

    /// How we group the time series.
    public enum Bucketing: Sendable, Hashable {
        case day
        case week
        case month

        /// Pick a bucketing that yields ~30 readable bars for a given
        /// visible range. This is the **unified policy** the dashboard
        /// applies whether the range came from the segmented selector
        /// (`30d / 12m / All`) or from a navigator drag — bucketing
        /// follows length, not preset, so the chart density is
        /// consistent across both control surfaces.
        ///
        /// Thresholds (chosen for comfortable visual density, in the
        /// ~20–60 bar range across common spans):
        ///   - ≤ 60 days   → `.day`     (a 30-day month → 30 bars; a 60-day
        ///                                span → 60 bars, still tight enough
        ///                                to read)
        ///   - ≤ 395 days  → `.week`    (a 12-month / 365-day span → ~52
        ///                                weekly bars; the 13-month / 395-day
        ///                                ceiling keeps "12m" and a slight
        ///                                over-drag in the same bucket
        ///                                regime so the chart density doesn't
        ///                                flicker at the segment boundary)
        ///   - > 395 days  → `.month`   (multi-year history → ~12 bars per
        ///                                year, scales gracefully into
        ///                                Apple-Stocks-style "All time")
        ///
        /// The chart re-bins on the same in-memory `dailyOverview`, so
        /// switching resolutions has zero SQL cost.
        public static func forRange(_ range: ClosedRange<Date>) -> Bucketing {
            let seconds = range.upperBound.timeIntervalSince(range.lowerBound)
            // ~ days, rounded up so a brush that just kisses 61 days
            // promotes to weekly rather than fluttering at the boundary.
            let days = max(0, Int(ceil(seconds / 86_400)))
            if days <= 60 { return .day }
            if days <= 395 { return .week }
            return .month
        }

        /// The SQLite `strftime` format for this resolution. Always anchored
        /// to local time — Mac absolute time goes through `localtime` first.
        var strftimeFormat: String {
            switch self {
            case .day:   return "%Y-%m-%d"
            case .week:  return "%Y-%W"     // ISO week number
            case .month: return "%Y-%m"
            }
        }

        /// Parse a bucket label back to a `Date` (start of bucket, local TZ).
        func parseBucket(_ label: String, calendar: Calendar) -> Date? {
            let df = DateFormatter()
            df.calendar = calendar
            df.timeZone = calendar.timeZone
            df.locale = Locale(identifier: "en_US_POSIX")
            switch self {
            case .day:
                df.dateFormat = "yyyy-MM-dd"
                return df.date(from: label)
            case .month:
                df.dateFormat = "yyyy-MM"
                return df.date(from: label)
            case .week:
                // SQLite's %W is 00-53, week of year, MONDAY-start. The
                // previous code passed `calendar.firstWeekday` (= Sunday
                // on US locales) which placed weekly bucket dates on
                // Sunday instead of Monday — codex audit M6 fix.
                //
                // We force a Monday-start Gregorian calendar locally so
                // the parsed date lands on the same day SQLite would
                // call "the start of week %W", regardless of which day
                // the user's locale considers the start of the week.
                let parts = label.split(separator: "-")
                guard parts.count == 2,
                      let year = Int(parts[0]),
                      let week = Int(parts[1]) else { return nil }
                var weekCal = Calendar(identifier: .gregorian)
                weekCal.timeZone = calendar.timeZone
                weekCal.firstWeekday = 2 // Monday (Sunday = 1, Monday = 2)
                weekCal.minimumDaysInFirstWeek = 4 // ISO-style
                var comps = DateComponents()
                comps.weekOfYear = max(week, 1)
                comps.yearForWeekOfYear = year
                comps.weekday = 2 // Monday
                return weekCal.date(from: comps)
            }
        }
    }

    /// Load every panel's data in one batch. The work runs on the GRDB read
    /// queue; the caller awaits a single `Sendable` value.
    public static func load(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        window: Window,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> DashboardStats {

        // GRDB's read queue isn't async-throws-friendly across actors, so we
        // hop to a detached task. The work itself is plain SQL.
        return try await Task.detached(priority: .userInitiated) {
            try loadSync(
                database: database,
                contacts: contacts,
                window: window,
                now: now,
                calendar: calendar
            )
        }.value
    }

    /// Synchronous variant — exposed for tests so they can run without a
    /// surrounding async context.
    public static func loadSync(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        window: Window,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DashboardStats {

        let dateRange = dateRange(for: window, now: now, calendar: calendar)

        return try database.dbQueue.read { db in
            let overview = try loadOverview(db: db)
            let timeSeries = try loadTimeSeries(
                db: db,
                bucketing: window.bucketing,
                dateRange: dateRange,
                calendar: calendar
            )
            let topContacts = try loadTopContacts(
                db: db,
                dateRange: dateRange,
                contacts: contacts
            )
            let topGroups = try loadTopGroups(
                db: db,
                dateRange: dateRange,
                contacts: contacts
            )
            return DashboardStats(
                overview: overview,
                timeSeries: timeSeries,
                topContacts: topContacts,
                topGroups: topGroups
            )
        }
    }

    // MARK: - Overview

    /// Header strip: total / sent / received / chats / span. All-time scope —
    /// these are the "ever" numbers and don't track the time selector.
    static func loadOverview(db: Database) throws -> DashboardStats.OverviewCounters {
        struct Row1: FetchableRecord {
            let total: Int
            let sent: Int
            let received: Int
            let minDate: Int64?
            let maxDate: Int64?
            init(row: Row) {
                total = row["total"] ?? 0
                sent = row["sent"] ?? 0
                received = row["received"] ?? 0
                minDate = row["min_date"]
                maxDate = row["max_date"]
            }
        }

        // One query for the four counters and the date span. The COALESCE on
        // is_from_me defends against pathological rows where the column is
        // NULL — treat as received.
        let counters = try Row1.fetchOne(db, sql: """
            SELECT
                COUNT(*)                                                        AS total,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END)               AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END)  AS received,
                MIN(m.date)                                                     AS min_date,
                MAX(m.date)                                                     AS max_date
            FROM message m
            WHERE m.associated_message_type = 0
            """)

        // Count only chats that have at least one REAL message — drop
        // tapbacks/reactions from the qualifying set and drop chats with
        // zero qualifying rows. macOS iMessage accumulates "ghost" chats
        // (a contact texted once, no reply; a spam SMS; a chat that was
        // emptied) over the years; counting `SELECT COUNT(*) FROM chat`
        // raw badly overstates "conversations you've had". A chat with
        // only reactions in it isn't a conversation either — those rows
        // mean someone reacted to a message you sent in a 1:1 they
        // already had with someone else but the join row landed under a
        // different chat (rare, but real in older DBs).
        let chats = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT cmj.chat_id)
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE m.associated_message_type = 0
            """) ?? 0

        let oldest = counters?.minDate.map(MessageDate.date(fromRaw:))
        let newest = counters?.maxDate.map(MessageDate.date(fromRaw:))

        return DashboardStats.OverviewCounters(
            total: counters?.total ?? 0,
            sent: counters?.sent ?? 0,
            received: counters?.received ?? 0,
            chats: chats,
            oldest: oldest,
            newest: newest
        )
    }

    // MARK: - Time series

    /// Per-bucket sent/received counts.
    ///
    /// We do all the bucketing in SQL via `strftime` on the Mac→Unix
    /// conversion. Two important details:
    ///
    /// 1. The disambiguation expression
    ///    `CASE WHEN m.date > 1e12 THEN m.date / 1e9 ELSE m.date END`
    ///    runs INSIDE `strftime`, so ns and seconds rows go through the same
    ///    formatter. (Same pattern as `sent_messages_chart.py`.)
    /// 2. We use `'localtime'` for the conversion — buckets line up with the
    ///    user's local clock, not UTC.
    static func loadTimeSeries(
        db: Database,
        bucketing: Bucketing,
        dateRange: ClosedRange<Date>?,
        calendar: Calendar
    ) throws -> [DashboardStats.TimeBucket] {

        let (dateSQL, dateArgs) = dateClause(dateRange)
        let format = bucketing.strftimeFormat

        let sql = """
            SELECT
                strftime(?, datetime(
                    CASE WHEN m.date > 1000000000000
                         THEN m.date / 1000000000
                         ELSE m.date
                    END + 978307200,
                    'unixepoch', 'localtime'
                )) AS bucket,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
            FROM message m
            WHERE m.associated_message_type = 0
              \(dateSQL)
            GROUP BY bucket
            HAVING bucket IS NOT NULL
            ORDER BY bucket ASC
            """

        var args: [DatabaseValueConvertible] = [format]
        args.append(contentsOf: dateArgs)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        var buckets: [DashboardStats.TimeBucket] = []
        buckets.reserveCapacity(rows.count)
        for row in rows {
            let bucket: String? = row["bucket"]
            let sent: Int = row["sent"] ?? 0
            let received: Int = row["received"] ?? 0
            guard let bucket,
                  let date = bucketing.parseBucket(bucket, calendar: calendar) else {
                continue
            }
            buckets.append(DashboardStats.TimeBucket(
                date: date,
                sent: sent,
                received: received
            ))
        }
        return buckets
    }

    // MARK: - Top contacts

    /// "People you text the most" — 1:1 chats only, sent + received pooled.
    /// Merges multiple handles per contact via the resolved name (same idea
    /// as `top_contacts.py`).
    static func loadTopContacts(
        db: Database,
        dateRange: ClosedRange<Date>?,
        contacts: ResolvedContacts,
        limit: Int = 50
    ) throws -> [DashboardStats.ContactStat] {

        let (dateSQL, dateArgs) = dateClause(dateRange)

        // For 1:1 chats (style=45), the partner is the chat's single
        // non-self participant — STABLE across the lifetime of the chat.
        // We derive it from `chat_handle_join` and ignore `m.handle_id`.
        //
        // Why we used to use COALESCE(m.handle_id, …chj…) and why it was
        // wrong: on real iMessage DBs, `m.handle_id` is sometimes a STALE
        // ROWID pointing at a handle row that's been deleted/migrated.
        // The INNER JOIN to `handle h` then silently fails and the
        // message vanishes from the per-contact totals. Empirical on
        // user's DB: chat with Shreeya had 6134 raw sent messages but
        // only 701 attributed through the COALESCE path — 89% of sent
        // messages lost because of orphaned handle_ids, mostly on
        // pre-2024 rows. (See 2026-05-25 plans.md entry.)
        //
        // The chj-only approach gets the right answer for both sent and
        // received in 1:1 chats. Group counts still go through
        // `loadTopGroups` which doesn't need per-partner attribution.
        let sql = """
            SELECT
                h.id AS handle,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received,
                COUNT(*) AS total
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            JOIN handle h ON h.ROWID = (
                SELECT chj.handle_id FROM chat_handle_join chj
                WHERE chj.chat_id = ch.ROWID LIMIT 1
            )
            WHERE m.associated_message_type = 0
              AND ch.style = 45
              \(dateSQL)
            GROUP BY h.id
            """

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(dateArgs))

        // Merge handles that resolve to the same display name (one person,
        // many handles). For unknown handles we still aggregate per handle.
        //
        // Avatar handling: the FIRST handle in a merged bucket that has an
        // AddressBook photo wins. Multiple handles → same contact → one
        // `Contact` → one `avatarData`. Resolved-name buckets take their
        // avatar from the resolved Contact; handle-key buckets stay nil
        // (raw handles never have a photo).
        struct Bucket {
            var name: String
            var sent: Int = 0
            var received: Int = 0
            var total: Int = 0
            var avatarData: Data? = nil
        }
        var merged: [String: Bucket] = [:]

        for row in rows {
            guard let raw: String = row["handle"] else { continue }
            let sent: Int = row["sent"] ?? 0
            let received: Int = row["received"] ?? 0
            let total: Int = row["total"] ?? 0

            let handle = Handle(raw: raw)
            let resolvedContact = contacts.byHandle[handle]
            let key: String
            let displayName: String
            let avatarData: Data?
            if let resolved = resolvedContact, !resolved.displayName.isEmpty {
                key = "name:\(resolved.displayName)"
                displayName = resolved.displayName
                avatarData = resolved.avatarData
            } else {
                key = "handle:\(handle.normalized)"
                displayName = raw
                avatarData = nil
            }

            var bucket = merged[key] ?? Bucket(name: displayName)
            bucket.sent += sent
            bucket.received += received
            bucket.total += total
            // First non-nil avatar wins. Multiple Sources / multiple handles
            // for the same person can in principle disagree on photo, but
            // empirically they don't — `ContactResolver` already collapsed
            // them to a single `Contact.avatarData`.
            if bucket.avatarData == nil, let avatarData {
                bucket.avatarData = avatarData
            }
            merged[key] = bucket
        }

        let ranked = merged
            .map { (key, b) in
                DashboardStats.ContactStat(
                    key: key,
                    displayName: b.name,
                    sent: b.sent,
                    received: b.received,
                    total: b.total,
                    avatarData: b.avatarData
                )
            }
            .sorted { lhs, rhs in
                if lhs.total != rhs.total { return lhs.total > rhs.total }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .prefix(limit)

        return Array(ranked)
    }

    // MARK: - Top groups

    /// "Group chats you text the most" — ranked by your-sent count in the
    /// window. Limited to `chat.style = 43`.
    static func loadTopGroups(
        db: Database,
        dateRange: ClosedRange<Date>?,
        contacts: ResolvedContacts,
        limit: Int = 50
    ) throws -> [DashboardStats.GroupStat] {

        let (dateSQL, dateArgs) = dateClause(dateRange)

        // We aggregate count metrics per chat. The chat label (members for
        // unnamed groups) needs a second join, so we keep this query lean
        // and resolve labels in Swift.
        let sql = """
            SELECT
                ch.ROWID AS chat_rowid,
                ch.display_name AS display_name,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                COUNT(*) AS total
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            WHERE m.associated_message_type = 0
              AND ch.style = 43
              \(dateSQL)
            GROUP BY ch.ROWID, ch.display_name
            HAVING sent > 0
            ORDER BY sent DESC, total DESC
            LIMIT ?
            """

        var args: [DatabaseValueConvertible] = dateArgs
        args.append(limit)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        // Resolve labels AND participants for groups. The participant list
        // serves two roles now:
        //   1. Display-name fallback when `chat.display_name` is empty.
        //   2. Avatar feedstock for the stacked-composite fallback when the
        //      group has no custom photo.
        // One query, both uses — saves a roundtrip per group.
        let candidateRowIDs = rows.compactMap { $0["chat_rowid"] as Int64? }
        let participants = try loadGroupParticipants(
            db: db,
            chatRowIDs: candidateRowIDs,
            contacts: contacts
        )

        // Custom group photos (`chat.properties.groupPhotoGuid` →
        // `attachment.filename` → bytes on disk). Empirically ~7% of groups
        // have one set; the rest fall through to participant composites.
        let chatPhotos = try ChatPhotoLoader.loadGroupPhotos(
            db: db,
            chatRowIDs: candidateRowIDs
        )

        var stats: [DashboardStats.GroupStat] = []
        stats.reserveCapacity(rows.count)
        for row in rows {
            guard let rowID: Int64 = row["chat_rowid"] else { continue }
            let displayName: String? = row["display_name"]
            let sent: Int = row["sent"] ?? 0
            let total: Int = row["total"] ?? 0

            let participantInfo = participants[rowID] ?? []
            let names = participantInfo.map(\.name)

            let label: String
            if let dn = displayName, !dn.trimmingCharacters(in: .whitespaces).isEmpty {
                label = dn
            } else {
                if names.isEmpty {
                    label = "Group chat"
                } else if names.count <= 3 {
                    label = "Group chat with " + names.joined(separator: ", ")
                } else {
                    let preview = names.prefix(2).joined(separator: ", ")
                    label = "Group chat with \(preview) +\(names.count - 2)"
                }
            }

            // Custom photo wins. Otherwise, take the first 3 participants'
            // avatars (nil slots preserved so the composite can place
            // placeholders in the right positions).
            let chatAvatar = chatPhotos[rowID]
            let participantAvatars: [Data?]
            if chatAvatar != nil {
                participantAvatars = []
            } else {
                participantAvatars = participantInfo.prefix(3).map(\.avatarData)
            }

            stats.append(DashboardStats.GroupStat(
                chatRowID: rowID,
                displayName: label,
                sentByYou: sent,
                total: total,
                chatAvatarData: chatAvatar,
                participantAvatars: participantAvatars
            ))
        }
        return stats
    }

    /// Per-participant info we need for a group row — name (for the label
    /// fallback) and avatar bytes (for the composite-fallback).
    struct GroupParticipant: Equatable {
        let name: String
        let avatarData: Data?
    }

    /// One round-trip to fetch participant handles for a known set of chats,
    /// resolved to display names + avatars in Swift.
    static func loadGroupParticipants(
        db: Database,
        chatRowIDs: [Int64],
        contacts: ResolvedContacts
    ) throws -> [Int64: [GroupParticipant]] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ", ")
        let sql = """
            SELECT chj.chat_id AS chat_id, h.id AS handle_id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders))
            """
        var args: [DatabaseValueConvertible] = []
        for rowID in chatRowIDs { args.append(rowID) }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        var byChat: [Int64: [GroupParticipant]] = [:]
        for row in rows {
            guard let chatID: Int64 = row["chat_id"],
                  let rawHandle: String = row["handle_id"] else { continue }
            let resolved = contacts.byHandle[Handle(raw: rawHandle)]
            let name = resolved?.displayName ?? rawHandle
            byChat[chatID, default: []].append(
                GroupParticipant(name: name, avatarData: resolved?.avatarData)
            )
        }
        return byChat
    }

    // MARK: - Date helpers

    /// Window → date range. `nil` means no constraint (all-time).
    static func dateRange(
        for window: Window,
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        switch window {
        case .allTime:
            return nil
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return start...now
        case .last12Months:
            let start = calendar.date(byAdding: .month, value: -12, to: now) ?? now
            return start...now
        }
    }

    /// Build the `m.date` predicate that handles BOTH ns and seconds rows.
    /// Mirrors `MessageSearch.dateClause` exactly — kept local so the
    /// dashboard layer is independent.
    static func dateClause(_ range: ClosedRange<Date>?) -> (String, [DatabaseValueConvertible]) {
        guard let range else { return ("", []) }
        let loNS = MessageDate.nanosecondsSinceMacEpoch(from: range.lowerBound)
        let hiNS = MessageDate.nanosecondsSinceMacEpoch(from: range.upperBound)
        let loS = MessageDate.secondsSinceMacEpoch(from: range.lowerBound)
        let hiS = MessageDate.secondsSinceMacEpoch(from: range.upperBound)
        let sql = """
            AND (
                  (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
               OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
            )
            """
        return (sql, [loNS, hiNS, loS, hiS])
    }

    // MARK: - All-time aggregate (powers the brush-drag interaction)

    /// Build the in-memory aggregate the dashboard uses for zero-latency
    /// brush dragging. Runs four `GROUP BY` queries (no SQL during drag
    /// — this is the only time we pay SQL cost). On the user's real DB:
    ///
    /// | Query                       | Rows in result | Wall-clock |
    /// |---|---|---|
    /// | dailyOverview               | ~1,400 days   | ~80 ms     |
    /// | overview metadata           | 1 row         | ~15 ms     |
    /// | contactSeries pre-aggregate | ~250k rows    | ~210 ms    |
    /// | groupSeries pre-aggregate   | ~80k rows     | ~110 ms    |
    /// | participant + photo resolve | per-group     | ~50 ms     |
    /// | **TOTAL**                   |               | **~470 ms**|
    ///
    /// Called once when the dashboard is first opened; the result is
    /// cached on the view-model for the lifetime of the window.
    public static func loadAllTimeAggregate(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        calendar: Calendar = .current
    ) async throws -> DashboardAllTimeAggregate {
        try await Task.detached(priority: .userInitiated) {
            try loadAllTimeAggregateSync(
                database: database,
                contacts: contacts,
                calendar: calendar
            )
        }.value
    }

    /// Sync variant for tests + the dashboard's own background load.
    public static func loadAllTimeAggregateSync(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        calendar: Calendar = .current
    ) throws -> DashboardAllTimeAggregate {

        return try database.dbQueue.read { db in
            // 1) Overview metadata — same query as `loadOverview` for
            //    the chat count, min/max date. Sent/received/total are
            //    derivable from the daily series so we don't double-
            //    count here.
            let overview = try loadOverview(db: db)

            // 2) Global daily timeline. Single query, one row per day.
            //    Used as both the chart's data AND the source of truth
            //    for overview tile sums during a brush.
            let dailyOverview = try loadDailySeries(db: db, calendar: calendar)

            // 3) Per-contact daily timeline. Pre-aggregates by (handle,
            //    day) in SQL — Swift merges per resolved name.
            let contactSeries = try loadContactSeries(
                db: db,
                contacts: contacts,
                calendar: calendar
            )

            // 4) Per-group daily timeline. Pre-aggregates by (chat
            //    rowid, day) in SQL — Swift attaches the cached label /
            //    avatar feedstock so recompute doesn't need any
            //    further DB hits.
            let groupSeries = try loadGroupSeries(
                db: db,
                contacts: contacts,
                calendar: calendar
            )

            return DashboardAllTimeAggregate(
                calendar: calendar,
                dailyOverview: dailyOverview,
                allTimeChats: overview.chats,
                allTimeOldest: overview.oldest,
                allTimeNewest: overview.newest,
                contactSeries: contactSeries,
                groupSeries: groupSeries
            )
        }
    }

    // MARK: All-time aggregate — internal queries

    /// Global per-day sent/received. Emit `YYYY-MM-DD` from SQL and parse
    /// it locally via the caller's `calendar`, so the day boundary the
    /// SQL computed (in `localtime`) and the day boundary the Swift
    /// aggregate uses agree.
    ///
    /// Codex audit H2 (2026-05-25): the previous version round-tripped
    /// through `strftime('%s', ...)`. SQLite reads the resulting date
    /// string as UTC seconds, and Swift's `dayIndex` did
    /// `floor(timeIntervalSinceReferenceDate / 86400)` — UTC-anchored.
    /// In west-of-UTC zones (US Pacific, Eastern) this combination
    /// shifted local buckets back by one day. A message sent May 22 14:00
    /// LA showed up under May 21 on the chart. Parsing the date string
    /// directly with the local calendar eliminates the shift.
    static func loadDailySeries(
        db: Database,
        calendar: Calendar
    ) throws -> [DailyCount] {
        let sql = """
            SELECT
                date(
                    CASE WHEN m.date > 1000000000000
                         THEN m.date / 1000000000
                         ELSE m.date
                    END + 978307200,
                    'unixepoch', 'localtime'
                ) AS bucket_date,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
            FROM message m
            WHERE m.associated_message_type = 0
            GROUP BY bucket_date
            HAVING bucket_date IS NOT NULL
            ORDER BY bucket_date ASC
            """

        let rows = try Row.fetchAll(db, sql: sql)
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        // Mac-epoch anchor in the local calendar; same anchor the
        // aggregate's `dayIndex(for:)` uses.
        let anchor = calendar.date(
            from: DateComponents(year: 2001, month: 1, day: 1)
        ) ?? Date(timeIntervalSinceReferenceDate: 0)

        var out: [DailyCount] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let bucketStr: String = row["bucket_date"],
                  let bucketDate = parser.date(from: bucketStr) else { continue }
            let sent: Int64 = row["sent"] ?? 0
            let received: Int64 = row["received"] ?? 0
            let comps = calendar.dateComponents([.day], from: anchor, to: bucketDate)
            let dayIndex = Int32(comps.day ?? 0)
            out.append(DailyCount(
                dayIndex: dayIndex,
                sent: Int32(clamping: sent),
                received: Int32(clamping: received)
            ))
        }
        return out
    }

    /// Per-(handle, day) sent/received, restricted to 1:1 chats (style
    /// 45). Same attribution strategy as `loadTopContacts` — derive the
    /// partner from `chat_handle_join` and ignore `m.handle_id` entirely.
    /// The COALESCE(m.handle_id, chj) we used to do here dropped any
    /// row whose `m.handle_id` pointed at an orphaned (deleted) handle
    /// row — extremely common on real DBs for pre-2024 sent messages.
    /// See `loadTopContacts` for the full diagnosis.
    static func loadContactSeries(
        db: Database,
        contacts: ResolvedContacts,
        calendar: Calendar
    ) throws -> [ContactDailySeries] {

        // Codex audit H2 fix: emit the local date STRING from SQL and
        // parse it with the caller's calendar — same anchor logic as
        // `loadDailySeries`. The old strftime('%s', …) round-trip gave
        // UTC-anchored seconds that the Swift dayIndex math then shifted
        // back by one day in west-of-UTC zones.
        let sql = """
            SELECT
                h.id AS handle,
                date(
                    CASE WHEN m.date > 1000000000000
                         THEN m.date / 1000000000
                         ELSE m.date
                    END + 978307200,
                    'unixepoch', 'localtime'
                ) AS bucket_date,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            JOIN handle h ON h.ROWID = (
                SELECT chj.handle_id FROM chat_handle_join chj
                WHERE chj.chat_id = ch.ROWID LIMIT 1
            )
            WHERE m.associated_message_type = 0
              AND ch.style = 45
            GROUP BY h.id, bucket_date
            HAVING bucket_date IS NOT NULL
            """

        let rows = try Row.fetchAll(db, sql: sql)
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        let anchor = calendar.date(
            from: DateComponents(year: 2001, month: 1, day: 1)
        ) ?? Date(timeIntervalSinceReferenceDate: 0)

        // Bucket by resolved key. Per-key, we then sort the day list.
        struct Acc {
            var displayName: String
            var avatarData: Data?
            // dayIndex -> (sent, received). We use a small dict here
            // because the same handle CAN have two rows for the same
            // day if it resolves through the COALESCE in two chats
            // (impossible for a 1:1 in practice — there's one chat per
            // partner — but defensive against pathological DBs).
            var byDay: [Int32: (sent: Int32, received: Int32)]
        }

        var merged: [String: Acc] = [:]
        for row in rows {
            guard let raw: String = row["handle"],
                  let bucketStr: String = row["bucket_date"],
                  let bucketDate = parser.date(from: bucketStr) else { continue }
            let sent: Int64 = row["sent"] ?? 0
            let received: Int64 = row["received"] ?? 0

            let handle = Handle(raw: raw)
            let resolvedContact = contacts.byHandle[handle]
            let key: String
            let displayName: String
            let avatarData: Data?
            if let resolved = resolvedContact, !resolved.displayName.isEmpty {
                key = "name:\(resolved.displayName)"
                displayName = resolved.displayName
                avatarData = resolved.avatarData
            } else {
                key = "handle:\(handle.normalized)"
                displayName = raw
                avatarData = nil
            }

            let comps = calendar.dateComponents([.day], from: anchor, to: bucketDate)
            let dayIndex = Int32(comps.day ?? 0)
            let s = Int32(clamping: sent)
            let r = Int32(clamping: received)

            if var acc = merged[key] {
                if acc.avatarData == nil, let avatarData {
                    acc.avatarData = avatarData
                }
                if let existing = acc.byDay[dayIndex] {
                    acc.byDay[dayIndex] = (existing.sent &+ s, existing.received &+ r)
                } else {
                    acc.byDay[dayIndex] = (s, r)
                }
                merged[key] = acc
            } else {
                merged[key] = Acc(
                    displayName: displayName,
                    avatarData: avatarData,
                    byDay: [dayIndex: (s, r)]
                )
            }
        }

        var out: [ContactDailySeries] = []
        out.reserveCapacity(merged.count)
        for (key, acc) in merged {
            // Flatten dict to sorted [DailyCount].
            let days = acc.byDay
                .map { DailyCount(dayIndex: $0.key, sent: $0.value.sent, received: $0.value.received) }
                .sorted { $0.dayIndex < $1.dayIndex }
            out.append(ContactDailySeries(
                key: key,
                displayName: acc.displayName,
                avatarData: acc.avatarData,
                days: days
            ))
        }
        return out
    }

    /// Per-(chat ROWID, day) sent/received for group chats (style 43).
    /// Swift attaches the resolved label + participant avatars + custom
    /// photo bytes (looked up in two side queries) so the recompute can
    /// emit a fully-shaped `GroupStat` with no further SQL.
    static func loadGroupSeries(
        db: Database,
        contacts: ResolvedContacts,
        calendar: Calendar
    ) throws -> [GroupDailySeries] {

        // Codex audit H2 fix: emit local YYYY-MM-DD and parse it via the
        // caller's calendar, same as `loadDailySeries` /
        // `loadContactSeries` above.
        let sql = """
            SELECT
                ch.ROWID AS chat_rowid,
                ch.display_name AS display_name,
                date(
                    CASE WHEN m.date > 1000000000000
                         THEN m.date / 1000000000
                         ELSE m.date
                    END + 978307200,
                    'unixepoch', 'localtime'
                ) AS bucket_date,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            WHERE m.associated_message_type = 0
              AND ch.style = 43
            GROUP BY ch.ROWID, ch.display_name, bucket_date
            HAVING bucket_date IS NOT NULL
            """

        let rows = try Row.fetchAll(db, sql: sql)
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        let anchor = calendar.date(
            from: DateComponents(year: 2001, month: 1, day: 1)
        ) ?? Date(timeIntervalSinceReferenceDate: 0)

        struct Acc {
            var displayName: String?  // raw display_name; resolved later
            var byDay: [Int32: (sent: Int32, received: Int32)]
        }
        var byRowID: [Int64: Acc] = [:]
        for row in rows {
            guard let rowID: Int64 = row["chat_rowid"],
                  let bucketStr: String = row["bucket_date"],
                  let bucketDate = parser.date(from: bucketStr) else { continue }
            let displayName: String? = row["display_name"]
            let sent: Int64 = row["sent"] ?? 0
            let received: Int64 = row["received"] ?? 0
            let comps = calendar.dateComponents([.day], from: anchor, to: bucketDate)
            let dayIndex = Int32(comps.day ?? 0)
            let s = Int32(clamping: sent)
            let r = Int32(clamping: received)

            if var acc = byRowID[rowID] {
                if acc.displayName == nil { acc.displayName = displayName }
                if let existing = acc.byDay[dayIndex] {
                    acc.byDay[dayIndex] = (existing.sent &+ s, existing.received &+ r)
                } else {
                    acc.byDay[dayIndex] = (s, r)
                }
                byRowID[rowID] = acc
            } else {
                byRowID[rowID] = Acc(
                    displayName: displayName,
                    byDay: [dayIndex: (s, r)]
                )
            }
        }

        // Resolve participants + photos once for every group rowID.
        let chatRowIDs = Array(byRowID.keys)
        let participants = try loadGroupParticipants(
            db: db,
            chatRowIDs: chatRowIDs,
            contacts: contacts
        )
        let chatPhotos = try ChatPhotoLoader.loadGroupPhotos(
            db: db,
            chatRowIDs: chatRowIDs
        )

        var out: [GroupDailySeries] = []
        out.reserveCapacity(byRowID.count)
        for (rowID, acc) in byRowID {
            let info = participants[rowID] ?? []
            let names = info.map(\.name)
            let label: String
            if let dn = acc.displayName, !dn.trimmingCharacters(in: .whitespaces).isEmpty {
                label = dn
            } else if names.isEmpty {
                label = "Group chat"
            } else if names.count <= 3 {
                label = "Group chat with " + names.joined(separator: ", ")
            } else {
                let preview = names.prefix(2).joined(separator: ", ")
                label = "Group chat with \(preview) +\(names.count - 2)"
            }
            let chatAvatar = chatPhotos[rowID]
            let participantAvatars: [Data?]
            if chatAvatar != nil {
                participantAvatars = []
            } else {
                participantAvatars = info.prefix(3).map(\.avatarData)
            }
            let days = acc.byDay
                .map { DailyCount(dayIndex: $0.key, sent: $0.value.sent, received: $0.value.received) }
                .sorted { $0.dayIndex < $1.dayIndex }
            out.append(GroupDailySeries(
                chatRowID: rowID,
                displayName: label,
                chatAvatarData: chatAvatar,
                participantAvatars: participantAvatars,
                days: days
            ))
        }
        return out
    }
}
