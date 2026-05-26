//
//  StatPanel.swift
//  Hourglass — Dashboard components
//
//  A glass-card-wrapped panel with a header strip (title + optional accessory)
//  and arbitrary content below. Used for the chart panel and the two top-list
//  panels. Reuses the existing `GlassCard` so navigation-layer glass stays
//  consistent with the rest of the app.
//

import SwiftUI

struct StatPanel<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard(cornerRadius: Radius.large, showsBorder: true) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: Space.md)
                    accessory()
                }

                content()
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Convenience init for the common case of no accessory.
extension StatPanel where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// A small numeric stat — used in the header strip across the top of the
/// dashboard. Big number, small caption, optional subtitle.
///
/// The value + caption use `.contentTransition(.numericText())` so the
/// digits roll over fluidly during a brush-drag instead of popping —
/// matches Apple's Wallet/Fitness/Stocks aesthetic. Numeric value drives
/// the transition's `value:` so SwiftUI knows when to animate (we don't
/// want every redraw to animate, only true number changes).
struct StatTile: View {
    let label: String
    let value: String
    var caption: String? = nil

    /// Stable numeric value used to scope the `.contentTransition`
    /// animation. When the formatted `value` string changes (e.g.
    /// 184,392 → 41,008 mid-drag), this Double changes too, which
    /// triggers the numeric-text roll-over. Parsed from `value` —
    /// non-numeric characters are stripped so "184,392" → 184392.0.
    private var numericValue: Double {
        let digits = value.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .default))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText(value: numericValue))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview("StatPanel — light", traits: .fixedLayout(width: 420, height: 220)) {
    StatPanel(title: "Texting frequency", subtitle: "Last 30 days") {
        Text("body content goes here")
            .frame(height: 100)
    }
    .padding(Space.lg)
    .background(Color.chromeBackground)
}

#Preview("StatTile row", traits: .fixedLayout(width: 720, height: 110)) {
    HStack(spacing: Space.xl) {
        StatTile(label: "Total", value: "184,392", caption: "all time")
        StatTile(label: "Sent", value: "92,304", caption: "50.1%")
        StatTile(label: "Received", value: "92,088", caption: "49.9%")
        StatTile(label: "Conversations", value: "147")
    }
    .padding(Space.lg)
    .background(Color.chromeBackground)
}
