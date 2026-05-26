import SwiftUI

/// The hero search field. Big rounded liquid-glass pill at the top of the
/// detail pane. Hosts inline filter chips before the typing cursor.
///
/// Filter chips are passed in as an array of `ActiveFilter` and rendered inside
/// the same glass surface as the text field, wrapped in a `GlassEffectContainer`
/// so they morph smoothly as the user adds/removes them.
struct SearchField: View {
    /// A single active filter, identifiable so SwiftUI can animate add/remove.
    struct ActiveFilter: Identifiable, Hashable {
        let id: UUID
        let category: FilterCategory
        let label: String

        init(id: UUID = UUID(), category: FilterCategory, label: String) {
            self.id = id
            self.category = category
            self.label = label
        }
    }

    @Binding var text: String
    /// Optional binding to a case-sensitive toggle. When supplied, an `Aa`
    /// pill is rendered inside the field; tap toggles it. When nil, no
    /// toggle is shown — useful for browse-window contexts that don't need
    /// it. The pill sits just before the trailing clear-X button.
    var caseSensitive: Binding<Bool>? = nil
    var filters: [ActiveFilter] = []
    var placeholder: String = "Search messages, people, dates…"
    /// Optional rotating example queries shown IN PLACE of the placeholder
    /// when the field is empty + unfocused. Each example fades through
    /// over `rotationInterval` (default 4s). Pass empty to disable.
    ///
    /// Implementation: SwiftUI's `TextField` placeholder can't cleanly
    /// crossfade between strings — its placeholder argument is taken at
    /// view-build time and the only way to animate text inside the field
    /// is to overlay our own `Text` and pass an empty placeholder to the
    /// underlying field. That's exactly what we do.
    var rotatingExamples: [String] = []
    /// How long each example stays visible before fading to the next.
    var rotationInterval: TimeInterval = 4.0
    var onRemoveFilter: ((ActiveFilter) -> Void)? = nil
    var onSubmit: (() -> Void)? = nil

    /// Visual mode the field renders. Drives the leading glyph + the
    /// accent color of the focus ring and trailing affordances. `nil`
    /// keeps the field in its default keyword styling (the dashboard's
    /// browse field, the panel before NL is wired up).
    var mode: Mode = .keyword
    /// Called when the user clicks the leading mode-glyph (sparkles in
    /// NL mode, magnifying glass in keyword mode). The panel uses this
    /// to toggle modes. Nil disables the toggle affordance.
    var onModeToggle: (() -> Void)? = nil
    /// Called when the user clicks the trailing `?` button. Nil hides
    /// the button — used by the dashboard's browse field.
    var onHelpRequested: (() -> Void)? = nil

    /// Two modes the field can render in. Keyword is the default; ask is
    /// the NL agent surface (purple accent + sparkles glyph + "Ask
    /// anything…" placeholder).
    enum Mode: Hashable, Sendable {
        case keyword
        case ask

        var glyph: String {
            switch self {
            case .keyword: return "magnifyingglass"
            case .ask:     return "sparkles"
            }
        }

        var accent: Color {
            switch self {
            case .keyword: return .accentColor
            case .ask:     return .purple
            }
        }

        var toggleHint: String {
            switch self {
            case .keyword: return "Switch to Ask anything mode (Tab)"
            case .ask:     return "Switch to keyword mode (Tab)"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .keyword: return "Keyword search mode"
            case .ask:     return "Ask anything mode"
            }
        }
    }

    @FocusState private var isFocused: Bool

    /// Index into `rotatingExamples`. Advances on a `rotationInterval`-
    /// second timer while the rotator is active.
    @State private var rotatorIndex: Int = 0

    /// Whether the rotating-placeholder layer should drive the field's
    /// prompt. False as soon as the user types or focuses the field — at
    /// which point we fall back to the static `placeholder` string.
    private var isRotatorActive: Bool {
        !rotatingExamples.isEmpty && text.isEmpty && !isFocused
    }

    /// The current placeholder string the field shows beneath the user's
    /// text. When the rotator is active this is empty (the rotator owns
    /// the slot); otherwise it's the static `placeholder` value.
    private var fieldPlaceholder: String {
        isRotatorActive ? "" : placeholder
    }

    /// The example string the rotating layer should currently show.
    private var currentExample: String {
        guard !rotatingExamples.isEmpty else { return "" }
        let safe = ((rotatorIndex % rotatingExamples.count) + rotatingExamples.count) % rotatingExamples.count
        return rotatingExamples[safe]
    }

