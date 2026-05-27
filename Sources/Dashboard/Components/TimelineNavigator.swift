//
//  TimelineNavigator.swift
//  Hourglass — Dashboard components
//
//  Compact horizontal strip that sits BELOW the main FrequencyChart and
//  acts as a context navigator (a.k.a. minimap, range-pill, scrubber).
//
//  Apple-canon reference points:
//    - Stocks → the range-pill strip below the price chart
//    - Apple Health → activity scrubber below the day's chart
//    - Bloomberg Terminal → range strip
//    - d3.js brush component (the canonical example)
//
//  Visual model:
//      ┌──────────────────────────────────────────────────────────────┐
//      │           ░░░░░░░░░░░░░░░░░░░░░░░░░░░ ← dim outside window   │
//      │            ████████████ ← window pill (resizable)            │
//      │              ┌──        ──┐ ← two grippy handles             │
//      │           ─── area sparkline (full-history) ─────            │
//      │  Aug 19, 2022                                  May 24, 2026  │
//      └──────────────────────────────────────────────────────────────┘
//
//  Interactions:
//    - LEFT handle drag → moves the start edge → window grows/shrinks
//    - RIGHT handle drag → moves the end edge
//    - PILL BODY drag → translates window without resizing
//    - Crossing past the other edge swaps which handle is "left"/"right"
//    - Minimum window = 7 days
//    - Keyboard: ←/→ = right edge ±1 day; Shift+←/→ = left edge; ⌥ holds week step
//    - VoiceOver: announces current range; per-handle accessibility actions
//
//  Data:
//    - The sparkline is the FULL `allTimeAggregate.dailyOverview` (sent +
//      received per day). Tiny resolution (~1500 days at most) → cheap.
//    - The window pill is `brushedRange`. Dragging mutates the same
//      @Binding `FrequencyChart` used to drive; the zero-latency
//      `recomputeFromAggregateIfPossible()` path picks up every tick.
//
//  Per-tick perf: identical to the previous brush-on-chart, since both
//  ultimately call `recomputeFromAggregateIfPossible` on the view model.
//  Measured ~2 ms / tick on the user's 525k-msg DB; no SQL.
//

import AppKit
import SwiftUI

/// Drag-target classification — what the user grabbed.
/// Lives at file scope (not nested) so `TimelineNavigatorMath` and the
/// view can refer to it without a generic forward-declaration dance.
public enum NavigatorDragTarget: Hashable, Sendable {
    case leftHandle
    case rightHandle
    case pillBody
}

struct TimelineNavigator: View {

    // MARK: - Inputs

    /// Full all-time daily totals (sent + received). The sparkline plots
    /// `Int(c.sent) + Int(c.received)` per `dayIndex`. We deliberately
    /// don't take the aggregate itself — only the bits we need — so this
    /// view stays pure and easy to preview.
    let daily: [DailyCount]

    /// Calendar used to convert day-index ↔ Date. Comes from the
    /// aggregate so the navigator's math agrees with the chart axis.
    let calendar: Calendar

    /// The currently-selected window. nil = no brush; the navigator
    /// renders an "everything is selected" pill spanning the whole strip.
    @Binding var brushedRange: ClosedRange<Date>?

    /// Whether the navigator is interactive. Same gate the chart used —
    /// when the all-time aggregate isn't loaded yet, drags are no-ops.
    let enabled: Bool

    // MARK: - Layout constants (callable from tests + previews)

    /// Total strip height (sparkline area). 64pt is the sweet spot: tall
    /// enough that the sparkline is readable, short enough that the main
    /// chart above stays the visual hero.
    static let stripHeight: CGFloat = 64

    /// Vertical padding above/below the date label row.
    static let labelRowSpacing: CGFloat = 4

    /// Handle: 4pt visible width, 24pt tall (centered vertically).
    static let handleVisibleWidth: CGFloat = 4
    static let handleVisibleHeight: CGFloat = 24

    /// Handle hit area — 16pt wide so the cursor can grab the edge
    /// comfortably without precisely landing on the 4pt visual.
    static let handleHitWidth: CGFloat = 16

