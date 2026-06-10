//
//  LinguisticInsightsPanel.swift
//  Hourglass — Linguistic Insights
//
//  Self-contained dashboard panel: "How you talk." Surfaces the GROUNDED,
//  measurable facts about the user's texting style — a grid of style stat
//  tiles (avg message length, lowercase %, question %, exclamation %, emoji %,
//  no-end-punctuation %, abbreviation rate) plus the words they stretch out
//  ("soooo", "hmmm").
//
//  CUT in the rebuild (user: "surfaces names / generic English"): the
//  "Words that are unmistakably you" cloud (leaked proper nouns) and the
//  "Signature phrases" list (generic English bigrams), plus the openers/closers
//  lists. Only the genuinely-useful, ground-truth stats remain.
//
//  COUNT RECONCILIATION: this panel and the Vernacular panel both report "how
//  many of your messages we read." They now scan the SAME cap (`maxMessages`,
//  default 400k) so the two headline counts line up; the subtitle states
//  exactly what it measures ("messages with text you sent").
//
//  Construction (for lead wiring into DashboardView):
//      LinguisticInsightsPanel(database: viewModel.database)
//  where `database` is the dashboard's already-open `ChatDatabase?`. The
//  panel owns its own `LinguisticInsightsViewModel`, runs the analysis off
//  the main actor on first appear, caches it, and renders progress / empty /
//  error states. No `ResolvedContacts` needed — the analysis is purely over
//  the user's own sent text.
//
//  Visual language: matches `StatPanel` / `ScrollableTopListPanel`. Glass
//  lives only on the panel chrome (via `StatPanel` → `GlassCard`); the inner
//  insight cards are solid surfaces with hairline borders, per the project's
//  glass policy (see docs/design-notes.md).
//

import SwiftUI

public struct LinguisticInsightsPanel: View {

    @State private var model: LinguisticInsightsViewModel

    /// - Parameters:
    ///   - database: the dashboard's open chat.db handle (read-only). When
    ///     nil the panel renders an "unavailable" state.
    ///   - maxMessages: cap on most-recent sent messages analyzed. This panel
    ///     now renders only texting-STYLE stats (avg length, lowercase %, emoji
    ///     %, abbreviation rate, elongations) — all statistically stable on a
    ///     fraction of the corpus — so we cap at 60k for fast load. (The 400k
    ///     cap that matched the Vernacular panel made this take ~30s+ decoding
    ///     bodies; the two panels now live on separate pages, so the headline
    ///     counts no longer need to agree.)
    public init(database: ChatDatabase?, maxMessages: Int = 60_000) {
        _model = State(initialValue: LinguisticInsightsViewModel(database: database, maxMessages: maxMessages))
    }

    public var body: some View {
        StatPanel(
            title: "How you talk",
            subtitle: subtitle
        ) {
            content
                .task { model.loadIfNeeded() }
        }
    }

    private var subtitle: String {
        switch model.state {
        case .loaded(let insights):
            return "Your texting habits across \(insights.totalSentMessages.formatted()) messages with text you sent"
        case .loading, .idle:
            return "Analyzing your sent messages…"
        case .empty:
            return "Not enough sent messages yet"
        case .failed:
            return "Your texting habits — length, caps, punctuation & more"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            loadingState
        case .failed(let message):
            messageState(icon: "exclamationmark.triangle",
                         title: "Couldn’t analyze your messages",
                         detail: message)
        case .empty:
            messageState(icon: "text.bubble",
                         title: "Not enough to analyze yet",
                         detail: "Send a few more messages and check back.")
        case .loaded(let insights):
            loadedState(insights)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Space.md) {
            ProgressView()
                .controlSize(.large)
            Text("Reading your sent messages…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }

    private func messageState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
        .padding(.vertical, Space.sm)
    }

    @ViewBuilder
    private func loadedState(_ insights: LinguisticInsights) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if model.usedPlaceholderBaseline {
                placeholderBaselineNote
            }

            // 1) Style stat tiles — the headline, all ground truth (avg length,
            //    lowercase %, question %, exclamation %, emoji %, no-end-
            //    punctuation %, abbreviation rate).
            if !insights.styleStats.isEmpty {
                StyleStatGrid(stats: insights.styleStats)
            }

            // 2) Words you stretch out ("soooo", "hmmm") — also ground truth.
            if !insights.elongations.isEmpty {
                ElongationCard(elongations: insights.elongations)
            }
        }
    }

    private var placeholderBaselineNote: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Using a fallback word list — distinctive-word quality is reduced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }
}

// MARK: - Inner content cards (solid surfaces, hairline borders)

/// Shared container for a single insight card: a solid rounded surface with
/// a hairline border + a small header. Matches the "content layer is not
/// glass" rule.
private struct InsightCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            content()
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }
}

/// Word elongations — "you really stretch these."
private struct ElongationCard: View {
    let elongations: [LinguisticInsights.Elongation]

    var body: some View {
        InsightCard(title: "Words you stretch out", systemImage: "arrow.left.and.right") {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(elongations.prefix(6)) { e in
                    HStack {
                        Text(e.exampleForm)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Text("\(e.count.formatted())×")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Grid of style stat tiles.
private struct StyleStatGrid: View {
    let stats: [LinguisticInsights.StyleStat]

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: Space.md)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.md) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.value)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(stat.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.8))
                    if let detail = stat.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(Space.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 1)
                )
            }
        }
    }
}
