//
//  SearchHeroCTA.swift
//  Hourglass — Dashboard components
//
//  Hero "Search messages" affordance at the top of the Dashboard. The
//  whole point: tell the user — in zero clicks of discovery — that this
//  app is a search tool, and let them launch the floating Spotlight
//  panel without knowing the hotkey.
//
//  Visual contract (per `docs/design-notes.md`):
//    - Lives on the **navigation layer** → wrapped in liquid glass via
//      `.glassEffect(_:in:)` on the outer rounded rect. The CTA acts as
//      a launcher / control surface, not a content card.
//    - Sized to feel like the Spotlight bar that the click summons —
//      tall pill, generous internal padding, magnifying glass leading
//      glyph, hotkey badge trailing.
//    - Hover state nudges the surface slightly and brightens the
//      accent. Press state scales down 1% (Apple's standard tactile
//      feedback amount). Animations use `bm*` presets.
//    - The placeholder slot supports a rotating example query — runs
//      while the user hasn't yet hovered, fades on hover so the row
//      stops being noisy when the user is actively engaging with it.
//
//  Wiring:
//    - `action` fires on click. The Dashboard wires this to
//      `(NSApp.delegate as? AppDelegate)?.showPanel()`.
//    - `hotkeyName` drives the trailing badge. When the user has no
//      shortcut bound, the badge falls back to a "Set hotkey…" pill
//      that opens Settings — so the user always has a path forward.
//

import SwiftUI
import KeyboardShortcuts

struct SearchHeroCTA: View {

    /// Action invoked when the user clicks the CTA. Should summon the
    /// floating Spotlight panel.
    let action: () -> Void

    /// Shortcut to surface in the trailing badge.
    var hotkeyName: KeyboardShortcuts.Name = .toggleSpotlightPanel

    /// Static fallback placeholder for the search prompt when the
    /// rotating examples are exhausted or the caller passes none.
    var placeholder: String = "Search every message, person, and chat…"

    /// Rotating example queries that animate in/out behind the static
    /// "Search messages" headline. Empty disables rotation entirely.
    var exampleQueries: [String] = SearchHeroCTA.defaultExamples

    /// Default examples — a mix of phrases, person filters, date
    /// filters, and chat filters to telegraph the query syntax without
    /// requiring the user to read docs.
    static let defaultExamples: [String] = [
        "from:mom flights",
        "vegas trip last:6mo",
        "type:image last:30d",
        "cactus 2024",
        "happy birthday from:Henry",
    ]

    @State private var isHovering: Bool = false

    /// Index into `exampleQueries`. Advances on a 4-second timer while
    /// the user isn't engaging with the CTA. Resets on hover.
    @State private var rotatorIndex: Int = 0

    /// Whether to drive the rotating example slot. False during hover
    /// (so the user has a static surface while interacting) and when
    /// `exampleQueries` is empty.
    private var isRotating: Bool {
        !exampleQueries.isEmpty && !isHovering
    }

    private var currentExample: String {
        guard !exampleQueries.isEmpty else { return placeholder }
        let safe = ((rotatorIndex % exampleQueries.count) + exampleQueries.count) % exampleQueries.count
        return exampleQueries[safe]
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.accentColor.opacity(0.75))
                    .accessibilityHidden(true)
                    .animation(.bmHover, value: isHovering)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Search messages")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    rotatingSubtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingHint
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous))
        }
        .buttonStyle(PressableHeroButtonStyle())
        .glassOrMaterial(
            tint: Color.accentColor,
            tintOpacity: isHovering ? 0.14 : 0.08,
            in: RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isHovering ? 0.32 : 0.14),
                    lineWidth: 1
                )
        )
        // Subtle floating shadow tied to hover — implies the surface
        // can be lifted.
        .shadow(
            color: Color.accentColor.opacity(isHovering ? 0.18 : 0.0),
            radius: isHovering ? 14 : 0,
            x: 0,
            y: isHovering ? 4 : 0
        )
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.bmHover, value: isHovering)
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        // Auto-advance the rotator. We can't use the .task(id:) trick
        // because we want the timer to keep running across re-renders;
        // a simple Combine timer would also work but we prefer a Task
        // so it auto-cancels when the view leaves the hierarchy.
        .task(id: isRotating) {
            guard isRotating, exampleQueries.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, isRotating else { return }
                withAnimation(.bmDefault) {
                    rotatorIndex &+= 1
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Search messages")
        .accessibilityHint("Opens the floating search panel")
    }

    /// Rotating subtitle that cycles through example queries with a
    /// crossfade. Falls back to the static placeholder when rotation
    /// is disabled.
    @ViewBuilder
    private var rotatingSubtitle: some View {
        if exampleQueries.isEmpty {
            Text(placeholder)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text(currentExample)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .id("example-\(rotatorIndex)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity.combined(with: .offset(y: -4))
                ))
        }
    }

    /// Trailing hotkey badge — "Press ⌃⌥Space" or, when the user
    /// hasn't bound a shortcut, a tappable "Set hotkey…" pill that
    /// opens Settings.
    private var trailingHint: some View {
        HStack(spacing: Space.xs) {
            // `.hidden` (not `.placeholder`) — the placeholder mode
            // renders a NESTED Button ("Set hotkey…" tappable pill) during
            // the initial render before `displayDescription` resolves.
            // SwiftUI binds gesture state on that first render and the
            // outer hero Button's action never fires, even after the
            // nested element swaps to a plain Text. Until the shortcut
            // is rebindable from here (it's set in Settings anyway), the
            // safest default is to just hide.
            KeyboardShortcutBadge(
                name: hotkeyName,
                unsetBehavior: .hidden,
                size: .regular
            )
        }
    }
}

// MARK: - Button style

/// `.plain`-style button style with a subtle press-down nudge. We need a
/// custom style here (rather than `.plain`) because we want a tactile
/// press-state response on the hero CTA — and the proper way to read
/// `isPressed` in SwiftUI is via `ButtonStyleConfiguration`, not the
/// private `_onButtonGesture` SPI.
private struct PressableHeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
            .animation(.bmHover, value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("SearchHeroCTA — light", traits: .fixedLayout(width: 900, height: 200)) {
    SearchHeroCTA(action: {})
        .padding(Space.xl)
        .background(Color.chromeBackground)
        .preferredColorScheme(.light)
}

#Preview("SearchHeroCTA — dark", traits: .fixedLayout(width: 900, height: 200)) {
    SearchHeroCTA(action: {})
        .padding(Space.xl)
        .background(Color.chromeBackground)
        .preferredColorScheme(.dark)
}

#Preview("SearchHeroCTA — no examples", traits: .fixedLayout(width: 900, height: 200)) {
    SearchHeroCTA(
        action: {},
        placeholder: "Search every message, person, and chat…",
        exampleQueries: []
    )
    .padding(Space.xl)
    .background(Color.chromeBackground)
}
