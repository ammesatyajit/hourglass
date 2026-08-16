//
//  NLSearchViewModel.swift
//  Hourglass — Natural-language search
//
//  @Observable VM bound by the dashboard's NL bar. Holds:
//    - the user's current NL query
//    - the latest `NLQueryResult` (or in-progress trace)
//    - readiness for the bundled local router
//
//  Routing model
//  -------------
//  The VM doesn't own the agent; AppDelegate injects the bundled Needle2
//  agent and tests may replace it without losing UI state.
//
//  Cancellation
//  ------------
//  Every `ask(...)` call bumps a generation counter; old in-flight tasks
//  ignore their output if a newer one has started. Matches the same
//  pattern `SearchViewModel` uses for keyword search debounce.
//

import Foundation
import Observation
import os

/// Shares the "nl-bar-rendering" category with `AppDelegate`'s logger so
/// runtime-swap + dispatch trails line up in Console.
private let nlBarLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-bar-rendering"
)

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

    /// Non-nil only when the bundled local runtime cannot initialize.
    public private(set) var runtimeNotReadyReason: String?

    /// Display label for the active runtime, surfaced in the trace footer.
    public private(set) var runtimeLabel: String

    // MARK: - Internal

    private var agent: NLAgent
    private var generation: Int = 0
    private var currentTask: Task<Void, Never>?
    public init(agent: NLAgent) {
        self.agent = agent
        self.runtimeLabel = agent.runtime.modelLabel
    }

    /// Swap the underlying agent (primarily for tests and diagnostics).
    public func replaceAgent(_ newAgent: NLAgent) async {
        self.agent = newAgent
        self.runtimeLabel = newAgent.runtime.modelLabel
        await refreshRuntimeReadiness()
    }

    /// Refresh the not-ready state from the bundled runtime.
    public func refreshRuntimeReadiness() async {
        let ready = await agent.runtime.isReady
        self.runtimeNotReadyReason = ready ? nil : "The bundled Needle2 runtime could not initialize."
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

        let ready = await agent.runtime.isReady
        if !ready {
            runtimeNotReadyReason = "The bundled Needle2 runtime could not initialize."
            return
        }

        isAsking = true
        partialTrace = []
        result = nil

        // We could stream partial trace updates by having `NLAgent.answer`
        // accept a callback. This path runs to completion and surfaces the
        // short routing trace at the end.
        //
        // Needle2 takes the production path: one constrained route, one
        // validated database function, direct results. Legacy runtimes remain
        // available to tests and explicit diagnostics.
        let agentRef = agent
        let useNeedle = agentRef.runtime is any NeedleRoutingRuntime
        let useToolLoop = !useNeedle && !(agentRef.runtime is StubLLMRuntime)
        // L4 diagnostic — one log line per query identifies which path
        // ran. Console filter: `subsystem:com.satyajit.bettermessages
        // category:nl-bar-rendering`. Critical when "NL search doesn't
        // work" reports come in: was the runtime ready, was the tool
        // loop used, etc.
        nlBarLogger.info("ask: runtime=\(String(describing: type(of: agentRef.runtime)), privacy: .public) useNeedle=\(useNeedle, privacy: .public) useToolLoop=\(useToolLoop, privacy: .public) query=\"\(q, privacy: .public)\"")
        let task = Task { [weak self] in
            let answer: NLQueryResult
            if useNeedle {
                answer = await agentRef.answerWithNeedle(userQuery: q, now: now)
            } else if useToolLoop {
                answer = await agentRef.answerWithToolLoop(userQuery: q, now: now)
            } else {
                answer = await agentRef.answer(userQuery: q, now: now)
            }
            // Release any runtime scratch space once the tool result is ready.
            if !Task.isCancelled {
                await agentRef.runtime.releaseResources()
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

    /// Cancel any in-flight routing work and wait for a bounded unwind.
    public func prepareForTermination(timeout: Duration = .seconds(3)) async {
        guard let task = currentTask else { return }
        currentTask = nil
        task.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await task.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()   // whichever first: clean unwind or the cap
            group.cancelAll()
        }
    }
}
