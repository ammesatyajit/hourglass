import SwiftUI

/// A sidebar list row: icon + label + optional count badge.
///
/// In macOS 26 the sidebar surface itself gets glass automatically from
/// `NavigationSplitView` + `.sidebar` list style. We only paint glass on the
/// **selected** state, as a subtle highlight — selected rows feel like little
/// glowing pills.
struct SidebarItem: View {
    let label: String
    let systemImage: String
    var count: Int? = nil
    var isSelected: Bool = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 20)

            Text(label)
                .font(.body)
                .foregroundStyle(labelColor)
                .lineLimit(1)

            Spacer(minLength: Space.sm)

            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Glass only on selected state; subtle wash on hover.
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .glassOrMaterial(
                        tint: Color.accentColor,
                        tintOpacity: 0.30,
                        in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    )
            } else if isHovering {
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium))
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        .animation(.bmDefault, value: isSelected)
    }

    private var iconColor: Color {
        isSelected ? Color.accentColor : .secondary
    }

    private var labelColor: Color {
        isSelected ? .primary : .primary
    }
}

// MARK: - Previews

#Preview("SidebarItem — states", traits: .fixedLayout(width: 260, height: 340)) {
    ZStack {
        Color.chromeBackground.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 2) {
            Text("LIBRARY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.xs)

            SidebarItem(label: "All Messages", systemImage: "tray.full", count: 12_483)
            SidebarItem(label: "People", systemImage: "person.2", count: 247, isSelected: true)
            SidebarItem(label: "Group Chats", systemImage: "person.3", count: 18)
            SidebarItem(label: "Pinned", systemImage: "pin.fill")

            Text("TIME RANGE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Space.md)
                .padding(.top, Space.md)
                .padding(.bottom, Space.xs)

            SidebarItem(label: "Last 7 days", systemImage: "calendar")
            SidebarItem(label: "Last 30 days", systemImage: "calendar")
            SidebarItem(label: "This year", systemImage: "calendar")
            SidebarItem(label: "All time", systemImage: "infinity")
        }
        .padding(.vertical, Space.md)
        .padding(.horizontal, Space.sm)
    }
}

#Preview("SidebarItem — dark", traits: .fixedLayout(width: 260, height: 240)) {
    ZStack {
        Color.chromeBackground.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 2) {
            SidebarItem(label: "All Messages", systemImage: "tray.full", count: 12_483)
            SidebarItem(label: "People", systemImage: "person.2", count: 247)
            SidebarItem(label: "Group Chats", systemImage: "person.3", count: 18, isSelected: true)
            SidebarItem(label: "Pinned", systemImage: "pin.fill")
        }
        .padding(Space.md)
    }
    .preferredColorScheme(.dark)
}
