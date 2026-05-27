//
//  MLXRuntimeTests.swift
//  HourglassTests
//
//  Tests for the Phase 2 NL runtime lift:
//    1. `MLXRuntimeError` shape / messaging
//    2. `ModelDownloadState` Equatable behavior
//    3. `ModelDownloadProgress` fraction math + cached snapshot probe
//    4. The runtime-selection branch in `AppDelegate.selectRuntime`
//       (via a thin shim — we don't bring up the full delegate).
//
//  What we explicitly DO NOT test here:
//    - Real MLX inference: no model on disk in CI, and even with one
//      a single inference run takes 100+ ms and 1 GB of RAM. We mock
//      via the existing `LLMRuntime` protocol when other tests want
//      to exercise the agent loop.
//    - The actual download to Hugging Face: would push 1 GB across the
//      wire on every test run. Instead we test the state machine and
//      cache-probe in isolation.
//
//  These tests pair with the existing `NLAgentTests` (which mock the
//  runtime). Together they cover the surface of the Phase 2 lift
//  without invoking MLX itself.
//

import Foundation
import XCTest
@testable import Hourglass
import MLXLMCommon

final class MLXRuntimeTests: XCTestCase {

    // MARK: - MLXRuntimeError

    func testMLXRuntimeError_modelNotLoaded_describesItself() {
        let err = MLXRuntimeError.modelNotLoaded
        let s = String(describing: err)
        XCTAssertTrue(s.contains("model"))
        XCTAssertTrue(s.contains("not loaded"))
    }

    func testMLXRuntimeError_inferenceFailed_includesUnderlying() {
        let err = MLXRuntimeError.inferenceFailed(underlying: "kv cache overflow")
        let s = String(describing: err)
        XCTAssertTrue(s.contains("kv cache overflow"),
                      "underlying error reason should be surfaced: \(s)")
    }

    // MARK: - ModelDownloadState equality

    func testDownloadState_equality_distinguishesCases() {
        XCTAssertEqual(ModelDownloadState.idle, ModelDownloadState.idle)
        XCTAssertEqual(ModelDownloadState.ready, ModelDownloadState.ready)
        XCTAssertNotEqual(ModelDownloadState.idle, ModelDownloadState.ready)
    }

