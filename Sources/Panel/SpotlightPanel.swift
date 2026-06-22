import SwiftUI

/// The compact, Spotlight-style search surface. Hosted inside `SpotlightNSPanel`
/// by `PanelController`. Composes design-agent's existing components.
///
/// Layout: single column. Hero search field at top, results list below.
/// No sidebar — that's the browse window's job.
struct SpotlightPanel: View {
    @Bindable var viewModel: SearchViewModel
    @Bindable var recentSearches: RecentSearchesStore
    /// Lazy provider for the NL view model. The panel calls this exactly
    /// when the user toggles into Ask mode (auto-detect or explicit Tab)
    /// for the first time per panel-show, so the agent isn't built
    /// until needed.
    var nlSearchViewModelProvider: @MainActor () -> NLSearchViewModel? = { nil }
    let dismiss: () -> Void

    @State private var selectedResultID: Int64?
    @State private var suggestionIndex: Int = 0

    /// Whether the help-syntax sheet is currently overlaid on the panel.
    /// Triggered by the `?` button in the search field, the ? in the
    /// footer, ⌘/ or ⌘?.
    @State private var showHelp: Bool = false

    /// Active mode of the search field. `keyword` is the default;
    /// `ask` routes the query through the NL agent and renders the
    /// agent's trace / hero result in place of the keyword results list.
    /// **Tab toggles between modes** — no auto-detection (the old
    /// `looksLikeNL` heuristic was removed because it was unpredictable:
    /// typing "find my cactus message" would jump into Ask mode even
    /// when the user wanted a literal keyword search).
    @State private var mode: SearchField.Mode = .keyword

    /// Cached NL view model. Built on first toggle into `ask` mode
    /// (lazy — see `nlSearchViewModelProvider`).
    @State private var nlViewModel: NLSearchViewModel?

    /// Example queries that crossfade through the placeholder slot while
    /// the search field is empty and unfocused. Each example demonstrates
    /// a different filter category so a user idling over the panel learns
    /// the grammar by osmosis.
    ///
    /// The "Try:" prefix makes it unambiguously a hint, not the user's
    /// own text. We keep the list small (5 entries, ~20s cycle) so a user
    /// hovering on the panel briefly sees variety without being
    /// overwhelmed.
    static let placeholderExamples: [String] = [
        "Try: cactus from:Mom",
        "Try: type:image last:30d",
        "Try: reactions:>=3",
        "Try: vacation+flight",
        "Try: chat:family last:1y",
    ]

    /// NL example queries shown when the field is empty in Ask mode.
    /// Mirrors `NLSearchBar.examples` so the dashboard and panel
    /// surface the same hero examples.
    static let askPlaceholderExamples: [String] = [
        "Ask: who did I text the most this year?",
        "Ask: when did I first text my favorite contact?",
        "Ask: how many photos did I send last month?",
        "Ask: what plans did we make about Vegas?",
        "Ask: show me the funniest messages from last week",
    ]


    // MARK: - Mode plumbing

    /// Binding the SearchField writes to. In Ask mode it tunnels through
    /// to the NL view model's `query` so the same field drives the
    /// agent — otherwise the user would have to type twice to get an
    /// answer. In Keyword mode it's a direct passthrough to the
    /// existing search view model.
    private var searchFieldBinding: Binding<String> {
        if mode == .ask, let nl = nlViewModel {
            return Binding(
                get: { nl.query },
                set: { nl.query = $0 }
            )
        }
        return $viewModel.query
    }

    /// Flip the mode. `explicit = true` when the user pressed Tab or
    /// clicked the sparkles glyph; we pin the choice so auto-detect
    /// doesn't override it. `explicit = false` for the auto-detect
    /// path; the user can still ESC out and the next typed character
    /// that doesn't look NL won't re-flip them.
    private func toggleMode() {
        let next: SearchField.Mode = (mode == .keyword) ? .ask : .keyword
        // Ensure the NL view model is fetched on first entry into Ask
        // mode. If the provider returns nil (FDA denied, agent setup
        // failed) we silently refuse — better to stay in keyword
        // mode than to flash an unusable Ask surface.
        if next == .ask, nlViewModel == nil {
            nlViewModel = nlSearchViewModelProvider()
            guard nlViewModel != nil else { return }
        }
        withAnimation(.bmDefault) {
            mode = next
        }
        // When entering Ask mode, seed the NL VM with whatever the
        // keyword field currently has so the user doesn't lose the
        // text they were typing. The two view models are otherwise
        // independent; we sync on this single transition only.
        if next == .ask, let nl = nlViewModel {
            nl.query = viewModel.query
        } else if next == .keyword, let nl = nlViewModel {
            // Returning to keyword mode → copy the NL text back so the
            // user can re-issue as a literal keyword search if they
            // want. Cheap; nothing else reads from the NL VM.
            viewModel.query = nl.query
        }
    }

    /// Run the NL agent against the current Ask-mode query. Mirrors
    /// `NLSearchBar`'s submit handler — same path, same agent.
    private func runAskQuery() {
        guard let nl = nlViewModel else { return }
        let q = nl.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Record into the shared recents queue so the user can pull
        // the question up again later (it'll re-detect as NL on submit).
        recentSearches.record(q)
        Task { await nl.ask() }
    }

    /// Reveal the message GUID surfaced by the NL agent's hero result.
    /// Routes through the same GUID path keyword results use; on
    /// success the panel dismisses (consistent UX with keyword opens).
    private func revealMessageFromAsk(messageGUID: String) {
        _ = MessagesGUIDReveal.sendSpotlightOpenURL(messageGUID: messageGUID)
        dismiss()
    }

    /// Escalate the agent's keyword-fallback query into the keyword
    /// pipeline. The user clicked "See in Spotlight →" — we drop them
    /// back into keyword mode with that query primed, fire the search,
    /// and let them browse the wider candidate set.
    private func escalateAskToKeyword(query: String) {
        nlViewModel?.clear()
        mode = .keyword
        viewModel.query = query
        Task { await viewModel.search() }
    }

