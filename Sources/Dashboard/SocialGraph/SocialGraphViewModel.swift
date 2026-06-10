//
//  SocialGraphViewModel.swift
//  Hourglass — Dashboard / Social Graph
//
//  Owns the Social Graph panel's state. The heavy work — read-only SQL,
//  contact resolution, graph construction, community detection, and the
//  force-layout simulation — runs on a DETACHED background task. Only the
//  published result + flags live on the main actor, so the Canvas render is
//  the only thing that touches the main thread.
//
//  Wiring (lead): the dashboard already opens chat.db + resolves contacts once
//  (`DashboardViewModel.bootstrapIfNeeded`). Rather than re-open and re-race
//  TCC, this view model is HANDED the live handle + contacts via `load(...)`.
//  There's also a `bootstrapStandalone()` for previews / standalone hosting
//  that opens its own read-only handle.
//

import Foundation
import Observation

@MainActor
@Observable
public final class SocialGraphViewModel {

    /// The clustered graph + its layout. Nil until the first load resolves.
    public private(set) var result: SocialGraphResult?

    /// True while a build/layout is in flight.
    public private(set) var isLoading = false

    /// Sticky error string (DB open / query failure). nil on success.
    public private(set) var errorMessage: String?

    /// Cap on visible contact nodes. Re-loading with a different cap is cheap
    /// enough to expose as a UI control later; for v1 it's fixed.
    public let nodeCap: Int

    private var generation = 0

    public init(nodeCap: Int = SocialGraphBuilder.defaultNodeCap) {
        self.nodeCap = nodeCap
    }

    // MARK: - Loading

    /// Build the graph from an ALREADY-OPEN chat.db handle + resolved
    /// contacts (the dashboard's). Cancels any in-flight load via the
    /// generation counter. Idempotent-ish: calling twice with the same inputs
    /// just rebuilds; the result is deterministic so the view won't flicker
    /// between distinct layouts.
    public func load(database: ChatDatabase, contacts: ResolvedContacts) {
        let myGen = generation &+ 1
        generation = myGen
        isLoading = true
        errorMessage = nil
        let cap = nodeCap

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let res = try SocialGraphLoader.load(
                    database: database,
                    contacts: contacts,
                    nodeCap: cap
                )
                await self?.apply(res, generation: myGen)
            } catch {
                await self?.fail(error.localizedDescription, generation: myGen)
            }
        }
    }

    /// Open chat.db + resolve contacts independently, then build. For preview
    /// / standalone hosting where no dashboard handle is available. Safe to
    /// call once; surfaces FDA errors into `errorMessage`.
    public func bootstrapStandalone() {
        guard result == nil, !isLoading else { return }
        let myGen = generation &+ 1
        generation = myGen
        isLoading = true
        errorMessage = nil
        let cap = nodeCap

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let db = try ChatDatabase()
                let contacts = ContactResolver.resolve()
                let res = try SocialGraphLoader.load(
                    database: db,
                    contacts: contacts,
                    nodeCap: cap
                )
                await self?.apply(res, generation: myGen)
            } catch let err as ChatDatabase.OpenError {
                await self?.fail(String(describing: err), generation: myGen)
            } catch {
                await self?.fail(error.localizedDescription, generation: myGen)
            }
        }
    }

    /// Inject a prebuilt result directly (previews / tests). Bypasses SQL.
    public func setResultForPreview(_ res: SocialGraphResult) {
        generation &+= 1
        result = res
        isLoading = false
        errorMessage = nil
    }

    // MARK: - Apply / fail (main actor)

    private func apply(_ res: SocialGraphResult, generation: Int) {
        guard generation == self.generation else { return }
        result = res
        isLoading = false
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        errorMessage = message
        isLoading = false
    }
}
