//
//  NostalgiaDepthCards.swift
//  Hourglass — Dashboard / Nostalgia panel (hide-management UX)
//
//  The SENSITIVE hide-management UX for the Nostalgia panel, over the read-only
//  published surfaces on `NostalgiaViewModel`:
//
//    • HideSuggestionCard — a neutral "you were very close — hide from reminders
//      & nostalgia?" prompt with Hide / Keep. COPY IS NEUTRAL by contract: it
//      NEVER says "ex", "romantic", "partner", or implies a relationship type.
//      No label, no badge, nothing that reveals WHY the person was suggested.
//    • HiddenManagementSheet — lists everyone currently hidden with an un-hide
//      button each, plus an add-anyone contact picker. This is how the user
//      sees and controls the suppression set.
//    • HidePersonButton — the small per-row hide affordance reused across the
//      story cards (in `NostalgiaStoryCards.swift`).
//
//  NOTE: the earlier "depth" cards (StreakCard / FirstWordsCard / EraTimelineCard
//  / FunnyMomentCard) were RETIRED when Nostalgia was rebuilt into per-chat
//  story timelines — they're gone; the per-chat `ChatStoryRow` + `MomentTimeline`
//  in `NostalgiaStoryCards.swift` supersede them.
//
//  All content-layer (solid + hairline per the glass policy). `AvatarView` is
//  reused for people. Owned by design-agent.
//

import SwiftUI

// MARK: - Hide suggestion (NEUTRAL, suppression-only)

/// A gentle, NEUTRAL prompt to hide someone from reminders & nostalgia. Driven
/// by `suggestedHides`. The copy NEVER says "ex/romantic/partner" or implies a
/// relationship type — it is purely "you two were very close — hide from
/// reminders?" with Hide / Keep. There is NO label or badge that reveals why
/// the person was surfaced. Confirm → `hide(name)`; Keep → `dismissHideSuggestion`.
struct HideSuggestionCard: View {
    let name: String
    let avatarData: Data?
    let onHide: () -> Void
    let onKeep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            AvatarView(
                imageData: avatarData,
                initials: NostalgiaInitials.of(name),
                size: 40,
                tint: .secondary.opacity(0.25)
            )

            VStack(alignment: .leading, spacing: Space.xs) {
                // NEUTRAL copy — no relationship inference, suppression-only.
                Text("You and \(firstName) were very close.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Want to hide them from reminders & nostalgia? You can undo this any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.sm) {
                    Button(action: onHide) {
                        Text("Hide")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, Space.md).padding(.vertical, Space.xs + 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Hide \(name) from reminders & nostalgia")

                    Button(action: onKeep) {
                        Text("Keep")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, Space.md).padding(.vertical, Space.xs + 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Keep \(name) — don't ask again")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

// MARK: - Hidden management sheet

/// The management view for the suppression set: everyone currently hidden, each
/// with an un-hide button, plus an add-anyone picker so the user can hide ANY
/// contact (not only the ones the advisory detector surfaced). Presented as a
/// sheet from the panel's "Hidden people" control.
struct HiddenManagementSheet: View {
    /// Current hidden display names.
    let hidden: Set<String>
    /// All resolvable contacts (for the add-anyone picker).
    let allContacts: [Contact]
    let onHide: (String) -> Void
    let onUnhide: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var addQuery = ""

    private var hiddenSorted: [String] {
        hidden.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Contacts not already hidden, filtered by the search query. Capped so the
    /// list stays light.
    private var addCandidates: [Contact] {
        let q = addQuery.trimmingCharacters(in: .whitespaces)
        return allContacts
            .filter { !hidden.contains($0.displayName) }
            .filter { q.isEmpty || $0.displayName.localizedCaseInsensitiveContains(q) }
            .prefix(40)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    currentlyHiddenSection
                    addAnyoneSection
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
            }
        }
        .padding(.top, Space.lg)
        .frame(width: 460, height: 540)
        .background(Color.chromeBackground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Hidden people")
                    .font(.title3.weight(.semibold))
                Text("People you've hidden won't appear in nostalgia or reminders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.lg)
    }

    @ViewBuilder
    private var currentlyHiddenSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("CURRENTLY HIDDEN")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)

            if hiddenSorted.isEmpty {
                Text("No one is hidden. Use the list below to hide anyone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
                    .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(Color.secondary.opacity(0.06)))
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(hiddenSorted, id: \.self) { name in
                        HiddenPersonRow(name: name) { onUnhide(name) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var addAnyoneSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("HIDE SOMEONE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)

            // Search field for the contact picker.
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search contacts", text: $addQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1))

            if allContacts.isEmpty {
                Text("Contacts unavailable.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if addCandidates.isEmpty {
                Text("No matching contacts.")
                    .font(.caption).foregroundStyle(.tertiary).padding(.vertical, Space.xs)
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(addCandidates) { contact in
                        AddablePersonRow(contact: contact) { onHide(contact.displayName) }
                    }
                }
            }
        }
    }
}

/// One row in the "currently hidden" list — a person + an un-hide button.
private struct HiddenPersonRow: View {
    let name: String
    let onUnhide: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            AvatarView(imageData: nil, initials: NostalgiaInitials.of(name), size: 28,
                       tint: .secondary.opacity(0.22))
            Text(name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: Space.sm)
            Button(action: onUnhide) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
                    Text("Un-hide").font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.18 : 0.10)))
            }
            .buttonStyle(.plain)
            .help("Show \(name) in nostalgia again")
        }
        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(Color.secondary.opacity(0.05)))
        .onHover { inside in withAnimation(.bmHover) { hovering = inside } }
    }
}

/// One row in the add-anyone picker — a contact + a hide button.
private struct AddablePersonRow: View {
    let contact: Contact
    let onHide: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onHide) {
            HStack(spacing: Space.sm) {
                AvatarView(imageData: contact.avatarData,
                           initials: NostalgiaInitials.of(contact.displayName),
                           size: 28, tint: .secondary.opacity(0.22))
                Text(contact.displayName).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: Space.sm)
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color.secondary.opacity(hovering ? 0.10 : 0.04)))
        }
        .buttonStyle(.plain)
        .help("Hide \(contact.displayName) from nostalgia & reminders")
        .onHover { inside in withAnimation(.bmHover) { hovering = inside } }
    }
}

// MARK: - Shared per-row hide affordance

/// A small eye-slash button used across the depth cards to hide a person. Quiet
/// by default, emphasized on ITS OWN hover. Neutral wording — never implies
/// anything about the relationship.
///
/// The hover state lives HERE, not on the host row: a row-level `.onHover`
/// makes every row a scroll→state converter (rows crossing the stationary
/// cursor during scroll fire animated @State writes that re-evaluate the whole
/// row body — avatar, formatters, the lot). Scoped to this 22pt glyph, a
/// crossing re-evaluates only the button, and rows without a button carry no
/// tracking area at all.
struct HidePersonButton: View {
    let name: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Hide \(name) from nostalgia & reminders")
        .accessibilityLabel("Hide \(name)")
    }
}

// MARK: - Small shared formatting helpers

enum NostalgiaInitials {
    static func of(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }
}

enum NostalgiaDateText {
    // Cached: these run from row bodies during scroll, and a fresh
    // DateFormatter per call is milliseconds-scale — enough to hitch.
    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f
    }()
    private static let longFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        return f
    }()

    static func medium(_ date: Date) -> String {
        mediumFormatter.string(from: date)
    }
    static func long(_ date: Date) -> String {
        longFormatter.string(from: date)
    }
}
