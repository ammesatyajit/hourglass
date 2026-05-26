//
//  ModelDownloader.swift
//  Hourglass — Natural-language search
//
//  Wraps `mlx-swift-lm`'s built-in Hugging Face downloader (the
//  `#huggingFaceLoadModelContainer` macro / `LLMModelFactory.shared.loadContainer`
//  path) and surfaces progress to the UI as @Observable state.
//
//  Lifecycle
//  ---------
//  ModelDownloader is a long-lived singleton owned by `AppDelegate`. It is
//  the *single owner* of the loaded `ModelContainer` for the LLM. The
//  `MLXRuntime` actor borrows the container by reference once download is
//  complete.
//
//  Resumability
//  ------------
//  `mlx-swift-lm` delegates to `swift-transformers`'s `HubApi` under the hood,
//  which writes to the standard `~/.cache/huggingface/hub/` path with sibling
//  `.incomplete` files. If the user quits mid-download, re-running pick up
//  from the last completed chunk because the loader sees the partial files.
//  This is handled at the package level — we don't need to write resume code.
//
//  Cancellation
//  ------------
//  We hold the download `Task` and call `.cancel()` from `cancelDownload()`.
//  The cancellation propagates through `loadContainer` into the underlying
//  `HubApi` URL session, leaving the partial files on disk for a future
//  resume.
//

import Foundation
import Observation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
// `#huggingFaceLoadModelContainer` desugars to code that references
// `HuggingFace.HubClient` and `Tokenizers.AutoTokenizer` literally. These
// imports must be in scope at the call site or the macro expansion fails
// with "cannot find HubClient / Tokenizers in scope". MLXHuggingFace
// deliberately doesn't re-export them (it doesn't even depend on them) —
// see the macro's `// make sure you: import HuggingFace` doc comment.
import HuggingFace
import Tokenizers

/// Bridges Hugging Face's progress callback (called off-main) to a
/// `@Sendable` closure that the @MainActor-isolated downloader can react
/// to. Lives as a class so it has a stable identity the loader can capture
/// without re-wrapping. The forwarder itself holds no @MainActor state —
/// the only mutation it performs is invoking the supplied handler.
///
/// Why an explicit type instead of an inline closure: the
/// `#huggingFaceLoadModelContainer` macro re-wraps its progressHandler
/// argument in its own `@Sendable` shell. Capturing `[weak self]` into
/// that double-shell trips Swift 6's strict-concurrency var-capture check
/// (`reference to captured var 'self' in concurrently-executing code`).
/// Passing a method on a sendable class side-steps that — the method
/// reference is sendable by itself.
private final class ProgressForwarder: @unchecked Sendable {
    private let handler: @Sendable (Progress) -> Void
    init(handler: @escaping @Sendable (Progress) -> Void) {
        self.handler = handler
    }
    /// The closure-shaped entry point the loader calls. Method (not
    /// property) so we can pass `forwarder.handle` as a function value.
    @Sendable
    func handle(_ progress: Progress) {
        handler(progress)
    }
}

/// Snapshot of the current download state. UI subscribes via `@Observable`.
public struct ModelDownloadProgress: Sendable, Equatable {
    /// Bytes already fetched (sum across all model files).
    public var bytesDownloaded: Int64
    /// Total bytes to fetch. Zero before the manifest is known.
    public var totalBytes: Int64
    /// Estimated wall-clock seconds remaining at the current rate. Nil
    /// when the rate isn't yet stable (first ~500 ms of the download).
    public var etaSeconds: Double?
    /// Bytes-per-second sliding average over the last few samples.
    public var bytesPerSecond: Double

