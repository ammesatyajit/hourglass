//
//  NLSearchViewModel.swift
//  Hourglass — Natural-language search
//
//  @Observable VM bound by the dashboard's NL bar. Holds:
//    - the user's current NL query
//    - the latest `NLQueryResult` (or in-progress trace)
//    - a flag for the first-run "model not yet downloaded" UX
//    - a reference to the model downloader so the bar can render progress
//      and let the user kick off / cancel / retry the download.
//
//  Routing model
//  -------------
//  The VM doesn't OWN the agent — it's injected at init AND can be replaced
//  via `replaceAgent(_:)`. The pattern: at init the VM points at whatever
//  runtime is available (the stub if the model isn't ready, MLX if it is).
//  When the model finishes downloading, `AppDelegate` builds a fresh
//  MLX-backed `NLAgent` and calls `replaceAgent` so the *next* query uses
//  it without losing UI state.
//
//  Cancellation
//  ------------
//  Every `ask(...)` call bumps a generation counter; old in-flight tasks
//  ignore their output if a newer one has started. Matches the same
//  pattern `SearchViewModel` uses for keyword search debounce.
//

import Foundation
import Observation

@Observable
@MainActor
public final class NLSearchViewModel {

    // MARK: - Bindable state

    /// The user's free-text NL input. Bound to the text field in
    /// `NLSearchBar`.
    public var query: String = ""

    /// The latest answer, or nil until the user runs a query. The bar
    /// renders the hero + trace + candidates from this struct.
    public private(set) var result: NLQueryResult?

    /// In-progress trace steps for live rendering during the agent loop.
    /// While `result == nil` and `isAsking == true`, the bar shows this
    /// instead — gives the user a real-time "Planning… / Searching…" view.
    public private(set) var partialTrace: [NLTraceStep] = []

    /// Whether an `ask` is currently running. The bar shows a spinner /
    /// disables the input while true.
    public private(set) var isAsking: Bool = false

    /// Non-nil when the LLM runtime isn't ready (e.g. model not downloaded
    /// yet). The bar surfaces a first-run download CTA.
    public private(set) var runtimeNotReadyReason: String?

    /// Display label for the active runtime — surfaced in the trace footer
    /// ("Powered by Qwen 2.5 1.5B" or "Powered by StubLLMRuntime"). Updates
    /// when `replaceAgent` swaps the runtime.
    public private(set) var runtimeLabel: String

    // MARK: - Download wiring

    /// The shared model downloader. Optional so unit tests / preview shims
    /// can construct the VM without a downloader.
    public let modelDownloader: ModelDownloader?

    /// Snapshot of the current download progress, if a download is active.
    /// Nil when the downloader is idle / ready / failed (those states are
    /// surfaced via `downloadState` instead).
    public var downloadProgress: ModelDownloadProgress? {
        guard let modelDownloader else { return nil }
        if case .downloading(let p) = modelDownloader.state { return p }
        return nil
    }

    /// Full download state — let the UI pattern-match on it for the failed
    /// vs idle vs ready branches.
    public var downloadState: ModelDownloadState {
        modelDownloader?.state ?? .ready
    }

    // MARK: - Internal

    private var agent: NLAgent
    private var generation: Int = 0
    private var currentTask: Task<Void, Never>?
    /// A query the user submitted while the runtime wasn't ready. We hold
    /// it so we can auto-run it once the download finishes — the user
    /// shouldn't have to retype after waiting through a 1 GB download.
    private var pendingQuery: String?

    public init(
        agent: NLAgent,
        modelDownloader: ModelDownloader? = nil
    ) {
        self.agent = agent
        self.runtimeLabel = agent.runtime.modelLabel
        self.modelDownloader = modelDownloader
    }

    /// Swap the underlying agent. Called by `AppDelegate` when a model
    /// download completes and the runtime needs to flip from stub → MLX.
    /// Refreshes `runtimeLabel` and `runtimeNotReadyReason` from the new
    /// agent's runtime so the UI updates without an explicit refresh call.
    public func replaceAgent(_ newAgent: NLAgent) async {
        self.agent = newAgent
        self.runtimeLabel = newAgent.runtime.modelLabel
        await refreshRuntimeReadiness()
        // If we held a query while the runtime was unavailable, fire it now.
        if let q = pendingQuery {
            pendingQuery = nil
            self.query = q
            await ask()
        }
    }

