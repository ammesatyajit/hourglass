import AppKit
import SwiftUI

/// Owns the floating spotlight panel — an `NSPanel` rather than a standard
/// `NSWindow` so it doesn't steal first-responder from whatever app the user
/// was just in.
///
/// Lifecycle:
/// - Constructed once by `AppDelegate` at launch.
/// - `toggle()` shows or hides the panel.
/// - The panel is reused across toggles — never recreated — so the search
///   state inside it survives between activations within a session.
/// - **Dismiss-on-click-out**: when the panel loses key status (user clicks
///   somewhere outside it), we order it out. Spotlight does the same. The
///   query + filter state lives on `SearchViewModel` (owned by AppDelegate),
///   so the next hotkey-summon shows the panel with whatever was typed
///   before — no state loss.
@MainActor
final class PanelController: NSObject {
    private var panel: SpotlightNSPanel?
    private let viewModel: SearchViewModel
    private let recentSearches: RecentSearchesStore
    /// Hand to the AppDelegate so the panel can lazily fetch the
    /// `NLSearchViewModel` when the user toggles into Ask mode.
    /// Closure form (instead of a direct AppDelegate reference) keeps
    /// `PanelController` test-instantiable without the full app
    /// lifecycle.
    private let nlSearchViewModelProvider: @MainActor () -> NLSearchViewModel?

    /// NotificationCenter token for the panel's `didResignKey`. Held so we
    /// COULD remove the observer in a deinit — but the AppDelegate retains
    /// this controller for the whole app lifetime, and a nonisolated
    /// deinit can't safely touch this main-actor-isolated property under
    /// Swift 6 strict concurrency. Cleanup is left to process exit.
    private var resignKeyObserver: NSObjectProtocol?

    init(
        viewModel: SearchViewModel,
        recentSearches: RecentSearchesStore,
        nlSearchViewModelProvider: @escaping @MainActor () -> NLSearchViewModel? = { nil }
    ) {
        self.viewModel = viewModel
        self.recentSearches = recentSearches
        self.nlSearchViewModelProvider = nlSearchViewModelProvider
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionAtTopCenter(panel)
        // Order the panel front and let it become key for keystrokes —
        // but DELIBERATELY do NOT call `NSApp.activate(...)`. The panel's
        // `.nonactivatingPanel` style means it can receive input without
        // the owning app becoming frontmost, which is exactly the
        // Spotlight-style behavior we want: hotkey summons ONLY the
        // floating panel, the user's current app stays focused, and our
        // Dashboard window (if open in the background) doesn't pop forward.
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: Panel construction

    private func makePanel() -> SpotlightNSPanel {
        // 520pt is the SwiftUI body's `idealHeight` — match it so the
        // panel comes up at the size SwiftUI expects, no resize on first
        // paint. The body's `minHeight: 420` matches the panel's
        // `contentMinSize` (set below) so manual resizing can't crop the
        // footer either.
        let initialSize = NSSize(width: 720, height: 520)
        let panel = SpotlightNSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        // `.popUpMenu` (level 101) keeps the panel visible above standard
        // windows of OTHER apps without needing `NSApp.activate(...)`. With
        // the default `.floating` (3) the panel only floats relative to our
        // own app's other windows — when the user is in Safari, our app is
        // inactive and the panel ends up behind Safari's windows.
        // Spotlight uses the same trick.
        panel.level = .popUpMenu
        // Don't auto-hide when our app deactivates — the user-visible
        // workflow is "summon panel, use it, dismiss with Esc/click-out".
        // Auto-hide-on-deactivate would close the panel as soon as we
        // tried to interact, since our app is intentionally not activated
        // when the panel is shown from a background context.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Enforce a content-area minimum so the manual resize handle
        // (the panel uses `.resizable` styleMask) can't shrink the panel
        // below the size that fits the search field + footer. Without
        // this, a user dragging the bottom edge up could clip the
        // footer's "Open in Messages · Navigate · Dismiss" hint row.
        // 420pt matches the SwiftUI body's `minHeight` so the two
        // constraints don't fight.
        panel.contentMinSize = NSSize(width: 640, height: 420)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        let host = NSHostingView(
            rootView: SpotlightPanel(
                viewModel: viewModel,
                recentSearches: recentSearches,
                nlSearchViewModelProvider: nlSearchViewModelProvider,
                dismiss: { [weak self] in
                    self?.close()
                }
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        // Observe key-loss → dismiss. This is the "click outside" behavior
        // the user expects from a Spotlight-style panel. The panel is
        // REUSED across show/hide (never recreated), and viewModel.query
        // lives on the AppDelegate-owned SearchViewModel — so dismissing
        // here is purely cosmetic; the next hotkey-summon shows the
        // panel with whatever was typed before.
        //
        // We attach the observer to THIS panel instance specifically
        // (`object: panel`) so unrelated windows losing key (e.g. the
        // Dashboard background-losing focus when a different app comes
        // forward) don't trigger us.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            // The closure is `@Sendable` but everything we touch is
            // main-actor-isolated. Hop onto MainActor explicitly. The
            // notification is already delivered on .main (the OperationQueue
            // we passed), so this hop is effectively a no-op scheduling-wise
            // — it just satisfies Swift 6's actor-isolation checker.
            Task { @MainActor in
                guard let panel, panel.isVisible else { return }
                // Skip if a sheet/modal is up on top — clicking inside a
                // sheet attached to the panel briefly drops the panel's
                // key status.
                if panel.attachedSheet != nil { return }
                self?.close()
            }
        }

        return panel
    }

    private func positionAtTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let panelSize = panel.frame.size
        // Slightly above true center, like Spotlight.
        let x = visible.midX - panelSize.width / 2
        let y = visible.maxY - panelSize.height - visible.height * 0.18
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// `NSPanel` subclass that can become key and accept text input despite the
/// `.nonactivatingPanel` style mask, and that dismisses on Esc.
final class SpotlightNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Esc → hide. Reusing the panel preserves state for next time.
        self.orderOut(nil)
    }
}