    /// Pill body's vertical inset from the strip edges — leaves room for
    /// the sparkline's gradient to peek above/below the pill.
    static let pillInset: CGFloat = 2

    /// Minimum window in days. Two handles within this range are clamped
    /// so the brushed window never collapses to ~0.
    static let minWindowDays: Int = 7

    // MARK: - Local state

    /// Live drag context — what the user is dragging + how much to offset.
    /// Captured on `onChanged.first` so subsequent ticks compute the new
    /// range from the START state, not last-frame state (avoids drift).
    @State private var dragContext: DragContext?

    /// Tracks focus so ESC / arrow keys are scoped to this view when the
    /// user has clicked into the strip.
    @FocusState private var isFocused: Bool

    /// Tracks hover state for the pill body so we can flip the cursor
    /// to `.openHand` (mirrors AppKit drag affordance).
    @State private var isHoveringPill: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Self.labelRowSpacing) {
            // The strip itself.
            strip
                .frame(height: Self.stripHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 0.5)
                )

            // Date-label row — left = earliest, right = latest.
            dateLabelRow
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Drag handles to change the visible date range. Press escape to clear.")
        .accessibilityRepresentation { accessibilityProxy }
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if brushedRange != nil {
                withAnimation(.bmDefault) { brushedRange = nil }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            handleArrowKey(direction: -1, shift: NSEvent.modifierFlags.contains(.shift))
        }
        .onKeyPress(.rightArrow) {
            handleArrowKey(direction: 1, shift: NSEvent.modifierFlags.contains(.shift))
        }
    }

    // MARK: - Strip body

    /// The sparkline + window pill + handles, in one GeometryReader so
    /// every pixel-to-date conversion shares the same width.
    private var strip: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let math = TimelineNavigatorMath(
                fullRange: fullDateRange,
                width: width,
                calendar: calendar
            )

            ZStack(alignment: .topLeading) {
                // Solid background so the sparkline reads against it.
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(Color.contentBackground.opacity(0.6))

                // Sparkline (full-history area).
                sparkline(width: width, height: height)
                    .allowsHitTesting(false)

                // Outside-the-pill dim overlay — darkens the strip
                // OUTSIDE the active window so the eye snaps inside.
                if let pillRect = pillRectIfBrushed(math: math, height: height) {
                    Path { p in
                        // Left dim region
                        p.addRect(CGRect(x: 0, y: 0, width: pillRect.minX, height: height))
                        // Right dim region
                        p.addRect(CGRect(
                            x: pillRect.maxX,
                            y: 0,
                            width: max(0, width - pillRect.maxX),
                            height: height
                        ))
                    }
                    .fill(Color.primary.opacity(0.06))
                    .allowsHitTesting(false)

                    // Window pill (fill + stroke).
                    windowPill(rect: pillRect)
                        .gesture(
                            enabled ? pillDragGesture(math: math) : nil
                        )

                    // Two handles on the edges. Drawn AFTER the pill so
                    // they're on top — and they own their own gestures
                    // so the pill gesture doesn't swallow them.
                    handleView(at: pillRect.minX, height: height, edge: .leftHandle)
                        .gesture(
                            enabled ? handleDragGesture(.leftHandle, math: math) : nil
                        )
                    handleView(at: pillRect.maxX, height: height, edge: .rightHandle)
                        .gesture(
                            enabled ? handleDragGesture(.rightHandle, math: math) : nil
                        )
                }
            }
        }
    }

    /// The area-sparkline plotting `dailyOverview` totals across the
    /// strip's full width. Uses a manual Path (not Swift Charts) — at
    /// this resolution it's cheaper, has no axis chrome to suppress, and
    /// the styling matches the "muted background" intent precisely.
    @ViewBuilder
    private func sparkline(width: CGFloat, height: CGFloat) -> some View {
        if daily.isEmpty || width <= 0 {
            EmptyView()
        } else {
            let paths = sparklinePaths(width: width, height: height)
            ZStack {
                // Subtle area fill (gradient to fade into the strip).
                paths.area
                    .fill(LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.22),
                            Color.accentColor.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                // Crisp 1pt stroke on top.
                paths.line
                    .stroke(
                        Color.accentColor.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.0, lineJoin: .round)
                    )
            }
        }
    }

    /// Compute the sparkline's polyline (top edge) + the closed area
    /// path (top edge + baseline) in one pass so both can be rendered
    /// independently from a shared sample set.
    private func sparklinePaths(width: CGFloat, height: CGFloat) -> (line: Path, area: Path) {
        // Find the data's vertical extent (peak total) for normalization.
        // Use the daily totals (sent + received) — same semantic as the
        // main chart's combined activity.
        var peak: Int = 1
        for c in daily {
            let t = Int(c.sent) + Int(c.received)
            if t > peak { peak = t }
        }
        // 5% top padding so the peak doesn't graze the top edge.
        let usableHeight = height * 0.92

        // Buckets — at this resolution (~1500 daily cells, ~720 strip
        // pixels) downsampling by averaging into pixel-wide buckets
        // gives a cleaner line than plotting every day. We aim for
        // roughly one sample per 2 pixels.
        let targetBuckets = max(2, Int(width / 2))
        let samples = downsampledSamples(targetBuckets: targetBuckets)

        var linePath = Path()
        var areaPath = Path()
        if samples.isEmpty {
            return (linePath, areaPath)
        }

        let baseline = height - 1 // 1pt above the bottom edge so stroke is crisp
        for (i, sample) in samples.enumerated() {
            let value = Double(sample.total)
            let normalizedY = peak > 0 ? (value / Double(peak)) : 0
            let x = sample.normalizedX * width
            let y = baseline - CGFloat(normalizedY) * usableHeight
            if i == 0 {
                linePath.move(to: CGPoint(x: x, y: y))
                areaPath.move(to: CGPoint(x: x, y: baseline))
                areaPath.addLine(to: CGPoint(x: x, y: y))
            } else {
                linePath.addLine(to: CGPoint(x: x, y: y))
                areaPath.addLine(to: CGPoint(x: x, y: y))
            }
        }
        // Close the area path down to baseline back at the start.
        if let lastSample = samples.last {
            areaPath.addLine(to: CGPoint(x: lastSample.normalizedX * width, y: baseline))
            areaPath.closeSubpath()
        }
        return (linePath, areaPath)
    }

    /// Downsample `daily` into `targetBuckets` evenly spaced samples
    /// across the date span. Each output sample carries a normalized
    /// x (0..1) and the average total in its bucket. Cheap O(n+m).
    private func downsampledSamples(targetBuckets: Int) -> [SparklineSample] {
        guard !daily.isEmpty else { return [] }
        guard daily.count > targetBuckets else {
            // Few enough points to plot directly.
            let first = daily.first!.dayIndex
            let last = daily.last!.dayIndex
            let span = max(1, Int(last - first))
            return daily.map { c in
                SparklineSample(
                    normalizedX: Double(Int(c.dayIndex) - Int(first)) / Double(span),
                    total: Int(c.sent) + Int(c.received)
                )
            }
        }

        let first = daily.first!.dayIndex
        let last = daily.last!.dayIndex
        let span = max(1, Int(last - first))
        var buckets: [(sum: Int, count: Int)] = Array(repeating: (0, 0), count: targetBuckets)
        for c in daily {
            let offset = Int(c.dayIndex) - Int(first)
            let bucketIdx = min(targetBuckets - 1, max(0, (offset * targetBuckets) / span))
            buckets[bucketIdx].sum += Int(c.sent) + Int(c.received)
            buckets[bucketIdx].count += 1
        }
        return buckets.enumerated().map { idx, b in
            let avg = b.count > 0 ? b.sum / max(1, b.count) : 0
            return SparklineSample(
                normalizedX: Double(idx) / Double(max(1, targetBuckets - 1)),
                total: avg
            )
        }
    }

    private struct SparklineSample {
        let normalizedX: Double
        let total: Int
    }

    // MARK: - Pill & handles

    /// Translucent window pill — the rectangle highlighting the active
    /// brush range. Filled with accent at low opacity, with a stroke at
    /// medium opacity so it reads cleanly against the sparkline.
    @ViewBuilder
    private func windowPill(rect: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringPill = hovering
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Drag to slide the window")
    }

    /// One grippy handle. 4pt visible stem, 16pt hit area, vertically
    /// centered. Cursor flips to `.resizeLeftRight` on hover.
    @ViewBuilder
    private func handleView(at x: CGFloat, height: CGFloat, edge: NavigatorDragTarget) -> some View {
        let centerY = height / 2
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(
                    width: Self.handleVisibleWidth,
                    height: Self.handleVisibleHeight
                )
        }
        .frame(width: Self.handleHitWidth, height: height)
        .contentShape(Rectangle())
        .position(x: x, y: centerY)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Drag to resize the window")
    }

    private func pillRectIfBrushed(math: TimelineNavigatorMath, height: CGFloat) -> CGRect? {
        let range = effectiveRange
        let loX = math.x(for: range.lowerBound)
        let hiX = math.x(for: range.upperBound)
        let lo = min(loX, hiX)
        let hi = max(loX, hiX)
        return CGRect(
            x: lo,
            y: Self.pillInset,
            width: max(2, hi - lo),
            height: max(0, height - Self.pillInset * 2)
        )
    }

    /// What to paint as the "window" — when there's no brush, we paint
    /// the FULL strip as the active region so the UI never looks empty.
    /// (Acts as "you're seeing everything"; the segmented selector at
    /// the top still drives the main chart's actual domain via its
    /// resolved date range.)
    private var effectiveRange: ClosedRange<Date> {
        if let brushedRange { return brushedRange }
        return fullDateRange
    }

    private var fullDateRange: ClosedRange<Date> {
        guard let first = daily.first, let last = daily.last else {
            let now = Date()
            return now.addingTimeInterval(-86_400)...now
        }
        // Use the calendar's dayIndex → Date conversion (start of local
        // day) so the strip's edges line up with the main chart's
        // x-axis exactly.
        let lo = dayIndexDate(first.dayIndex)
        let hi = dayIndexDate(last.dayIndex)
        if lo >= hi { return lo...hi.addingTimeInterval(86_400) }
        return lo...hi
    }

    private func dayIndexDate(_ idx: Int32) -> Date {
        let secondsPerDay: TimeInterval = 86_400
        let utcStart = Date(
            timeIntervalSinceReferenceDate: TimeInterval(idx) * secondsPerDay
        )
        return calendar.startOfDay(for: utcStart)
    }

    // MARK: - Gestures

    private func pillDragGesture(math: TimelineNavigatorMath) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if dragContext == nil {
                    // First tick of this drag: snapshot the starting
                    // range so subsequent ticks compute the new range
                    // by translation from the snapshot (no drift).
                    dragContext = DragContext(
                        target: .pillBody,
                        startRange: effectiveRange,
                        startPointerX: value.startLocation.x
                    )
                    if brushedRange == nil {
                        // Promote "no brush" to "brush = full range" so
                        // the pill becomes a draggable object.
                        brushedRange = fullDateRange
                    }
                    NSCursor.closedHand.push()
                }
                guard let ctx = dragContext else { return }
                let newRange = math.translatedRange(
                    ctx.startRange,
                    by: value.translation.width,
                    clampedTo: fullDateRange
                )
                writeBrushedRange(newRange)
            }
            .onEnded { _ in
                NSCursor.pop()
                dragContext = nil
            }
    }

    private func handleDragGesture(
        _ target: NavigatorDragTarget,
        math: TimelineNavigatorMath
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragContext == nil {
                    dragContext = DragContext(
                        target: target,
                        startRange: effectiveRange,
                        startPointerX: value.startLocation.x
                    )
                    if brushedRange == nil {
                        brushedRange = fullDateRange
                    }
                }
                guard let ctx = dragContext else { return }
                // For handle drags we compute the date from the CURRENT
                // pointer x, not the START + translation, because the
                // pointer can move on either side of the original handle
                // location — which is exactly the swap case.
                let currentX = ctx.startPointerX + value.translation.width
                let rawDate = math.date(forX: currentX)
                let result = math.applyHandleDrag(
                    target: ctx.target,
                    startRange: ctx.startRange,
                    toDate: rawDate,
                    fullRange: fullDateRange,
                    minWindowDays: Self.minWindowDays
                )
                writeBrushedRange(result.newRange)
                // If the drag crossed past the opposite edge, the
                // dragged edge has effectively swapped — keep tracking
                // the same FINGER motion but with a new identity, AND
                // rebase startRange to the post-swap range. Without
                // the rebase, the next tick's `applyHandleDrag` would
                // still use the original pre-swap range as its
                // baseline, producing wrong results once the user
                // continues dragging past the swap point (e.g. a left
                // handle dragged from day 50 past day 100 and on to
                // day 150 would erroneously expand to [50, 150]
                // instead of staying on the swapped track at
                // [100, 150]).
                if result.swapped {
                    dragContext?.target = result.activeTarget
                    dragContext?.startRange = result.newRange
                }
            }
            .onEnded { _ in
                dragContext = nil
            }
    }

    /// Wrap brush writes in a non-animating transaction so each drag
    /// tick is instantaneous. View-level `.contentTransition` on the
    /// stat tiles still produces the digit-rolldown on the final value.
    private func writeBrushedRange(_ range: ClosedRange<Date>) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            brushedRange = range
        }
    }

    // MARK: - Date labels

    private var dateLabelRow: some View {
        HStack {
            Text(fullRangeLabel(fullDateRange.lowerBound))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if let brushedRange {
                Text(brushSummary(brushedRange))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
            Text(fullRangeLabel(fullDateRange.upperBound))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
    }

    private func fullRangeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    private func brushSummary(_ range: ClosedRange<Date>) -> String {
        // Always show the year on BOTH bounds. The previous "year only when
        // it changes" rule turned `Dec 28, 2025 → May 26, 2026` into
        // `Dec 28 → May 26, 2026`, which leaves the lower bound ambiguous
        // (Dec 28 of what year?). Especially confusing on multi-year ranges
        // and ranges that LOOK same-year but actually crossed a boundary
        // years ago (e.g. a brush ending Jan 2 starting Dec 30 previous
        // year would still drop the year). Matches `fullRangeLabel` and
        // the dashboard's `spanLabel` (which uses `dateStyle = .medium`).
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        let cal = calendar
        let lo = f.string(from: range.lowerBound)
        let hi = f.string(from: range.upperBound)
        let days = max(
            1,
            cal.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0
        )
        return "\(lo) → \(hi) · \(days) day\(days == 1 ? "" : "s")"
    }

    // MARK: - Keyboard

    /// Arrow-key handler. Direction is -1 (left) / +1 (right). Shift
    /// moves the LEFT edge; bare arrow moves the RIGHT edge. Option
    /// multiplies the step to a week.
    private func handleArrowKey(direction: Int, shift: Bool) -> KeyPress.Result {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let step = optionHeld ? 7 : 1
        let range = brushedRange ?? fullDateRange
        guard let newRange = TimelineNavigatorMath.shiftedRange(
            range,
            edge: shift ? .leftHandle : .rightHandle,
            byDays: direction * step,
            calendar: calendar,
            fullRange: fullDateRange,
            minWindowDays: Self.minWindowDays
        ) else {
            return .ignored
        }
        writeBrushedRange(newRange)
        return .handled
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        guard let brushedRange else {
            return "Time range navigator. No custom range selected."
        }
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        let lo = f.string(from: brushedRange.lowerBound)
        let hi = f.string(from: brushedRange.upperBound)
        return "Time range navigator. Current selection: \(lo) to \(hi)."
    }

    private var accessibilityProxy: some View {
        // A hidden slider stand-in so VoiceOver users can adjust the
        // range with the rotor. The real interaction model is mouse
        // drag; keyboard handlers above cover ←/→.
        Rectangle()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - Types

    private struct DragContext {
        var target: NavigatorDragTarget
        /// Mutable so we can rebase after a handle swap — see
        /// `handleDragGesture`'s post-swap update.
        var startRange: ClosedRange<Date>
        let startPointerX: CGFloat
    }
}

// MARK: - Math (pure, testable)

/// Pure-function math driving the navigator. Extracted into its own
/// type so tests can exercise it without spinning up SwiftUI views or
/// pretending to be a GeometryReader.
///
/// Pixel-to-date math:
///   - `x(for: date)` clamps to [0, width] and maps linearly across
///     the full date range.
///   - `date(forX: x)` inverts the mapping. Out-of-range x clamps to
///     the full range's bounds.
///
/// Handle drag:
///   - `applyHandleDrag(target:startRange:toDate:fullRange:minWindowDays:)`
///     returns the new range AND whether the dragged handle has
///     swapped identity (crossed past the opposite edge).
///
/// Pill body drag:
///   - `translatedRange(_:by:clampedTo:)` shifts the brush by a pixel
///     delta and clamps so neither edge escapes the full range. If the
///     translation would push the window off either side, it's pinned
///     instead — the window keeps its width and slides along the wall.
public struct TimelineNavigatorMath: Sendable {
    public let fullRange: ClosedRange<Date>
    public let width: CGFloat
    public let calendar: Calendar

    /// Result of a handle drag — encapsulates the new range and the
    /// (possibly swapped) handle the user is now driving.
    public struct HandleDragResult: Sendable {
        public let newRange: ClosedRange<Date>
        public let activeTarget: NavigatorDragTarget
        public let swapped: Bool
    }

    public init(
        fullRange: ClosedRange<Date>,
        width: CGFloat,
        calendar: Calendar
    ) {
        self.fullRange = fullRange
        self.width = width
        self.calendar = calendar
    }

    /// Total span of the strip's date axis, in seconds. Guaranteed > 0.
    public var spanSeconds: TimeInterval {
        max(1, fullRange.upperBound.timeIntervalSince(fullRange.lowerBound))
    }

    public func x(for date: Date) -> CGFloat {
        guard width > 0 else { return 0 }
        let clamped = clampDate(date)
        let fraction = clamped.timeIntervalSince(fullRange.lowerBound) / spanSeconds
        return CGFloat(max(0.0, min(1.0, fraction))) * width
    }

    public func date(forX x: CGFloat) -> Date {
        guard width > 0 else { return fullRange.lowerBound }
        let clamped = max(0.0, min(Double(width), Double(x)))
        let fraction = clamped / Double(width)
        return fullRange.lowerBound.addingTimeInterval(fraction * spanSeconds)
    }

    public func clampDate(_ date: Date) -> Date {
        if date < fullRange.lowerBound { return fullRange.lowerBound }
        if date > fullRange.upperBound { return fullRange.upperBound }
        return date
    }

    /// Translate `startRange` by `pixelDelta` along the x axis. If the
    /// translation would push either edge past the full range, pin the
    /// affected edge to the wall and keep the OTHER edge moving (so the
    /// window's width is preserved as long as possible; the window only
    /// shrinks if its width exceeds the full range, which can't happen
    /// in practice).
    public func translatedRange(
        _ startRange: ClosedRange<Date>,
        by pixelDelta: CGFloat,
        clampedTo full: ClosedRange<Date>
    ) -> ClosedRange<Date> {
        guard width > 0 else { return startRange }
        let secondsPerPixel = spanSeconds / Double(width)
        let secondsDelta = Double(pixelDelta) * secondsPerPixel
        let lo = startRange.lowerBound.addingTimeInterval(secondsDelta)
        let hi = startRange.upperBound.addingTimeInterval(secondsDelta)
        // Clamp: if the translation pushes lo below full.lower, snap lo
        // and translate hi by the same amount so the window keeps its
        // width. Mirror on the other side.
        if lo < full.lowerBound {
            let shift = full.lowerBound.timeIntervalSince(lo)
            return full.lowerBound...(hi.addingTimeInterval(shift))
        }
        if hi > full.upperBound {
            let shift = hi.timeIntervalSince(full.upperBound)
            return (lo.addingTimeInterval(-shift))...full.upperBound
        }
        return lo...hi
    }

    /// Apply a handle drag to `startRange`, producing a new range and
    /// flagging whether the dragged handle swapped identity (crossed
    /// past the opposite edge).
    ///
    /// `minWindowDays` enforces a floor on the brush width — when the
    /// user drags one handle within `< minWindow` of the other, the
    /// dragged edge snaps to maintain at least `minWindow` days.
    public func applyHandleDrag(
        target: NavigatorDragTarget,
        startRange: ClosedRange<Date>,
        toDate rawDate: Date,
        fullRange full: ClosedRange<Date>,
        minWindowDays: Int
    ) -> HandleDragResult {
        let minWindow = TimeInterval(minWindowDays) * 86_400
        var d = rawDate
        if d < full.lowerBound { d = full.lowerBound }
        if d > full.upperBound { d = full.upperBound }

        switch target {
        case .leftHandle:
            // Case A: d ≤ upper - minWindow → normal resize.
            // Case B: d > upper - minWindow but ≤ upper → snap to upper - minWindow.
            // Case C: d > upper → SWAP. The dragged "left" handle has
            //          crossed past the right edge; it becomes the new
            //          right handle; old right becomes new left.
            let upper = startRange.upperBound
            if d <= upper.addingTimeInterval(-minWindow) {
                return HandleDragResult(
                    newRange: d...upper,
                    activeTarget: .leftHandle,
                    swapped: false
                )
            } else if d <= upper {
                // Floor the window at minWindow. No swap.
                let snapped = upper.addingTimeInterval(-minWindow)
                return HandleDragResult(
                    newRange: max(full.lowerBound, snapped)...upper,
                    activeTarget: .leftHandle,
                    swapped: false
                )
            } else {
                // d > upper → swap. New range is [upper, d] (clamped
                // so the new window is at least minWindow days; old
                // upper now sits at the left, dragged date at the right).
                let newLower = upper
                var newUpper = d
                if newUpper.timeIntervalSince(newLower) < minWindow {
                    newUpper = newLower.addingTimeInterval(minWindow)
                    if newUpper > full.upperBound { newUpper = full.upperBound }
                }
                return HandleDragResult(
                    newRange: newLower...newUpper,
                    activeTarget: .rightHandle,
                    swapped: true
                )
            }

        case .rightHandle:
            let lower = startRange.lowerBound
            if d >= lower.addingTimeInterval(minWindow) {
                return HandleDragResult(
                    newRange: lower...d,
                    activeTarget: .rightHandle,
                    swapped: false
                )
            } else if d >= lower {
                let snapped = lower.addingTimeInterval(minWindow)
                return HandleDragResult(
                    newRange: lower...min(full.upperBound, snapped),
                    activeTarget: .rightHandle,
                    swapped: false
                )
            } else {
                // d < lower → swap. New range is [d, lower].
                var newLower = d
                let newUpper = lower
                if newUpper.timeIntervalSince(newLower) < minWindow {
                    newLower = newUpper.addingTimeInterval(-minWindow)
                    if newLower < full.lowerBound { newLower = full.lowerBound }
                }
                return HandleDragResult(
                    newRange: newLower...newUpper,
                    activeTarget: .leftHandle,
                    swapped: true
                )
            }

        case .pillBody:
            // Body drags go through `translatedRange`, not this fn —
            // but support it anyway so callers don't have to branch.
            return HandleDragResult(
                newRange: startRange,
                activeTarget: .pillBody,
                swapped: false
            )
        }
    }

    /// Shift one edge of `range` by `days` in the given direction.
    /// Returns nil if the shift would either escape the full range OR
    /// crush the window below `minWindowDays`.
    public static func shiftedRange(
        _ range: ClosedRange<Date>,
        edge: NavigatorDragTarget,
        byDays days: Int,
        calendar: Calendar,
        fullRange: ClosedRange<Date>,
        minWindowDays: Int
    ) -> ClosedRange<Date>? {
        guard days != 0 else { return nil }
        let secondsDelta = TimeInterval(days) * 86_400
        switch edge {
        case .leftHandle:
            var newLower = range.lowerBound.addingTimeInterval(secondsDelta)
            if newLower < fullRange.lowerBound { newLower = fullRange.lowerBound }
            // Enforce min window
            let minUpperGap = TimeInterval(minWindowDays) * 86_400
            if range.upperBound.timeIntervalSince(newLower) < minUpperGap {
                newLower = range.upperBound.addingTimeInterval(-minUpperGap)
                if newLower < fullRange.lowerBound { newLower = fullRange.lowerBound }
            }
            return newLower...range.upperBound
        case .rightHandle:
            var newUpper = range.upperBound.addingTimeInterval(secondsDelta)
            if newUpper > fullRange.upperBound { newUpper = fullRange.upperBound }
            if newUpper.timeIntervalSince(range.lowerBound) < TimeInterval(minWindowDays) * 86_400 {
                newUpper = range.lowerBound.addingTimeInterval(TimeInterval(minWindowDays) * 86_400)
                if newUpper > fullRange.upperBound { newUpper = fullRange.upperBound }
            }
            return range.lowerBound...newUpper
        case .pillBody:
            // Translate both edges; clamp via translatedRange-equivalent.
            var lo = range.lowerBound.addingTimeInterval(secondsDelta)
            var hi = range.upperBound.addingTimeInterval(secondsDelta)
            if lo < fullRange.lowerBound {
                let shift = fullRange.lowerBound.timeIntervalSince(lo)
                lo = fullRange.lowerBound
                hi = hi.addingTimeInterval(shift)
            }
            if hi > fullRange.upperBound {
                let shift = hi.timeIntervalSince(fullRange.upperBound)
                hi = fullRange.upperBound
                lo = lo.addingTimeInterval(-shift)
            }
            return lo...hi
        }
    }
}

// MARK: - Previews

#Preview("TimelineNavigator — with brush", traits: .fixedLayout(width: 720, height: 120)) {
    NavigatorPreviewHost(initialBrushed: true)
        .padding(Space.lg)
        .background(Color.chromeBackground)
}

#Preview("TimelineNavigator — no brush", traits: .fixedLayout(width: 720, height: 120)) {
    NavigatorPreviewHost(initialBrushed: false)
        .padding(Space.lg)
        .background(Color.chromeBackground)
}

private struct NavigatorPreviewHost: View {
    let initialBrushed: Bool

    @State private var brush: ClosedRange<Date>?

    init(initialBrushed: Bool) {
        self.initialBrushed = initialBrushed
    }

    var body: some View {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        // 1400 days of synthetic data — same order as the real DB.
        let daily: [DailyCount] = (0..<1400).map { offset in
            let dayIdx = DashboardAllTimeAggregate.dayIndex(
                for: cal.date(byAdding: .day, value: -1399 + offset, to: today) ?? today
            )
            let s = max(0, 30 + Int(sin(Double(offset) * 0.05) * 25 + Double.random(in: -8...8)))
            let r = max(0, 28 + Int(cos(Double(offset) * 0.04) * 22 + Double.random(in: -6...6)))
            return DailyCount(dayIndex: dayIdx, sent: Int32(s), received: Int32(r))
        }
        return TimelineNavigator(
            daily: daily,
            calendar: cal,
            brushedRange: $brush,
            enabled: true
        )
        .onAppear {
            if initialBrushed {
                let lo = cal.date(byAdding: .day, value: -90, to: today) ?? today
                let hi = cal.date(byAdding: .day, value: -10, to: today) ?? today
                brush = lo...hi
            }
        }
    }
}
