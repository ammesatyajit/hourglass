# Design Notes — Hourglass

Living reference for the visual language. Updated when decisions shift.

---

## Liquid Glass — what we actually use

Apple shipped real Liquid Glass APIs in macOS 26 (Tahoe) / SwiftUI 6, introduced at WWDC25. We target macOS 26.0 (deployment target in `project.yml`), so we use them directly with no fallbacks.

### The APIs

| API | What it does | Where we use it |
|---|---|---|
| `.glassEffect()` | Applies the liquid glass material to a view. Defaults: `.regular` variant, `.capsule` shape. | Search field, filter chips, sidebar items (selection state), floating controls |
| `.glassEffect(_:in:)` | Same, with explicit variant + shape. We pass `RoundedRectangle(cornerRadius:)` mostly. | Anywhere we need a non-capsule shape |
| `.glassEffect(.regular.tint(_:))` | Tinted glass. Use sparingly — Apple says tint **only primary actions**. | The clear/dismiss chip button, primary CTA only |
| `GlassEffectContainer { ... }` | Wraps multiple glass elements so they sample a single region. Required when glass elements sit near each other (glass can't sample glass). | Sidebar item stack, filter chip row |
| `.glassEffectID(_, in:)` | Pairs with a `@Namespace` for morphing transitions between glass shapes. | Filter chip add/remove animation |
| `.buttonStyle(.glass)` | Translucent button style for secondary actions. | Sidebar buttons, chip dismiss |
| `.buttonStyle(.glassProminent)` | Opaque, tinted button for primary actions. | (reserved — none yet) |

### Variants

- **`.regular`** — default, adaptive, works on any background. **This is what we use almost everywhere.**
- **`.clear`** — only for media-rich backgrounds (photos, video). We have none, so we don't use it.
- **Never mix variants in the same group.** Apple's guidance, and it looks awful when violated.

### Critical rules (from Apple HIG + WWDC25 #323)

1. **Glass belongs to the navigation layer**, never the content layer.
   - YES: search bar, sidebar, toolbar, filter chips, floating controls
   - NO: result rows themselves (these are content)
2. **No glass-on-glass.** Always wrap stacked glass elements in `GlassEffectContainer`.
3. **Tint only primary actions.** A field full of tinted chips is noise.
4. **The system handles accessibility.** Reduce Transparency, Increased Contrast, Reduce Motion all just work — don't override.
5. **Sidebars/toolbars get glass automatically on macOS 26** when you use `NavigationSplitView`. We lean on that and don't double-up.

### What this means for our UI

- The **search field** at the top of the detail pane is the hero glass element — large rounded rect, `.regular` variant, generous padding, no tint.
- **Filter chips** live inside the search field row and are individually glass-effected, wrapped in a `GlassEffectContainer` so they morph nicely when added/removed.
- **Result rows** are NOT glass. They're solid (or near-solid) `.background(.background)` cards with a hairline border. Glass on every row would be visually overwhelming and violates the "navigation layer only" rule.
- **Sidebar** uses native `.sidebar` list style — macOS 26 already paints it with glass behind the scenes. Selection state gets a subtle glass tint via `.glassEffect()` on the row.

---

## Design tokens

These are the *deliberate* choices. Other agents — please use these constants, don't invent new ones.

### Corner radius

| Token | Value | Where |
|---|---|---|
| `Radius.small` | 8 | Avatars, tiny pills, count badges |
| `Radius.medium` | 12 | Filter chips, sidebar items |
| `Radius.large` | 16 | **Default for GlassCard, result rows** |
| `Radius.xlarge` | 22 | Search field |
| `Radius.huge` | 28 | (reserved for hero modals, none yet) |

### Spacing scale (4pt grid)

| Token | Value |
|---|---|
| `Space.xs` | 4 |
| `Space.sm` | 8 |
| `Space.md` | 12 |
| `Space.lg` | 16 |
| `Space.xl` | 24 |
| `Space.xxl` | 32 |

Outer page padding is `Space.lg` (16). Component-internal padding is usually `Space.md` (12) horizontal, `Space.sm` (8) vertical.

### Typography

We use system fonts only — SF Pro Display + SF Pro Text via SwiftUI's semantic font styles:

| Use | Style |
|---|---|
| Search field input | `.title3` |
| Result row sender | `.headline` |
| Result row body | `.body` |
| Result row metadata (timestamp, chat) | `.caption.monospacedDigit()` for time |
| Sidebar label | `.body` |
| Sidebar section header | `.caption.weight(.semibold).textCase(.uppercase)` |
| Empty-state title | `.title2` |
| Filter chip label | `.subheadline.weight(.medium)` |

Always `.foregroundStyle(.primary / .secondary / .tertiary)` — never hex colors for text.

### Color palette

Mostly system colors. We commit to:

- **Accent**: system blue (`Color.accentColor`), inherited from the app's tint. **No custom brand color** — this is a utility app and we want it to feel like Mail or Messages.
- **Tints for chip categories**:
  - Person chip → `.blue`
  - Date-range chip → `.purple`
  - Chat-type chip → `.orange`
  - Free-text token → `.gray` (no tint)
  - These tints are *very subtle* — used as `.glassEffect(.regular.tint(.blue.opacity(0.3)))` not full saturation.
- **Backgrounds**: `Color(nsColor: .windowBackgroundColor)`, `.controlBackgroundColor`, `.textBackgroundColor` — let the window's translucency do the work.
- **Border**: `Color.primary.opacity(0.08)` for hairlines on content cards.

### Motion

- Default animation: `.smooth(duration: 0.22)` for most interactions
- Glass morph (chip add/remove): `.bouncy(duration: 0.32, extraBounce: 0.1)`
- Hover scale on result rows: `1.0 → 1.005` over `.snappy`
- We don't override the system's reduce-motion behavior — `.glassEffectTransition(.matchedGeometry)` handles it automatically.

---

## The vibe

Imagine Apple's Mail app + Spotlight + Things 3 had a baby that grew up in 2026.

- **Window**: hidden title bar, unified toolbar, translucent — content shows through faintly when there's a colorful desktop behind. The whole window IS glass.
- **Sidebar**: classic macOS sidebar, soft glass, sections for All / People / Group Chats / Time Range. Selection looks like a gently glowing glass pill.
- **Top of detail pane**: one large, beautiful Liquid Glass search field. As you type and add filters (person, date, chat), little glass chips slide in next to your cursor. They feel physical — they merge into the field's glass when adjacent, and morph out when dismissed.
- **Below the field**: a clean list of results. Each result is a quiet card with sender name, message body, timestamp on the right. No glass on the rows themselves — they're content. Hovering nudges them slightly and highlights them.
- **Empty state**: huge centered magnifying glass icon, a friendly prompt ("Search through years of conversations"), and 3 example queries the user can tap to populate.

Light mode and dark mode both look first-party Apple — light is bright with subtle frost, dark is graphite with luminous accents.

---

## Inline filter feedback (active query tokens)

When the user types a recognized token (`chat:amme`, `from:mom`, `last:7d`),
we want them to know "yes, that registered" without disrupting the flow of
typing. The choice was between:

- **(A) Inline highlight in the text field**: the token text gets a subtle
  tinted background where it sits in the search field.
- **(B) Chip row below the field**: each recognized token shows up as a
  removable `FilterChip` underneath the search bar.

**Decision: (B) — chip row below the search field**, with the literal token
text staying in the field. The token shows up twice (as text in the field, as
a chip below) on purpose:

- The literal text keeps the query *round-trippable*. Copying the query out
  and pasting it back gives an equivalent search — a property the iMessage
  client itself lacks.
- The chip layer gives a *glanceable* "what is this search actually doing"
  summary. Once a query has three or four tokens mixed with free text, the
  chips make the active filters legible at a glance.
- Removing a chip scrubs the matching token from the query — single source
  of truth is still the string, so the chip is a "view" on the parser result,
  never separate state.

Why not (A): SwiftUI's `TextField` doesn't reliably render `AttributedString`
for live-editable text, so painting a styled background under specific
character ranges as the user types is brittle. We can revisit when SwiftUI's
field gets first-class AttributedString editing.

Implementation lives in `SpotlightPanel.swift` — `activeFiltersRow`. The
chips are derived from `MessageSearch.parseQuery(viewModel.query).tokens` on
every render. The parser is microseconds-fast; no cache needed.

## What's intentionally NOT here

- **No custom brand color or logo.** This app is a utility. The user's content is the hero.
- **No skeuomorphic message bubbles.** Result rows are not chat bubbles — they're structured search results. Apple Spotlight, not iMessage.
- **No glass on result rows.** Tempting, but wrong per HIG. We commit to this.
- **No multiple glass variants.** Only `.regular`. Saves us from `.clear`/`.regular` mixing bugs.

---

## References

- [WWDC25 #323 — Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [GlassEffectContainer | Apple Developer Documentation](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- [Liquid Glass best practices — diskcleankit](https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo)
- [LiquidGlassReference (community)](https://github.com/conorluddy/LiquidGlassReference)
