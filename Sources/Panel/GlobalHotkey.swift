import KeyboardShortcuts

/// Registered global hotkeys for Hourglass.
///
/// The default summons the spotlight panel. The user can rebind it in
/// Settings via `KeyboardShortcuts.Recorder(for: .toggleSpotlightPanel)`.
extension KeyboardShortcuts.Name {
    /// Default ⌃⌥Space. Chosen because:
    /// - ⌘Space is Spotlight
    /// - ⌃Space is the macOS "previous input source" switch
    /// - ⌃⌥Space is only used by macOS for "next input source", which is a
    ///   no-op when the user has a single input source (the typical case).
    /// - Single-hand friendly, comfortable thumb + pinky + index reach.
    /// User can still rebind in Settings → KeyboardShortcuts.Recorder.
    static let toggleSpotlightPanel = Self(
        "toggleSpotlightPanel",
        default: .init(.space, modifiers: [.control, .option])
    )
}