    /// Convenience: 0.0…1.0 fraction. Returns 0 when `totalBytes` is unknown.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(bytesDownloaded) / Double(totalBytes)))
    }

    public init(
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        etaSeconds: Double? = nil,
        bytesPerSecond: Double = 0
    ) {
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.etaSeconds = etaSeconds
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Lifecycle states a download can be in. UI observes via `state`.
public enum ModelDownloadState: Sendable, Equatable {
    /// Never started. Default at app launch when the model isn't already cached.
    case idle
    /// Currently fetching files from Hugging Face.
    case downloading(ModelDownloadProgress)
    /// Model is on disk and ready to load. Reached either by completion of an
    /// in-flight download OR by detecting an existing cached copy at launch.
    case ready
    /// Download failed (network error, disk full, etc.). The reason is
    /// user-presentable.
    case failed(reason: String)

    public static func == (lhs: ModelDownloadState, rhs: ModelDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        case (.ready, .ready): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// Orchestrates the one-time first-run model download. Single instance per
/// app launch. Owns the loaded `ModelContainer` once download completes,
/// passes it to `MLXRuntime` on demand.
@MainActor
@Observable
public final class ModelDownloader {

    // MARK: - Observable state

    /// Current download lifecycle state. Drives the NL bar's UI.
    public private(set) var state: ModelDownloadState = .idle

    /// The loaded model container, available once `state == .ready`. The
    /// `MLXRuntime` borrows this; we keep the strong reference so SwiftUI
    /// view updates don't destroy the loaded model mid-inference.
    public private(set) var modelContainer: ModelContainer? = nil

    /// Where the model is cached. Surfaced to the UI for a "show in Finder"
    /// affordance + debugging. We don't override the cache root; the value
    /// here is computed (the default Hugging Face cache directory).
    public var modelCachePath: URL {
        // `swift-transformers`'s default. Documented at
        // https://github.com/huggingface/swift-transformers — `~/.cache/huggingface/hub`.
        // We don't override it because (a) the default works on macOS, (b)
        // sharing the cache with the Python mlx-lm setup means devs can
        // pre-warm it without using our app at all.
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent("models--\(modelID.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
    }

    // MARK: - Configuration

    /// The Hugging Face repo we download. Hardcoded — the design doc settled
    /// on this model. If we ever want to flip models in production, this
    /// becomes a Settings toggle. For now: do not change without re-running
    /// the planner-quality benchmarks in `docs/nl-search-design.md` § Q1.
    public let modelID: String

    // MARK: - Internal

    private var downloadTask: Task<Void, Never>? = nil

    /// Sliding window over (timestamp, bytesDownloaded) pairs for ETA math.
    /// Holding 10 samples means we average across the last ~5 seconds at the
    /// 500ms cadence Hub's progress reporter ticks at.
    private var rateSamples: [(t: Date, bytes: Int64)] = []
    private let maxSamples = 10

    public init(modelID: String = "mlx-community/Qwen2.5-1.5B-Instruct-4bit") {
        self.modelID = modelID
        // We DON'T flip state to `.ready` here even if the cache exists —
        // having the files on disk isn't the same as having the model
        // loaded into Metal. `.ready` is reserved for "container is
        // populated and we can answer inference calls immediately."
        //
        // The cache probe is used elsewhere (`isModelCached`) so callers
        // can decide whether the next `beginDownload()` call will be
        // free (just a memory map) vs costly (1 GB over the wire).
    }

    /// Whether the model weights are on disk. Cheap (directory check).
    /// Useful for: (a) the UI deciding whether to show "Download (1 GB)"
    /// vs "Load model" on first run, and (b) the AppDelegate's auto-load
    /// behavior at launch.
    public var isModelCached: Bool {
        Self.cachedSnapshotExists(for: modelID)
    }

    // MARK: - Public API

    /// Kick off the download. Idempotent — if a download is already running
    /// this is a no-op. If the model is `.ready` BUT the container hasn't
    /// been loaded yet (cache-present-at-launch case), proceeds — the
    /// `loadContainer` call short-circuits the actual download and loads
    /// from disk in seconds.
    public func beginDownload() {
        switch state {
        case .downloading:
            return
        case .ready:
            // Already have a container loaded — nothing to do.
            if modelContainer != nil { return }
            // Otherwise: cache was probed at init time and we believed it
            // was complete, but the container hasn't been mapped into
            // memory yet. Proceed to load — this is fast (a few seconds)
            // and produces no network traffic.
        case .idle, .failed:
            break
        }

        state = .downloading(ModelDownloadProgress())
        rateSamples = []

        let modelID = self.modelID
        // We can't capture `self` directly inside the macro-supplied
        // progressHandler because the macro re-wraps the closure in a
        // `@Sendable` shell, and the Swift 6 strict concurrency checker
        // refuses `[weak self]` across that boundary. Bridge via a
        // Sendable forwarding object that doesn't know about Self.
        let forwarder = ProgressForwarder { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.recordProgress(progress)
            }
        }
        let task = Task { [weak self] in
            do {
                let configuration = ModelConfiguration(id: modelID)
                // `#huggingFaceLoadModelContainer` is a freestanding macro
                // shipped by MLXHuggingFace that desugars to a
                // `LLMModelFactory.shared.loadContainer(from:using:configuration:progressHandler:)`
                // call wired to the default `HubClient` + `TokenizersLoader`.
                // We use it (rather than calling loadContainer directly)
                // because the default downloader instance is internal to
                // the MLXHuggingFace module — the macro is the public
                // entry point for that wiring. We supply our own
                // progressHandler so the @Observable state ticks.
                let container = try await #huggingFaceLoadModelContainer(
                    configuration: configuration,
                    progressHandler: forwarder.handle
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.modelContainer = container
                    self?.state = .ready
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.state = .idle
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .failed(reason: Self.humanReadable(error))
                }
            }
        }
        downloadTask = task
    }

    /// Cancel any in-flight download. Partial files are left on disk; a
    /// subsequent `beginDownload()` resumes from the last completed chunk
    /// (handled by `swift-transformers`'s HubApi).
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        // We don't transition state here — the Task's catch block flips
        // back to `.idle` after the cancellation propagates. If we flipped
        // synchronously, the UI would briefly show "Idle" then "Downloading"
        // again if the network slept-and-resumed.
    }

    /// Retry after a failure. Same as `beginDownload()` but explicit so the
    /// UI button can wire to it without checking state.
    public func retry() {
        // Reset to idle so beginDownload's guard lets us through.
        state = .idle
        beginDownload()
    }

    // MARK: - Internal — progress accounting

    /// Called from the loader's progress callback. Updates the observable
    /// snapshot + computes a sliding-window bytes/sec.
    fileprivate func recordProgress(_ progress: Progress) {
        let completed = Int64(progress.completedUnitCount)
        let total = Int64(progress.totalUnitCount)
        let now = Date()

        rateSamples.append((t: now, bytes: completed))
        if rateSamples.count > maxSamples {
            rateSamples.removeFirst(rateSamples.count - maxSamples)
        }

        var bps: Double = 0
        var eta: Double? = nil
        if rateSamples.count >= 2,
           let first = rateSamples.first,
           let last = rateSamples.last {
            let dt = last.t.timeIntervalSince(first.t)
            let db = Double(last.bytes - first.bytes)
            if dt > 0.25 {  // Need ~quarter second of data for a useful rate.
                bps = db / dt
                if bps > 0, total > 0 {
                    eta = Double(total - completed) / bps
                }
            }
        }

        state = .downloading(ModelDownloadProgress(
            bytesDownloaded: completed,
            totalBytes: total,
            etaSeconds: eta,
            bytesPerSecond: bps
        ))
    }

    // MARK: - Cache probing

    /// Does the model appear to be cached locally already? Cheap directory
    /// check — doesn't validate weights or tokenizer integrity (that's the
    /// loader's job and happens at `loadContainer` time).
    ///
    /// Errs on the side of "missing" — if anything looks off we re-download.
    /// Marked `nonisolated` so it can be called from `init` AND from
    /// non-main contexts (tests, background pre-warming).
    nonisolated static func cachedSnapshotExists(for modelID: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let snapshotsDir = home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent("models--\(modelID.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil),
              let snapshot = entries.first else {
            return false
        }
        // Look for the safetensors weights file as a proxy for completeness.
        // MLX-format models always ship at least one *.safetensors.
        guard let snapshotContents = try? fm.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil) else {
            return false
        }
        return snapshotContents.contains(where: { $0.pathExtension == "safetensors" })
    }

    // MARK: - Errors

    nonisolated static func humanReadable(_ error: Error) -> String {
        let raw = String(describing: error)
        // Trim huge structural errors down. We just want a 1-line summary
        // for the banner; the full error gets logged via os_log elsewhere.
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        if firstLine.count > 200 {
            return String(firstLine.prefix(200)) + "…"
        }
        return firstLine
    }

    // MARK: - Formatting helpers (also used by the UI)
    // Both formatters are pure functions of their inputs; `nonisolated` so
    // tests and view code can call them without entering @MainActor.

    nonisolated public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated public static func formatETA(_ seconds: Double) -> String {
        if seconds < 1   { return "<1s" }
        if seconds < 60  { return "\(Int(seconds.rounded()))s" }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            let s = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(m)m \(s)s"
        }
        let h = Int(seconds / 3600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(h)h \(m)m"
    }
}
