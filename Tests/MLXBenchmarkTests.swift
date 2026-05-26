//
//  MLXBenchmarkTests.swift
//  HourglassTests
//
//  In-process benchmark for the MLX runtime. Paired with the standalone
//  probe at `scripts/probes/cactus-vs-mlx-bench.swift` — that probe
//  reports what it can without linking MLX; this XCTest produces real
//  cold-load + per-prompt + RSS numbers because it runs INSIDE the app
//  target where MLXLLM is linked.
//
//  Gating: same convention as `testMLXIntegration_realLoadAndInference` —
//  off by default so `./scripts/test.sh` stays fast. Flip
//  `RUN_BENCHMARK` to true and run:
//
//    xcodebuild test -project Hourglass.xcodeproj \
//      -scheme Hourglass -configuration Debug \
//      -destination 'platform=macOS' -derivedDataPath build \
//      -skipMacroValidation \
//      -only-testing:HourglassTests/MLXBenchmarkTests/testMLXBenchmark_coldAndWarmRuns \
//      2>&1 | grep '\[BENCH\]'
//
//  Why an XCTest and not a separate executable target:
//  - XCTest's host process gives us the full Swift Package Manager
//    dependency graph (MLXLLM, MLXLMCommon, MLXHuggingFace) without
//    project.yml surgery.
//  - We can read `mach_task_basic_info` for our OWN resident size,
//    which is what we want (the test host's RSS during inference is the
//    RSS the production app would see).
//  - The bench output goes to stdout via `print` and is captured by
//    xcodebuild; the operator pipes through grep to extract just the
//    bench rows.
//
//  Output format (one line per phase, tagged [BENCH]):
//    [BENCH] runtime=MLX phase=cold_load duration_s=… rss_mb=…
//    [BENCH] runtime=MLX phase=prompt label=… duration_s=… tokens=… rss_mb=…
//    [BENCH] runtime=MLX phase=summary avg_wall_s=… peak_rss_mb=… …
//

import Foundation
import XCTest
@testable import Hourglass
import MLXLMCommon

#if canImport(Darwin)
import Darwin
#endif

final class MLXBenchmarkTests: XCTestCase {

    /// Resident size in bytes via `mach_task_basic_info` against the
    /// CURRENT process (the test host). 0 on failure.
    private func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size /
                                            MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    private func mb(_ bytes: UInt64) -> Double {
        return Double(bytes) / 1_048_576
    }

    /// Canonical prompts mirroring `Tests/NLAgentReActTests.swift` and
    /// `scripts/probes/cactus-vs-mlx-bench.swift`. Kept short so
    /// first-token latency dominates over generation length.
    private static let benchPrompts: [(label: String, system: String, user: String, maxTokens: Int)] = [
        ("Q1_top_contacts",
         "Respond with one JSON object: a tool call OR a final answer.",
         "Who did I text the most this year? Pick the right tool.",
         320),
        ("Q2_vegas_search",
         "Respond with one JSON object: a tool call OR a final answer.",
         "What plans did we make about Vegas? Pick the right tool.",
         320),
        ("Q3_count_photos",
         "Respond with one JSON object: a tool call OR a final answer.",
         "How many photos did I send last month? Pick the right tool.",
         320),
        ("Q4_argument_cluster",
         "Respond with one JSON object: a tool call OR a final answer.",
         "What was my argument with Annika around 3 weeks ago? Pick the right tool.",
         320),
        ("Q5_short_freeform",
         "You answer briefly.",
         "Name three colors.",
         64),
    ]

