//
//  NLSearchBar.swift
//  Hourglass — Dashboard components
//
//  The natural-language search bar on the dashboard. Sits BELOW the
//  keyword `SearchHeroCTA`. Different visual treatment — purple tint,
//  sparkles glyph, "Ask anything" headline — so users don't confuse
//  it with keyword search.
//
//  Visual contract:
//    - Liquid-glass surface (navigation layer per HIG)
//    - Purple accent tint distinguishes from the blue keyword CTA
//    - In compact state: pill with sparkles glyph + headline + placeholder
//    - Expanded state: inline text field with live agent trace below it
//    - Hero result row + "see all candidates" disclosure
//
//  Wiring:
//    - Binds to `NLSearchViewModel`. The dashboard owns one VM, hands it
//      down via `@Bindable`.
//    - On hero-row tap: invokes `onRevealMessage(messageGUID:)` so the
//      dashboard can route through `MessagesGUIDReveal` (which is
//      AppKit-only, not appropriate to call from a SwiftUI component).
//

import AppKit
import SwiftUI

struct NLSearchBar: View {

    @Bindable var viewModel: NLSearchViewModel

    /// Called when the user taps the hero result row. Caller routes to
    /// `MessagesGUIDReveal.reveal(messageGUID:)`.
    var onRevealMessage: (String) -> Void = { _ in }

    /// Called when the user explicitly asks to escalate to the Spotlight
    /// keyword panel using the agent's fallback query. Caller wires this
    /// to the same path the people-tile clicks use.
    var onEscalateToSpotlight: (String) -> Void = { _ in }

    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false
    @FocusState private var fieldFocused: Bool

    /// Rotating NL example queries shown in compact state.
    @State private var exampleIndex: Int = 0
    private static let examples: [String] = [
        "who did I text the most this year?",
        "when did I first text my best friend?",
        "how many photos did I send last month?",
        "what plans did we make about Vegas?",
        "show me my most-loved messages this year",
    ]

