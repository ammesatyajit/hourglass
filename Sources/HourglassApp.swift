import SwiftUI
import KeyboardShortcuts
import Sparkle

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
            ZoomContainer {
                DashboardView(searchViewModel: appDelegate.viewModel,
                              appDelegate: appDelegate)
            }
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
        .commands {
            // ⌘+/⌘−/⌘0 — browser-style dashboard zoom. "+" needs ⇧ on US
            // layouts, so "=" is registered too (matches Safari/Chrome).
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { DashboardZoom.shared.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom In (=)") { DashboardZoom.shared.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                    .hidden()
                Button("Zoom Out") { DashboardZoom.shared.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { DashboardZoom.shared.reset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

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

        // Sparkle "Check for Updates…" — pulls the appcast declared in
        // Info.plist's SUFeedURL, verifies the signed update via
        // SUPublicEDKey, and (on a confirmed newer build) shows the
        // standard Sparkle update panel. The action target is the
        // SPUStandardUpdaterController owned by AppDelegate; calling
        // `checkForUpdates(_:)` is the documented "user-initiated check"
        // entry point and is always safe to invoke from a button click.
        // We disable the button when Sparkle reports it can't currently
        // check (e.g. a check is already in-flight) so we don't queue
        // duplicate checks.
        CheckForUpdatesMenuItem(updater: appDelegate.updaterController.updater)

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

// MARK: - Sparkle Check-for-Updates menu item
//
// Sparkle's recommended SwiftUI integration: observe `SPUUpdater.canCheckForUpdates`
// via KVO + Combine, and disable the button when a check is in-flight.
//
// We intentionally keep this as a tiny standalone view rather than mixing
// the `@ObservedObject` plumbing into `MenuBarContent` — the view-model
// has its own lifecycle that we want collapsed with the button.
//
// Reference: https://sparkle-project.org/documentation/programmatic-setup/

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates: Bool = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesMenuItem: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        // @StateObject's wrappedValue closure is invoked exactly once for
        // the lifetime of the view — safe to construct the VM here even
        // though `updater` is captured by reference. The VM's KVO
        // subscription stays alive until the view is removed from the
        // hierarchy (which, for a menu bar item, is "process lifetime").
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
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
    /// Persisted NL "quality mode". Backed by the same UserDefaults key
    /// `NLModelPreference` reads at `ModelDownloader` construction. Writing it
    /// here posts `UserDefaults.didChangeNotification`, which `AppDelegate`
    /// observes to rebuild the downloader against the newly-selected model.
    @AppStorage(NLModelPreference.defaultsKey) private var qualityRaw: String =
        NLModelQuality.standard.rawValue

    private var quality: NLModelQuality {
        NLModelQuality(rawValue: qualityRaw) ?? .standard
    }

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

            Section {
                Picker("Answer quality:", selection: $qualityRaw) {
                    ForEach(NLModelQuality.allCases) { mode in
                        Text("\(mode.settingsTitle) — \(mode.displayLabel) (\(mode.approxDownloadLabel))")
                            .tag(mode.rawValue)
                    }
                }
            } header: {
                Text("Natural-language search")
            } footer: {
                Text("Standard runs Qwen3 4B — fast and accurate for most questions. High runs Qwen2.5 7B Instruct for tougher questions, at a larger download and more memory. Switching modes downloads the new model the next time you ask a question.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(height: 320)
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
