//
//  NLModelPreference.swift
//  Hourglass — Natural-language search
//
//  The user-selectable "quality mode" for the on-device NL model, plus the
//  canonical HF repo id / display label / chat-template family for each mode.
//  This is the SINGLE source of truth the rest of the NL stack reads:
//    - `ModelDownloader.init()` picks its `modelID` from the persisted mode.
//    - `MLXRuntime` is built family-aware (only Qwen3 gets the
//      `enable_thinking` template kwarg) + labelled from the mode.
//    - The Settings picker (HourglassApp.GeneralSettingsPane) reads/writes
//      the persisted mode.
//
//  Why a separate file
//  -------------------
//  Centralising the model catalog here means there is exactly ONE place that
//  knows "Standard = Qwen3-4B-4bit, High = Qwen2.5-7B-Instruct-4bit", and the
//  per-family chat-template quirks live next to the ids they apply to. Both
//  Settings and the runtime wiring read from it, so they can never drift.
//
//  Codex consult #3 (plans.md 2026-06-03): default on-device model moved
//  1.7B → 4B (the synthesis/general floor), with an opt-in 7B High mode.
//

import Foundation

/// The chat-template family a model belongs to. The two families we ship
/// render their prompts differently and we must NOT treat them the same:
///
///   - **Qwen3** templates emit a `<think>…</think>` reasoning block before
///     the answer UNLESS `enable_thinking=false` is passed as a template
///     render kwarg. We measured ~10s/turn of think-block generation on the
///     1.7B (plans.md 2026-06-02) — disabling it is the real latency fix.
///   - **Qwen2.5-Instruct** has no reasoning mode at all; its template never
///     references `enable_thinking` and never emits `<think>`. Passing the
///     kwarg would be silently ignored by Jinja, but we deliberately DON'T
///     pass it so the render kwargs match exactly what the template expects.
public enum NLModelFamily: Sendable, Equatable {
    case qwen3
    case qwen25Instruct

    /// Whether this family's chat template honours an `enable_thinking`
    /// render kwarg (and therefore whether we should pass it).
    public var supportsEnableThinkingKwarg: Bool {
        switch self {
        case .qwen3:          return true
        case .qwen25Instruct: return false
        }
    }
}

/// The user-facing quality mode for the on-device NL model. Persisted in
/// `UserDefaults`. `standard` is the default — a 4B model is the floor for
/// reliable synthesis + general ReAct (Codex #3). `high` is the opt-in 7B
/// for users who want the best answers and have the disk + RAM headroom.
public enum NLModelQuality: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Default. `mlx-community/Qwen3-4B-4bit` (~2.5 GB) — the grounded eval's
    /// tool-calling winner (docs/nl-eval-grounded.md): beats the 1.7B (which
    /// hallucinates operators) and the 7B (no reasoning mode → loops). ~2.5GB
    /// resident during a query; the container isn't unloaded between queries,
    /// which is fine for normal single-query use.
    case standard
    /// Opt-in. `mlx-community/Qwen2.5-7B-Instruct-4bit` (~4.3 GB). NOTE: the
    /// eval found this WORSE than Standard for tool-calling (no reasoning mode);
    /// kept only as a heavier alternative for non-agentic synthesis.
    case high

    public var id: String { rawValue }

    /// The canonical Hugging Face repo id downloaded + loaded for this mode.
    /// Both verified to resolve on HF (mlx-community, 4-bit, safetensors +
    /// chat template) on 2026-06-03.
    public var modelID: String {
        switch self {
        // Qwen3-4B is the default — the grounded eval's tool-calling winner
        // (docs/nl-eval-grounded.md). ~2.5GB resident during a query. NOTE: the
        // container isn't unloaded between queries (ModelDownloader holds it;
        // releaseResources only clears the GPU buffer cache), so it stays
        // resident after the first ask. That's fine for normal single-query
        // use; idle-unload is a future nicety, not a correctness need.
        case .standard: return "mlx-community/Qwen3-4B-4bit"
        case .high:     return "mlx-community/Qwen2.5-7B-Instruct-4bit"
        }
    }

    /// Which chat-template family this mode's model belongs to. Drives the
    /// per-family render-kwarg handling in `MLXRuntime`.
    public var family: NLModelFamily {
        switch self {
        case .standard: return .qwen3
        case .high:     return .qwen25Instruct
        }
    }

    /// Short label shown in the trace footer ("Powered by …") and the
    /// Settings picker. Kept terse — the picker pairs it with a size hint.
    public var displayLabel: String {
        switch self {
        case .standard: return "Qwen3 4B (MLX)"
        case .high:     return "Qwen2.5 7B Instruct (MLX)"
        }
    }

    /// Human label for the Settings picker row.
    public var settingsTitle: String {
        switch self {
        case .standard: return "Standard"
        case .high:     return "High"
        }
    }

    /// Approximate on-disk download size, surfaced in Settings so the user
    /// knows what a switch will cost before they trigger the fetch.
    public var approxDownloadLabel: String {
        switch self {
        case .standard: return "~2.5 GB"
        case .high:     return "~4.3 GB"
        }
    }
}

/// Persistence + lookup for the selected `NLModelQuality`. Reads/writes a
/// single `UserDefaults` key. Pure value-free helpers (static) so any layer
/// — `ModelDownloader.init` (off-main at construction), the Settings view,
/// the runtime wiring — can read the current selection without owning state.
public enum NLModelPreference {

    /// UserDefaults key for the persisted quality mode.
    public static let defaultsKey = "nl.model.quality"

    /// The currently selected quality mode, read from `defaults`. Falls back
    /// to `.standard` (the 4B default) when unset or unrecognised.
    public static func current(_ defaults: UserDefaults = .standard) -> NLModelQuality {
        guard let raw = defaults.string(forKey: defaultsKey),
              let mode = NLModelQuality(rawValue: raw) else {
            return .standard
        }
        return mode
    }

    /// The model id for the current selection — what `ModelDownloader`
    /// downloads/loads by default.
    public static func currentModelID(_ defaults: UserDefaults = .standard) -> String {
        current(defaults).modelID
    }

    /// Map a concrete model id back to its quality mode + family, for the
    /// runtime wiring (which is handed a `modelID` string by the downloader
    /// and must pick the right chat-template handling). Falls back to a
    /// best-effort family sniff for ids not in our catalog (e.g. a legacy
    /// cached Qwen3-1.7B): any id containing "qwen3" → qwen3, else
    /// qwen2.5-instruct treatment.
    public static func quality(forModelID id: String) -> NLModelQuality? {
        NLModelQuality.allCases.first { $0.modelID == id }
    }

    /// Best-effort family for ANY model id (catalog or not). Used by
    /// `MLXRuntime` so it always knows whether to pass `enable_thinking`.
    public static func family(forModelID id: String) -> NLModelFamily {
        if let mode = quality(forModelID: id) { return mode.family }
        // Fall back to a name sniff for ids we don't catalog (e.g. a
        // previously-cached Qwen3-1.7B-4bit, or a hand-set id).
        let lower = id.lowercased()
        if lower.contains("qwen3") { return .qwen3 }
        // Qwen2.5 / Qwen2 / anything else → treat as a plain instruct model
        // with no thinking mode (the safe default: don't inject a kwarg the
        // template may not understand).
        return .qwen25Instruct
    }

    /// Best-effort display label for ANY model id (catalog or not).
    public static func displayLabel(forModelID id: String) -> String {
        if let mode = quality(forModelID: id) { return mode.displayLabel }
        // Unknown id — show the bare repo leaf so the footer is still useful.
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        return "\(leaf) (MLX)"
    }
}
