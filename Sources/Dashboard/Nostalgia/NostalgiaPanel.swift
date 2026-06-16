//
//  NostalgiaPanel.swift
//  Hourglass — Dashboard / Nostalgia panel (per-chat "notable moments")
//
//  The "Nostalgia" dashboard panel — resurfaces meaningful moments from the
//  user's message history, reframed (3rd generation) as PER-CHAT story
//  timelines. Two surfaces, plus the sensitivity hide-management UX:
//
//    1. On this day  — EVENT-GATED anniversaries: only moments whose month/day
//                      matches today (a chat's origin, a biggest day, a peak
//                      reaction on this date). Empty most days — and that's
//                      correct; the section simply hides when there's nothing.
//    2. Your chats   — a browsable list of the chats worth reminiscing about
//                      (biggest first). Each row expands to that chat's moments
//                      timeline: started → longest conversation → biggest day →
//                      peak reaction → (for groups) joins / leaves / renames.
//
//    + the hide-management UX (RETAINED from the prior build): a NEUTRAL "hide
//      from reminders?" suggestion prompt (`suggestedHides`), per-row hide, and
//      a "Hidden people" manage sheet (un-hide + add anyone). Copy NEVER reveals
//      why anyone was surfaced — no "ex/romantic/partner".
//
//  RETIRED (no longer rendered — the per-chat timelines supersede them): the
//  legacy `eras`, `streaks`, `milestones`, `beloved`, `firstMessages`,
//  `funnyMoments`, and the legacy `onThisDay` ([OnThisDayMemory]) surfaces. They
//  remain published on the VM only so older code compiles; this panel ignores
//  them and reads `chatStories` + `onThisDayMoments` instead.
//
//  ENTRY POINT (the page wires this in):
//
//      NostalgiaPanel(
//          database: ChatDatabase,
//          contacts: ResolvedContacts,
//          aggregate: DashboardAllTimeAggregate
//      )
//
//  All three inputs are owned by the dashboard. The panel builds + owns its own
//  `NostalgiaViewModel`, loads on appear, and runs the DB-backed work off-main.
//
//  Design: section headers are plain; cards are SOLID content surfaces with a
//  hairline border (matches `StatPanel`'s content treatment — glass is
//  navigation-only per HIG). `AvatarView` is reused for people.
//

import SwiftUI

public struct NostalgiaPanel: View {

    @State private var viewModel: NostalgiaViewModel
    /// Captured at init from the same `ResolvedContacts` the VM is built from —
    /// powers the add-anyone picker in the hidden-management sheet and a
    /// name→avatar lookup for the suggestion prompts. Read-only; the panel never
    /// mutates contact data (that's the data layer's job).
    private let allContacts: [Contact]

    @State private var showingHiddenSheet = false

    public init(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        aggregate: DashboardAllTimeAggregate
    ) {
        _viewModel = State(initialValue: NostalgiaViewModel(
            database: database,
            contacts: contacts,
            aggregate: aggregate
        ))
        self.allContacts = contacts.allContacts
    }

    /// Test / preview seam — inject a pre-built view model.
    init(viewModel: NostalgiaViewModel, allContacts: [Contact] = []) {
        _viewModel = State(initialValue: viewModel)
        self.allContacts = allContacts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            rekindleSection
            onThisDaySection
            chatStoriesSection
            hiddenManagementBar

            if viewModel.hasLoadedOnce && storiesEmpty {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showingHiddenSheet) {
            HiddenManagementSheet(
                hidden: viewModel.hiddenFromNostalgia,
                allContacts: allContacts,
                onHide: { name in withAnimation(.bmDefault) { viewModel.hide(name) } },
                onUnhide: { name in withAnimation(.bmDefault) { viewModel.unhide(name) } }
            )
        }
    }

    /// Name → contact avatar bytes, for the suggestion prompts (the VM publishes
    /// only flagged names, not avatars).
    private func avatar(for name: String) -> Data? {
        allContacts.first { $0.displayName == name }?.avatarData
    }

    // MARK: - On This Day (event-gated anniversaries)

