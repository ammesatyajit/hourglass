//
//  FrequencyChart.swift
//  Hourglass — Dashboard components
//
//  Swift Charts line + area chart of sent vs received messages over time.
//  Built on the public `Charts` framework (macOS 13+, polished on macOS 26).
//
//  Visual:
//    - Two line series (sent in accent, received in secondary dashed)
//    - Hover tooltip overlays the date and exact counts
//    - The chart is DISPLAY ONLY. Direct manipulation of the visible
//      range now lives in the dedicated `TimelineNavigator` strip
//      directly below this view (see DashboardView.frequencyPanel).
//
//  Domain model:
//    - The chart paints whatever buckets the view-model decides to give
//      it (driven by `brushedRange`/`window`). To make the navigator's
//      "main chart zooms" promise crisp, we ALSO pin `chartXScale` to
//      the explicit `visibleRange` binding when present — guards against
//      Swift Charts auto-padding the domain.
//

import SwiftUI
import Charts

struct FrequencyChart: View {
    let buckets: [DashboardStats.TimeBucket]
    let bucketing: DashboardLoader.Bucketing

    /// The dashboard's currently-selected window — `brushedRange` when
    /// active, or the window's resolved date range when there's no brush.
    ///
    /// **Does NOT drive the X-axis domain.** The chart always pins X to
    /// the buckets' actual span (see `chartXDomain()` for the long
    /// rationale — short version: bucket boundaries don't line up with
    /// `visibleRange.lowerBound`, so pinning to it makes the leftmost
    /// data point drift around as the window changes). The "main chart
    /// zooms" UX still works because narrowing the brush filters the
    /// underlying SQL → fewer buckets → narrower domain.
    ///
    /// `visibleRange` IS used for: the VoiceOver accessibility label
    /// (which announces the active window) and as the animation key on
    /// the chart so the cross-fade fires when the window changes.
    let visibleRange: ClosedRange<Date>?

    /// Live hover position — drives the tooltip rule + selection ring.
    @State private var hoverDate: Date?

    var body: some View {
        if buckets.isEmpty {
            emptyState
        } else {
            chartBody
        }
    }

    // MARK: - Chart body