    var body: some View {
        glassEffectContainerCompat(spacing: 18) {
            HStack(spacing: Space.md) {
                // Leading mode glyph. Clickable when `onModeToggle` is
                // wired so the user can flip into NL mode without typing
                // a question word. In keyword mode it's just the
                // magnifying glass; in ask mode it's sparkles.
                modeGlyphButton

                // Inline filter chips
                if !filters.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(filters) { filter in
                            FilterChip(
                                category: filter.category,
                                label: filter.label,
                                onDismiss: onRemoveFilter.map { remove in
                                    { remove(filter) }
                                }
                            )
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.6).combined(with: .opacity),
                                    removal: .scale(scale: 0.6).combined(with: .opacity)
                                )
                            )
                        }
                    }
                }

                ZStack(alignment: .leading) {
                    TextField(fieldPlaceholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isFocused)
                        .onSubmit { onSubmit?() }
                        .submitLabel(.search)

                    // Rotating-example overlay — sits in the placeholder slot
                    // when the rotator is active. We give the inner Text a
                    // .id so SwiftUI knows each example is a distinct view
                    // and animates the transition between them.
                    if isRotatorActive {
                        Text(currentExample)
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .id(rotatorIndex)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 6)),
                                    removal: .opacity.combined(with: .offset(y: -6))
                                )
                            )
                    }
                }

                if let caseBinding = caseSensitive {
                    Button {
                        caseBinding.wrappedValue.toggle()
                    } label: {
                        Text("Aa")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(caseBinding.wrappedValue ? Color.accentColor : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                    .fill(caseBinding.wrappedValue
                                          ? Color.accentColor.opacity(0.18)
                                          : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                    .strokeBorder(
                                        caseBinding.wrappedValue
                                            ? Color.accentColor.opacity(0.45)
                                            : Color.hairline,
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .animation(.bmDefault, value: caseBinding.wrappedValue)
                    .help(caseBinding.wrappedValue
                          ? "Case-sensitive search is ON. Click to make it case-insensitive."
                          : "Case-insensitive search. Click to make it case-sensitive.")
                    .accessibilityLabel("Case-sensitive search")
                    .accessibilityValue(caseBinding.wrappedValue ? "On" : "Off")
                    .accessibilityAddTraits(caseBinding.wrappedValue ? .isSelected : [])
                }

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .help("Clear search")
                }

                // Help (?) button — always visible when wired. The user
                // explicitly asked for this to be discoverable rather
                // than buried in the footer. Sits at the trailing edge,
                // adjacent to the clear-X so the discoverable
                // affordances cluster.
                if let onHelpRequested {
                    Button(action: onHelpRequested) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help("Search syntax (⌘/ or ⌘?)")
                    .accessibilityLabel("Search syntax help")
                    .accessibilityHint("Opens the keyboard shortcut reference")
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, 14)
            .glassOrMaterial(
                in: RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
                    .strokeBorder(
                        mode.accent.opacity(isFocused ? 0.45 : 0.0),
                        lineWidth: 1.5
                    )
                    .animation(.bmDefault, value: isFocused)
                    .animation(.bmDefault, value: mode)
                    .allowsHitTesting(false)
            }
            .animation(.bmGlassMorph, value: filters)
            .animation(.bmDefault, value: text.isEmpty)
            .animation(.smooth(duration: 0.5), value: rotatorIndex)
            .animation(.bmDefault, value: isRotatorActive)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .task(id: isRotatorActive) {
                // Driven by `isRotatorActive`: when it flips true we start
                // a fresh loop; when it flips false the task is cancelled.
                guard isRotatorActive else { return }
                while !Task.isCancelled {
                    let nanos = UInt64(rotationInterval * 1_000_000_000)
                    do {
                        try await Task.sleep(nanoseconds: nanos)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, isRotatorActive else { return }
                    rotatorIndex = (rotatorIndex + 1) % max(rotatingExamples.count, 1)
                }
            }
        }
    }

    /// The leading mode glyph. In keyword mode it's a non-interactive
    /// magnifying glass; in ask mode it's a clickable sparkles. When
    /// `onModeToggle` is wired, the glyph becomes a button regardless
    /// of mode so the user can flip BOTH directions with a single click.
    @ViewBuilder
    private var modeGlyphButton: some View {
        if let onModeToggle {
            Button(action: onModeToggle) {
                modeGlyphLabel
            }
            .buttonStyle(.plain)
            .help(mode.toggleHint)
            .accessibilityLabel(mode.accessibilityLabel)
            .accessibilityHint(mode.toggleHint)
        } else {
            modeGlyphLabel
                .accessibilityHidden(true)
        }
    }

    private var modeGlyphLabel: some View {
        Image(systemName: mode.glyph)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isFocused ? mode.accent : modeGlyphRestColor)
            .symbolRenderingMode(mode == .ask ? .hierarchical : .monochrome)
            .contentTransition(.symbolEffect(.replace.downUp))
            .animation(.bmDefault, value: mode)
            .animation(.bmDefault, value: isFocused)
    }

    /// Resting color for the leading glyph. In ask mode the sparkles
    /// always reads purple-ish even when unfocused so the mode is
    /// glanceable; in keyword mode it stays as the muted secondary
    /// color until focus.
    private var modeGlyphRestColor: Color {
        switch mode {
        case .keyword: return .secondary
        case .ask:     return .purple.opacity(0.85)
        }
    }
}

// MARK: - Previews

private struct SearchFieldPreviewWrapper: View {
    @State var text: String
    @State var filters: [SearchField.ActiveFilter]
    var body: some View {
        SearchField(
            text: $text,
            filters: filters,
            onRemoveFilter: { f in
                withAnimation(.bmGlassMorph) {
                    filters.removeAll { $0.id == f.id }
                }
            }
        )
        .padding(Space.xl)
    }
}

#Preview("SearchField — empty", traits: .fixedLayout(width: 760, height: 140)) {
    ZStack {
        LinearGradient(
            colors: [.orange.opacity(0.4), .pink.opacity(0.45), .purple.opacity(0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        SearchFieldPreviewWrapper(text: "", filters: [])
    }
}

#Preview("SearchField — with chips", traits: .fixedLayout(width: 760, height: 140)) {
    ZStack {
        LinearGradient(
            colors: [.teal.opacity(0.5), .cyan.opacity(0.5), .blue.opacity(0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        SearchFieldPreviewWrapper(
            text: "flight",
            filters: [
                .init(category: .person, label: "Mom"),
                .init(category: .dateRange, label: "Last 30 days"),
            ]
        )
    }
}

#Preview("SearchField — dark", traits: .fixedLayout(width: 760, height: 140)) {
    ZStack {
        LinearGradient(
            colors: [.indigo.opacity(0.6), .black],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        SearchFieldPreviewWrapper(
            text: "",
            filters: [.init(category: .chat, label: "Vegas planning")]
        )
    }
    .preferredColorScheme(.dark)
}
