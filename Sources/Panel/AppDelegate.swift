import AppKit
import KeyboardShortcuts
import os

/// Same logger surface used by SearchViewModel. Filter in Console.app:
///   subsystem == "com.satyajit.bettermessages" && category == "nl-bar-rendering"
private let nlBarLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-bar-rendering"
)

/// App lifecycle owner.
///
/// Responsibilities:
/// - Hold the singleton `SearchViewModel` and `PanelController`.
/// - Register the global hotkey via `KeyboardShortcuts`.
/// - Bootstrap the menu bar item (wired in `HourglassApp.swift` via SwiftUI's
///   `MenuBarExtra`, but the click handlers route through here).
/// - Open the Dashboard on cold launch and when the Dock icon is clicked
///   while no windows are visible.
/// - Own the singleton `ModelDownloader` for the NL search agent (so the
///   download survives dashboard close/re-open cycles) and pick the right
///   `LLMRuntime` (MLX when downloaded, stub otherwise).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = SearchViewModel()
    /// Persistent history of recent searches, surfaced in the panel's
    /// empty state. Shared singleton so the same store survives across
    /// panel toggles (the panel can rebuild its View hierarchy on every
    /// show; a per-view store would lose its in-memory cache between
    /// toggles even though UserDefaults would persist).
    let recentSearches = RecentSearchesStore()
    private(set) lazy var panelController = PanelController(
        viewModel: viewModel,
        recentSearches: recentSearches,
        // The panel's Ask mode pulls the NL view model on demand via this
        // closure (lazy — the agent isn't built until the user actually
        // switches into Ask mode for the first time). Wrapping the
        // getter in a closure keeps PanelController free of the
        // AppDelegate type for unit tests + previews.
        nlSearchViewModelProvider: { [weak self] in self?.nlSearchViewModel }
    )

    /// One downloader instance for the entire app lifetime. Owns the loaded
    /// MLX `ModelContainer` post-download. Constructed eagerly because:
    ///   - probing for an existing cached copy is cheap (file existence
    ///     check) and lets us start in the `.ready` state without any
    ///     user interaction;
    ///   - holding the @Observable instance from launch means the NL bar's
    ///     SwiftUI view picks up the same instance no matter when the user
    ///     opens the dashboard.
    let modelDownloader = ModelDownloader()
    /// Observation token that watches the downloader state for the
    /// download-completed transition. When it flips to `.ready` we
    /// invalidate the cached `_nlAgent` so the next access builds a fresh
    /// MLX-backed agent.
    private var downloaderObserver: NSObjectProtocol?

    /// Lazy NL search agent. Built only when the dashboard's NL bar is
    /// first interacted with so initial startup stays as cheap as the
    /// pre-NL build. Runtime selection: MLX when the model downloader is
    /// ready, stub otherwise (so the bar still works while the download is
    /// in-flight, just with canned demo answers).
    private var _nlAgent: NLAgent?
    var nlAgent: NLAgent? {
        // Need the chat.db handle from the existing search view model.
        // If FDA is denied / setup failed, return nil — the NL bar then
        // shows a setup-needed state via its runtimeNotReadyReason path.
        if let cached = _nlAgent {
            nlBarLogger.debug("nlAgent getter: returning cached agent")
            return cached
        }
        // If the init-time open failed (FDA wasn't ready then, but is
        // now — common race when the user grants FDA between rebuilds),
        // give it one more shot. Idempotent; cheap if database is
        // already open.
        let retried = viewModel.retryOpenIfNeeded()
        nlBarLogger.debug("nlAgent getter: retryOpenIfNeeded returned \(retried)")
        guard let chatDB = viewModel.database,
              let search = viewModel.messageSearch else {
            nlBarLogger.notice("nlAgent getter: returning nil (no db / no search engine)")
            return nil
        }
        let tools = MessageSearchTools(
            instr: search,
            fts: viewModel.ftsSearcher,
            indexStore: viewModel.indexStore,
            chatDB: chatDB
        )
        let runtime: LLMRuntime = selectRuntime()
        nlBarLogger.info("nlAgent getter: BUILT agent (runtime=\(String(describing: type(of: runtime)), privacy: .public))")
        let agent = NLAgent(runtime: runtime, tools: tools)
        _nlAgent = agent
        return agent
    }

    /// Picks the best runtime for the current `modelDownloader.state`:
    ///   - `.ready` + a loaded container → `MLXRuntime`
    ///   - everything else → `StubLLMRuntime`
    /// Factored out so tests can exercise the selection logic without
    /// invoking the full Application lifecycle.
    func selectRuntime() -> LLMRuntime {
        if case .ready = modelDownloader.state,
           let container = modelDownloader.modelContainer {
            return MLXRuntime(container: container)
        }
        // We hit this branch in two real-world cases:
        //   1. Cold launch on a machine that's never downloaded the model
        //      (state == .idle, container == nil): the stub answers the
        //      canned queries while the download progresses.
        //   2. Cold launch on a machine where the cache directory exists
        //      but no model has been loaded yet (state == .ready,
        //      container == nil): we'd still need the container. The first
        //      MLX call would have to trigger a load, which we don't want
        //      to do synchronously on the LLM hot path. Stub for now;
        //      `beginDownload()` will populate the container.
        //
        // Both fall through to the stub cleanly. The agent's fallback path
        // means the user gets *something* either way.
        return StubLLMRuntime()
    }

    /// Shared NLSearchViewModel for the dashboard's NL bar. Lazy for the
    /// same reason as `nlAgent` — until the user clicks the bar, no
    /// agent setup happens.
    private var _nlSearchViewModel: NLSearchViewModel?
    var nlSearchViewModel: NLSearchViewModel? {
        if let cached = _nlSearchViewModel {
            nlBarLogger.debug("nlSearchViewModel getter: returning cached VM")
            return cached
        }
        guard let agent = nlAgent else {
            nlBarLogger.notice("nlSearchViewModel getter: returning nil (no agent)")
            return nil
        }
        let vm = NLSearchViewModel(agent: agent, modelDownloader: modelDownloader)
        _nlSearchViewModel = vm
        nlBarLogger.info("nlSearchViewModel getter: BUILT new VM")
        // If the model is already on disk at launch time, kick off a load
        // so the runtime gets the MLX container without the user
        // explicitly clicking Download. The download path no-ops the
        // network and goes straight to a memory-map (a few seconds).
        if modelDownloader.isModelCached, modelDownloader.modelContainer == nil {
            modelDownloader.beginDownload()
        }
        return vm
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire the global hotkey to toggle the spotlight panel.
        KeyboardShortcuts.onKeyDown(for: .toggleSpotlightPanel) { [weak self] in
            self?.panelController.toggle()
        }

        // Watch the downloader so that when the model becomes available we
        // invalidate the cached agent. The next `nlAgent` access will build
        // a fresh MLX-backed agent.
        observeDownloaderForRuntimeSwap()

        // Cold launch: SwiftUI's first-declared `Window` scene auto-opens, so
        // the Dashboard is already on screen. If for some reason it isn't
        // (e.g. user reset window state), nudge it open as a safety net.
        DispatchQueue.main.async {
            if NSApp.windows.contains(where: { $0.isVisible && !($0 is SpotlightNSPanel) }) {
                return
            }
            WindowOpener.shared.openDashboard()
        }
    }

    /// Subscribe to the downloader's `state` so we can flip the cached
    /// runtime as soon as the model becomes ready. We use a polling task
    /// instead of KVO because `ModelDownloader` is `@Observable` (which is
    /// macro-driven, not KVO-based). Polling every 250 ms is microsecond-
    /// cheap and the only thing that observes here.
    ///
    /// On runtime swap, we tell the NLSearchViewModel about the new agent
    /// so the trace footer ("Powered by …") refreshes and any pending
    /// query that was held back during download fires automatically.
    private func observeDownloaderForRuntimeSwap() {
        Task { @MainActor [weak self] in
            var lastState: ModelDownloadState = .idle
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.modelDownloader.state
                let stateChanged: Bool
                switch (lastState, current) {
                case (.ready, .ready):
                    // Same ready state — but if we just got a container,
                    // that's still a transition we care about.
                    stateChanged = (self._nlAgent?.runtime is StubLLMRuntime)
                                   && (self.modelDownloader.modelContainer != nil)
                default:
                    stateChanged = lastState != current
                }
                if stateChanged {
                    self.handleDownloadStateChange(to: current)
                    lastState = current
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func handleDownloadStateChange(to state: ModelDownloadState) {
        guard case .ready = state, modelDownloader.modelContainer != nil else { return }

        // Force a fresh agent build with the new runtime.
        _nlAgent = nil
        let newAgent = nlAgent
        if let newAgent, let vm = _nlSearchViewModel {
            Task { @MainActor in
                await vm.replaceAgent(newAgent)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock-icon click (or "reopen" Apple Event). Open the Dashboard
        // window — this is the entry point users expect from the Dock.
        // The hotkey panel remains the way to summon quick search; Dock
        // clicks deliberately do NOT route to it.
        if !flag {
            WindowOpener.shared.openDashboard()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func showPanel() { panelController.show() }
    func closePanel() { panelController.close() }
}

/// Bridge between AppKit (this delegate) and SwiftUI (the scene graph) for
/// opening a `Window(id:)` scene programmatically. SwiftUI's `openWindow`
/// environment value is only available inside views, so we capture it from a
/// trivial view at scene-construction time and stash it on this singleton for
/// AppKit callers to invoke later.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private init() {}

    /// Set by the SwiftUI side once `openWindow` is available.
    var open: ((String) -> Void)?

    /// Convenience for the Dashboard's well-known scene id.
    func openDashboard() {
        open?(WindowID.dashboard)
    }
}