    @ViewBuilder
    private var chartBody: some View {
        Chart {
            ForEach(buckets) { b in
                LineMark(
                    x: .value("Date", b.date),
                    y: .value("Sent", b.sent),
                    series: .value("Series", "Sent")
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.0))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Date", b.date),
                    y: .value("Sent", b.sent),
                    series: .value("Series", "Sent")
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Date", b.date),
                    y: .value("Received", b.received),
                    series: .value("Series", "Received")
                )
                .foregroundStyle(Color.secondary.opacity(0.95))
                .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [3, 2]))
                .interpolationMethod(.monotone)
            }

            // Hover/scrub tooltip rule + dots.
            if let hoverDate, let bucket = nearestBucket(to: hoverDate) {
                RuleMark(x: .value("Hover", bucket.date))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

                PointMark(
                    x: .value("Hover sent", bucket.date),
                    y: .value("Sent", bucket.sent)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(64)

                PointMark(
                    x: .value("Hover received", bucket.date),
                    y: .value("Received", bucket.received)
                )
                .foregroundStyle(Color.secondary)
                .symbolSize(48)
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisLabel(for: date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text(intVal.formatted(.number.notation(.compactName)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            if let date = dateForPoint(p, proxy: proxy, geo: geo) {
                                hoverDate = date
                            } else {
                                hoverDate = nil
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .chartXScale(domain: chartXDomain())
        .animation(.bmDefault, value: visibleRange)
        .overlay(alignment: .topTrailing) {
            tooltip
                .padding(.top, 4)
                .padding(.trailing, 4)
        }
        .frame(minHeight: 220, idealHeight: 260)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Use the timeline strip below the chart to change the visible date range.")
    }

    // MARK: - Tooltip

    private var tooltip: some View {
        Group {
            if let hoverDate, let bucket = nearestBucket(to: hoverDate) {
                HStack(spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tooltipDateLabel(for: bucket.date))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                        .frame(height: 22)
                    legendDot(.accentColor, label: "Sent", value: bucket.sent)
                    legendDot(.secondary, label: "Received", value: bucket.received)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Static legend when not hovering.
                HStack(spacing: Space.md) {
                    legendDot(.accentColor, label: "Sent", value: nil)
                    legendDot(.secondary, label: "Received", value: nil)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .animation(.bmHover, value: hoverDate)
    }

    @ViewBuilder
    private func legendDot(_ color: Color, label: String, value: Int?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            if let value {
                Text(value.formatted(.number))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No activity in this window")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Helpers

    /// Convert a hover point in geo-local coords to a Date inside the
    /// plot area. nil if the point falls outside the plot frame.
    private func dateForPoint(
        _ p: CGPoint,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geo[plotFrame].origin
        let relativeX = p.x - origin.x
        return proxy.value(atX: relativeX)
    }

    /// X-axis domain. ALWAYS pinned to the buckets' actual span (with a
    /// small symmetric padding), NEVER to `visibleRange` — even when one
    /// is provided.
    ///
    /// Why not honor `visibleRange`?
    /// -----------------------------
    /// Buckets are anchored to calendar boundaries (start of day, Monday,
    /// start of month), but `visibleRange` is the navigator's exact
    /// bounds — usually some random time-of-day. So the first bucket's
    /// date is anywhere from 0 to one-full-bucket BEFORE
    /// `visibleRange.lowerBound`. The size of that offset, relative to
    /// the chart width, depends on the bucketing AND the percentage
    /// padding we add:
    ///   - daily (30d):   buckets-vs-range gap ≤ 1d, padding ~0.6d
    ///                     → first point sits ~0–2% from left edge
    ///   - weekly (12m):  buckets-vs-range gap ≤ 7d, padding ~7d
    ///                     → first point sits ~0–4% from left edge
    ///   - monthly (all): buckets-vs-range gap ≤ 30d, padding ~30–70d
    ///                     → first point sits ~1.5% from left edge
    /// Net effect: the leftmost data point's pixel position DRIFTS as the
    /// user changes the window. Plus the AreaMark's monotone interpolation
    /// grows a "tail" that smooths out to the chart's left border, making
    /// short timeframes look like the data has been smeared leftward.
    ///
    /// Pinning to buckets eliminates both. The brushed-zoom UX still
    /// works because changing the brush filters the underlying SQL —
    /// fewer buckets get returned — so the chart still "zooms" through
    /// the data path, just without the visual drift.
    ///
    /// `visibleRange` is still consumed by the view (accessibility
    /// label, animation key) — it just doesn't drive the domain.
    private func chartXDomain() -> ClosedRange<Date> {
        // Pad both ends by a small fraction of the total span so the
        // leftmost / rightmost data points (and the area fill below
        // them) don't clip against the plot border. 2% reads as
        // natural breathing room without wasting visible real estate.
        func padded(_ range: ClosedRange<Date>) -> ClosedRange<Date> {
            let span = range.upperBound.timeIntervalSince(range.lowerBound)
            guard span > 0 else {
                let lo = range.lowerBound.addingTimeInterval(-3600)
                let hi = range.upperBound.addingTimeInterval(3600)
                return lo...hi
            }
            let pad = span * 0.02
            let lo = range.lowerBound.addingTimeInterval(-pad)
            let hi = range.upperBound.addingTimeInterval(pad)
            return lo...hi
        }
        if let first = buckets.first?.date, let last = buckets.last?.date {
            return padded(first...last)
        }
        let now = Date()
        return now.addingTimeInterval(-86_400)...now
    }

    /// Find the bucket with the smallest |date difference| to the hover point.
    /// Buckets are ordered ascending; we could binary-search but the lists
    /// stay small (max ~365 for 30-day daily / 12 for monthly).
    private func nearestBucket(to date: Date) -> DashboardStats.TimeBucket? {
        guard !buckets.isEmpty else { return nil }
        var best = buckets[0]
        var bestDelta = abs(best.date.timeIntervalSince(date))
        for b in buckets.dropFirst() {
            let d = abs(b.date.timeIntervalSince(date))
            if d < bestDelta {
                bestDelta = d
                best = b
            }
        }
        return best
    }

    private func xAxisLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        switch bucketing {
        case .day:
            formatter.dateFormat = "MMM d"
        case .week:
            formatter.dateFormat = "MMM d"
        case .month:
            formatter.dateFormat = "MMM ''yy"
        }
        return formatter.string(from: date)
    }

    private func tooltipDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        switch bucketing {
        case .day:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case .week:
            formatter.dateFormat = "'Week of' MMM d, yyyy"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
        }
        return formatter.string(from: date)
    }

    /// VoiceOver-friendly description of the chart's state.
    private var accessibilityLabel: String {
        if let visibleRange {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return "Texting frequency chart, showing \(f.string(from: visibleRange.lowerBound)) to \(f.string(from: visibleRange.upperBound))."
        }
        return "Texting frequency chart, sent and received messages over time."
    }
}

// MARK: - Previews

#Preview("FrequencyChart — daily", traits: .fixedLayout(width: 720, height: 360)) {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    let buckets = (0..<30).map { offset -> DashboardStats.TimeBucket in
        let day = cal.date(byAdding: .day, value: -29 + offset, to: today) ?? today
        let sent = max(0, 30 + Int(sin(Double(offset) * 0.4) * 18 + Double.random(in: -5...5)))
        let received = max(0, 25 + Int(cos(Double(offset) * 0.32) * 14 + Double.random(in: -4...4)))
        return DashboardStats.TimeBucket(date: day, sent: sent, received: received)
    }
    return FrequencyChart(
        buckets: buckets,
        bucketing: .day,
        visibleRange: nil
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}