    /// Parsed view of the current query — recomputed on every render. The
    /// parser is microseconds-fast and this keeps every derived view (chips,
    /// recognized-tokens hint, suggestion eligibility) in lockstep without
    /// any separate state to sync.
    private var parsedQuery: MessageSearch.ParsedQuery {
        MessageSearch.parseQuery(viewModel.query, contacts: nil)
    }

    /// Per-token chip representation. Each chip's label is the literal token
    /// substring (e.g. `chat:amme`) so removing a chip can scrub the matching
    /// substring from `viewModel.query` deterministically.
    ///
    /// **Design note**: tokens stay as literal text inside the search field
    /// AND as chips outside it. This is intentional — chips give a glanceable
    /// "what is this search actually doing" summary; the literal text keeps
    /// the field round-trippable (paste a query out, paste it back in).
    /// See `docs/design-notes.md` § "Inline filter feedback".
    private var filters: [SearchField.ActiveFilter] {
        var out: [SearchField.ActiveFilter] = []
        for token in parsedQuery.tokens {
            let literal = "\(token.prefix.rawValue)\(quoteIfNeeded(token.value))"
            let category: FilterCategory
            switch token.prefix.category {
            case .chat: category = .chat
            case .person: category = .person
            case .date: category = .dateRange
            case .reaction: category = .reaction
            case .type: category = .type
            }
            out.append(.init(category: category, label: literal))
        }
        return out
    }

    /// Quote a value if it contains whitespace (so the chip label reads
    /// faithfully as the on-the-wire token text).
    private func quoteIfNeeded(_ value: String) -> String {
        value.contains(where: { $0.isWhitespace }) ? "\"\(value)\"" : value
    }

    /// Remove the token whose label matches `chipLabel` from the query. We
    /// scan token-by-token rather than doing a string `.replacingOccurrences`
    /// so we don't accidentally clobber a matching substring inside free text.
    private func removeFilter(label chipLabel: String) {
        let parsed = MessageSearch.parseQuery(viewModel.query, contacts: nil)
        for token in parsed.tokens {
            let literal = "\(token.prefix.rawValue)\(quoteIfNeeded(token.value))"
            guard literal == chipLabel else { continue }
            var newQuery = viewModel.query
            newQuery.removeSubrange(token.range)
            // Collapse the double-space we may have left behind.
            viewModel.query = newQuery.replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return
        }
    }

    /// The current autocomplete context derived from the query. When `nil`,
    /// the suggestions popover hides and arrow keys go back to the result
    /// list (or stay in the text field as caret motion — SwiftUI handles).
    private var autocompleteContext: AutocompleteContext? {
        QueryAutocomplete.analyze(query: viewModel.query)
    }

    /// The suggestions for the current context, if any.
    private var suggestions: [QuerySuggestion] {
        guard let ctx = autocompleteContext else { return [] }
        return QuerySuggestionsProvider.suggestions(
            for: ctx,
            contacts: viewModel.allContacts,
            chats: viewModel.allChats
        )
    }

    /// Reveal the given result in Messages.app and dismiss the panel.
    ///
    /// Routing:
    /// - **GUID-based path** (`MessagesGUIDReveal`) — preferred. Uses
    ///   `sms://open?groupid=...` to open 1:1 or group chats, AX-scrolls the
    ///   bubble into view, then synthesizes ⌘F + ⌘V + ↵ for the highlight.
    /// - **Legacy fallback** (`MessagesReveal`) — only if the message or chat
    ///   GUID is missing (shouldn't normally happen post-plumbing).
    private func reveal(_ result: MessageSearch.Result) {
        // Opening a result is the strongest "this search was useful" signal —
        // commit it to recents so the user can re-run it later from the
        // empty state.
        recentSearches.record(viewModel.query)
        if let messageGUID = result.message.guid,
           let chatGUID = result.chatGUID {
            // GUID path runs async; fire-and-forget so the panel can dismiss
            // immediately instead of overlaying Messages.app during the scroll.
            Task { @MainActor in
                _ = await MessagesGUIDReveal.reveal(
                    messageGUID: messageGUID,
                    chatGUID: chatGUID,
                    body: result.message.body,
                    senderName: result.senderName,
                    isFromMe: result.message.isFromMe,
                    messageDate: result.message.date
                )
            }
        } else {
            _ = MessagesReveal.reveal(result)
        }
        dismiss()
    }

    /// The result currently highlighted (selected or, if none, the first).
    /// Used by the Enter key to know which row to open.
    private var currentSelection: MessageSearch.Result? {
        if let id = selectedResultID,
           let hit = viewModel.results.first(where: { $0.message.id == id }) {
            return hit
        }
        return viewModel.results.first
    }

