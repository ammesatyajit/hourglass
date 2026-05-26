import SwiftUI

/// A pill-shaped filter token. Lives inline in the search field for things
/// like "Person: Mom" or "Last 30 days". Optionally dismissible.
///
/// Tinting is intentional but subtle — see `docs/design-notes.md` for the
/// per-category tint palette.
struct FilterChip: View {
    let category: FilterCategory
    let label: String
    var icon: String? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: icon ?? category.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(category.tint)
                .symbolRenderingMode(.hierarchical)

            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1.0 : 0.65)
                .help("Remove filter")
            }
        }
        .padding(.leading, Space.md)
        .padding(.trailing, onDismiss == nil ? Space.md : Space.sm)
        .padding(.vertical, 6)
        .glassOrMaterial(
            tint: category.tint,
            tintOpacity: 0.18,
            in: Capsule(style: .continuous)
        )
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
    }
}

// MARK: - Previews

#Preview("FilterChip — variants", traits: .fixedLayout(width: 520, height: 220)) {
    ZStack {
        LinearGradient(
            colors: [.teal.opacity(0.5), .blue.opacity(0.55), .indigo.opacity(0.5)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        glassEffectContainerCompat(spacing: 20) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    FilterChip(category: .person, label: "Mom", onDismiss: {})
                    FilterChip(category: .person, label: "Alex Chen", onDismiss: {})
                }
                HStack(spacing: Space.sm) {
                    FilterChip(category: .dateRange, label: "Last 30 days", onDismiss: {})
                    FilterChip(category: .dateRange, label: "2024", onDismiss: {})
                }
                HStack(spacing: Space.sm) {
                    FilterChip(category: .chat, label: "Vegas planning", onDismiss: {})
                    FilterChip(category: .chat, label: "Group chats only", onDismiss: {})
                }
                HStack(spacing: Space.sm) {
                    FilterChip(category: .freeText, label: "flight", onDismiss: {})
                    FilterChip(category: .freeText, label: "no dismiss") // no x button
                }
            }
            .padding(Space.xl)
        }
    }
}

#Preview("FilterChip — dark mode", traits: .fixedLayout(width: 520, height: 160)) {
    ZStack {
        Color.black.ignoresSafeArea()
        LinearGradient(
            colors: [.purple.opacity(0.6), .black],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()

        glassEffectContainerCompat(spacing: 20) {
            HStack(spacing: Space.sm) {
                FilterChip(category: .person, label: "Mom", onDismiss: {})
                FilterChip(category: .dateRange, label: "Last 30 days", onDismiss: {})
                FilterChip(category: .chat, label: "Vegas planning", onDismiss: {})
                FilterChip(category: .freeText, label: "flight", onDismiss: {})
            }
            .padding(Space.xl)
        }
    }
    .preferredColorScheme(.dark)
}
