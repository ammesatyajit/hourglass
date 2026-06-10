//
//  CactusRuntime.swift
//  Hourglass — Natural-language search
//
//  OPT-IN, DEFAULT-OFF `LLMRuntime` backed by the Cactus on-device inference
//  engine (CACTUS_VERSION v2.0). A *light* integration: it links the vendored
//  `cactus-macos.xcframework`, loads a Cactus CQ model directory, and runs a
//  single completion per `respond()` so we can later benchmark MLX vs Cactus.
//
//  This file deliberately does NOT touch the production MLX path. The default
//  NL runtime stays `MLXRuntime` (when the model is downloaded) / `StubLLMRuntime`
//  (otherwise). `AppDelegate.selectRuntime()` only returns a `CactusRuntime`
//  when BOTH of these hold:
//    1. `defaults write com.satyajit.hourglass nl.runtime.cactus -bool true`
//    2. a readable model directory at `nl.cactus.modelPath` (UserDefaults)
//  If the flag is off, or the path is missing/unreadable, Cactus is never
//  constructed and nothing here runs.
//
//  Concurrency
//  -----------
//  An `actor`, for the same reason `MLXRuntime` is one — and a stronger one:
//  Cactus's C engine is explicitly single-threaded *per model handle* (its
//  docs require serial use + `cactus_reset` between unrelated conversations +
//  `cactus_destroy` on teardown). Two `cactus_complete` calls in flight on the
//  same handle would corrupt the KV cache. Actor isolation gives us that
//  serialization for free; the agent loop already awaits each call.
//
//  Lifecycle
//  ---------
//  Lazy load. The model handle (`cactus_model_t`, an opaque `void*`) is created
//  on the FIRST `respond()` via `cactus_init`, then cached for the runtime's
//  lifetime — `cactus_init` is the expensive step (memory-maps + builds the
//  model), `cactus_complete` is cheap by comparison. `releaseResources()` does
//  NOT destroy the handle (we want it warm for the next query, matching MLX's
//  "keep weights resident" policy); `shutdown()` destroys it on app teardown.
//
//  Privacy / cloud handoff — IMPORTANT
//  -----------------------------------
//  Cactus ships an optional cloud-handoff path: when local confidence drops
//  below `confidence_threshold` AND `auto_handoff` is true (BOTH defaults are
//  "on enough" to forward prompts), it can POST the prompt to Cactus Cloud.
//  Hourglass's product promise is local-only. We HARD-DISABLE that on every
//  call by passing options `auto_handoff:false`, `confidence_threshold:0`,
//  and `enable_thinking_if_supported:false`. We also never set a Cactus app
//  id / telemetry environment, and we `cactus_telemetry_shutdown()` defensively
//  at load. Net: nothing leaves the device. (See plans.md 2026-05-27 for the
//  cloud-handoff risk write-up that motivated these flags.)
//

import Foundation
import os

// The `cactus` clang module comes from the vendored xcframework
// (Vendor/cactus-macos.xcframework). Its umbrella header is `cactus_engine.h`.
// We guard the import behind `canImport` so the file still *parses* on a
// machine/CI where the framework hasn't been vendored yet — it just compiles
// to an unavailable stub there rather than breaking the whole target.
#if canImport(cactus)
import cactus
#endif

private let cactusLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "cactus-runtime"
)

public enum CactusRuntimeError: Error, CustomStringConvertible, Sendable {
    /// The Cactus framework isn't linked into this build (the `cactus` clang
    /// module wasn't importable at compile time). Should never fire in a
    /// normal build — the xcframework is vendored + linked via project.yml.
    case frameworkUnavailable
    /// No model directory configured, or the path doesn't exist / isn't a
    /// directory. The UserDefaults key is `nl.cactus.modelPath`.
    case modelPathMissing(path: String?)
    /// `cactus_init` returned NULL — the path exists but Cactus couldn't load
    /// a model from it (wrong format, missing config/tokenizer, etc.).
    case modelLoadFailed(detail: String)
    /// `cactus_complete` returned a negative status, or the engine reported
    /// `success:false` in its JSON envelope.
    case completionFailed(detail: String)
    /// The completion succeeded at the C layer but its JSON envelope couldn't
    /// be parsed / had no `response` field.
    case malformedResponse(detail: String)

    public var description: String {
        switch self {
        case .frameworkUnavailable:
            return "CactusRuntime: cactus framework not linked into this build"
        case .modelPathMissing(let p):
            return "CactusRuntime: model path missing or unreadable (\(p ?? "nil"))"
        case .modelLoadFailed(let d):
            return "CactusRuntime: cactus_init failed (\(d))"
        case .completionFailed(let d):
            return "CactusRuntime: cactus_complete failed (\(d))"
        case .malformedResponse(let d):
            return "CactusRuntime: malformed completion envelope (\(d))"
        }
    }
}