    /// EVENT-GATED: only renders when there's at least one moment whose date
    /// matches today. Empty most days — we simply hide the section then. While
    /// the DB pass is still running on first load we show a quiet placeholder so
    /// the page doesn't look broken.
    @ViewBuilder
    private var onThisDaySection: some View {
        if !viewModel.onThisDayMoments.isEmpty {
            NostalgiaSection(
                title: "On this day",
                subtitle: onThisDaySubtitle,
                systemImage: "calendar.badge.clock",
                tint: .purple
            ) {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(viewModel.onThisDayMoments) { moment in
                        OnThisDayMomentCard(
                            moment: moment,
                            chatTitle: chatTitle(forMomentID: moment.id),
                            now: now,
                            calendar: calendar,
                            onHide: moment.person.map { person in
                                { withAnimation(.bmDefault) { viewModel.hide(person) } }
                            }
                        )
                    }
                }
            }
        } else if viewModel.isLoading && !viewModel.hasLoadedOnce {
            NostalgiaSection(
                title: "On this day",
                subtitle: nil,
                systemImage: "calendar.badge.clock",
                tint: .purple
            ) {
                loadingRow
            }
        }
    }

    private var onThisDaySubtitle: String {
        let n = viewModel.onThisDayMoments.count
        return n == 1
            ? "A moment from this date in years past"
            : "\(n) moments from this date in years past"
    }

    // MARK: - Reach out? (rekindle reminders)

    /// A gentle "you two used to talk a lot" prompt for heavy 1:1 correspondents
    /// who've gone quiet (already suppression-filtered by the VM — hidden set AND
    /// the advisory romantic flag). Each card dismisses via the EXISTING hide
    /// mechanism (`viewModel.hide`), so "Not now" hides them everywhere. Tone is a
    /// soft nudge, never naggy — see `RekindleCard`. Hidden entirely when empty.
    @ViewBuilder
    private var rekindleSection: some View {
        if !viewModel.rekindleReminders.isEmpty {
            NostalgiaSection(
                title: "Reach out?",
                subtitle: rekindleSubtitle,
                systemImage: "hand.wave",
                tint: .pink,
                solidContent: false
            ) {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(viewModel.rekindleReminders) { reminder in
                        RekindleCard(
                            reminder: reminder,
                            onDismiss: { withAnimation(.bmDefault) { viewModel.hide(reminder.name) } }
                        )
                    }
                }
            }
        }
    }

    private var rekindleSubtitle: String {
        let n = viewModel.rekindleReminders.count
        return n == 1
            ? "Someone you used to talk to a lot — no pressure, just a nudge"
            : "\(n) people you used to talk to a lot — no pressure, just a nudge"
    }

    // MARK: - Your chats (per-chat moment timelines)

    /// The browsable list of chats worth reminiscing about — biggest first. Each
    /// row expands to that chat's moments timeline. This is the primary surface.
    @ViewBuilder
    private var chatStoriesSection: some View {
        if !viewModel.chatStories.isEmpty {
            NostalgiaSection(
                title: "Your chats",
                subtitle: chatStoriesSubtitle,
                systemImage: "clock.arrow.circlepath",
                tint: .blue,
                solidContent: false
            ) {
                // LAZY: this list is the page's bulk (often 150+ chat rows).
                // A plain VStack materializes every row up front — layout and
                // compositing the whole tree on each scroll frame is the
                // page's scroll lag. Lazy keeps only the visible rows mounted.
                LazyVStack(alignment: .leading, spacing: Space.md) {
                    ForEach(viewModel.chatStories) { story in
                        ChatStoryRow(
                            story: story,
                            onHide: { name in withAnimation(.bmDefault) { viewModel.hide(name) } }
                        )
                    }
                }
            }
        } else if viewModel.isLoading && !viewModel.hasLoadedOnce {
            NostalgiaSection(
                title: "Your chats",
                subtitle: nil,
                systemImage: "clock.arrow.circlepath",
                tint: .blue
            ) {
                loadingRow
            }
        }
    }

    private var chatStoriesSubtitle: String {
        let n = viewModel.chatStories.count
        return n == 1
            ? "One conversation worth looking back on — tap to relive it"
            : "\(n) conversations worth looking back on — tap any to relive it"
    }

    /// Resolve which chat a given anniversary moment belongs to, by finding the
    /// story whose moments contain it (the VM's `onThisDayMoments` are flattened
    /// out of `chatStories`, so the title isn't carried on the moment itself).
    private func chatTitle(forMomentID id: String) -> String {
        for story in viewModel.chatStories {
            if story.moments.contains(where: { $0.id == id }) { return story.title }
        }
        return ""
    }

    private var now: Date { Date() }
    private var calendar: Calendar { Calendar.current }

    /// True when the two surfaces this panel actually renders are both empty —
    /// drives the friendly empty state. (We intentionally ignore the legacy
    /// `viewModel.isEmpty`, which also considers the retired surfaces.)
    private var storiesEmpty: Bool {
        viewModel.chatStories.isEmpty && viewModel.onThisDayMoments.isEmpty
    }

    // MARK: - Hidden-people management entry

    /// A quiet footer control to open the hidden-people manager. Always present
    /// (even when nothing is hidden) so the user can pre-emptively hide anyone.
    private var hiddenManagementBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "eye.slash")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(hiddenSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.sm)
            Button("Manage") { showingHiddenSheet = true }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var hiddenSummary: String {
        let n = viewModel.hiddenFromNostalgia.count
        switch n {
        case 0: return "No one is hidden from nostalgia."
        case 1: return "1 person is hidden from nostalgia."
        default: return "\(n) people are hidden from nostalgia."
        }
    }

    // MARK: - Shared bits

    private var loadingRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                // Tracks the live DB-backed loader (`viewModel.phase`) so the
                // wait reads as honest progress; falls back to a default before
                // the first loader reports.
                Text(viewModel.phase?.message ?? "Looking back through your history…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // Determinate bar — fills as the (two) real stages complete.
            if let phase = viewModel.phase {
                ProgressView(value: Double(phase.step + 1),
                             total: Double(NostalgiaViewModel.LoadPhase.total))
                    .progressViewStyle(.linear)
                    .tint(.pink)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.vertical, Space.sm)
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No stories to look back on yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("As your conversations grow, the chats worth reminiscing about — and their notable moments — will appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }
}

// MARK: - Section wrapper (solid content panel, hairline border)

/// One titled section of the panel. Header strip + content.
///
/// `solidContent` (default true) wraps the content in a single solid card with a
/// hairline border — matches `StatPanel`'s content treatment without the
/// navigation-layer glass (HIG: glass = navigation only). Pass `false` when the
/// content is ALREADY a stack of self-contained cards (e.g. the chat-story rows),
/// so we don't draw a card-inside-a-card.
private struct NostalgiaSection<Content: View>: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    var solidContent: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if solidContent {
                content()
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                            .fill(Color.contentBackground)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                            .strokeBorder(Color.hairline, lineWidth: 1)
                    }
            } else {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
