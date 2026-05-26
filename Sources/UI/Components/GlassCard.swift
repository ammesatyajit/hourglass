import SwiftUI

/// A reusable container that wraps content in Liquid Glass.
///
/// Use this for navigation-layer surfaces: search fields, floating controls,
/// sidebar item backgrounds. **Do not** wrap content (result rows, list items)
/// in `GlassCard` — see `docs/design-notes.md` for the rationale.
///
/// Example:
/// ```swift
/// GlassCard(cornerRadius: Radius.xlarge) {
///     HStack { Image(systemName: "magnifyingglass"); TextField(...) }
/// }
/// ```
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Radius.large
    var tint: Color? = nil
    var showsBorder: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content()
            .glassOrMaterial(
                tint: tint ?? .clear,
                tintOpacity: tint == nil ? 0.0 : 0.32,
                in: shape
            )
            .overlay {
                if showsBorder {
                    shape.strokeBorder(Color.hairline, lineWidth: 1)
                }
            }
    }
}

// MARK: - Previews

#Preview("GlassCard — light", traits: .fixedLayout(width: 440, height: 280)) {
    ZStack {
        // Colorful backdrop so glass effect is visible in preview.
        LinearGradient(
            colors: [.orange.opacity(0.6), .pink.opacity(0.5), .purple.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack(spacing: Space.lg) {
            GlassCard {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Default glass card")
                        .font(.headline)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
            }

            GlassCard(cornerRadius: Radius.medium, tint: .blue, showsBorder: true) {
                Text("Tinted with border")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
            }

            GlassCard(cornerRadius: Radius.xlarge) {
                HStack(spacing: Space.md) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Larger radius, search-bar-sized")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.xl)
    }
    .preferredColorScheme(.light)
}

#Preview("GlassCard — dark", traits: .fixedLayout(width: 440, height: 280)) {
    ZStack {
        LinearGradient(
            colors: [.blue.opacity(0.45), .indigo.opacity(0.55), .black],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack(spacing: Space.lg) {
            GlassCard {
                Text("Glass on dark")
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
            }
            GlassCard(tint: .purple, showsBorder: true) {
                Text("Tinted on dark")
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
            }
        }
        .padding(Space.xl)
    }
    .preferredColorScheme(.dark)
}