/// UserDefaults keys the Cactus integration reads. Kept in one place so the
/// runtime, `AppDelegate.selectRuntime()`, and any future Settings UI agree.
public enum CactusDefaultsKey {
    /// Bool, default false. The opt-in master switch. When true (and a model
    /// path resolves), `selectRuntime()` returns a `CactusRuntime`.
    public static let enabled = "nl.runtime.cactus"
    /// String. Absolute path to a Cactus CQ model *directory* (the kind
    /// `cactus download` writes under `weights/<model>/`, containing
    /// `config.txt`, `vocab.txt`, `chat_template.jinja2`, and the quantized
    /// `*.weights` / `*.scale` tensors). Passed verbatim to `cactus_init`.
    public static let modelPath = "nl.cactus.modelPath"
}

/// Local-LLM runtime backed by the Cactus engine. Opt-in alternative to
/// `MLXRuntime` for benchmarking. Actor-isolated to honour Cactus's
/// single-threaded-per-model contract.
public actor CactusRuntime: LLMRuntime {

    /// Display name surfaced in the trace footer ("Powered by …").
    public nonisolated let modelLabel: String

    /// Absolute path to the Cactus model directory. Resolved at construction
    /// from UserDefaults (or injected directly in tests/benchmarks).
    private let modelPath: String?

    /// Opaque Cactus model handle (`cactus_model_t` == `void*`). nil until the
    /// first successful `cactus_init`. We hold it as `UnsafeMutableRawPointer`
    /// so this file still type-checks even when the `cactus` module is absent.
    private var handle: UnsafeMutableRawPointer?

    /// True once we've tried (and failed) to load, so we don't hammer
    /// `cactus_init` on every call when the model is unloadable.
    private var loadAttemptedAndFailed = false

    /// Construct from UserDefaults. This is what `selectRuntime()` calls.
    public init() {
        self.modelPath = UserDefaults.standard.string(forKey: CactusDefaultsKey.modelPath)
        self.modelLabel = "Cactus"
        self.handle = nil
    }

    /// Construct with an explicit model path (tests / benchmark harness).
    public init(modelPath: String?, modelLabel: String = "Cactus") {
        self.modelPath = modelPath
        self.modelLabel = modelLabel
        self.handle = nil
    }

    /// Whether we can generate right now. We treat "a model directory exists
    /// on disk at the configured path" as ready — the expensive `cactus_init`
    /// is deferred to the first `respond()`, mirroring how `MLXRuntime`
    /// reports ready before its first generation warms the session. Returns
    /// false (never crashes) when unconfigured, so callers can fall back.
    public var isReady: Bool {
        get async {
            #if canImport(cactus)
            guard !loadAttemptedAndFailed else { return false }
            guard let path = modelPath, !path.isEmpty else { return false }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && isDir.boolValue
            #else
            return false
            #endif
        }
    }

    /// Generate a reply. Loads the model lazily on first call, then runs one
    /// Cactus completion and returns the model's `response` text. Cloud
    /// handoff + thinking are hard-disabled (see header).
    public func respond(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        #if canImport(cactus)
        let model = try loadIfNeeded()

        let messagesJSON = try Self.encodeMessages(system: systemPrompt, user: userPrompt)
        let optionsJSON = Self.encodeOptions(maxTokens: maxTokens)

        // Response buffer. Cactus writes a JSON envelope (not raw text) here.
        // 64 KiB is the size the upstream Swift README uses and is ample for a
        // plan JSON + the metrics envelope; on overflow Cactus returns a
        // negative status and we surface it rather than truncating silently.
        let bufferSize = 1 << 16
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let written: Int32 = messagesJSON.withCString { msgPtr in
            optionsJSON.withCString { optPtr in
                cactus_complete(
                    model,
                    msgPtr,
                    &buffer,
                    bufferSize,
                    optPtr,
                    nil,    // tools_json — none for the light integration
                    nil,    // streaming callback
                    nil,    // user_data
                    nil,    // pcm_buffer
                    0       // pcm_buffer_size
                )
            }
        }

        guard written >= 0 else {
            let detail = Self.lastError() ?? "cactus_complete returned \(written)"
            throw CactusRuntimeError.completionFailed(detail: detail)
        }

        let envelope = String(cString: buffer)
        return try Self.extractResponse(fromEnvelope: envelope)
        #else
        throw CactusRuntimeError.frameworkUnavailable
        #endif
    }

    /// No-op for parity with `MLXRuntime.releaseResources()`. We intentionally
    /// keep the loaded model warm between queries (loading is the expensive
    /// part). Use `shutdown()` to actually free the handle.
    public func releaseResources() async {
        // Intentionally empty — keep the model resident.
    }

    /// Destroy the Cactus model handle. Call on app teardown. Idempotent.
    public func shutdown() async {
        #if canImport(cactus)
        if let h = handle {
            cactus_destroy(h)
            handle = nil
            cactusLogger.info("CactusRuntime: model handle destroyed")
        }
        #endif
    }

    // MARK: - Loading

    #if canImport(cactus)
    /// Return the loaded handle, loading it on first use. Throws (never traps)
    /// when the path is missing or `cactus_init` fails. After a failure we set
    /// `loadAttemptedAndFailed` so we don't retry on every call.
    private func loadIfNeeded() throws -> UnsafeMutableRawPointer {
        if let h = handle { return h }
        if loadAttemptedAndFailed {
            throw CactusRuntimeError.modelLoadFailed(detail: "prior load failed; not retrying")
        }

        guard let path = modelPath, !path.isEmpty else {
            loadAttemptedAndFailed = true
            throw CactusRuntimeError.modelPathMissing(path: modelPath)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            loadAttemptedAndFailed = true
            throw CactusRuntimeError.modelPathMissing(path: path)
        }

        // Defensive: make sure no telemetry/app-id was registered, and quiet
        // the engine's logging to WARN+ so it doesn't spam our unified log.
        cactus_log_set_level(2)
        cactus_telemetry_shutdown()

        cactusLogger.info("CactusRuntime: loading model at \(path, privacy: .public)")
        let h: UnsafeMutableRawPointer? = path.withCString { p in
            // corpus_dir = NULL (no RAG), cache_index = false.
            cactus_init(p, nil, false)
        }
        guard let loaded = h else {
            loadAttemptedAndFailed = true
            let detail = Self.lastError() ?? "cactus_init returned NULL"
            throw CactusRuntimeError.modelLoadFailed(detail: detail)
        }
        handle = loaded
        cactusLogger.info("CactusRuntime: model loaded")
        return loaded
    }

    /// Pull the engine's last error string, if any.
    private static func lastError() -> String? {
        guard let c = cactus_get_last_error() else { return nil }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }
    #endif

    // MARK: - JSON encoding / decoding (pure, testable, framework-independent)

    /// Encode the system+user prompt into Cactus's chat-messages JSON array as
    /// ONE user message with the system text prepended — NOT a separate
    /// system-role message. The v1.14 engine's multi-message/system-role path
    /// drops content NONDETERMINISTICALLY: the same 8.4k-char payload
    /// prefilled 47 tokens as [system,user] but 2,525 as a single user
    /// message, and short [system,user] calls flipped between working and
    /// "please provide a question" across runs (see plans.md 2026-06-09
    /// cactus-bench entry). Single-user-message calls were stable across
    /// every test, including repeated completes on one held handle (the
    /// ReAct loop's exact pattern). Gemma-family chat templates have no real
    /// system role anyway, so this is also the template-faithful encoding.
    static func encodeMessages(system: String, user: String) throws -> String {
        let merged = system.isEmpty ? user : system + "\n\n" + user
        let messages: [[String: String]] = [
            ["role": "user", "content": merged],
        ]
        let data = try JSONSerialization.data(withJSONObject: messages, options: [])
        guard let s = String(data: data, encoding: .utf8) else {
            throw CactusRuntimeError.malformedResponse(detail: "could not encode messages JSON")
        }
        return s
    }

    /// Encode generation options. Crucially HARD-DISABLES cloud handoff +
    /// thinking so prompts never leave the device and the output is a clean
    /// answer (no `<think>` block). Greedy (`temperature:0`) to match the
    /// MLX runtime's deterministic JSON-planning configuration.
    static func encodeOptions(maxTokens: Int) -> String {
        let options: [String: Any] = [
            "max_tokens": maxTokens,
            "temperature": 0.0,
            // --- local-only guardrails ---
            "auto_handoff": false,
            "confidence_threshold": 0,
            "enable_thinking_if_supported": false,
        ]
        // JSONSerialization can't fail for this fixed, JSON-safe dictionary;
        // fall back to a hand-written literal if it somehow does.
        if let data = try? JSONSerialization.data(withJSONObject: options, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"max_tokens\":\(maxTokens),\"temperature\":0,\"auto_handoff\":false,\"confidence_threshold\":0,\"enable_thinking_if_supported\":false}"
    }

    /// Parse Cactus's completion envelope and return the model's text. The
    /// envelope is a JSON object: `{ "success": bool, "error": string?,
    /// "response": string, "function_calls": [...], ... }`. We surface the
    /// `error` field on `success:false`, and the `response` field otherwise.
    static func extractResponse(fromEnvelope envelope: String) throws -> String {
        guard let data = envelope.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CactusRuntimeError.malformedResponse(detail: "not a JSON object: \(envelope.prefix(200))")
        }
        if let success = obj["success"] as? Bool, success == false {
            let err = (obj["error"] as? String) ?? "unknown error"
            throw CactusRuntimeError.completionFailed(detail: err)
        }
        guard let response = obj["response"] as? String else {
            throw CactusRuntimeError.malformedResponse(detail: "no `response` field in envelope")
        }
        return response
    }
}
