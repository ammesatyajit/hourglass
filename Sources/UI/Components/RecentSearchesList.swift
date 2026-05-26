//
//  RecentSearchesList.swift
//  Hourglass
//
//  Compact list of recently-run search queries, surfaced in the empty
//  state of the spotlight panel. Tapping an entry repopulates the search
//  field with the original query and reruns the search.
//
//  Visual
//  ------
//  Solid (not glass) content-layer rows — same vocabulary as the empty-
//  state quick-filter pills. A clock icon distinguishes them from the
//  quick-filter pills at a glance. Hover reveals a small × per row so
//  the user can prune the list without diving into Settings.
//
//  We deliberately cap the *visible* count at 5, even when the store
//  holds up to 8. The extra capacity lets a "recent" still surface even
//  if the user opens the panel after a long session of varied searches;
//  showing all 8 at once crowds the empty state.
//

import SwiftUI

struct RecentSearchesList: View {
    /// The full history. Caller filters/orders before passing.
    let entries: [String]
    /// Maximum entries to render. Default 5 — keeps the empty state
    /// breathable.
    var maxVisible: Int = 5
    /// Tap an entry → load the query and run the search.
    let onSelect: (String) -> Void
    /// Click the per-row × → remove that entry from the store.
    let onRemove: (String) -> Void

    private var visible: [String] {
        Array(entries.prefix(maxVisible))
    }

    var body: some View {
        if visible.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text("Recent")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Spacer()
                }
                .padding(.horizontal, Space.xs)

                VStack(spacing: 2) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, entry in
                        RecentRow(
                            entry: entry,
                            onSelect: { onSelect(entry) },
                            onRemove: { onRemove(entry) }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
            }
            .frame(maxWidth: 520)
            .animation(.bmDefault, value: visible)
        }
    }
}

private struct RecentRow: View {
    let entry: String
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(entry)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1.0 : 0.0)
                .help("Forget this search")
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        .help("Run again — \(entry)")
    }
}

// MARK: - Previews

#Preview("RecentSearchesList", traits: .fixedLayout(width: 560, height: 220)) {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        RecentSearchesList(
            entries: [
                "cactus from:Mom",
                "type:image last:30d",
                "reactions:>=3 in:family",
                "vacation+flight",
                "henry",
            ],
            onSelect: { _ in },
            onRemove: { _ in }
        )
        .padding(Space.xl)
    }
}
