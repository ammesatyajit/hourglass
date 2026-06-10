import AppKit
import KeyboardShortcuts
import Sparkle
import os
import OSLog

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

    /// Sparkle updater. Owns the `SPUUpdater` lifecycle and the standard
    /// user-driver (alert + progress UI).
    ///
    /// `startingUpdater: true` kicks off the background scheduler immediately
    /// — Sparkle then honors `SUEnableAutomaticChecks` / `SUScheduledCheckInterval`
    /// from Info.plist. With no delegates wired up we get the default
    /// behavior: respect the feed URL + public key declared in Info.plist,
    /// show the standard "An update is available" panel on the user's
    /// schedule, install on quit.
    ///
    /// The menu-bar "Check for Updates…" item routes here via
    /// `updaterController.checkForUpdates(_:)` — see
    /// `Sources/HourglassApp.swift::MenuBarContent`.
    ///
    /// PRE-RELEASE NOTE: the Info.plist `SUFeedURL` and `SUPublicEDKey` are
    /// placeholders today. The updater will quietly fail its first check
    /// against the placeholder host (`updates.example.com`); that's expected
    /// until we publish the real appcast. See plans.md 2026-05-26
    /// build-agent entry for the fill-in checklist.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
    ///
    /// `private(set) var` (not `let`) so we can REBUILD it when the user
    /// switches the NL "quality mode" in Settings — a fresh `ModelDownloader`
    /// reads the newly-selected model id at construction. See
    /// `applyModelQualityChangeIfNeeded()`.
    private(set) var modelDownloader = ModelDownloader()
    /// Observation token that watches the downloader state for the
    /// download-completed transition. When it flips to `.ready` we
    /// invalidate the cached `_nlAgent` so the next access builds a fresh
    /// MLX-backed agent.
    private var downloaderObserver: NSObjectProtocol?
    /// Observation token for `UserDefaults.didChangeNotification` — fires the
    /// quality-mode reconciliation when the Settings picker writes a new mode.
    private var defaultsObserver: NSObjectProtocol?

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

    /// Gated AI labeler for the Vernacular Insights panel (Layer 4). Returns a
    /// real MLX-backed labeler ONLY when the model is downloaded + loaded;
    /// nil otherwise (the gate — the panel then shows Layer-1/2/3 results with
    /// no AI labels, exactly like the NL bar's "model not ready" path).
    ///
    /// Crucially this does NOT auto-load the model and is a no-op under
    /// XCTest: if `modelDownloader.modelContainer` is nil (which it always is
    /// under the test host, where the eager warmup is `underTest`-guarded), we
    /// return nil and never touch MLX. So the Vernacular panel never triggers
    /// the XCTest-host model-load hang.
    var vernacularLabeler: (any VernacularAILabeling)? {
        guard case .ready = modelDownloader.state,
              let container = modelDownloader.modelContainer else {
            return nil
        }
        return LLMVernacularLabeler(runtime: MLXRuntime(container: container, modelID: modelDownloader.modelID))
    }

    /// Picks the best runtime for the current `modelDownloader.state`:
    ///   - `.ready` + a loaded container → `MLXRuntime`
    ///   - everything else → `StubLLMRuntime`
    /// Factored out so tests can exercise the selection logic without
    /// invoking the full Application lifecycle.
    func selectRuntime() -> LLMRuntime {
        // OPT-IN Cactus branch (default OFF). Strictly gated on the
        // `nl.runtime.cactus` UserDefaults flag — when unset (the default),
        // this is skipped entirely and the existing MLX/Stub logic below is
        // unchanged. Enable with:
        //   defaults write com.satyajit.hourglass nl.runtime.cactus -bool true
        //   defaults write com.satyajit.hourglass nl.cactus.modelPath -string /abs/path/to/cactus-model-dir
        // CactusRuntime degrades safely (isReady=false, throws rather than
        // crashes) if the model path is missing, so even a misconfigured
        // opt-in never takes down the app — but the agent would then have no
        // working runtime, so the flag is for benchmarking, not production.
        if UserDefaults.standard.bool(forKey: CactusDefaultsKey.enabled) {
            nlBarLogger.notice("selectRuntime: Cactus opt-in flag set → CactusRuntime")
            return CactusRuntime()
        }
        if case .ready = modelDownloader.state,
           let container = modelDownloader.modelContainer {
            // Hand the runtime the actual model id so it picks the correct
            // chat-template family (Qwen3 → enable_thinking; Qwen2.5 → none)
            // and the right "Powered by …" label.
            return MLXRuntime(container: container, modelID: modelDownloader.modelID)
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
        //
        // GUARD under XCTest: the unit tests are HOSTED in this app, so the
        // test runner launches it and the Dashboard auto-opens, which reads
        // this getter (the NL bar). Once a model is cached on the machine
        // (937 MB Qwen3), an unguarded auto-load here memory-maps the
        // weights + compiles Metal shaders DURING host launch and blows
        // past the test runner's connection timeout → "test runner hung
        // before establishing connection", hanging the ENTIRE suite. The
        // bug is latent: it only bites after a model is cached (which is
        // why earlier runs were green). Matches the same guard on the
        // eager warmup in applicationDidFinishLaunching. The opt-in MLX
        // integration/bench tests call `beginDownload` explicitly, so
        // guarding only this AUTO-fire leaves them functional.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        if !underTest, modelDownloader.isModelCached, modelDownloader.modelContainer == nil {
            modelDownloader.beginDownload()
        }
        return vm
    }

    /// Terminate guard for the MLX shutdown race. The observed quit-time crash was
    /// EXC_BAD_ACCESS inside MLX's C++ static destructors (`mlx::core::scheduler`
    /// teardown / `CompilerCache`) running concurrently with a still-live inference
    /// thread when `exit()` fired. If an NL inference is in flight we cancel it and
    /// await its unwind (bounded) BEFORE allowing termination, so MLX is idle when
    /// the statics are destroyed. Vernacular no longer touches MLX (Phase 2 gated
    /// off), so the NL search bar is the only in-flight MLX path; idle → no-op.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = _nlSearchViewModel else { return .terminateNow }
        Task { @MainActor in
            await vm.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ------------------------------------------------------------------
        // HEADLESS NL-SEARCH EVAL ENTRYPOINTS (diagnostic baselines only)
        // ------------------------------------------------------------------
        // Strictly env-var-gated. Two flavors:
        //   • HOURGLASS_NL_EVAL_REACT — runs the query through the REAL
        //     PRODUCTION path: `NLAgent.answerWithToolLoop(...)` (the ReAct
        //     tool loop the live app uses for the MLX runtime, per
        //     `NLSearchViewModel.ask`). This is the TRUE baseline a user hits.
        //   • HOURGLASS_NL_EVAL — runs the query through the legacy single-shot
        //     `NLAgent.answer(...)` plan→search→rank loop (NOT what the live
        //     app uses for MLX; kept as a comparison baseline).
        // Either way we load the SAME cached MLX model + build the SAME
        // `MessageSearchTools` over the same chat.db, dump the full result to
        // stdout (every line prefixed `NLEVAL::`), then exit(0). We do NOT open
        // the dashboard/panel, register the hotkey, or kick the normal warmups
        // — so a NORMAL launch (neither env var set) is byte-identical to
        // before: this guard returns immediately and the rest of this method
        // runs exactly as it always has.
        //
        // This path changes NO NL-search behaviour/logic; it only OBSERVES the
        // agent over the real runtime + real chat.db to capture an exact
        // current-state baseline. ReAct takes precedence if both are set.
        if let evalQuery = ProcessInfo.processInfo.environment["HOURGLASS_NL_EVAL_REACT"] {
            runHeadlessNLEval(query: evalQuery, mode: .react)
            return
        }
        if let evalQuery = ProcessInfo.processInfo.environment["HOURGLASS_NL_EVAL"] {
            runHeadlessNLEval(query: evalQuery, mode: .singleShot)
            return
        }
        // HEADLESS 2-PANEL LOAD BENCHMARK — env-gated, diagnostic only. Times
        // every Nostalgia + Vernacular load stage over the real chat.db and
        // dumps `BENCH::` lines, then exit(0). A normal launch (unset) is
        // unaffected — this guard returns before any UI/warmup wiring.
        if ProcessInfo.processInfo.environment["HOURGLASS_PANEL_BENCH"] != nil {
            runHeadlessPanelBench()
            return
        }

        // Wire the global hotkey to toggle the spotlight panel.
        KeyboardShortcuts.onKeyDown(for: .toggleSpotlightPanel) { [weak self] in
            self?.panelController.toggle()
        }

        // Watch the downloader so that when the model becomes available we
        // invalidate the cached agent. The next `nlAgent` access will build
        // a fresh MLX-backed agent.
        observeDownloaderForRuntimeSwap()

        // Watch UserDefaults for the NL quality-mode toggle (Settings →
        // General → "Answer quality"). When the persisted mode no longer
        // matches the live downloader's model id, rebuild the downloader (so
        // it points at the newly-selected repo) and invalidate the cached
        // agent/VM. The didChangeNotification can fire off other prefs too —
        // the reconciliation is a cheap no-op when the model id is unchanged.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyModelQualityChangeIfNeeded()
            }
        }

        // L1 (NL race fix): eagerly kick off `beginDownload()` so MLX
        // starts memory-mapping the cached weights at launch instead of
        // waiting for first Ask-mode entry. Without this, the user can
        // submit their first NL query before MLX is ready, falling back
        // to `StubLLMRuntime` + the broken literal-text path (returned
        // 44 "find" matches for the Annika argument query — see
        // plans.md 2026-05-27 entry).
        //
        // We touch `modelDownloader` directly (NOT `nlSearchViewModel`)
        // to avoid building the agent before chat.db is open. The
        // `observeDownloaderForRuntimeSwap` task above will pick up the
        // `.ready` transition and swap the agent the moment chat.db +
        // MLX are both ready. Skipped under XCTest where chat.db isn't
        // available and we don't want a background task fighting the
        // bundle-injection handshake.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        if !underTest, modelDownloader.isModelCached, modelDownloader.modelContainer == nil {
            modelDownloader.beginDownload()
            nlBarLogger.info("applicationDidFinishLaunching: kicked off MLX memory-map warmup")
        }

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
    /// runtime as soon as the model becomes ready. We poll (rather than
    /// KVO) because `ModelDownloader` is `@Observable` (macro-driven, not
    /// KVO-based).
    ///
    /// BATTERY: this loop now TERMINATES the moment the MLX runtime is
    /// live — it polls only while there's a transition still pending
    /// (download running, or a loaded container we haven't swapped to
    /// yet). Once `_nlAgent.runtime` is a real `MLXRuntime`, there is
    /// nothing left to observe, so the loop returns and stops waking the
    /// CPU. Previously it spun at 4 Hz for the entire life of the app
    /// (including long after a query finished), which kept the CPU from
    /// idling and drained battery. We also back off to 1 s polling —
    /// model load takes seconds, so 250 ms bought no real responsiveness.
    ///
    /// On runtime swap, we tell the NLSearchViewModel about the new agent
    /// so the trace footer ("Powered by …") refreshes and any pending
    /// query that was held back during download fires automatically.
    private func observeDownloaderForRuntimeSwap() {
        Task { @MainActor [weak self] in
            var lastState: ModelDownloadState = .idle
            while !Task.isCancelled {
                guard let self else { return }
                // Terminal condition: MLX is live. Nothing more to watch —
                // stop polling so the app can idle and the CPU can sleep.
                if self._nlAgent?.runtime is MLXRuntime {
                    return
                }
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
                try? await Task.sleep(for: .seconds(1))
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

    /// Reconcile the live `ModelDownloader` with the persisted NL quality
    /// mode. Called when UserDefaults changes (the Settings picker writes the
    /// mode). When the selected model id differs from the downloader's current
    /// `modelID`, we REBUILD the downloader so it targets the newly-selected
    /// repo, tear down the cached agent + NL view model (which both captured
    /// the OLD downloader/runtime), restart the downloader-state observer for
    /// the new instance, and — if that model is already cached — kick off the
    /// (memory-map) load so the runtime warms without the user re-clicking.
    ///
    /// No-op (cheap string compare) when the model id is unchanged, so this is
    /// safe to invoke on every UserDefaults change.
    func applyModelQualityChangeIfNeeded() {
        let desiredID = NLModelPreference.currentModelID()
        guard desiredID != modelDownloader.modelID else { return }

        nlBarLogger.info("applyModelQualityChangeIfNeeded: switching model \(self.modelDownloader.modelID, privacy: .public) → \(desiredID, privacy: .public)")

        // Cancel any in-flight download on the old instance so it doesn't keep
        // mutating state after we drop it.
        modelDownloader.cancelDownload()

        // Rebuild the downloader against the newly-selected model id.
        modelDownloader = ModelDownloader(modelID: desiredID)

        // Tear down everything that captured the OLD downloader / runtime.
        // The next `nlAgent` / `nlSearchViewModel` access rebuilds against the
        // new downloader; an existing NL VM is dropped so it re-reads the new
        // `modelDownloader` reference (it captured the old one as a `let`).
        _nlAgent = nil
        _nlSearchViewModel = nil

        // Restart the state observer for the new downloader instance (the old
        // task returns once it sees the agent is no longer an MLXRuntime).
        observeDownloaderForRuntimeSwap()

        // If the newly-selected model is already cached, start the load now so
        // the runtime warms in the background (memory-map, no network). Guard
        // under XCTest exactly like the other auto-load sites.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        if !underTest, modelDownloader.isModelCached, modelDownloader.modelContainer == nil {
            modelDownloader.beginDownload()
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

    // MARK: - Headless NL-search eval (diagnostic)

    /// Which agent entry point the headless eval exercises.
    private enum NLEvalMode: Equatable {
        /// `NLAgent.answerWithToolLoop(...)` — the REAL production path the
        /// live app drives for the MLX runtime (see `NLSearchViewModel.ask`).
        case react
        /// `NLAgent.answer(...)` — the legacy single-shot plan→search→rank
        /// loop. NOT what the live app uses for MLX; comparison baseline only.
        case singleShot
    }

    /// Opt-in one-call reclaimedWords classifier for the headless profile bench.
    /// This deliberately bypasses the Cactus runtime branch: Cactus has no
    /// usable transpiled model in this app yet, so reclaimed classification
    /// either uses the already-shipped MLX/Qwen model or falls back unfiltered.
    private func prepareHeadlessPanelBenchReclaimedRuntime(
        emit: @escaping @Sendable (String) -> Void
    ) async -> (any LLMRuntime)? {
        emit("reclaimed.llm.model id=\(modelDownloader.modelID) cached=\(modelDownloader.isModelCached)")
        guard modelDownloader.isModelCached else {
            emit("reclaimed.llm.skip model is NOT cached; leaving reclaimedWords unfiltered")
            return nil
        }

        modelDownloader.beginDownload()
        let loadTimeout: TimeInterval = 180
        let loadStart = Date()
        while true {
            switch modelDownloader.state {
            case .ready where modelDownloader.modelContainer != nil:
                guard let container = modelDownloader.modelContainer else { return nil }
                emit(String(format: "reclaimed.llm.model READY in %.1fs", Date().timeIntervalSince(loadStart)))
                return MLXRuntime(container: container, modelID: modelDownloader.modelID)
            case .failed(let reason):
                emit("reclaimed.llm.skip model load failed: \(reason)")
                return nil
            case .idle, .downloading, .ready:
                break
            }
            if Date().timeIntervalSince(loadStart) > loadTimeout {
                emit("reclaimed.llm.skip model load timed out after \(Int(loadTimeout))s; leaving reclaimedWords unfiltered")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Headless 2-PANEL LOAD BENCHMARK, gated behind `HOURGLASS_PANEL_BENCH`.
    /// Runs BOTH dashboard panels' REAL load pipelines over the real chat.db
    /// through the real GRDB stack — calling the SAME loaders the view-models
    /// call — timing each stage and sampling peak `phys_footprint`. Prints
    /// `BENCH::`-prefixed lines, then `exit(0)`. Never opens the UI. It loads
    /// MLX only for the explicit Phase-2 Vernacular section, and only when the
    /// selected model is already cached. Diagnostic ONLY: no behaviour change;
    /// just observes the load.
    private func runHeadlessPanelBench() {
        Task { @MainActor in
            _ = viewModel.retryOpenIfNeeded()
            guard let database = viewModel.database else {
                print("BENCH:: FATAL chat.db unavailable (Full Disk Access?)"); fflush(stdout); exit(1)
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    print("BENCH:: FATAL AppDelegate unavailable"); fflush(stdout); exit(1)
                }
                // Thread-safe peak-footprint tracker (global + resettable per stage).
                final class Peak: @unchecked Sendable {
                    private let lock = NSLock()
                    private var g = 0.0, s = 0.0, phase = 0.0
                    private var phaseRunning = false
                    private var run = true
                    func tick(_ m: Double) {
                        lock.lock()
                        g = max(g, m)
                        s = max(s, m)
                        if phaseRunning { phase = max(phase, m) }
                        lock.unlock()
                    }
                    func resetStage(_ m: Double) { lock.lock(); s = m; lock.unlock() }
                    func beginPhase(_ m: Double) { lock.lock(); phase = m; phaseRunning = true; lock.unlock() }
                    func endPhase() { lock.lock(); phaseRunning = false; lock.unlock() }
                    func stagePeak() -> Double { lock.lock(); defer { lock.unlock() }; return s }
                    func phasePeak() -> Double { lock.lock(); defer { lock.unlock() }; return phase }
                    func globalPeak() -> Double { lock.lock(); defer { lock.unlock() }; return g }
                    func stop() { lock.lock(); run = false; lock.unlock() }
                    func running() -> Bool { lock.lock(); defer { lock.unlock() }; return run }
                }
                func footMB() -> Double {
                    var info = task_vm_info_data_t()
                    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                    let kr = withUnsafeMutablePointer(to: &info) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                        }
                    }
                    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : -1
                }
                func emit(_ s: String) { print("BENCH:: \(s)"); fflush(stdout) }

                let peak = Peak(); peak.tick(footMB())
                let sampler = Thread { while peak.running() { peak.tick(footMB()); usleep(25_000) } }
                sampler.start()

                // Time `body`, reporting wall-ms + the peak footprint reached DURING it.
                func stage<T>(_ label: String, _ body: () throws -> T) -> T? {
                    peak.resetStage(footMB())
                    let t0 = Date()
                    var out: T? = nil; var err: String? = nil
                    do { out = try body() } catch { err = (error as NSError).localizedDescription }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let lbl = label.padding(toLength: 18, withPad: " ", startingAt: 0)
                    if let e = err { emit("  \(lbl) \(ms) ms   ERROR: \(e)") }
                    else { emit("  \(lbl) \(ms) ms   peak \(String(format: "%.1f", peak.stagePeak())) MB") }
                    return out
                }
                emit("==== HOURGLASS PANEL LOAD BENCH (real chat.db, real loaders) ====")
                emit("db: \(database.url.path)")
                let cal = Calendar.current
                let now = Date()

                // Shared dependencies (both panels need these; the dashboard builds
                // them once before either panel loads).
                let contacts = stage("contacts.resolve") { ContactResolver.resolve() }
                    ?? ResolvedContacts(byHandle: [:], allContacts: [])
                let search = MessageSearch(database: database, contacts: contacts)

                // Nostalgia gets ONE pass in practice (the app loads it once per
                // session), so vernacular iterations shouldn't re-pay its ~30-50s
                // on every bench run. `HOURGLASS_PANEL_BENCH=vernacular` skips it;
                // any other value (e.g. "1") keeps the full two-panel bench.
                let benchMode = ProcessInfo.processInfo.environment["HOURGLASS_PANEL_BENCH"] ?? ""
                if benchMode.lowercased() == "vernacular" {
                    emit("---- NOSTALGIA SKIPPED (HOURGLASS_PANEL_BENCH=vernacular — one pass in practice) ----")
                } else {
                    emit("---- NOSTALGIA (the 7 loaders run SEQUENTIALLY in production) ----")
                    let aggregate = stage("aggregate.build") {
                        try DashboardLoader.loadAllTimeAggregateSync(database: database, contacts: contacts, calendar: cal)
                    }
                    let stories = stage("chatStories") { try ChatStoryBuilder.loadStories(database: database, contacts: contacts, calendar: cal) }
                    if let s = stories { emit("    → \(s.count) stories, \(s.reduce(0) { $0 + $1.moments.count }) moments (parity: expect 185 / 788)") }
                    _ = stage("rekindle") { try RekindleBuilder.load(database: database, contacts: contacts, now: now) }
                    _ = stage("beloved") { try BelovedMessagesLoader(search: search).load() }
                    if let agg = aggregate {
                        _ = stage("onThisDay") { try OnThisDayLoader(search: search, calendar: cal).load(now: now, historyOldest: agg.allTimeOldest, historyNewest: agg.allTimeNewest) }
                        _ = stage("firstMessages") { try FirstMessageLoader(database: database, contacts: contacts).load(series: agg.contactSeries) }
                    }
                    _ = stage("funnyMoments") { try FunnyMomentsLoader(database: database, contacts: contacts).load() }
                    _ = stage("romantic") { try RomanticDetector.flaggedContactNames(database: database, contacts: contacts) }
                }

                emit("---- VERNACULAR Phase 1 (pure stats) ----")
                let baseline = LinguisticBaseline.load()
                let messages = stage("loadMessages") {
                    // Bench corpus cap is tunable for fast perf iteration:
                    //   -vernacular.bench.maxMessages 40000   (default 1,000,000)
                    let capArg = UserDefaults.standard.integer(forKey: "vernacular.bench.maxMessages")
                    let cap = capArg > 0 ? capArg : 1_000_000
                    return try VernacularLoader.loadMessages(database: database, contacts: contacts, maxMessages: cap)
                }
                if let msgs = messages {
                    let profileSubject = VernacularSubject.fromDisplayName(
                        UserDefaults.standard.string(forKey: "vernacular.subject")
                    )
                    let profileSubjectContext = VernacularSubjectContext.build(messages: msgs, subject: profileSubject)
                    emit("BENCH::   vernacular.subject \"\(profileSubject.displayName)\" world=\(profileSubjectContext.worldMessageCount) sent=\(profileSubjectContext.subjectMessageCount) other=\(profileSubjectContext.otherMessageCount)")
                    if let caveat = profileSubjectContext.visibleCorpusCaveat {
                        emit("BENCH::   vernacular.subject.caveat \(caveat)")
                    }
                    let ooo = stage("oneOnOneMap") { (try? VibeLoader.oneOnOneContactMap(database: database, contacts: contacts)) ?? [:] } ?? [:]
                    let parts = stage("chatParticipants") { (try? VernacularLoader.chatParticipantsMap(database: database, contacts: contacts)) ?? [:] } ?? [:]
                    // PARAMETER SWEEP: load corpus once, run the profile engine with
                    // several weight tunings, print the top phrases + n-length mix for
                    // each so we can compare which surfaces style/words vs topics.
                    //   -vernacular.sweep YES
                    // TOKEN PROBE: why is a specific word (e.g. "fade") absent? Prints
                    // sent/received message counts + baseline commonness so we can see
                    // whether it's a frequency, send-vs-receive, or common-word issue.
                    //   -vernacular.probe "fade,cone,chalk,chalked,smth,lowk,ts,yap,crashout"
                    if let probeArg = UserDefaults.standard.string(forKey: "vernacular.probe") {
                        let probes = probeArg.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces).lowercased()
                        }
                        let probeSet = Set(probes)
                        var sent: [String: Int] = [:]
                        var recv: [String: Int] = [:]
                        for m in msgs where profileSubjectContext.isWorldMessage(m) {
                            for t in m.wordSet.intersection(probeSet) {
                                if profileSubjectContext.isSubjectMessage(m) {
                                    sent[t, default: 0] += 1
                                } else {
                                    recv[t, default: 0] += 1
                                }
                            }
                        }
                        emit("######## TOKEN PROBE (msgs containing token) subject=\(profileSubject.displayName) ########")
                        for t in probes {
                            emit(String(format: "  %-10@ subject=%-5d other=%-5d  baselineProb=%.7f  known=%@  register=%.2f",
                                        t, sent[t] ?? 0, recv[t] ?? 0,
                                        baseline.probability(of: t), baseline.isKnown(t) ? "Y" : "N",
                                        VernacularTextingRegister.penalty(for: t)))
                        }
                        emit("######## PROBE DONE ########")
                        fflush(stdout)
                        exit(0)
                    }
                    // SPREAD PROBE: trace why a specific (term -> person) transmission
                    // edge does/doesn't surface. Reproduces the UI's personInfluence
                    // path AND dumps the raw GraphAcc attribution + incoming/outgoing
                    // gate verdict, so we can see exactly which gate (universe membership,
                    // 5-before, 30-day, 2x-dominance, niche<=20, exposure) blocks it.
                    //   -vernacular.spreadProbe "aiaiaii=Beck Peterson;cone=Annika Renganathan;yuh=Venkat Chitturi;voc:brother=Keeshant Hoogar"
                    if let spArg = UserDefaults.standard.string(forKey: "vernacular.spreadProbe") {
                        emit("######## SPREAD PROBE ########")
                        let pairs: [(String, String)] = spArg.split(separator: ";").compactMap { seg in
                            let kv = seg.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                            guard kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty else { return nil }
                            return (kv[0].lowercased(), kv[1])
                        }
                        var cfg = VernacularConfig.fromUserDefaults()
                        cfg.isEnabled = true
                        cfg.enableSemanticShiftEmbeddings = false
                        let day = 86_400.0
                        let opts = VernacularAnalyzer.GraphOptions.default
                        emit("  building YOU profile…")
                        let youProf = VernacularEngine.buildProfile(messages: msgs, baseline: baseline,
                                                                    contacts: contacts, subject: .you, config: cfg)
                        emit("  YOU profile: words=\(youProf.words.count) reclaimed=\(youProf.reclaimedWords.count) templates=\(youProf.templates.count)")
                        let posSenses = VernacularPOSSense.detectVocativeSurfaces(messages: msgs,
                                                                                  baseline: baseline,
                                                                                  config: cfg)
                        let posSenseByID = Dictionary(uniqueKeysWithValues: posSenses.map { ($0.id, $0) })
                        emit("  POS senses: \(posSenses.map { $0.id }.joined(separator: ", "))")
                        var profCache: [String: VernacularProfile] = [:]
                        for (term, person) in pairs {
                            emit("==== PROBE term=\"\(term)\" person=\"\(person)\" ====")
                            let posSense = term.hasPrefix("voc:") ? posSenseByID[term] : nil
                            let displayTerm = posSense?.surface ?? term
                            if term.hasPrefix("voc:") {
                                if let posSense {
                                    emit(String(format: "  POS sense: detected=Y id=%@ surface=%@ tag=%@ subjectUses=%d contactUses=%d totalVoc=%d totalWord=%d rate=%.3f",
                                                posSense.id, posSense.surface, posSense.senseTag,
                                                posSense.subjectUses, posSense.contactUses,
                                                posSense.totalVocativeUses, posSense.totalWordUses,
                                                posSense.vocativeRate))
                                } else {
                                    emit("  POS sense: detected=N id=\(term)")
                                }
                                emit("  POS universe: inVocativeUniverse=\(posSense != nil)")
                            }
                            let inYouWords = youProf.words.contains { $0.surface.lowercased() == displayTerm }
                            let inYouReclaimed = youProf.reclaimedWords.contains { $0.surface.lowercased() == displayTerm }
                            let inYouTemplates = youProf.templates.contains { $0.pattern.lowercased().contains(displayTerm) }
                            emit("  YOU universe: inWords=\(inYouWords) inReclaimed=\(inYouReclaimed) inTemplates=\(inYouTemplates)")
                            let themProf = profCache[person] ?? VernacularEngine.buildProfile(
                                messages: msgs, baseline: baseline, contacts: contacts,
                                subject: .contact(person), config: cfg)
                            profCache[person] = themProf
                            let inThemWords = themProf.words.contains { $0.surface.lowercased() == displayTerm }
                            let inThemReclaimed = themProf.reclaimedWords.contains { $0.surface.lowercased() == displayTerm }
                            emit("  THEM(\(person)) profile: enabled=\(themProf.isEnabled) words=\(themProf.words.count) reclaimed=\(themProf.reclaimedWords.count) | inWords=\(inThemWords) inReclaimed=\(inThemReclaimed)")
                            // raw attribution + gate trace
                            let acc: GraphAcc
                            if let posSense {
                                let ids = posSense.messageIDs
                                acc = GraphAcc(posSense.id, { m in
                                    m.messageID >= 0 && ids.contains(m.messageID)
                                }, distinctive: true)
                            } else {
                                let toks = displayTerm.split(separator: " ").map(String.init)
                                acc = GraphAcc(displayTerm, { m in
                                    toks.count == 1 ? m.wordSet.contains(toks[0]) : VernacularAnalyzer.hasSubsequence(m.words, toks)
                                }, distinctive: true)
                            }
                            _ = VernacularAnalyzer.assembleGraph(accumulators: [acc], messages: msgs,
                                                                 chatParticipants: parts, options: opts)
                            let yf = acc.yourFirst < .greatestFiniteMagnitude
                                ? Date(timeIntervalSince1970: acc.yourFirst).description : "never"
                            emit("  ACC: yourTotal=\(acc.yourTotal) yourFirst=\(yf) distinctContacts=\(acc.total.count)")
                            for (who, n) in acc.total.sorted(by: { $0.value > $1.value }).prefix(8) {
                                let bf = acc.firstByContact[who].map { Date(timeIntervalSince1970: $0).description } ?? "?"
                                let before = acc.events.filter { $0.who == who && $0.date < acc.yourFirst }.count
                                emit("    \(who): total=\(n) first=\(bf) before-you=\(before)")
                            }
                            if let inc = VernacularAnalyzer.incoming(acc, options: opts, day: day) {
                                emit("  INCOMING: source=\(inc.source) before=\(inc.before)")
                            } else {
                                emit("  INCOMING: nil (no dominant qualifying source @ 5-before/30-day/2x)")
                            }
                            let outs = VernacularAnalyzer.outgoing(acc, options: opts, day: day, chatParticipants: parts)
                            if outs.isEmpty {
                                emit("  OUTGOING: none (gate: distinctive/niche<=20/5-before/30-day/2x-dominance/exposure)")
                            } else {
                                for o in outs.prefix(6) { emit("    OUTGOING: adopter=\(o.adopter) youBefore=\(o.youBefore)") }
                            }
                            let pi = VernacularAnalyzer.personInfluence(person: person, you: youProf, them: themProf,
                                                                        messages: msgs, baseline: baseline,
                                                                        config: cfg, chatParticipants: parts)
                            func matchesProbeRow(_ row: InfluencedTerm) -> Bool {
                                if term.hasPrefix("voc:") {
                                    return row.id.hasSuffix(":\(term)")
                                }
                                return row.surface.lowercased() == displayTerm && row.senseTag == nil
                            }
                            let inRow = pi.theyToYou.contains(where: matchesProbeRow)
                            let outRow = pi.youToThem.contains(where: matchesProbeRow)
                            let coRow = pi.independentCoUse.contains(where: matchesProbeRow)
                            emit("  personInfluence(\(person)): theyToYou=\(pi.theyToYou.count) youToThem=\(pi.youToThem.count) coUse=\(pi.independentCoUse.count) | term present: in=\(inRow) out=\(outRow) co=\(coRow)")
                        }
                        emit("######## SPREAD PROBE DONE ########")
                        fflush(stdout)
                        exit(0)
                    }
                    if UserDefaults.standard.bool(forKey: "vernacular.sweep") {
                        emit("######## VERNACULAR PARAMETER SWEEP ########")
                        var base = VernacularConfig.default
                        base.isEnabled = true
                        func sweep(_ name: String, _ mutate: (inout VernacularConfig) -> Void) {
                            autoreleasepool {
                                var c = base; mutate(&c)
                                let w = c.weights
                                let prof = VernacularEngine.buildProfile(messages: msgs, baseline: baseline,
                                                                         contacts: contacts,
                                                                         subject: profileSubject,
                                                                         config: c)
                                var nDist = [0, 0, 0, 0, 0]
                                for ph in prof.phrases.prefix(40) { nDist[min(ph.n, 4)] += 1 }
                                emit("---- \(name) subject=\(prof.stats.subjectName) [worldEff=\(w.worldDistinctiveness) role=\(w.role) disp=\(w.dispersion) echo=\(w.echo) burst=\(w.burstResistance) glue=\(w.glue) coll=\(w.collocation) sem=\(w.semanticShift)] words=\(prof.words.count) reclaimed=\(prof.reclaimedWords.count) circle=\(prof.circleSlang.count) phrases=\(prof.phrases.count) templates=\(prof.templates.count) top40phrases: n2=\(nDist[2]) n3=\(nDist[3]) n4=\(nDist[4]) ----")
                                emit("    WORDS:")
                                for word in prof.words.prefix(12) {
                                    let f = word.features
                                    emit(String(format: "      n%d x%-3d recv%-3d %.3f worldEff%.2f zR%.2f coll%.2f sem%.2f reg%.2f disp%.2f burst%.2f  %@",
                                                word.n, word.counts.userMessages, word.counts.receivedMessages,
                                                word.score, f.zWorld, f.zRole, f.collocation,
                                                f.semanticShift, f.registerPenalty,
                                                f.dispersion, f.burst, word.surface))
                                }
                                emit("    RECLAIMED:")
                                for reclaimed in prof.reclaimedWords.prefix(12) {
                                    emit(String(format: "      x%-3d recv%-3d %.3f worldEff%.2f pct%.2f coll%.2f sense%.2f role%.2f conc%.2f partner=%@  %@",
                                                reclaimed.counts.userMessages, reclaimed.counts.receivedMessages,
                                                reclaimed.score, reclaimed.worldEff, reclaimed.percentile,
                                                reclaimed.collocation,
                                                reclaimed.senseDistance, reclaimed.roleSkew,
                                                reclaimed.concentration, reclaimed.topCollocationPartner ?? "-",
                                                reclaimed.surface))
                                }
                                emit("    CIRCLE:")
                                for slang in prof.circleSlang.prefix(16) {
                                    let f = slang.features
                                    emit(String(format: "      n%d x%-3d recv%-3d ppl%d %.3f worldEff%.2f zR%.2f reg%.2f disp%.2f echo%.2f burst%.2f  %@",
                                                slang.n, slang.counts.userMessages, slang.counts.receivedMessages,
                                                slang.counts.activeContactUsers, slang.score, f.zWorld, f.zRole,
                                                f.registerPenalty, f.dispersion, f.echo, f.burst, slang.surface))
                                }
                                emit("    PHRASES:")
                                for ph in prof.phrases.prefix(16) {
                                    let f = ph.features
                                    emit(String(format: "      n%d x%-3d recv%-3d %.3f worldEff%.2f zR%.2f reg%.2f disp%.2f glue%.2f topic%.2f  %@",
                                                ph.n, ph.counts.userMessages, ph.counts.receivedMessages,
                                                ph.score, f.zWorld, f.zRole, f.registerPenalty, f.dispersion, f.glue,
                                                f.topic, ph.surface))
                                }
                                emit("    TEMPLATES:")
                                for tmpl in prof.templates.prefix(8) {
                                    let f = tmpl.features
                                    emit(String(format: "      x%-3d recv%-3d %.3f worldEff%.2f zR%.2f disp%.2f burst%.2f prod%.2f  %@",
                                                tmpl.counts.userMessages, tmpl.counts.receivedMessages,
                                                tmpl.score, f.zWorld, f.zRole, f.dispersion,
                                                f.burst, f.productivity, tmpl.pattern))
                                }
                            }
                        }
                        sweep("default") { _ in }
                        sweep("words-on (low length)") { $0.weights.length = 0.03 }
                        sweep("world-heavy") { $0.weights.worldDistinctiveness = 0.48; $0.weights.dispersion = 0.18 }
                        sweep("idiolect-forward") { $0.weights.role = 0.34; $0.weights.echo = 0.05; $0.weights.dispersion = 0.24 }
                        sweep("circle-forward") { $0.weights.echo = 0.34; $0.weights.role = 0.04; $0.weights.dispersion = 0.30 }
                        sweep("dispersion-heavy") { $0.weights.dispersion = 0.40; $0.weights.burstResistance = 0.24 }
                        sweep("burst-strict") { $0.weights.burstResistance = 0.34; $0.weights.recency = 0.02 }
                        sweep("glue-heavy") { $0.weights.glue = 0.30; $0.weights.length = 0.06 }
                        emit("######## SWEEP DONE ########")
                        fflush(stdout)
                        exit(0)
                    }
                    let profileConfig = VernacularConfig.fromUserDefaults()
                    let all = stage("buildAllSections") {
                        VernacularLoader.buildAllSections(messages: msgs, contacts: contacts, baseline: baseline,
                                                          oneOnOneContact: ooo, chatParticipants: parts,
                                                          profileConfig: profileConfig,
                                                          profileSubject: profileSubject)
                    }
                    if let all {
                        // NEW unified Phase-1 profile A/B dump (only when
                        // `vernacular.profile.enabled` is set). Lets the operator see the
                        // actual phrases/templates the new engine extracts from the real
                        // corpus, with the feature breakdown, without any UI cutover.
                        let profile = all.profile
                        var reclaimedWordsForDump = profile.reclaimedWords
                        var reclaimedLLMResult: VernacularReclaimedLLMClassifier.Result?
                        if profile.isEnabled && profileConfig.enableReclaimedLLMClassifier {
                            let classifyStart = Date()
                            if let runtime = await self.prepareHeadlessPanelBenchReclaimedRuntime(emit: { @Sendable s in print("BENCH:: \(s)"); fflush(stdout) }) {
                                let result = await VernacularReclaimedLLMClassifier.classify(profile.reclaimedWords,
                                                                                             runtime: runtime)
                                await runtime.releaseResources()
                                reclaimedWordsForDump = result.filtered
                                reclaimedLLMResult = result
                                emit(String(format: "profile.reclaimed.llmClassify %d ms status=%@ kept=%d considered=%d model=%@",
                                            Int(Date().timeIntervalSince(classifyStart) * 1000),
                                            result.status, result.filtered.count,
                                            result.considered.count, result.usedModel ? "Y" : "N"))
                            } else {
                                emit(String(format: "profile.reclaimed.llmClassify %d ms status=fallback-no-mlx-runtime kept=%d considered=0 model=N",
                                            Int(Date().timeIntervalSince(classifyStart) * 1000),
                                            reclaimedWordsForDump.count))
                            }
                        }
                        if profile.isEnabled {
                            let s = profile.stats
                            emit("---- VERNACULAR PROFILE (new engine) ----")
                            emit(String(format: "BENCH::   profile.stats subject=%@ lowConfidence=%@ world=%d sent=%d other=%d contacts=%d ngramHashes=%d exactNgrams=%d tmplHashes=%d exactTmpl=%d words=%d reclaimed=%d circle=%d phrases=%d templates=%d topics=%d",
                                        s.subjectName, s.lowConfidence ? "Y" : "N",
                                        s.worldMessages, s.sentMessages, s.receivedMessages, s.activeContacts,
                                        s.candidateNgramHashes, s.exactNgramCandidates,
                                        s.candidateTemplateHashes, s.exactTemplateCandidates,
                                        profile.words.count, reclaimedWordsForDump.count, profile.circleSlang.count,
                                        profile.phrases.count, profile.templates.count, profile.topics.count))
                            if let caveat = s.caveat {
                                emit("BENCH::   profile.caveat \(caveat)")
                            }
                            emit("BENCH::   profile.words (rank score x=subjectMsgs other=worldOthers ppl=contacts | worldEff zRole coll sem reg disp burst spam):")
                            for w in profile.words.prefix(40) {
                                let f = w.features
                                emit(String(format: "BENCH::     #%02d %.3f x%d other%d ppl%d | worldEff%.2f zR%.2f coll%.2f sem%.2f reg%.2f disp%.2f burst%.2f spam%.2f  %@",
                                            w.rank, w.score, w.counts.userMessages, w.counts.receivedMessages,
                                            w.counts.activeContactUsers, f.zWorld, f.zRole, f.collocation,
                                            f.semanticShift, f.registerPenalty,
                                            f.dispersion, f.burst, f.spamResistance, w.surface))
                            }
                            if let llm = reclaimedLLMResult {
                                emit("BENCH::   profile.reclaimed.llmVerdicts (verdict score partner surface example):")
                                for item in llm.considered {
                                    let verdict: String
                                    if llm.usedModel {
                                        verdict = (llm.verdicts[item.surface] == true) ? "KEEP" : "DROP"
                                    } else {
                                        verdict = "UNFILTERED"
                                    }
                                    let example = item.examples.first.map {
                                        String($0.replacingOccurrences(of: "\n", with: " ")
                                            .replacingOccurrences(of: "\r", with: " ")
                                            .prefix(80))
                                    } ?? ""
                                    emit(String(format: "BENCH::     llm %@ %.3f partner=%@  %@  \"%@\"",
                                                verdict, item.score,
                                                item.topCollocationPartner ?? "-",
                                                item.surface, String(example)))
                                }
                            }
                            if !profile.reclaimedContextDiagnostics.isEmpty {
                                emit("BENCH::   profile.reclaimed.context (rank verdict slang topic margin cat ner windows partner surface example):")
                                for d in profile.reclaimedContextDiagnostics.prefix(80) {
                                    let example = d.example.map {
                                        String($0.replacingOccurrences(of: "\n", with: " ")
                                            .replacingOccurrences(of: "\r", with: " ")
                                            .prefix(80))
                                    } ?? ""
                                    emit(String(format: "BENCH::     #%02d %@ slang%.2f topic%.2f margin%+.2f cat%.2f ner%.2f win%d partner=%@  %@  \"%@\"",
                                                d.rank, d.verdict.rawValue, d.slangRate, d.topicRate,
                                                d.keepMargin, d.topicCategoryProximity, d.namedEntityRate,
                                                d.windows, d.topCollocationPartner ?? "-", d.surface,
                                                String(example)))
                                }
                            }
                            // "people you said it to": distinct chats the subject used each reclaimed surface in.
                            var reclaimedChatsBySurface: [String: Set<Int64>] = [:]
                            let reclaimedSurfaceSet = Set(reclaimedWordsForDump.prefix(40).map { $0.surface })
                            if !reclaimedSurfaceSet.isEmpty {
                                for m in msgs where profileSubjectContext.isSubjectMessage(m) {
                                    for w in m.wordSet.intersection(reclaimedSurfaceSet) {
                                        reclaimedChatsBySurface[w, default: []].insert(m.chat)
                                    }
                                }
                            }
                            emit("BENCH::   profile.reclaimedWords (rank score x=subjectMsgs other=worldOthers people=distinctChatsYouSaidItIn | worldEff pctile coll senseDist roleSkew concentration steady ctxSlang ctxTopic ctxMargin verdict partner surface):")
                            for r in reclaimedWordsForDump.prefix(40) {
                                emit(String(format: "BENCH::     #%02d %.3f x%d other%d people=%d | worldEff%.2f pctile%.2f coll%.2f sense%.2f role%.2f conc%.2f steady%.2f ctxS%.2f ctxT%.2f ctxM%+.2f %@ partner=%@  %@",
                                            r.rank, r.score, r.counts.userMessages, r.counts.receivedMessages,
                                            reclaimedChatsBySurface[r.surface]?.count ?? 0,
                                            r.worldEff, r.percentile, r.collocation, r.senseDistance, r.roleSkew,
                                            r.concentration, 1.0 - r.counts.maxMonthShare,
                                            r.contextSlangRate, r.contextTopicRate, r.contextKeepMargin,
                                            r.contextVerdict.rawValue, r.topCollocationPartner ?? "-", r.surface))
                            }
                            emit("BENCH::   profile.circleSlang (rank n score x=subjectMsgs other=worldOthers ppl=contacts | worldEff zRole reg disp echo burst glue):")
                            for c in profile.circleSlang.prefix(40) {
                                let f = c.features
                                emit(String(format: "BENCH::     #%02d n%d %.3f x%d other%d ppl%d | worldEff%.2f zR%.2f reg%.2f disp%.2f echo%.2f burst%.2f glue%.2f  %@",
                                            c.rank, c.n, c.score, c.counts.userMessages, c.counts.receivedMessages,
                                            c.counts.activeContactUsers, f.zWorld, f.zRole, f.registerPenalty, f.dispersion,
                                            f.echo, f.burst, f.glue, c.surface))
                            }
                            emit("BENCH::   profile.phrases (rank n score x=subjectMsgs other=worldOthers ppl=contacts | worldEff zRole reg disp burst glue topic):")
                            for p in profile.phrases.prefix(40) {
                                let f = p.features
                                emit(String(format: "BENCH::     #%02d n%d %.3f x%d other%d ppl%d | worldEff%.2f zR%.2f reg%.2f disp%.2f burst%.2f glue%.2f topic%.2f  %@",
                                            p.rank, p.n, p.score, p.counts.userMessages, p.counts.receivedMessages,
                                            p.counts.activeContactUsers, f.zWorld, f.zRole, f.registerPenalty,
                                            f.dispersion, f.burst, f.glue, f.topic, p.surface))
                            }
                            emit("BENCH::   profile.templates (rank score x=subjectMsgs other=worldOthers fills | worldEff zRole disp burst prod anchor):")
                            for t in profile.templates.prefix(20) {
                                let f = t.features
                                let fills = t.topFills.prefix(4).map { "\($0.fill)(\($0.count))" }.joined(separator: ",")
                                emit(String(format: "BENCH::     #%02d %.3f x%d other%d slots%d | worldEff%.2f zR%.2f disp%.2f burst%.2f prod%.2f anchor%.2f  %@   ⟦%@⟧",
                                            t.rank, t.score, t.counts.userMessages, t.counts.receivedMessages,
                                            t.slotCount, f.zWorld, f.zRole, f.dispersion, f.burst,
                                            f.productivity, f.anchorDistinctiveness, t.pattern, fills))
                            }
                            if !all.spreadProfile.isEmpty {
                                emit("BENCH::   profile.spreadProfile (rank spread breadth totalUses surface):")
                                for term in all.spreadProfile.terms.prefix(40) {
                                    emit(String(format: "BENCH::     #%02d spread%d breadth%d total%d  %@",
                                                term.rank, term.spread, term.breadth,
                                                term.totalUses, term.displaySurface))
                                }
                            }
                            emit("---- END VERNACULAR PROFILE ----")
                        }
                        emit("---- VERNACULAR legacy Phase 2 removed; spreadProfile now drives the graph ----")
                    }
                }

                peak.stop(); usleep(80_000)
                emit(String(format: "==== DONE — overall peak %.1f MB ====", peak.globalPeak()))
                exit(0)
            }
        }
    }

    /// Run ONE NL query through the real MLX runtime + the chosen `NLAgent`
    /// entry point and dump the full result to stdout, then `exit(0)`. Gated
    /// entirely behind `HOURGLASS_NL_EVAL` / `HOURGLASS_NL_EVAL_REACT` (see
    /// `applicationDidFinishLaunching`) — never reached on a normal launch.
    ///
    /// We deliberately mirror the production wiring step-for-step:
    ///   1. open chat.db via the same `SearchViewModel` the app uses,
    ///   2. load the SAME cached MLX model via `ModelDownloader.beginDownload`
    ///      (the cache-present path = a memory-map, no network), then AWAIT
    ///      `.ready` + a non-nil container,
    ///   3. build `MessageSearchTools` over the same engines as the `nlAgent`
    ///      getter, wrapped in a real `MLXRuntime`,
    ///   4. call the same agent method `NLSearchViewModel.ask` would for this
    ///      runtime — `.react` → `answerWithToolLoop(userQuery:now:)` (the MLX
    ///      production path); `.singleShot` → `answer(userQuery:now:)`.
    ///
    /// Every line is prefixed `NLEVAL::` so the caller can `grep NLEVAL`.
    private func runHeadlessNLEval(query: String, mode: NLEvalMode) {
        // Detached so we never block the main run loop; bumps off the
        // launch frame and drives the async agent loop to completion.
        Task { @MainActor in
            func emit(_ line: String) {
                print("NLEVAL:: \(line)")
                // Force a flush so a long-running model load / inference
                // still surfaces incrementally through a piped `grep`.
                fflush(stdout)
            }

            let modeLabel: String
            switch mode {
            case .react:      modeLabel = "REACT (answerWithToolLoop — PRODUCTION MLX path)"
            case .singleShot: modeLabel = "SINGLE-SHOT (answer — legacy plan path)"
            }

            emit("==== HOURGLASS NL-SEARCH EVAL (diagnostic baseline) ====")
            emit("mode: \(modeLabel)")
            emit("query: \(query)")
            emit("note: running real on-device MLX runtime + agent (NO behaviour changes)")

            // Capture a starting timestamp BEFORE any react logging so we can
            // scrape the `nl-agent-react` os_log afterward for the per-turn
            // raw model output + full observations (read-only; surfaces logs
            // the production code already writes — no behaviour change).
            let logCutoff = Date()

            // ---- 1. chat.db ----
            // `SearchViewModel.init` already attempts to open chat.db; retry
            // is idempotent and covers the FDA-granted-late race.
            _ = viewModel.retryOpenIfNeeded()
            guard let chatDB = viewModel.database,
                  let search = viewModel.messageSearch else {
                emit("FATAL: chat.db unavailable (no Full Disk Access? not opened). Cannot run eval.")
                emit("==== END (no db) ====")
                exit(1)
            }
            emit("chat.db: OPEN (\(chatDB.url.path))")

            // ---- 2. runtime: MLX (default) or Cactus (opt-in) ----
            // Honors the SAME `nl.runtime.cactus` opt-in `selectRuntime()`
            // uses, so HOURGLASS_NL_EVAL_REACT can A/B the two runtimes
            // (the MLX-vs-Cactus benchmark). Cactus lazy-loads its model on
            // the first respond(), so it has no up-front load to await.
            if UserDefaults.standard.bool(forKey: "nl.runtime.cactus") {
                #if canImport(cactus)
                let cactusRuntime = CactusRuntime()
                let cactusPath = UserDefaults.standard.string(forKey: "nl.cactus.modelPath") ?? "(unset)"
                emit("runtime: Cactus — nl.runtime.cactus=YES modelPath=\(cactusPath)")
                await self.runHeadlessNLEvalBody(query: query, mode: mode, runtime: cactusRuntime,
                                                 chatDB: chatDB, search: search,
                                                 logCutoff: logCutoff, emit: emit)
                return
                #else
                emit("FATAL: nl.runtime.cactus is set but the cactus framework is not linked.")
                emit("==== END (no cactus) ====")
                exit(1)
                #endif
            }

            // ---- 2b. MLX runtime: load the cached model + await readiness ----
            emit("model: id=\(modelDownloader.modelID) cached=\(modelDownloader.isModelCached)")
            guard modelDownloader.isModelCached else {
                emit("FATAL: model is NOT cached on disk; headless eval will not download ~1GB. Run the GUI once to fetch it, or pre-warm the HF cache.")
                emit("==== END (no model cache) ====")
                exit(1)
            }
            // Same call the app uses at launch — for a cached model this is a
            // memory-map + Metal shader compile, not a network fetch.
            modelDownloader.beginDownload()
            emit("model: beginDownload() invoked (cache present → loading into Metal)")

            // Await `.ready` + a non-nil container, with a sane timeout. The
            // load includes mmap'ing ~1GB of weights + compiling Metal
            // shaders; on a cold machine this can take a couple of minutes.
            let loadTimeout: TimeInterval = 300 // 5 minutes
            let loadStart = Date()
            var loadFailureReason: String? = nil
            while true {
                switch modelDownloader.state {
                case .ready where modelDownloader.modelContainer != nil:
                    loadFailureReason = nil
                case .ready:
                    loadFailureReason = nil // ready but container not yet mapped; keep waiting
                case .failed(let reason):
                    loadFailureReason = reason
                case .idle, .downloading:
                    loadFailureReason = nil
                }
                if case .ready = modelDownloader.state, modelDownloader.modelContainer != nil {
                    break
                }
                if let reason = loadFailureReason {
                    emit("FATAL: model load FAILED — \(reason)")
                    emit("==== END (model load failed) ====")
                    exit(1)
                }
                if Date().timeIntervalSince(loadStart) > loadTimeout {
                    emit("FATAL: model did NOT become ready within \(Int(loadTimeout))s.")
                    emit("       state=\(String(describing: modelDownloader.state)) container=\(modelDownloader.modelContainer != nil ? "loaded" : "nil")")
                    emit("       (likely a headless / no-Metal environment — run this from a GUI session.)")
                    emit("==== END (load timeout) ====")
                    exit(1)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let container = modelDownloader.modelContainer else {
                emit("FATAL: container nil after .ready (unexpected).")
                emit("==== END (no container) ====")
                exit(1)
            }
            let loadSeconds = Date().timeIntervalSince(loadStart)
            emit(String(format: "model: READY in %.1fs", loadSeconds))

            let runtime = MLXRuntime(container: container, modelID: modelDownloader.modelID)
            emit("runtime: \(runtime.modelLabel)")
            emit("model: family=\(modelDownloader.modelID.lowercased().contains("qwen3") ? "qwen3 (enable_thinking=false)" : "qwen2.5-instruct (no thinking kwarg)")")

            await self.runHeadlessNLEvalBody(query: query, mode: mode, runtime: runtime,
                                             chatDB: chatDB, search: search,
                                             logCutoff: logCutoff, emit: emit)
        }
    }

    /// Shared tail of the headless NL eval — tools + agent + dump + teardown —
    /// used by BOTH runtime legs (the default MLX path and the opt-in Cactus
    /// benchmark leg). Mirrors the production wiring exactly; exits the
    /// process when done.
    private func runHeadlessNLEvalBody(
        query: String,
        mode: NLEvalMode,
        runtime: any LLMRuntime,
        chatDB: ChatDatabase,
        search: MessageSearch,
        logCutoff: Date,
        emit: (String) -> Void
    ) async {
        // ---- 3. tools (identical to the `nlAgent` getter) ----
        let tools = MessageSearchTools(
            instr: search,
            fts: viewModel.ftsSearcher,
            indexStore: viewModel.indexStore,
            chatDB: chatDB
        )
        let agent = NLAgent(runtime: runtime, tools: tools)

        // ---- 4. run the SAME agent method NLSearchViewModel.ask would ----
        let result: NLQueryResult
        let askStart = Date()
        switch mode {
        case .react:
            // EXACTLY what `NLSearchViewModel.ask` calls for an MLX
            // runtime: `answerWithToolLoop(userQuery:now:)` with the
            // method's own defaults (maxIterations: 8, maxCandidates: 50).
            emit("agent: calling NLAgent.answerWithToolLoop(...) — real ReAct inference, may take a while")
            result = await agent.answerWithToolLoop(userQuery: query, now: askStart)
        case .singleShot:
            emit("agent: calling NLAgent.answer(...) — real single-shot inference, may take a while")
            result = await agent.answer(userQuery: query, now: askStart)
        }
        let askSeconds = Date().timeIntervalSince(askStart)
        emit(String(format: "agent: returned in %.2fs", askSeconds))

        // ---- 5. DUMP ----
        // For the ReAct path, surface the iteration-level detail FIRST —
        // the raw per-turn tool calls + observations scraped from the
        // `nl-agent-react` os_log, then the structured-trace digest.
        if mode == .react {
            Self.dumpReActLog(since: logCutoff, emit: emit)
            Self.dumpReActTraceDigest(result, emit: emit)
        }
        Self.dumpNLResult(result, emit: emit)

        // Mirror the production teardown (no-op observable, keeps the
        // GPU from holding a warm working set — harmless here).
        await runtime.releaseResources()

        emit("==== END (success) ====")
        exit(0)
    }

    /// Scrape this process's `nl-agent-react` os_log entries written since
    /// `cutoff` and emit them as `NLEVAL::` lines. This is the ONLY way to
    /// surface the FULL per-turn raw model output + full observation text:
    /// `answerWithToolLoop` logs `react: iter=N raw (...)` and
    /// `react: iter=N observation: ...` to the unified log, NOT to stdout or
    /// the `NLQueryResult`. Reading them back via `OSLogStore` is purely
    /// observational — we add no logging and change no behaviour.
    ///
    /// `OSLogStore(scope:.currentProcessIdentifier)` requires no entitlement
    /// for the current process. If it's unavailable in this environment we
    /// say so and fall back to the structured-trace digest (which still
    /// carries tool name + summarized args + observation summary per step).
    private static func dumpReActLog(since cutoff: Date, emit: (String) -> Void) {
        emit("---- ReAct RAW LOG (per-turn model output + observations, from os_log nl-agent-react) ----")
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: cutoff)
            // Narrow to our subsystem; we filter category in the loop since
            // the predicate API for category varies across OS versions.
            let predicate = NSPredicate(format: "subsystem == %@", "com.satyajit.bettermessages")
            let entries = try store.getEntries(at: position, matching: predicate)
            var count = 0
            for entry in entries {
                guard let log = entry as? OSLogEntryLog, log.category == "nl-agent-react" else { continue }
                count += 1
                // The composed message already contains the `react: …` text.
                // Collapse newlines so each log line stays one NLEVAL row.
                let msg = log.composedMessage
                    .replacingOccurrences(of: "\n", with: "⏎")
                    .replacingOccurrences(of: "\r", with: "")
                emit("  • \(msg)")
            }
            if count == 0 {
                emit("  (no nl-agent-react entries found in this process's log — OSLogStore returned nothing; relying on the structured-trace digest below)")
            }
        } catch {
            emit("  (OSLogStore unavailable here: \(error). The full structured trace + digest below still capture tool name, summarized args, and observation summaries per turn.)")
        }
    }

    /// Emit a ReAct-specific digest reconstructed from the PUBLIC
    /// `NLQueryResult.trace`: every iteration's tool + summarized args +
    /// observation summary, the total iteration count, whether the
    /// repeat-call breaker fired, and whether a fallback answer was
    /// synthesized vs the model emitting its own final answer. These are the
    /// exact signals `answerWithToolLoop` encodes into the trace + result.
    private static func dumpReActTraceDigest(
        _ result: NLQueryResult,
        emit: (String) -> Void
    ) {
        emit("---- ReAct TRACE DIGEST (reconstructed from NLQueryResult.trace) ----")

        // Tool-call turns are the `.searching` steps whose label begins
        // "Tool: ". Their label carries "Tool: <name> (<args>) → <summary>"
        // after completion (or "Tool: <name> (<args>)" while in-progress —
        // but by return time they're all complete/failed).
        var toolTurn = 0
        var repeatBreakerFired = false
        var modelEmittedFinal = false
        for step in result.trace {
            switch step.phase {
            case .searching where step.label.hasPrefix("Tool:"):
                toolTurn += 1
                let dur = step.duration.map { String(format: "%.0fms", $0 * 1000) } ?? "—"
                emit("  turn \(toolTurn): \(step.label)  [\(step.status.rawValue) · \(dur)]")
            case .answering where step.label.hasPrefix("Final:"):
                modelEmittedFinal = true
                emit("  → model emitted FINAL answer: \(step.label.replacingOccurrences(of: "Final: ", with: ""))")
            case .answering where step.label.hasPrefix("Stopped — repeated"):
                repeatBreakerFired = true
                emit("  → REPEAT-CALL BREAKER fired (model re-issued an identical tool call): \(step.label)")
            default:
                break
            }
        }

        // Total iterations: the planning step's final label reads
        // "Used N tool call(s)".
        let iterLabel = result.trace.first(where: { $0.phase == .planning })?.label ?? "(planning step missing)"
        emit("  iterations: \(iterLabel)")
        emit("  tool-call turns observed in trace: \(toolTurn)")
        emit("  repeat-call breaker fired: \(repeatBreakerFired)")
        emit("  model emitted its own final answer: \(modelEmittedFinal)")

        // Synthesis inference: `answerWithToolLoop` sets `degradedToFallback`
        // = (degraded && hero == nil). If the model did NOT emit a final
        // answer yet there IS an explanation, the post-loop synthesizer
        // (`synthesizeFallbackAnswer`) produced it. Make that explicit.
        let synthesized = !modelEmittedFinal && (result.explanation != nil)
        emit("  fallback answer synthesized post-loop (synthesizeFallbackAnswer): \(synthesized)")
        emit("  degradedToFallback (final): \(result.degradedToFallback)")
    }

    /// Pretty-print an `NLQueryResult` line-by-line, each prefixed `NLEVAL::`
    /// by the supplied `emit`. Kept `static` + pure (only touches the value
    /// type + the injected sink) so it has no lifecycle coupling.
    private static func dumpNLResult(
        _ result: NLQueryResult,
        emit: (String) -> Void
    ) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")

        func oneLine(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "(empty)" }
            return s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\r", with: "")
        }

        func describeResult(_ r: MessageSearch.Result) -> [String] {
            let m = r.message
            return [
                "  text  : \(oneLine(m.body))",
                "  sender: \(r.senderName)\(m.isFromMe ? " (you)" : "")",
                "  date  : \(df.string(from: m.date))",
                "  chat  : \(oneLine(m.chatDisplayName?.isEmpty == false ? m.chatDisplayName : r.partnerName))  guid=\(r.chatGUID ?? "nil")",
            ]
        }

        emit("---- RESULT ----")
        emit("degradedToFallback: \(result.degradedToFallback)")
        emit("fallbackQuery: \(oneLine(result.fallbackQuery))")
        emit("explanation: \(oneLine(result.explanation))")

        // HERO
        emit("---- HERO ----")
        if let hero = result.hero {
            for l in describeResult(hero) { emit(l) }
        } else {
            emit("  (no hero — zero candidates)")
        }

        // PLAN
        emit("---- PLAN (PlanJSON) ----")
        if let plan = result.plan {
            emit("  intent      : \(plan.intent.rawValue)")
            emit("  person      : \(plan.person ?? "nil")")
            emit("  time_window : \(plan.timeWindow.rawValue)")
            emit("  padding_days: \(plan.paddingDays)")
            emit("  concept     : \(plan.concept ?? "nil")")
            emit("  search_query: \(oneLine(plan.searchQuery))")
        } else {
            emit("  (nil — planner failed / rule-based fallback)")
        }

        // CANDIDATES (top ~8)
        let topN = 8
        emit("---- CANDIDATES (top \(topN) of \(result.candidates.count)) ----")
        if result.candidates.isEmpty {
            emit("  (none)")
        } else {
            for (i, c) in result.candidates.prefix(topN).enumerated() {
                emit("  [\(i)]")
                for l in describeResult(c) { emit(l) }
            }
        }

        // TRACE
        emit("---- TRACE (\(result.trace.count) steps) ----")
        for (i, step) in result.trace.enumerated() {
            let dur = step.duration.map { String(format: "%.0fms", $0 * 1000) } ?? "—"
            emit("  [\(i)] \(step.phase.rawValue) · \(oneLine(step.label)) · \(step.status.rawValue) · \(dur)")
        }
    }
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