    /// Apply the highlighted suggestion to the query. Hides the popover
    /// implicitly by completing the token (no partial prefix left).
    private func acceptSuggestion(_ suggestion: QuerySuggestion) {
        guard let ctx = autocompleteContext else { return }
        let (newQuery, _) = QueryAutocomplete.apply(
            suggestion: suggestion.value,
            to: viewModel.query,
            in: ctx
        )
        // Trailing space — user wants to keep typing the next filter.
        viewModel.query = newQuery + " "
        suggestionIndex = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: searchFieldBinding,
                caseSensitive: mode == .keyword ? $viewModel.caseSensitive : nil,
                placeholder: mode == .ask ? "Ask anything…" : "Search messages",
                rotatingExamples: mode == .ask
                    ? SpotlightPanel.askPlaceholderExamples
                    : SpotlightPanel.placeholderExamples,
                mode: mode,
                onModeToggle: { toggleMode() },
                onHelpRequested: { withAnimation(.bmDefault) { showHelp = true } }
            )
            .padding(.horizontal, Space.lg)
            // Bumped from `Space.lg` (16) to `Space.xl` (24). The panel
            // uses `.fullSizeContentView` style so content extends under
            // the (invisible) title-bar strip — 16pt of top padding
            // wasn't enough to clear it, and the search field's rounded
            // glass background was getting clipped at the top edge.
            // Most visible after the indexing banner was added: the
            // banner's `move(edge: .top)` transition makes the clipping
            // obvious during the slide-in.
            .padding(.top, Space.xl)
            .padding(.bottom, filters.isEmpty ? Space.md : Space.xs)
            .onSubmit {
                // Enter handling:
                // - In Ask mode → run the agent against the query.
                // - Else if popover open → accept the highlighted suggestion.
                // - Else if a result is highlighted → reveal in Messages.app.
                // - Else → run the search immediately (skip debounce) and
                //   record the query as a recent (the user committed to
                //   it by pressing Enter, even if no result was opened).
                if mode == .ask {
                    runAskQuery()
                } else if !suggestions.isEmpty {
                    let idx = max(0, min(suggestionIndex, suggestions.count - 1))
                    acceptSuggestion(suggestions[idx])
                } else if let pick = currentSelection {
                    reveal(pick)
                } else {
                    recentSearches.record(viewModel.query)
                    Task { await viewModel.search() }
                }
            }
            // Keyboard navigation. We must consume these so they don't
            // bubble to the text field (where ↑/↓ would move caret/cursor).
            //
            // Two modes:
            //   - Suggestions popover visible → ↑/↓ moves the suggestion cursor.
            //   - Results list visible → ↑/↓ moves the row selection.
            // Tab still accepts the active suggestion in the popover mode.
            .onKeyPress(.upArrow) {
                if !suggestions.isEmpty {
                    suggestionIndex = max(0, suggestionIndex - 1)
                    return .handled
                }
                if !viewModel.results.isEmpty {
                    moveResultSelection(by: -1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                if !suggestions.isEmpty {
                    suggestionIndex = min(suggestions.count - 1, suggestionIndex + 1)
                    return .handled
                }
                if !viewModel.results.isEmpty {
                    moveResultSelection(by: 1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.tab) {
                if !suggestions.isEmpty {
                    let idx = max(0, min(suggestionIndex, suggestions.count - 1))
                    acceptSuggestion(suggestions[idx])
                    return .handled
                }
                // Tab with no suggestions → toggle between keyword and
                // ask mode. The only way to enter Ask mode (we removed
                // the auto-detect heuristic — see toggleMode docstring
                // for why). Preserves the query text so the user can
                // re-issue it through the other surface.
                toggleMode()
                return .handled
            }
            // Active filter chips — derived from the parsed query, NOT a
            // separate state slot. The user sees the same tokens twice (as
            // literal text in the field, and as removable chips here) — the
            // chips are the "what filters are active" affordance, the literal
            // text keeps the query round-trippable (copy-paste-share).
            if !filters.isEmpty {
                activeFiltersRow
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
                    .transition(.opacity)
            }

            // First-launch indexing banner. The search-quality engine
            // mirrors chat.db into a local FTS5 index for ~370× faster
            // keyword search (~1s → ~3ms on 525k rows). Building takes
            // ~10s on a beefy machine, longer on older hardware — the
            // user needs to know it's happening AND that search still
            // works (via the INSTR fallback) during the build. Renders
            // a slim non-blocking band; auto-disappears when done.
            if let progress = viewModel.indexingProgress {
                indexingBanner(progress: progress)
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
                    // Pure opacity — earlier `.move(edge: .top)` had the
                    // banner sliding into the search field's space on
                    // appear, which exposed the title-bar clipping above.
                    .transition(.opacity)
            }

            // Per-search error band. SearchViewModel.search() captures
            // engine throws into `errorMessage`; without this, the panel
            // just showed an empty list and the user had no idea why
            // their query produced nothing. Only render when there are
            // no results AND the search isn't currently in flight (we
            // don't want to flash an error while a new search is loading).
            if let errorMsg = viewModel.errorMessage,
               viewModel.results.isEmpty,
               !viewModel.isSearching {
                errorBanner(message: errorMsg)
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
                    .transition(.opacity)
            }

            // Mode dispatch:
            // - Ask mode: dedicated NL content area (agent trace + hero
            //   result + candidates) replaces the keyword results list.
            // - Keyword mode: existing suggestion / result / empty-state
            //   flow.
            if mode == .ask {
                Divider().opacity(0.3)
                askContent
                    .transition(.opacity)
            } else if !suggestions.isEmpty {
                // Suggestions take over the content area while the user is
                // actively typing a recognized token (`chat:am`, `from:m`, …).
                // Once the token is accepted or the user moves on, results return.
                // This is the standard search-autocomplete pattern (Spotlight,
                // browser address bar) — inline, not a floating modal.
                Divider().opacity(0.3)
                inlineSuggestionsList
                    .transition(.opacity)
            } else if let setupError = viewModel.setupError {
                accessDeniedState(message: setupError)
            } else if viewModel.isSearching {
                loadingState
            } else if viewModel.results.isEmpty {
                emptyState
            } else {
                Divider().opacity(0.3)
                resultsList
            }

            footer
        }
        // Bumped `minHeight` from 360 to 420 so the multi-section empty
        // state (5 categories × ~32pt rows + headers + spacing) renders
        // with the footer fully visible at the panel's minimum size. The
        // empty-state body is wrapped in a vertical ScrollView so even at
        // the new minimum the user can scroll if they shrink the panel
        // further — footer stays anchored either way.
        .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // The help overlay sits on top of the panel content. Tapping a
        // token snippet inside the sheet inserts it into the query, fires
        // the search, and dismisses — turning the cheatsheet into a
        // launchpad as well as a reference.
        .overlay {
            if showHelp {
                HelpSheet(
                    onClose: { withAnimation(.bmDefault) { showHelp = false } },
                    onInsert: { example in
                        viewModel.query = example
                        Task { await viewModel.search() }
                        withAnimation(.bmDefault) { showHelp = false }
                    }
                )
                .padding(Space.sm)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                .zIndex(1)
            }
        }
        .onChange(of: viewModel.query) { _, newValue in
            // Debounce — 150ms after last keystroke. Search is exhaustive and
            // can take a moment on broad queries; debouncing keeps typing
            // responsive without truncating results.
            viewModel.searchSoon()
            // Reset selection any time the query changes — otherwise a stale
            // index might point past the end of a now-shorter suggestion list.
            suggestionIndex = 0
            // (Auto-detect-NL-from-text removed 2026-05-25 per user
            // request. Mode is changed ONLY via Tab — predictable.)
        }
        // When the result set changes (new query landed, or filters
        // refined), auto-select the first row. Two reasons:
        //   1. The previous `selectedResultID` may not exist in the new
        //      results — without this it would be visually un-selected
        //      (no blue highlight) even though `currentSelection` falls
        //      back to results.first and ↩ still works.
        //   2. Matches Spotlight/Raycast: the top row is always
        //      pre-highlighted so ↩ is always armed against something
        //      obvious — no "press ↓ first to wake it up" step.
        //
        // Fingerprint = (count, first-row id). Cheap to diff and changes
        // exactly when the visually relevant prefix changes; avoids an
        // Equatable comparison of the full result array on every keystroke.
        .onChange(of: SpotlightPanel.selectionFingerprint(of: viewModel.results)) { _, _ in
            guard let firstID = viewModel.results.first?.message.id else {
                selectedResultID = nil
                return
            }
            let currentIsStale = selectedResultID.map { id in
                !viewModel.results.contains { $0.message.id == id }
            } ?? true
            if currentIsStale {
                selectedResultID = firstID
            }
        }
        .onChange(of: viewModel.caseSensitive) { _, _ in
            // Toggling the Aa pill must re-run the search — both code paths
            // (case-sensitive GLOB vs default LIKE+INSTR) produce different
            // result sets for the same query string.
            viewModel.searchSoon()
        }
        .onExitCommand {
            // Escape, layered (matches Spotlight/Raycast):
            //   1. If help sheet open → close it.
            //   2. Else if in Ask mode → drop back to keyword mode.
            //   3. Else → dismiss the panel.
            if showHelp {
                withAnimation(.bmDefault) { showHelp = false }
            } else if mode == .ask {
                withAnimation(.bmDefault) {
                    mode = .keyword
                }
            } else {
                dismiss()
            }
        }
        // ⌘/ — the keyboard convention for "open help". Toggles the sheet
        // so users who learn the shortcut don't have to mouse over to the
        // ? button every time. ⌘? is the user-requested alternate —
        // technically ⌘⇧/ on US keyboards but the user can think of it
        // as ⌘? and SwiftUI resolves it correctly.
        .background {
            // ⌘/ binding
            Button("Toggle help") {
                withAnimation(.bmDefault) { showHelp.toggle() }
            }
            .keyboardShortcut("/", modifiers: [.command])
            .opacity(0)
            .accessibilityHidden(true)
            // ⌘? (a.k.a. ⌘⇧/) — secondary binding so the user's
            // requested shortcut also works.
            Button("Toggle help (alt)") {
                withAnimation(.bmDefault) { showHelp.toggle() }
            }
            .keyboardShortcut("?", modifiers: [.command])
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// Horizontally-scrolling row of `FilterChip` pills, one per recognized
    /// token. Sits between the search field and the results, becomes visible
    /// only when at least one token is recognized.
    private var activeFiltersRow: some View {
        glassEffectContainerCompat(spacing: 18) {
            HStack(spacing: Space.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ForEach(filters) { filter in
                    FilterChip(
                        category: filter.category,
                        label: filter.label,
                        onDismiss: {
                            withAnimation(.bmGlassMorph) {
                                removeFilter(label: filter.label)
                            }
                        }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .scale(scale: 0.6).combined(with: .opacity)
                        )
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The results list, wired through `SpotlightResultsList` — an
    /// `Equatable`-conforming subview that skips its body re-evaluation
    /// when only `selectedResultID` and the result-ID sequence are
    /// stable. This removes the per-keystroke typing lag: previously
    /// the parent's body re-rendered on every `viewModel.query`
    /// change, dragging the 50-row list (avatars, formatted dates,
    /// reaction clusters, attributedBody decode) through SwiftUI's
    /// layout pass each time, even though `viewModel.results` only
    /// changes once per debounce window. With `.equatable()`, SwiftUI
    /// runs the cheap custom-`==` instead of rebuilding the tree.
    private var resultsList: some View {
        SpotlightResultsList(
            results: viewModel.results,
            selectedResultID: selectedResultID,
            onSelect: { selectedResultID = $0 },
            onReveal: reveal
        )
        .equatable()
    }

    /// Inline autocomplete — sits in the content area while the user is typing
    /// a recognized token. Reuses the existing `QuerySuggestionsPopover` view
    /// (its visual styling is fine; it just doesn't need to be floating).
    private var inlineSuggestionsList: some View {
        QuerySuggestionsPopover(
            suggestions: suggestions,
            selectedIndex: suggestionIndex,
            onSelect: acceptSuggestion,
            onHover: { suggestionIndex = $0 }
        )
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Ask mode body — replaces the keyword results list when `mode == .ask`.
    /// Three visual states:
    ///   1. Idle (no query, no result) → onboarding hint + recents.
    ///   2. Asking (in flight) → spinner + last-known trace.
    ///   3. Answered → hero result + candidates + trace + escalate CTA.
    ///
    /// We deliberately do NOT embed the dashboard's `NLSearchBar` view as-is:
    /// that view contains its own expandable shell, search field, and
    /// download/first-run UI which would double-up with the panel's own
    /// chrome. Instead the panel renders a slim purpose-built content area
    /// that talks to the same `NLSearchViewModel`.
    @ViewBuilder
    private var askContent: some View {
        if let nl = nlViewModel {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.md) {
                    if let reason = nl.runtimeNotReadyReason {
                        askNotReadyState(reason: reason, nl: nl)
                    } else if let result = nl.result {
                        askAnswerView(result: result, nl: nl)
                    } else if nl.isAsking {
                        askLoadingView(nl: nl)
                    } else {
                        askIdleView()
                    }
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Provider returned nil — degrade gracefully.
            VStack(spacing: Space.md) {
                Image(systemName: "sparkles.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Ask mode isn't available")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Grant Full Disk Access on the Dashboard, then try again.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Space.xl)
        }
    }

    /// Idle Ask state — what we render before the user has typed anything
    /// (or after they hit clear). Surfaces example questions + a hint
    /// that ESC drops back to keyword mode.
    private func askIdleView() -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label {
                Text("Ask anything about your messages")
                    .font(.headline)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
            }
            Text("Type a question like ")
                .foregroundStyle(.secondary)
            + Text("\u{201C}who did I text the most this year?\u{201D}")
                .font(.callout.monospaced())
                .foregroundStyle(.purple)
            + Text(" then press \u{21A9}.")
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "command")
                    .font(.caption2)
                Text("Press ⇥ Tab or ESC to switch back to keyword search.")
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)
            .padding(.top, Space.xs)
        }
        .font(.callout)
    }

    /// Mid-query Ask state — small spinner + recent trace lines.
    private func askLoadingView(nl: NLSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Thinking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !nl.partialTrace.isEmpty {
                askTraceList(steps: nl.partialTrace, compact: true)
            }
        }
    }

    /// Answered Ask state — hero result (if any) + the agent's answer
    /// summary + candidate list + escalate-to-keyword CTA.
    private func askAnswerView(result: NLQueryResult, nl: NLSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Explanation banner (when the agent provided one) — sits
            // above the hero so the user reads the "why this match" first.
            if let explanation = result.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                            .fill(Color.purple.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                            .strokeBorder(Color.purple.opacity(0.18), lineWidth: 0.5)
                    )
            }

            // Hero candidate (if any) — click to reveal.
            if let hero = result.hero {
                askCandidateRow(result: hero, isHero: true)
            } else if (result.explanation?.isEmpty ?? true) {
                // No hero AND no textual answer — the agent genuinely found
                // nothing, so surface the empty state with an escalate hook.
                //
                // GUARD on explanation: aggregate answers (e.g. "who did I
                // text the most" → topContacts) legitimately have NO single
                // hero message — the explanation banner above IS the answer.
                // Showing "No matching message found." beneath a confident
                // answer contradicts it (observed: a who-did-I-text-most
                // result rendered the answer AND "No matching message found"
                // at the same time). Only show the empty state when there's
                // no answer to contradict.
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("No matching message found.")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    if !result.fallbackQuery.isEmpty {
                        Text("Searched ")
                            .foregroundStyle(.secondary)
                        + Text(result.fallbackQuery)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            // Additional candidates.
            if result.candidates.count > 1 {
                Text("Other matches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                VStack(spacing: 4) {
                    ForEach(Array(result.candidates.dropFirst().prefix(4).enumerated()), id: \.offset) { _, candidate in
                        askCandidateRow(result: candidate, isHero: false)
                    }
                }
            }

            // Escalate CTA — drops into keyword mode with the agent's
            // fallback query primed.
            if !result.fallbackQuery.isEmpty {
                Button {
                    escalateAskToKeyword(query: result.fallbackQuery)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                        Text("See all in keyword search")
                            .font(.caption)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, Space.xs)
            }

            // Trace — collapsible reasoning. Caption-sized so it doesn't
            // dominate the answer.
            if !result.trace.isEmpty {
                askTraceList(steps: result.trace, compact: false)
                    .padding(.top, Space.xs)
            }
        }
    }

    private func askNotReadyState(reason: String, nl: NLSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label {
                Text("Ask mode isn't ready")
                    .font(.headline)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
            }
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)

            // The actionable bit. Without this the panel told the user to
            // "download the model" but gave them nothing to click — the
            // download CTA only existed on the dashboard NL bar. Now the
            // panel drives the download itself: one click starts it, the
            // query the user just typed is already stashed (pendingQuery),
            // and it auto-fires once the runtime swaps to MLX.
            switch nl.downloadState {
            case .idle, .failed:
                Button {
                    nl.beginDownload()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(nl.downloadState.isFailed
                             ? "Retry download"
                             : "Download model (~1 GB)")
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                            .fill(Color.purple.opacity(0.18))
                    )
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .padding(.top, Space.xs)

            case .downloading:
                // Live progress. `downloadProgress` ticks via the
                // @Observable downloader, so this re-renders as bytes land.
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: nl.downloadProgress?.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .tint(.purple)
                    Text(Self.downloadStatusText(nl.downloadProgress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Space.xs)

            case .ready:
                // Container loaded — the swap + auto-fire of the stashed
                // query is imminent; show a brief warming spinner.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting up…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Space.xs)
            }

            Text("You can keep using keyword search — press Tab or ESC.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// "412 MB / 1.0 GB · 8 MB/s · ~1m left" — compact one-liner under the
    /// download bar. Falls back gracefully when totals/ETA aren't known yet.
    private static func downloadStatusText(_ p: ModelDownloadProgress?) -> String {
        guard let p, p.totalBytes > 0 else { return "Starting download…" }
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        let done = bcf.string(fromByteCount: p.bytesDownloaded)
        let total = bcf.string(fromByteCount: p.totalBytes)
        var parts = ["\(done) / \(total)"]
        if p.bytesPerSecond > 0 {
            parts.append("\(bcf.string(fromByteCount: Int64(p.bytesPerSecond)))/s")
        }
        if let eta = p.etaSeconds, eta > 0, eta.isFinite {
            let m = Int(eta) / 60, s = Int(eta) % 60
            parts.append(m > 0 ? "~\(m)m left" : "~\(s)s left")
        }
        return parts.joined(separator: " · ")
    }

    /// Render one candidate (a `MessageSearch.Result`) as a clickable
    /// solid row. Hero gets a purple-tinted background; siblings are
    /// neutral.
    private func askCandidateRow(result: MessageSearch.Result, isHero: Bool) -> some View {
        Button {
            if let guid = result.message.guid {
                revealMessageFromAsk(messageGUID: guid)
            }
        } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.senderName)
                            .font(.subheadline.weight(.semibold))
                        if !result.partnerName.isEmpty,
                           result.partnerName != result.senderName {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(result.partnerName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(askTimestampLabel(result.message.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(result.message.body)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                if isHero {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(isHero ? Color.purple.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .strokeBorder(
                        isHero ? Color.purple.opacity(0.18) : Color.hairline,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// Compact trace list — caption-sized rows showing the agent's
    /// reasoning steps.
    private func askTraceList(steps: [NLTraceStep], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !compact {
                Text("Reasoning")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: askTraceIcon(for: step.status))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(askTraceColor(for: step.status))
                        .padding(.top, 2)
                    Text(step.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    private func askTraceIcon(for status: NLTraceStep.Status) -> String {
        switch status {
        case .inProgress: return "circle.dotted"
        case .complete:   return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        }
    }

    private func askTraceColor(for status: NLTraceStep.Status) -> Color {
        switch status {
        case .inProgress: return .secondary
        case .complete:   return .purple
        case .failed:     return .orange
        }
    }

    private func askTimestampLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var loadingState: some View {
        VStack(spacing: Space.md) {
            ProgressView()
                .controlSize(.large)
            Text("Searching…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }

    private var emptyState: some View {
        // The empty state has TWO sub-states:
        //   1. Empty field: 5 quick-filter chips (one per category) +
        //      recents (capped at 5) + slim "Ask anything" hint. The
        //      whole stack fits in ONE viewport at the default 520pt
        //      panel height — no scroll required. The user asked for
        //      this explicitly: "you shouldn't have to scroll through
        //      to choose options."
        //   2. Non-empty field but no results ("No matches" state) —
        //      already compact, rendered as-is.
        //
        // Previous version had a ScrollView wrapper because the 5
        // horizontal-scroll category rows ran taller than the panel
        // viewport. With one chip per category, the empty state is
        // intrinsically short enough that we can drop the ScrollView
        // entirely and rely on the panel's own minimum-size guard
        // (`contentMinSize: 640x420`) to keep the footer visible.
        Group {
            if viewModel.query.isEmpty {
                VStack(spacing: Space.lg) {
                    // Compact 5-chip row, one example per category. The
                    // primary discovery surface for the keyword grammar.
                    // The HelpSheet (⌘/ or ⌘?) covers the long tail.
                    EmptyStateSuggestions(
                        topContactNames: emptyStateTopContactNames,
                        onSelect: applyQuickFilter
                    )

                    // Recent searches (capped at 5 — see
                    // RecentSearchesList.maxVisible). Personalized
                    // re-runnable history; sits below the discovery
                    // chips because it's only useful for returning users.
                    if !recentSearches.entries.isEmpty {
                        RecentSearchesList(
                            entries: recentSearches.entries,
                            onSelect: applyRecentSearch,
                            onRemove: { recentSearches.remove($0) }
                        )
                    }

                    // Slim "Ask anything" hint at the bottom — gentle
                    // affordance toward the NL mode without making the
                    // user feel like they're missing a feature. The
                    // sparkles glyph in the field is the primary
                    // affordance; this is the reminder.
                    askModeHint

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.md)
            } else {
                // Non-empty field but no results. Surface the query they
                // searched for (so they can spot a typo at a glance) and
                // give them an easy escape hatch + a hint at what
                // operators might rescue the search.
                noMatchesState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Space.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Slim caption hinting at Ask mode. Rendered below the recents in
    /// the empty state so users know they can ask questions, not just
    /// type operator-laden queries.
    private var askModeHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.purple)
            Text("Ask a natural-language question — ")
                .foregroundStyle(.tertiary)
            + Text("press ⇥ Tab")
                .foregroundStyle(.secondary.opacity(0.85))
            + Text(" to switch modes.")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xs)
    }

    /// Most-recent 1:1 chat partners, surfaced as personalized `from:"<Name>"`
    /// pills in the empty state's People section.
    ///
    /// Source: `viewModel.allChats` (already loaded at SearchViewModel.init —
    /// zero extra SQL). `ChatListing.allChats` returns chats sorted by
    /// `lastMessageDate` descending, so iterating in order naturally gives
    /// us "people you've messaged recently" without a separate top-contacts
    /// query. We dedupe by name (a person with multiple handles shows as
    /// multiple 1:1 chats; the dedup picks the first/most-recent one) and
    /// cap at 4 candidates (the curator inside `EmptyStateSuggestion`
    /// picks 2 — extras are kept as headroom in case the first picks have
    /// names that don't render well, e.g. raw `+1...` handles for
    /// non-AddressBook contacts).
    private var emptyStateTopContactNames: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for chat in viewModel.allChats where chat.style == 45 {
            // 1:1 chat → the partner is the (sole) participant.
            guard let partner = chat.participantNames.first,
                  !partner.isEmpty else { continue }
            // Skip raw-handle partners (e.g. "+15555550100") — they don't
            // read as a "person you text" pill. A user without that
            // contact in AddressBook still gets the generic prompt pills.
            if partner.first == "+" || partner.contains("@") { continue }
            if seen.contains(partner) { continue }
            seen.insert(partner)
            out.append(partner)
            if out.count >= 4 { break }
        }
        return out
    }

    /// "No matches" state with the offending query echoed back + an easy
    /// escape (clear) and an operator hint. Previously was three lines of
    /// generic "No matches." text — useless when the user mistyped
    /// `chat:Annaika` and didn't notice the extra `a`.
    private var noMatchesState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No matches")
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text("for")
                        .foregroundStyle(.secondary)
                    Text("\u{201C}\(viewModel.query)\u{201D}")
                        .font(.callout.weight(.medium).monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
            // Recovery affordances. "Clear" is the universal escape; the
            // tip below it telegraphs an operator the user might not
            // know to try. Cycled per panel-open so we don't burn the
            // user out on one suggestion.
            VStack(spacing: Space.sm) {
                Button {
                    viewModel.query = ""
                } label: {
                    Label("Clear search", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Tip: try a person filter like ")
                    .foregroundStyle(.tertiary)
                + Text("`from:Name`")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                + Text(" or a time window like ")
                    .foregroundStyle(.tertiary)
                + Text("`last:30d`")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                + Text(".")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            .padding(.top, Space.sm)
        }
    }

    /// Re-run a saved query. We set `query` verbatim (no trailing space —
    /// the user committed to this exact string before) and fire the search
    /// immediately. The query is also re-recorded which moves it to the
    /// top of the list (the implicit "use again to bump" behavior).
    private func applyRecentSearch(_ query: String) {
        viewModel.query = query
        recentSearches.record(query)
        Task { await viewModel.search() }
    }

    /// Cheap diffing key for the `selectedResultID` auto-reset effect. The
    /// pair `(count, first-message-id)` changes exactly when the visually
    /// relevant prefix of the results changes (a new search landed, or the
    /// list was emptied). Sidesteps doing an Equatable comparison of the
    /// full results array on every render.
    fileprivate static func selectionFingerprint(of results: [MessageSearch.Result]) -> Int {
        var hasher = Hasher()
        hasher.combine(results.count)
        hasher.combine(results.first?.message.id ?? -1)
        return hasher.finalize()
    }

    /// Move the selected-result cursor up/down by `delta`. Clamped at both
    /// ends — keyboard navigation on a non-circular list. If nothing is
    /// selected yet, the first ↓ goes to row 0; the first ↑ goes to row 0
    /// as well (treating it as "start from the top"). Spotlight does the
    /// same — there's no wrap-around.
    private func moveResultSelection(by delta: Int) {
        let results = viewModel.results
        guard !results.isEmpty else { return }
        let currentIdx: Int
        if let sel = selectedResultID,
           let i = results.firstIndex(where: { $0.message.id == sel }) {
            currentIdx = i
        } else {
            // No selection yet — first key picks row 0.
            currentIdx = (delta > 0 ? -1 : 0)
        }
        let nextIdx = max(0, min(results.count - 1, currentIdx + delta))
        selectedResultID = results[nextIdx].message.id
    }

    /// Apply a quick-filter pill to the query field and fire the search.
    ///
    /// Implementation: we just set `viewModel.query` to the token (with a
    /// trailing space so the user can keep typing free text after it if
    /// they want — feels natural since the autocomplete popover does the
    /// same thing on accept). The `.onChange(of: query)` handler kicks off
    /// the debounced search automatically, but we also call `search()`
    /// directly so the user doesn't have to wait the debounce window for a
    /// pill they just clicked.
    private func applyQuickFilter(_ suggestion: EmptyStateSuggestion) {
        viewModel.query = suggestion.token + " "
        Task { await viewModel.search() }
    }

    /// Slim non-blocking band that appears at the top of the panel while
    /// the FTS5 index is being built (first launch) or caught up after a
    /// long gap (uncommon). Search still works via INSTR during the build;
    /// the banner just keeps the user informed.
    ///
    /// `progress.total` is nil during the "spin up" phase before the
    /// counter is known — we render an indeterminate progress view in that
    /// case rather than 0%.
    private func indexingBanner(progress: SearchViewModel.IndexingProgress) -> some View {
        HStack(spacing: Space.sm) {
            // Subtle activity indicator — small, low-saturation. Don't
            // pull attention away from the search field.
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(bannerHeadline(progress: progress))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Search still works while indexing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let pct = bannerPercent(progress: progress) {
                Text(pct)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bannerHeadline(progress: progress))
    }

    private func bannerHeadline(progress: SearchViewModel.IndexingProgress) -> String {
        if progress.isFullIndex {
            if let total = progress.total, total > 0 {
                let indexed = progress.indexed.formatted(.number.grouping(.automatic))
                let totalFmt = total.formatted(.number.grouping(.automatic))
                return "Indexing your messages… \(indexed) / \(totalFmt)"
            }
            return "Indexing your messages…"
        }
        // Catch-up: less to say. Don't over-explain in steady state.
        return "Catching the index up…"
    }

    private func bannerPercent(progress: SearchViewModel.IndexingProgress) -> String? {
        guard let total = progress.total, total > 0 else { return nil }
        let pct = Double(progress.indexed) / Double(total) * 100.0
        return String(format: "%.0f%%", pct)
    }

    /// Inline error band — surfaces engine throws (malformed query, SQL
    /// errors, transient I/O problems) instead of letting the user stare
    /// at an empty result list wondering what happened. Selectable so
    /// they can copy the message for a bug report.
    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search failed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search failed: \(message)")
    }

    private func accessDeniedState(message: String) -> some View {
        // `message` carries the underlying chat.db open error. Not
        // surfaced — the SQLite-error / path text is noise the user
        // can't act on and reads as alarming. Kept in the signature so
        // callers don't change.
        _ = message
        return VStack(spacing: Space.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
            Text("Allow access to Messages")
                .font(.headline)

            // Privacy-first lede. Matches the Dashboard's FDA panel —
            // single sentence, button labels carry the action verbs.
            Text("Everything stays on this Mac. Hourglass searches your iMessage history locally — nothing is uploaded, sent, or shared.")
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            HStack(spacing: Space.sm) {
                Button("Grant Full Disk Access") {
                    openFullDiskAccessSettingsAndRevealApp()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .help("Opens System Settings and reveals Hourglass.app in Finder so you can drag it into the Full Disk Access list.")

                // After the user toggles FDA on in System Settings, the
                // already-running process still can't read chat.db (the
                // open file descriptor predates the grant). A relaunch
                // is genuinely required.
                Button("Relaunch") {
                    relaunchApp()
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help("Quit and reopen Hourglass after you've toggled Full Disk Access on.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            // Verb correctness: ↵ doesn't "preview" — it opens the message
            // in Messages.app via the GURL Apple Event (`MessagesGUIDReveal`)
            // and dismisses the panel. "Open in Messages" is what's
            // actually happening, so that's what the hint should say.
            footerHint(icon: "return", text: "Open in Messages")
            footerHint(icon: "arrow.up.arrow.down", text: "Navigate")
            footerHint(icon: "escape", text: "Dismiss")
            Spacer()
            // Tiny "⚡" when the FTS5 path served the current results.
            // Reassures the user the fast path is live — and helps diagnose
            // the rare case where the index falls behind (no bolt = INSTR).
            // The footer's `result count` is the natural place for this:
            // adjacent to a number that's just been refreshed.
            // Only show the count when the user has actually run a search.
            // On the empty state (no query yet) "0 results" was misleading —
            // they hadn't searched anything to begin with.
            if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if viewModel.usingIndex {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Search served from the local FTS5 index — sub-millisecond.")
                        .accessibilityLabel("Fast index in use")
                }
                Text("\(viewModel.results.count) results")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            helpToggleButton
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.thinMaterial)
    }

    /// `?` button in the footer — opens the help sheet. Sits to the right
    /// of the result count so it's discoverable without competing with the
    /// keyboard-hint glyphs on the left.
    private var helpToggleButton: some View {
        Button {
            withAnimation(.bmDefault) { showHelp.toggle() }
        } label: {
            // `.tertiary` is a HierarchicalShapeStyle while Color.accentColor
            // is a Color — use a Color-typed adapter for the off state so
            // the ternary type-checks.
            Image(systemName: showHelp ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.caption)
                .foregroundStyle(showHelp ? Color.accentColor : Color.secondary.opacity(0.6))
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .help("Search syntax (⌘/)")
    }

    private func footerHint(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
    }
}

/// Result list, isolated so it skips re-evaluation when the user is
/// JUST typing (which mutates `viewModel.query` but not
/// `viewModel.results`). Conforms to `Equatable` with a custom `==`
/// that compares the ordered set of `message.id`s + the selected ID;
/// the `onReveal` closure is deliberately ignored — it's recaptured
/// every parent render but the produced view tree is identical.
///
/// Wrapped in `.equatable()` at the parent call site so SwiftUI runs
/// the cheap `==` before re-running `body`. With this in place, a
/// keystroke that doesn't change the result set produces zero
/// re-layout work on the 50-row list.
///
/// Per the 2026-05-28 typing-lag investigation: the panel's body
/// re-renders on every `viewModel.query` change because it reads
/// the query (through `filters`/`suggestions`/etc). Without this
/// extraction, that re-render fanned out to all rows — each
/// re-evaluating AvatarView, formatted timestamps, reaction
/// clusters, and attributedBody-derived text. NL mode doesn't show
/// this lag because it binds the field to `nl.query`, leaving
/// `viewModel.query` untouched.
private struct SpotlightResultsList: View, Equatable {
    let results: [MessageSearch.Result]
    let selectedResultID: Int64?
    // Closures are captured fresh by the parent every render; we
    // intentionally drop them from `==` so the Equatable diff stays
    // O(result-IDs) and lets SwiftUI skip the body when nothing
    // visible changed.
    let onSelect: (Int64) -> Void
    let onReveal: (MessageSearch.Result) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.xs) {
                    ForEach(results, id: \.message.id) { result in
                        SpotlightResultRow(
                            result: result,
                            isSelected: selectedResultID == result.message.id,
                            onTap: { onSelect(result.message.id) }
                        )
                        // Double-click → open the chat in Messages.app and dismiss.
                        // `simultaneousGesture` so the row's single-click selection
                        // still fires for the first of the two clicks.
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded { onReveal(result) }
                        )
                        .id(result.message.id)
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
            }
            .onChange(of: selectedResultID) { _, newID in
                guard let newID else { return }
                withAnimation(.bmDefault) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Selection change → re-render (so the highlight moves).
        guard lhs.selectedResultID == rhs.selectedResultID else { return false }
        // Result-set change → re-render. Compare the ID sequence
        // rather than the full `MessageSearch.Result` (which carries
        // decoded text, avatars, reactions — Equatable but expensive
        // to walk per keystroke). Same IDs in the same order = same
        // visible rows.
        if lhs.results.count != rhs.results.count { return false }
        for (a, b) in zip(lhs.results, rhs.results) {
            if a.message.id != b.message.id { return false }
        }
        return true
    }
}

/// Compact result row tailored for the spotlight panel. Distinct from the
/// browse window's `ResultRow` because the panel has tighter density.
private struct SpotlightResultRow: View {
    let result: MessageSearch.Result
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Space.md) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(result.senderName)
                            .font(.subheadline.weight(.semibold))
                        if !result.partnerName.isEmpty, result.partnerName != result.senderName {
                            // Render "· <chatName>" with a small leading
                            // SF Symbol — `person.3` for groups, omitted
                            // for 1:1. Replaces the old "[group] " ASCII
                            // prefix that lived inside the string itself.
                            HStack(spacing: 3) {
                                Text("·")
                                if result.message.chatStyle == 43 {
                                    Image(systemName: "person.3.fill")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Group chat")
                                }
                                Text(result.partnerName)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Reaction cluster sits on the trailing edge, BEFORE the
                        // timestamp — keeps timestamp at the far edge as the
                        // anchor element, with reactions clustering toward it.
                        if !result.reactions.isEmpty {
                            ReactionCluster(reactions: result.reactions)
                        }
                        Text(timestamp)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    // Body line: real text if we have any, otherwise a typed
                    // placeholder so attachment-only messages aren't blank.
                    // (`messageType` is .text for plain-text rows — only the
                    // empty-body non-text case shows the placeholder, so rows
                    // with both body AND attachment still display the text.)
                    if result.message.body.isEmpty && result.messageType != .text {
                        Label(result.messageType.displayLabel,
                              systemImage: result.messageType.sfSymbol)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(result.message.body)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        AvatarView(
            imageData: result.senderAvatar,
            initials: initials,
            size: 28,
            tint: .secondary.opacity(0.4)
        )
    }

    private var initials: String {
        let parts = result.senderName.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined()
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: result.message.date)
    }
}
