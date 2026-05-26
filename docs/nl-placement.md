# NL search placement — decision

**Decision: Option B — Natural-language search lives INSIDE the Spotlight panel,
embedded in the same search field as keyword search, with an auto-detection
heuristic + an explicit ⇥ Tab toggle + a sparkles pill affordance.**

**Date**: 2026-05-24
**Decider**: panel design-agent
**Status**: SHIPPED in this pass.

---

## What we shipped

One search field. One global hotkey (`⌃⌥Space`). Two modes inside it.

| Mode | Trigger | Visual |
|---|---|---|
| **Keyword** (default) | Anything with `:` operators OR ≤ 4 words OR no leading question word | Blue accent, `magnifyingglass` glyph, results list, filter chips |
| **Ask** (NL) | Query has NO `:` operator AND (ends in `?` OR starts with `who/what/when/where/why/how/did/find/show/tell/explain`) | Purple accent, `sparkles` glyph, hero result + agent trace + candidates |

The user can also:
- **⇥ Tab** when the field is empty (or focused, query empty) to toggle modes
- **Click the sparkles pill** to the LEFT of the field to toggle
- **⌃⌘? (or ⌘?)** to flip into ask mode and open with the cursor armed

ESC reverts: first ESC drops back to keyword mode from ask mode; second ESC dismisses
the panel. Same `recents` queue serves both modes — re-running an "ask" recent
re-detects as NL on submit.

## Why not option A (NL on dashboard only) or option C (separate hotkey)

**A (status quo dashboard-only)** is what we had. The friction was real:
- Two summon paths (hotkey for keyword, click into Dashboard for NL) is two
  mental models for "search my messages." The dashboard is a place you
  *browse*; the panel is a place you *summon*. Most NL queries are spur-of-
  the-moment ("did I ever apologize to Morgan?") and live in the panel's
  ergonomics, not the dashboard's.
- Discoverability of NL was poor. The dashboard's NL bar is below the fold
  for users who land on a tile-heavy first viewport.

**C (separate ⌃⌥A or similar hotkey)** would split muscle memory three ways
(keyword hotkey + ask hotkey + dashboard) and force the user to pre-classify
their query before the first keystroke. That's backwards — they should be
able to type "find my argument with Avery" and have it Just Work without
remembering which app-mode they're in.

**B** is the user's explicit instinct ("incorporate the natural language
query search into the search bar") and it preserves the single-summon
contract of the panel. Auto-detection plus an explicit affordance means
beginners get the right mode for free; power users can override.

## Auto-detection rules (in `SpotlightPanel`)

```swift
private static func looksLikeNL(_ q: String) -> Bool {
    let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    // Hard rules — operator syntax is ALWAYS keyword. The user is being
    // explicit; respect it.
    if trimmed.contains(":") { return false }

    // Soft rules — anything matching either gets routed to NL.
    if trimmed.hasSuffix("?") { return true }

    let leading = trimmed.split(separator: " ").first?.lowercased() ?? ""
    let questionWords: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which",
        "did", "do", "does", "is", "are", "was", "were",
        "find", "show", "tell", "explain", "summarize",
    ]
    return questionWords.contains(leading)
}
```

We do NOT auto-switch the user back from NL → keyword mid-typing. That would
be jarring. Once they explicitly toggle into NL (or auto-detection fires on
submit), the mode is sticky until they ESC out or clear.

## Dashboard implications (for dashboard-agent)

You can read this section straight: the panel now owns NL search end-to-end.

**Recommendation**: collapse `NLSearchBar` on the dashboard into a vestigial
**entry-point CTA** ("Ask anything... ⌃⌥Space") that, when clicked, opens
the floating panel pre-armed in NL mode. Don't ship a redundant second NL
surface — that re-introduces the two-mental-models problem this decision
exists to solve.

Alternative if you'd rather rip than refactor: delete `NLSearchBar` from
the dashboard entirely. The panel covers the use case. The dashboard hero
CTA already says "Press ⌃⌥Space to search" — adjust the caption to
"Press ⌃⌥Space to search or ask anything" and you're done.

**Files panel-agent (me) modified**:
- `Sources/Panel/SpotlightPanel.swift` — mode state, auto-detect, embedded NL view
- `Sources/UI/Components/EmptyStateSuggestions.swift` — compact 5-chip layout (one per category)
- `Sources/UI/Components/HelpSheet.swift` — tightened to one viewport; added ⌘? shortcut
- `Sources/UI/Components/SearchField.swift` — added sparkles mode-toggle pill + ? button
- `Sources/UI/Components/RecentSearchesList.swift` — minor: cap visible at 5 already, untouched
- `Sources/Panel/AppDelegate.swift` — exposed `nlSearchViewModel` to panel via `PanelController`
- `Sources/Panel/PanelController.swift` — injects `nlSearchViewModel` into the panel
- `Tests/EmptyStateSuggestionsTests.swift` — updated for new compact layout
- `Tests/SpotlightPanelNLDetectionTests.swift` — pin the auto-detect heuristic

**Files panel-agent did NOT modify** (dashboard-agent territory):
- `Sources/Dashboard/Components/NLSearchBar.swift` — kept intact; dashboard-agent decides
- `Sources/Dashboard/DashboardView.swift` — kept intact; dashboard-agent decides
- `Sources/Dashboard/Components/SearchHeroCTA.swift` — kept intact
- `Sources/UI/Components/KeyboardShortcutBadge.swift` — kept intact

## Coordination contract

- Panel-agent owns NL discovery + invocation from the spotlight panel.
- Dashboard-agent owns whether to keep/demote/remove the dashboard's NL bar.
- Both share `NLSearchViewModel` (instantiated once on `AppDelegate`).
- Recents are shared between modes — `RecentSearchesStore` doesn't care
  about the mode the query was originally run in.

## What this is NOT

- Not a fork of the agent loop. `NLAgent.answer()` is the same call from
  either surface.
- Not a deprecation of the dashboard. The dashboard is still a browse
  surface; "ask anything" is just no longer one of its primary affordances.
- Not a UX regression for keyword users. The default mode is keyword. Auto-
  detection kicks in only for queries that look unmistakably NL.