    /// Refresh the not-ready state from the runtime. Call after a
    /// model download completes to flip the UI.
    public func refreshRuntimeReadiness() async {
        let ready = await agent.runtime.isReady
        self.runtimeNotReadyReason = ready ? nil : Self.notReadyReason(for: modelDownloader?.state)
    }

    /// Build a user-presentable reason string for "runtime not ready". The
    /// string varies based on the downloader state so the bar can show
    /// "Click Download" vs "Downloading…" vs "Download failed".
    private static func notReadyReason(for state: ModelDownloadState?) -> String {
        guard let state else {
            return "Local AI model not loaded."
        }
        switch state {
        case .idle:
            return "Download the local AI model (~1 GB) to enable natural-language search."
        case .downloading:
            return "Downloading the local AI model…"
        case .ready:
            return "Model loaded; runtime warming up."
        case .failed(let reason):
            return "Model download failed: \(reason)"
        }
    }

    /// Trigger the model download. Routes to `ModelDownloader.beginDownload`
    /// and updates the not-ready reason for the UI.
    public func beginDownload() {
        modelDownloader?.beginDownload()
        runtimeNotReadyReason = Self.notReadyReason(for: modelDownloader?.state)
    }

    /// User asked to cancel the in-flight download. Leaves partial files on
    /// disk for a future resume.
    public func cancelDownload() {
        modelDownloader?.cancelDownload()
        runtimeNotReadyReason = Self.notReadyReason(for: modelDownloader?.state)
    }

    /// User asked to retry after a download failure.
    public func retryDownload() {
        modelDownloader?.retry()
        runtimeNotReadyReason = Self.notReadyReason(for: modelDownloader?.state)
    }

    /// Hide the not-ready CTA. The user picked "Use keyword search instead";
    /// the bar should collapse out of the first-run prompt without
    /// triggering a download. We clear the reason — the bar's expanded
    /// branch will go back to its empty active state.
    public func dismissFirstRunPrompt() {
        runtimeNotReadyReason = nil
    }

    /// Run the agent on the current `query`. Generation-counter-discards
    /// stale results.
    public func ask(now: Date = Date()) async {
        let myGen = generation + 1
        generation = myGen
        currentTask?.cancel()

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            result = nil
            partialTrace = []
            isAsking = false
            return
        }

        // If the runtime isn't ready, fall through to whatever the current
        // agent will do (the stub answers; MLX would throw .notReady). The
        // graceful-degradation policy is "always answer something" — the
        // agent's fallback path runs even when the LLM fails — so we don't
        // hard-block here.
        let ready = await agent.runtime.isReady
        if !ready {
            // Record the query so we can re-fire it after the download
            // completes. Then surface the not-ready reason so the bar
            // shows the first-run prompt instead of an empty trace.
            pendingQuery = q
            runtimeNotReadyReason = Self.notReadyReason(for: modelDownloader?.state)
            return
        }

        isAsking = true
        partialTrace = []
        result = nil

        // We could stream partial trace updates by having `NLAgent.answer`
        // accept a callback. Phase 1 just runs to completion and surfaces
        // the trace at the end — the agent is fast enough (<2 s for stub,
        // ~2 s for MLX) that this is acceptable.
        //
        // Routing: the stub runtime ships canned PlanJSON answers for the
        // canonical demo queries — keep it on the legacy `answer()` path
        // so the demo still works. The real MLX-backed runtime drives the
        // ReAct tool loop (`answerWithToolLoop`) so questions like "who
        // did I text the most" route through `topContacts` instead of
        // trying to lex a search out of a stats question.
        let agentRef = agent
        let useToolLoop = !(agentRef.runtime is StubLLMRuntime)
        let task = Task { [weak self] in
            let answer: NLQueryResult
            if useToolLoop {
                answer = await agentRef.answerWithToolLoop(userQuery: q, now: now)
            } else {
                answer = await agentRef.answer(userQuery: q, now: now)
            }
            await MainActor.run {
                guard let self else { return }
                // Discard if a newer ask superseded us.
                guard self.generation == myGen else { return }
                self.result = answer
                self.partialTrace = []
                self.isAsking = false
            }
        }
        currentTask = task
        await task.value
    }

    /// Clear the result and reset to the initial state (the bar collapses
    /// back to its compact form).
    public func clear() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        query = ""
        result = nil
        partialTrace = []
        isAsking = false
    }
}
