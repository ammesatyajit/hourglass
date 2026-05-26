import SwiftUI
import KeyboardShortcuts

@main
struct HourglassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Dashboard — the primary windowed surface. Declared FIRST so SwiftUI
        // treats it as the default scene: opens on cold launch and reopens
        // when the user clicks the Dock icon while no windows are visible.
        // Generous default size so the chart and two top-lists fit
        // side-by-side without crowding; a smaller min size keeps it usable
        // when the user shrinks the window down.
        Window("Dashboard", id: WindowID.dashboard) {
            // Inject the AppDelegate-owned SearchViewModel explicitly so
            // the dashboard can observe its `database` property without
            // depending on `NSApp.delegate` being populated yet. At the
            // first body evaluation of DashboardView, `NSApp.delegate`
            // can still be nil even though @NSApplicationDelegateAdaptor
            // has run — that race is exactly what was breaking the NL
            // bar's reactive swap (see plans.md 2026-05-24 features-agent).
            DashboardView(searchViewModel: appDelegate.viewModel,
                          appDelegate: appDelegate)
                .frame(minWidth: 900, minHeight: 620)
                .containerBackground(.thinMaterial, for: .window)
                // Publish `openWindow` to AppKit so AppDelegate can open the
                // Dashboard on Dock-click (see `WindowOpener`).
                .background(WindowOpenerBridge())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)

        // Menu bar entry — secondary, ever-present surface for quick access
        // to the panel, the browser, and Settings.
        MenuBarExtra("Hourglass", systemImage: "magnifyingglass.circle.fill") {
            MenuBarContent(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.menu)

        // (Browse window removed 2026-05-23. It rendered `PreviewData`
        // placeholder messages — the Round-2 "wire to SearchViewModel"
        // followup was never completed and the surface was confusing for
        // anyone who clicked "Open Browser". The Dashboard is the real
        // secondary surface; the floating panel is the primary. If a
        // future thumbnail-list view wants the old `ResultRow` layout,
        // it's still available — see `Sources/UI/Components/ResultRow.swift`.)

        // Settings — currently just hotkey rebinding. SettingsLink in the menu
        // bar pops this up.
        Settings {
            SettingsView()
        }
    }
}

/// String IDs for SwiftUI scenes. Keep them centralized so callers don't
/// duplicate magic strings.
enum WindowID {
    static let dashboard = "dashboard"
}

// MARK: - Menu bar content

private struct MenuBarContent: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Search…") {
            appDelegate.showPanel()
        }
        // No `.keyboardShortcut` modifier here. The global hotkey is owned
        // by the `KeyboardShortcuts` library (registered in AppDelegate)
        // and is user-rebindable in Settings — its current value is
        // displayed by the SearchHeroCTA's `KeyboardShortcutBadge`.
        // SwiftUI's `.keyboardShortcut` would only paint a STATIC visual
        // hint next to the menu item, and we'd lie if it didn't match
        // the live binding (we previously showed ⌃⌘M while the default
        // was changed to ⌃⌥Space — that was the bug). Better to omit
        // than to mislead.

        Divider()

        Button("Dashboard…") {
            openWindow(id: WindowID.dashboard)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Hourglass") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsPane: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle search panel:", name: .toggleSpotlightPanel)
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Summons the Hourglass search panel from anywhere on macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(height: 200)
    }
}

// MARK: - AppKit ↔ SwiftUI window-open bridge

/// Invisible helper view that captures SwiftUI's `openWindow` action and
/// hands it to `WindowOpener.shared`, so AppKit code (e.g. AppDelegate
/// responding to a Dock-icon click) can open SwiftUI windows by id.
private struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                WindowOpener.shared.open = { id in
                    openWindow(id: id)
                }
            }
    }
}
