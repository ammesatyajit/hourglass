import SwiftUI

/// A single message result.
///
/// **Important**: result rows are *content*, not navigation. Per Apple HIG,
/// content layers should NOT have glass. We use a quiet solid card with a
/// hairline border, lifted slightly on hover. See `docs/design-notes.md`.
///
/// Interactions:
/// - Single tap selects the row (`onTap`).
/// - Double tap reveals the message in Messages.app (`onDoubleTap`). Single-
///   click selection still fires for the first of the two clicks thanks to
///   `simultaneousGesture` ordering. Previews leave `onDoubleTap` nil.
struct ResultRow: View {
    let message: PreviewMessage
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            avatar
            VStack(alignment: .leading, spacing: Space.xs) {
                header
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.md)
        .background {
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(rowFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.55) : Color.hairline,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .scaleEffect(isHovering && !isSelected ? 1.005 : 1.0)
        .shadow(
            color: .black.opacity(isHovering ? 0.06 : 0.0),
            radius: isHovering ? 8 : 0,
            y: isHovering ? 2 : 0
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.large))
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        // Order matters: 2-count gesture must be registered BEFORE the 1-count
        // tap so SwiftUI's gesture dispatcher prefers it on a double-click.
        // Single-click `onTap` still fires for non-double clicks.
        .gesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        .onTapGesture { onTap?() }
        .animation(.bmDefault, value: isSelected)
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.08)
        }
        return Color.contentBackground.opacity(isHovering ? 0.95 : 0.7)
    }

    private var avatar: some View {
        AvatarView(
            imageData: message.avatarData,
            initials: message.avatarInitials,
            size: 36,
            // Tint only kicks in for the initials fallback. We pick a
            // deterministic hue from the sender's name so each contact's
            // monogram lands on a stable, recognizable color — even when
            // they don't have a photo. Matches the pre-avatar UX so the
            // visual diff for unknown handles is zero.
            tint: avatarFallbackColor,
            initialsForeground: .white
        )
    }

    /// Deterministic-by-sender tint for the initials fallback. Mid-saturation
    /// so the white text reads cleanly on top. Same hashing approach as the
    /// previous gradient — the monogram still looks "themed" to the contact.
    private var avatarFallbackColor: Color {
        let hue = Double(abs(message.sender.hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Text(message.sender)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if message.isFromMe {
                Text("YOU")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
            Spacer(minLength: 0)
            // Reaction badges sit immediately before the timestamp. They take
            // their natural width; the timestamp anchors the trailing edge.
            if !message.reactions.isEmpty {
                ReactionCluster(reactions: message.reactions)
            }
            Text(message.timestamp, format: .relative(presentation: .named))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: message.isGroup ? "person.3.fill" : "person.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(message.chatName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.top, 2)
    }
}

// MARK: - Previews

#Preview("ResultRow — variants", traits: .fixedLayout(width: 620, height: 540)) {
    ScrollView {
        VStack(spacing: Space.sm) {
            ForEach(Array(PreviewData.messages.prefix(5).enumerated()), id: \.element.id) { idx, msg in
                ResultRow(message: msg, isSelected: idx == 1)
            }
        }
        .padding(Space.lg)
    }
    .background(Color.chromeBackground)
}

#Preview("ResultRow — dark", traits: .fixedLayout(width: 620, height: 360)) {
    ScrollView {
        VStack(spacing: Space.sm) {
            ForEach(PreviewData.messages.prefix(4)) { msg in
                ResultRow(message: msg)
            }
        }
        .padding(Space.lg)
    }
    .background(Color.chromeBackground)
    .preferredColorScheme(.dark)
}
