//
//  RekindleCards.swift
//  Hourglass — Dashboard / Nostalgia "Reach out?" rekindle panel
//
//  Renders `NostalgiaViewModel.rekindleReminders` ([RekindleReminder]) — the
//  heavy 1:1 correspondents (upper-quartile by volume) the user has gone quiet
//  with for ≥1 month. The user asked to be reminded "to text people I haven't
//  texted, every month I haven't texted them — only for people who used to be in
//  the top 10 / upper quartile by volume."
//
//  TONE (load-bearing — this is the most sensitive surface in the app):
//    • A GENTLE nudge, never naggy or guilt-trippy. The copy is warm and
//      backward-looking ("you two used to talk a lot"), never an obligation
//      ("you should text them", "it's been too long"). No red badges, no
//      countdown-to-shame.
//    • Each card is DISMISSABLE per-person, and dismissing reuses the EXISTING
//      `hiddenFromNostalgia` hide mechanism (the same `viewModel.hide(_:)` the
//      Manage sheet drives) — so hiding someone here hides them EVERYWHERE in
//      Nostalgia + reminders, immediately and persistently. The card frames this
//      as "Not now" (soft), not "Block".
//    • The list is ALREADY suppression-filtered by the VM (hidden set AND the
//      advisory romantic flag) before it ever reaches us — a "say hi?" nudge for
//      an ex is exactly what the hide model prevents.
//
//  STYLE: a SOLID, warm-tinted content card with a hairline border (glass is
//  navigation-only per the HIG). Avatar via the shared `AvatarView`. Spacing /
//  radius / tint from `DesignTokens`. Dark-mode correct; reduce-motion respected.
//  Owned by design-agent.
//

import SwiftUI

// MARK: - One rekindle card

/// A single warm "reach back out?" card: the person's avatar + name, a gentle
/// backward-looking line ("you used to talk a lot · ~N months quiet"), the
/// all-time 1:1 volume, and a soft per-person "Not now" dismissal that reuses the
/// existing hide mechanism.
struct RekindleCard: View {
    let reminder: RekindleReminder
    /// Hide this person everywhere (reuses `NostalgiaViewModel.hide`).
    let onDismiss: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Warm coral — affectionate, not alarming. Distinct from the cool blue of
    /// the chat-stories section so "reach out" reads as its own gentle surface.
    private let tint = Color.pink

    private var firstName: String {
        reminder.name.split(whereSeparator: { $0 == " " || $0 == "," })
            .first.map(String.init) ?? reminder.name
    }

    private var initials: String {
        let comps = reminder.name.split(separator: " ")
        let first = comps.first?.first.map(String.init) ?? ""
        let last = comps.count > 1 ? comps.last?.first.map(String.init) ?? "" : ""
        let r = (first + last).uppercased()
        return r.isEmpty ? "?" : r
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            AvatarView(
                imageData: reminder.avatarData,
                initials: initials,
                size: 44,
                tint: tint.opacity(0.85),
                initialsForeground: .white
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // The gentle, backward-looking line — never an obligation.
                Text(quietLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Volume — the "you really did talk a lot" evidence, quiet.
                Label("\(NostalgiaFormat.compact(reminder.volume)) messages together",
                      systemImage: "bubble.left.and.bubble.right.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Space.sm)

            // The soft dismissal. "Not now" — not "Block". Hover-revealed so the
            // resting card stays warm and uncluttered, but always reachable.
            Button(action: { withAnimation(.bmDefault) { onDismiss() } }) {
                Text("Not now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.06 : 0.0)))
            .opacity(hovering ? 1 : 0.55)
            .help("Stop reminding you about \(firstName) — hides them everywhere in Nostalgia")
            .accessibilityLabel("Not now")
            .accessibilityHint("Stops reminders about \(firstName) and hides them from Nostalgia")
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(tint.opacity(hovering ? 0.08 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(hovering ? tint.opacity(0.28) : Color.hairline, lineWidth: 1))
        .onHover { inside in withAnimation(reduceMotion ? .none : .bmHover) { hovering = inside } }
    }

    /// "You two used to talk a lot · quiet for about N months." Warm, never
    /// guilt-tripping. Months come straight from the VM (`monthsSince`, ≥1).
    private var quietLine: String {
        let n = reminder.monthsSince
        let span: String
        switch n {
        case 1: return "You two used to talk a lot — it’s been about a month."
        case 2...11: span = "about \(n) months"
        case 12: span = "about a year"
        default:
            let years = n / 12
            span = years == 1 ? "over a year" : "about \(years) years"
        }
        return "You two used to talk a lot — quiet for \(span)."
    }
}

// MARK: - Previews

#Preview("RekindleCard", traits: .fixedLayout(width: 460, height: 280)) {
    VStack(spacing: Space.md) {
        RekindleCard(
            reminder: RekindleReminder(
                name: "Melina Noras", avatarData: nil, volume: 4210,
                lastDate: .now.addingTimeInterval(-86_400 * 95), monthsSince: 3
            ),
            onDismiss: {}
        )
        RekindleCard(
            reminder: RekindleReminder(
                name: "David Kim", avatarData: AvatarView.placeholderPNG, volume: 1980,
                lastDate: .now.addingTimeInterval(-86_400 * 400), monthsSince: 13
            ),
            onDismiss: {}
        )
    }
    .padding(Space.lg)
    .background(Color.chromeBackground)
}
