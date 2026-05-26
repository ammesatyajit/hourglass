//
//  KeyboardShortcutBadge.swift
//  Hourglass — UI Components
//
//  Spotlight-style "⌘ Space" badge for surfacing a globally-registered
//  hotkey in the UI. Reads the live binding from `KeyboardShortcuts` and
//  reactively re-renders when the user rebinds it in Settings, so the
//  user's currently-configured combo is the only source of truth.
//
//  Visual: small monospaced glyph row inside a subtle hairline-outlined
//  rounded rect — matches the system convention for kbd hints in menus
//  and tooltips. Strictly solid (content layer) — no glass. The hero CTA
//  it lives inside owns the navigation-layer glass.
//
//  Two flavors:
//    - `KeyboardShortcutBadge` — the bare badge. Use inline alongside a
//      verb ("Press [⌃⌥Space]" or "[⌃⌥Space] anywhere…").
//    - The `unsetFallback` overload renders a tappable "Set hotkey…" pill
//      when no shortcut is bound, so the user always has a route to
//      Settings.
//

import SwiftUI
import AppKit
import KeyboardShortcuts

/// A small kbd-style pill that displays a globally-registered keyboard
/// shortcut. Re-renders live when the user rebinds the shortcut in
/// Settings — observed via `UserDefaults.didChangeNotification` (the
/// `KeyboardShortcuts` library writes shortcut changes to standard
/// UserDefaults, so the notification fires when a rebind lands).
struct KeyboardShortcutBadge: View {
    /// The shortcut name to render.
    let name: KeyboardShortcuts.Name

    /// What to display when the user has no shortcut bound.
    ///
    /// - `.hidden`: render an empty view (badge disappears).
    /// - `.placeholder(label:)`: render a tappable "Set hotkey…" pill that
    ///   opens Settings when clicked.
    var unsetBehavior: UnsetBehavior = .placeholder(label: "Set hotkey…")

    /// Visual size variant. `.regular` for inline use beside a verb;
    /// `.compact` for the footer hint where it sits in flowing caption text.
    var size: Size = .regular

    enum UnsetBehavior: Equatable {
        case hidden
        case placeholder(label: String)
    }

    enum Size: Equatable {
        case compact
        case regular

        var fontSize: CGFloat {
            switch self {
            case .compact: return 10.5
            case .regular: return 12
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact: return 2
            case .regular: return 3
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: return 6
            case .regular: return 8
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .compact: return 5
            case .regular: return 6
            }
        }
    }

    /// Live shortcut. Re-fetched whenever UserDefaults changes — see
    /// `.onReceive` below. Recorded as a stored String so SwiftUI diffing
    /// is cheap (the underlying `Shortcut` is keyed off Carbon codes
    /// which Equal-by-value but storing the display string keeps the
    /// comparison trivial).
    @State private var displayDescription: String?

    var body: some View {
        Group {
            if let description = displayDescription {
                badge(text: description)
            } else {
                placeholderView
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // KeyboardShortcuts writes its bindings to UserDefaults; we
            // catch any change here and re-resolve. We over-refresh
            // (every UserDefaults write fires this), but it's cheap and
            // there's no narrower notification.
            refresh()
        }
    }

    private func badge(text: String) -> some View {
        Text(text)
            .font(.system(size: size.fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.78))
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .accessibilityLabel("Keyboard shortcut: \(text)")
    }

    @ViewBuilder
    private var placeholderView: some View {
        switch unsetBehavior {
        case .hidden:
            EmptyView()
        case .placeholder(let label):
            Button {
                openSettings()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.system(size: size.fontSize - 1, weight: .medium))
                    Text(label)
                        .font(.system(size: size.fontSize, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Open Settings to bind a hotkey")
        }
    }

    private func refresh() {
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            // `.description` is the symbolic representation, e.g. "⌃⌥Space"
            // — exactly what Spotlight's menu hint shows for ⌘ Space.
            displayDescription = shortcut.description
        } else {
            displayDescription = nil
        }
    }

    /// Open the app's Settings scene. SwiftUI's preferred route is
    /// `openSettings` but that's environment-only and we're a self-
    /// contained component — fall back to the AppKit selector, which
    /// the SwiftUI `Settings` scene answers to since macOS 14.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

// MARK: - Previews

#Preview("Set hotkey — bound", traits: .fixedLayout(width: 360, height: 80)) {
    HStack(spacing: Space.sm) {
        Text("Press")
            .foregroundStyle(.secondary)
        KeyboardShortcutBadge(name: .toggleSpotlightPanel)
        Text("anywhere to search")
            .foregroundStyle(.secondary)
    }
    .font(.subheadline)
    .padding(Space.lg)
    .background(Color.chromeBackground)
}

#Preview("Set hotkey — compact", traits: .fixedLayout(width: 360, height: 60)) {
    HStack(spacing: Space.xs) {
        Text("Tip:")
            .foregroundStyle(.tertiary)
        KeyboardShortcutBadge(name: .toggleSpotlightPanel, size: .compact)
        Text("from anywhere")
            .foregroundStyle(.tertiary)
    }
    .font(.caption)
    .padding(Space.lg)
    .background(Color.chromeBackground)
}