    private var accentTint: Color { .purple }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            mainBar
            if isExpanded {
                expandedBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.bmDefault, value: isExpanded)
        .animation(.bmDefault, value: viewModel.result != nil)
    }

    // MARK: - Main bar

    private var mainBar: some View {
        Button(action: { withAnimation(.bmDefault) { expandIfNeeded() } }) {
            HStack(spacing: Space.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isHovering ? accentTint : accentTint.opacity(0.75))
                    .accessibilityHidden(true)
                    .animation(.bmHover, value: isHovering)

                if isExpanded {
                    expandedField
                } else {
                    compactCaption
                }

                Spacer(minLength: 0)
                trailingHint
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous))
        }
        .buttonStyle(NLPressableButtonStyle())
        .glassOrMaterial(
            tint: accentTint,
            tintOpacity: isHovering ? 0.16 : 0.10,
            in: RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
                .strokeBorder(
                    accentTint.opacity(isHovering ? 0.32 : 0.14),
                    lineWidth: 1
                )
        )
        .shadow(
            color: accentTint.opacity(isHovering ? 0.18 : 0.0),
            radius: isHovering ? 14 : 0,
            x: 0,
            y: isHovering ? 4 : 0
        )
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.bmHover, value: isHovering)
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        // Auto-rotate examples in compact state.
        .task(id: isExpanded) {
            guard !isExpanded, !Self.examples.isEmpty else { return }
            while !Task.isCancelled, !isExpanded {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled, !isExpanded {
                    withAnimation(.bmDefault) {
                        exampleIndex = (exampleIndex + 1) % Self.examples.count
                    }
                }
            }
        }
    }

    private var compactCaption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Ask anything")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(Self.examples[exampleIndex])
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .id("example-\(exampleIndex)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity.combined(with: .offset(y: -4))
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedField: some View {
        HStack(spacing: Space.sm) {
            TextField(
                "who did I text the most this year?",
                text: $viewModel.query,
                axis: .horizontal
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .onSubmit {
                Task { await viewModel.ask() }
            }
            // Clear button.
            if !viewModel.query.isEmpty {
                Button(action: { viewModel.clear() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var trailingHint: some View {
        Group {
            if isExpanded {
                if viewModel.isAsking {
                    ProgressView()
                        .controlSize(.small)
                } else if !viewModel.query.isEmpty {
                    Button(action: { Task { await viewModel.ask() } }) {
                        Text("Ask")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, Space.sm)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.small)
                                    .fill(accentTint.opacity(0.18))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.small)
                                    .strokeBorder(accentTint.opacity(0.32), lineWidth: 1)
                            )
                            .foregroundStyle(accentTint)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                } else {
                    Image(systemName: "chevron.up")
                        .foregroundStyle(.tertiary)
                        .onTapGesture { withAnimation(.bmDefault) { isExpanded = false } }
                }
            } else {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func expandIfNeeded() {
        isExpanded = true
        // Defer focus until after the field renders.
        DispatchQueue.main.async { fieldFocused = true }
    }

    // MARK: - Expanded body

    @ViewBuilder
    private var expandedBody: some View {
        if let reason = viewModel.runtimeNotReadyReason {
            firstRunPrompt(reason: reason)
        } else if viewModel.isAsking {
            traceCard(steps: viewModel.partialTrace, isLive: true)
        } else if let result = viewModel.result {
            resultCard(result: result)
        }
    }

    /// Bundled-runtime failure. There is no download state or setup CTA:
    /// Needle2 ships inside the app and runs locally from the first query.
    private func firstRunPrompt(reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("AI Search unavailable")
                    .font(.headline)
            }
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.large)
                .fill(Color.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }

    private func traceCard(steps: [NLTraceStep], isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Working on it…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            ForEach(steps) { step in
                traceRow(step)
            }
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.large)
                .fill(Color.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }

    private func traceRow(_ step: NLTraceStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            switch step.status {
            case .inProgress:
                ProgressView().controlSize(.mini)
            case .complete:
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            Text(step.label)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let dur = step.duration {
                Text(formatDuration(dur))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func resultCard(result: NLQueryResult) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(result.trace) { step in
                    traceRow(step)
                }
            }
            Divider()
            if let hero = result.hero {
                heroRow(hero: hero, explanation: result.explanation)
                if result.candidates.count > 1 {
                    candidateDisclosure(
                        candidates: result.candidates,
                        heroGUID: hero.message.guid
                    )
                }
            } else {
                emptyState(result: result)
            }
            footer(result: result)
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.large)
                .fill(Color.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }

    private func heroRow(hero: MessageSearch.Result, explanation: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Image(systemName: "star.fill")
                    .foregroundStyle(accentTint)
                    .font(.caption)
                Text(hero.senderName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(hero.message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(hero.message.body)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let chatGUID = hero.chatGUID {
                Text(hero.partnerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(chatGUID)
            } else {
                Text(hero.partnerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Space.sm) {
                if let guid = hero.message.guid {
                    Button {
                        onRevealMessage(guid)
                    } label: {
                        Label("Reveal in Messages", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .tint(accentTint)
                }
                if let explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func candidateDisclosure(
        candidates: [MessageSearch.Result],
        heroGUID: String?
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, c in
                    if c.message.guid != heroGUID {
                        candidateRow(c)
                    }
                }
            }
            .padding(.top, Space.xs)
        } label: {
            Text("See \(candidates.count - 1) other candidate\(candidates.count == 2 ? "" : "s") the agent considered")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func candidateRow(_ c: MessageSearch.Result) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Text(c.message.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)
            Text(c.message.body)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let guid = c.message.guid {
                Button {
                    onRevealMessage(guid)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .tint(accentTint)
                .help("Reveal in Messages")
            }
        }
    }

    private func emptyState(result: NLQueryResult) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                Text("No matches")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            Text("I searched `\(result.fallbackQuery)` and didn't find anything. Try widening the date range or check the person's name.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                onEscalateToSpotlight(result.fallbackQuery)
            } label: {
                Label("Open in Spotlight panel", systemImage: "magnifyingglass.circle")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .tint(accentTint)
        }
    }

    private func footer(result: NLQueryResult) -> some View {
        HStack(spacing: Space.xs) {
            if result.degradedToFallback {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Used keyword fallback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
            Text("This was generated locally. Powered by \(viewModel.runtimeLabel).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                onEscalateToSpotlight(result.fallbackQuery)
            } label: {
                Text("See in Spotlight →")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.borderless)
            .tint(accentTint)
        }
        .padding(.top, Space.xs)
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        if s < 1 { return String(format: "%.0fms", s * 1000) }
        return String(format: "%.1fs", s)
    }
}

private struct NLPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.995 : 1.0)
            .animation(.bmHover, value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("NLSearchBar — compact") {
    let runtime = StubLLMRuntime()
    // We need an NLAgent for the VM. The preview can't reach a real DB
    // — provide a stub tools impl that returns nothing.
    let agent = NLAgent(runtime: runtime, tools: PreviewNLTools())
    let vm = NLSearchViewModel(agent: agent)
    return NLSearchBar(viewModel: vm)
        .padding(Space.xl)
        .frame(width: 900, height: 200)
        .background(Color.chromeBackground)
}

/// Tools impl for SwiftUI previews — returns no results. Lets the bar
/// render in compact mode without needing a real chat.db.
private struct PreviewNLTools: NLAgentTools {
    func search(query: String, dateRange: ClosedRange<Date>?, limit: Int?, order: MessageSearch.SortOrder) async throws -> [MessageSearch.Result] { [] }
    func oldestMatching(query: String) async throws -> MessageSearch.Result? { nil }
    func context(forGUID guid: String, before: Int, after: Int) async throws -> [MessageSearch.Result] { [] }
}