    /// The end-to-end benchmark. Off by default; flip `RUN_BENCHMARK` to
    /// true to run.
    @MainActor
    func testMLXBenchmark_coldAndWarmRuns() async throws {
        let RUN_BENCHMARK = false
        guard RUN_BENCHMARK else {
            throw XCTSkip("MLX benchmark disabled by default. Flip RUN_BENCHMARK in MLXBenchmarkTests to run.")
        }

        let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        guard ModelDownloader.cachedSnapshotExists(for: modelID) else {
            throw XCTSkip("Model not cached. Run app first to trigger download.")
        }

        // Baseline RSS before model load — gives us the model's incremental cost.
        let baselineRSS = currentResidentBytes()
        print("[BENCH] runtime=MLX phase=baseline_pre_load rss_mb=\(String(format: "%.1f", mb(baselineRSS)))")

        // ---- Cold load ----
        let downloader = ModelDownloader(modelID: modelID)
        let loadStart = Date()
        downloader.beginDownload()
        let deadline = Date().addingTimeInterval(60)
        while downloader.modelContainer == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let loadDur = Date().timeIntervalSince(loadStart)
        guard let container = downloader.modelContainer else {
            XCTFail("[BENCH] model load failed after 60s")
            return
        }
        let postLoadRSS = currentResidentBytes()
        print("[BENCH] runtime=MLX phase=cold_load duration_s=\(String(format: "%.3f", loadDur)) rss_mb=\(String(format: "%.1f", mb(postLoadRSS))) rss_delta_mb=\(String(format: "%.1f", mb(postLoadRSS) - mb(baselineRSS)))")

        // ---- Per-prompt runs ----
        let runtime = MLXRuntime(container: container)
        var measurements: [(label: String, wall: Double, rss: UInt64, outChars: Int)] = []
        var peakRSS: UInt64 = postLoadRSS

        for prompt in Self.benchPrompts {
            // Warm-up: one extra call we discard, to let CUDA/Metal warm.
            // We do this only on the first prompt for the runtime.
            let isFirst = (prompt.label == Self.benchPrompts[0].label)
            if isFirst {
                _ = try? await runtime.respond(
                    systemPrompt: "say ok",
                    userPrompt: "ok",
                    maxTokens: 4
                )
            }

            let promptStart = Date()
            let response: String
            do {
                response = try await runtime.respond(
                    systemPrompt: prompt.system,
                    userPrompt: prompt.user,
                    maxTokens: prompt.maxTokens
                )
            } catch {
                print("[BENCH] runtime=MLX phase=prompt label=\(prompt.label) error=\(error)")
                continue
            }
            let dur = Date().timeIntervalSince(promptStart)
            let rss = currentResidentBytes()
            peakRSS = max(peakRSS, rss)
            measurements.append((prompt.label, dur, rss, response.count))
            print("[BENCH] runtime=MLX phase=prompt label=\(prompt.label) duration_s=\(String(format: "%.3f", dur)) out_chars=\(response.count) rss_mb=\(String(format: "%.1f", mb(rss)))")
        }

        // ---- Summary ----
        if !measurements.isEmpty {
            let walls = measurements.map(\.wall)
            let avg = walls.reduce(0, +) / Double(walls.count)
            let minW = walls.min() ?? 0
            let maxW = walls.max() ?? 0
            print("[BENCH] runtime=MLX phase=summary cold_load_s=\(String(format: "%.3f", loadDur)) avg_wall_s=\(String(format: "%.3f", avg)) min_wall_s=\(String(format: "%.3f", minW)) max_wall_s=\(String(format: "%.3f", maxW)) peak_rss_mb=\(String(format: "%.1f", mb(peakRSS))) model_rss_delta_mb=\(String(format: "%.1f", mb(peakRSS) - mb(baselineRSS)))")
        }
    }

    /// Reports MLX model cache state without loading anything. Always
    /// runs (no gate). Helps the probe script know whether the real
    /// bench can be invoked.
    func testMLXBenchmark_modelCachePresent() throws {
        let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        let present = ModelDownloader.cachedSnapshotExists(for: modelID)
        print("[BENCH] runtime=MLX phase=cache_probe model=\(modelID) present=\(present)")
        // No assertion — informational.
    }
}