    func testDownloadState_equality_downloadingComparesByProgress() {
        let a = ModelDownloadState.downloading(ModelDownloadProgress(bytesDownloaded: 100, totalBytes: 1000))
        let b = ModelDownloadState.downloading(ModelDownloadProgress(bytesDownloaded: 100, totalBytes: 1000))
        let c = ModelDownloadState.downloading(ModelDownloadProgress(bytesDownloaded: 200, totalBytes: 1000))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDownloadState_equality_failedComparesByReason() {
        XCTAssertEqual(ModelDownloadState.failed(reason: "net"), ModelDownloadState.failed(reason: "net"))
        XCTAssertNotEqual(ModelDownloadState.failed(reason: "net"), ModelDownloadState.failed(reason: "disk"))
    }

    // MARK: - ModelDownloadProgress

    func testProgress_fraction_zeroBeforeTotalKnown() {
        let p = ModelDownloadProgress(bytesDownloaded: 100, totalBytes: 0)
        XCTAssertEqual(p.fraction, 0.0)
    }

    func testProgress_fraction_clamps01() {
        let over = ModelDownloadProgress(bytesDownloaded: 1500, totalBytes: 1000)
        XCTAssertEqual(over.fraction, 1.0)
        let under = ModelDownloadProgress(bytesDownloaded: -10, totalBytes: 1000)
        XCTAssertEqual(under.fraction, 0.0)
    }

    func testProgress_fraction_midwayAccurate() {
        let p = ModelDownloadProgress(bytesDownloaded: 250, totalBytes: 1000)
        XCTAssertEqual(p.fraction, 0.25, accuracy: 0.0001)
    }

    // MARK: - ModelDownloader formatters

    func testFormatBytes_megabytes() {
        let s = ModelDownloader.formatBytes(5_000_000)
        XCTAssertTrue(s.contains("MB"))
    }

    func testFormatBytes_gigabytes() {
        let s = ModelDownloader.formatBytes(1_500_000_000)
        XCTAssertTrue(s.contains("GB"))
    }

    func testFormatETA_subSecond() {
        XCTAssertEqual(ModelDownloader.formatETA(0.5), "<1s")
    }

    func testFormatETA_seconds() {
        XCTAssertEqual(ModelDownloader.formatETA(42), "42s")
    }

    func testFormatETA_minutes() {
        let s = ModelDownloader.formatETA(95)
        XCTAssertTrue(s.contains("m"))
        XCTAssertTrue(s.contains("s"))
    }

    // MARK: - Cached snapshot probe

    func testCachedSnapshotExists_returnsFalseForUnknownModel() {
        // A made-up model name we know doesn't exist in any cache.
        let probe = ModelDownloader.cachedSnapshotExists(for: "fake-org/fake-model-nonexistent-\(UUID().uuidString)")
        XCTAssertFalse(probe, "should report no cache for a random model id")
    }

    // MARK: - ModelDownloader lifecycle

    @MainActor
    func testDownloader_idleByDefault_whenNoCache() {
        // Use a fresh UUID to guarantee no cached copy on the test machine.
        let randomID = "fake-org/model-\(UUID().uuidString)"
        let dl = ModelDownloader(modelID: randomID)
        XCTAssertEqual(dl.state, .idle)
        XCTAssertNil(dl.modelContainer)
    }

    @MainActor
    func testDownloader_modelCachePath_followsHFConvention() {
        let dl = ModelDownloader(modelID: "mlx-community/gemma-4-e2b-it-4bit")
        let p = dl.modelCachePath.path
        XCTAssertTrue(p.contains(".cache"),
                      "cache path should be under ~/.cache: \(p)")
        XCTAssertTrue(p.contains("huggingface"),
                      "cache path should be HF-conventional: \(p)")
        XCTAssertTrue(p.contains("models--mlx-community--gemma-4-e2b-it-4bit"),
                      "cache path should encode the model ID HF-style: \(p)")
    }

    // MARK: - NotReady reason

    @MainActor
    func testNotReadyReason_promptsForDownload_whenIdle() async {
        // Inject a stub runtime so we have a controlled isReady value.
        let tools = NLAgentTests.MockTools()
        let runtime = NotReadyRuntime()
        let agent = NLAgent(runtime: runtime, tools: tools)
        let randomID = "fake-org/model-\(UUID().uuidString)"
        let dl = ModelDownloader(modelID: randomID)
        let vm = NLSearchViewModel(agent: agent, modelDownloader: dl)
        await vm.refreshRuntimeReadiness()
        XCTAssertNotNil(vm.runtimeNotReadyReason)
        XCTAssertTrue(vm.runtimeNotReadyReason?.contains("Download") == true ||
                      vm.runtimeNotReadyReason?.contains("download") == true,
                      "should mention download: \(vm.runtimeNotReadyReason ?? "nil")")
    }

    @MainActor
    func testDismissFirstRunPrompt_clearsReason() {
        let tools = NLAgentTests.MockTools()
        let runtime = NotReadyRuntime()
        let agent = NLAgent(runtime: runtime, tools: tools)
        let dl = ModelDownloader(modelID: "fake-org/model-\(UUID().uuidString)")
        let vm = NLSearchViewModel(agent: agent, modelDownloader: dl)
        vm.beginDownload()
        XCTAssertNotNil(vm.runtimeNotReadyReason)
        vm.dismissFirstRunPrompt()
        XCTAssertNil(vm.runtimeNotReadyReason)
    }

    @MainActor
    func testReplaceAgent_swapsRuntimeLabel() async {
        let tools = NLAgentTests.MockTools()
        let stub = StubLLMRuntime(modelLabel: "stub-A")
        let agent1 = NLAgent(runtime: stub, tools: tools)
        let vm = NLSearchViewModel(agent: agent1)
        XCTAssertEqual(vm.runtimeLabel, "stub-A")
        let stub2 = StubLLMRuntime(modelLabel: "stub-B")
        let agent2 = NLAgent(runtime: stub2, tools: tools)
        await vm.replaceAgent(agent2)
        XCTAssertEqual(vm.runtimeLabel, "stub-B")
    }

    // MARK: - Runtime selection (the AppDelegate branch)

    /// Mirrors `AppDelegate.selectRuntime`'s logic in a unit-testable form.
    /// We can't easily spin up the real `AppDelegate` (it requires the
    /// `SearchViewModel.database` to be opened against chat.db with FDA),
    /// so we inline the branch and exercise it against a fake downloader.
    func testRuntimeSelection_picksStubWhenContainerMissing() async {
        // `.idle` state, no container — should fall through to stub.
        let runtime: LLMRuntime = selectRuntimeForTest(state: .idle, container: nil)
        XCTAssertTrue(runtime is StubLLMRuntime)
    }

    func testRuntimeSelection_picksStubWhenReadyButNoContainer() async {
        // `.ready` state but no container yet — the load hasn't completed.
        // We should still fall through to the stub so the bar works in
        // the meantime.
        let runtime: LLMRuntime = selectRuntimeForTest(state: .ready, container: nil)
        XCTAssertTrue(runtime is StubLLMRuntime)
    }

    func testRuntimeSelection_picksStubWhenDownloading() async {
        let runtime: LLMRuntime = selectRuntimeForTest(
            state: .downloading(ModelDownloadProgress(bytesDownloaded: 100, totalBytes: 1000)),
            container: nil
        )
        XCTAssertTrue(runtime is StubLLMRuntime)
    }

    func testRuntimeSelection_picksStubWhenFailed() async {
        let runtime: LLMRuntime = selectRuntimeForTest(
            state: .failed(reason: "no net"),
            container: nil
        )
        XCTAssertTrue(runtime is StubLLMRuntime)
    }

    /// Mirror of `AppDelegate.selectRuntime` — keep this in sync with the
    /// real one. If the branch in AppDelegate changes, this helper has to
    /// move with it.
    private func selectRuntimeForTest(state: ModelDownloadState, container: ModelContainer?) -> LLMRuntime {
        if case .ready = state, let container {
            return MLXRuntime(container: container)
        }
        return StubLLMRuntime()
    }

    // MARK: - Integration test (gated on model being cached)

    /// Real end-to-end load + inference against the cached MLX model.
    /// Skipped by default — opt in by setting `BETTERMESSAGES_RUN_MLX=1`
    /// in the environment. This keeps `./scripts/test.sh` fast and CI
    /// stable (no model on the runner). To run locally:
    ///
    ///   BETTERMESSAGES_RUN_MLX=1 xcodebuild test \
    ///     -only-testing:HourglassTests/MLXRuntimeTests/testMLXIntegration_realLoadAndInference
    ///
    /// On a dev machine that has the model cached this confirms:
    ///   1. The `#huggingFaceLoadModelContainer` macro expands and runs.
    ///   2. The MLX kernels can be loaded into Metal.
    ///   3. `ChatSession.respond` returns non-empty text.
    /// First load is ~1 second (mmap + tokenizer init); inference is
    /// ~500ms on M2 Pro for a ~50 token plan output.
    @MainActor
    func testMLXIntegration_realLoadAndInference() async throws {
        // Disabled by default — flip RUN_MLX_INTEGRATION to `true` for
        // a one-shot bench, then flip back. The scheme env-var path is
        // unreliable across XcodeGen / xcodebuild combinations; this
        // toggle is simpler and works.
        let RUN_MLX_INTEGRATION = false
        guard RUN_MLX_INTEGRATION else {
            throw XCTSkip("MLX integration disabled by default. Flip RUN_MLX_INTEGRATION in MLXRuntimeTests to bench.")
        }
        let modelID = "mlx-community/gemma-4-e2b-it-4bit"
        guard ModelDownloader.cachedSnapshotExists(for: modelID) else {
            throw XCTSkip("Model not cached on this machine. Run app once and click Download to pre-warm, or skip integration test.")
        }

        let downloader = ModelDownloader(modelID: modelID)
        XCTAssertEqual(downloader.state, .idle, "downloader starts idle even when cache exists")
        XCTAssertTrue(downloader.isModelCached, "cache should be detected")

        // Drive the downloader to actually load the container (no network
        // hits since the cache is present — this is a local-file load).
        let loadStart = Date()
        downloader.beginDownload()
        // Wait for the load to complete by polling state with a timeout.
        let deadline = Date().addingTimeInterval(30)
        while downloader.modelContainer == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let loadDur = Date().timeIntervalSince(loadStart)
        guard let container = downloader.modelContainer else {
            XCTFail("Model container never loaded after 30 s")
            return
        }
        print("[MLXRuntime integration] model load: \(String(format: "%.2f", loadDur))s")

        // Construct the runtime + run one canonical inference.
        let runtime = MLXRuntime(container: container)
        let isReady = await runtime.isReady
        XCTAssertTrue(isReady)

        // Probe the canonical queries from the design doc Q3 and the bug
        // report. We log raw output + parse outcome for each so the
        // developer running this gets a real failure spectrum, not a
        // single-query yes/no.
        let canonicalQueries: [String] = [
            "find my argument with annika that happened maybe 2 weeks ago",
            "what plans did Erik and I make about vegas",
            "when did I first text Howard?",
            "show me funny things from the family chat",
            "did mom say anything about dinner this week?",
            "did I ever apologize to Henry?",
        ]

        for q in canonicalQueries {
            let inferStart = Date()
            let response = try await runtime.respond(
                systemPrompt: NLAgent.plannerSystemPrompt,
                userPrompt: q,
                maxTokens: 256
            )
            let inferDur = Date().timeIntervalSince(inferStart)
            print("======================================================")
            print("QUERY: \(q)")
            print("[\(String(format: "%.2f", inferDur))s, \(response.count) chars]")
            print("----- RAW OUTPUT -----")
            print(response)
            print("----- PARSE -----")
            do {
                let parsed = try PlanJSONParser.parse(response)
                print("OK: intent=\(parsed.intent.rawValue) person=\(parsed.person ?? "nil") tw=\(parsed.timeWindow.rawValue) padding=\(parsed.paddingDays) concept=\(parsed.concept ?? "nil") query=\(parsed.searchQuery)")
            } catch {
                print("FAILED: \(error)")
            }
        }
        // We don't assert here — this is a probe for the developer.
    }
}

/// Runtime that reports `isReady = false` for the NotReady test.
private struct NotReadyRuntime: LLMRuntime {
    let modelLabel = "not-ready"
    var isReady: Bool { get async { false } }
    func respond(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        throw LLMRuntimeError.notReady(reason: "test fixture")
    }
}
