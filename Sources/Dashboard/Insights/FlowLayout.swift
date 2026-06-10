//
//  FlowLayout.swift
//  Hourglass — Linguistic Insights
//
//  A minimal wrapping flow layout used by the distinctive-words "word
//  cloud" in `LinguisticInsightsPanel`. Lays subviews left-to-right,
//  wrapping to the next line when the current one would overflow the
//  proposed width.
//
//  Scoped to the Insights feature on purpose (a private `FlowingHStack`
//  already exists elsewhere in the UI layer but isn't exposed, and the
//  panel agents are meant to be self-contained). Pure layout math; no
//  state.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } +
            CGFloat(max(0, rows.count - 1)) * lineSpacing
        // When the proposal has a finite width, fill it (so leading
        // alignment behaves) but never exceed the natural content width
        // if the proposal is unbounded.
        let resolvedWidth = proposal.width.map { min($0, max(width, $0)) } ?? width
        return CGSize(width: resolvedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    // MARK: - Row computation

    private struct Row {
        var items: [(index: Int, width: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let additional = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && additional > maxWidth {
                rows.append(current)
                current = Row()
                current.items.append((index, size.width))
                current.width = size.width
                current.height = size.height
            } else {
                if current.items.isEmpty {
                    current.width = size.width
                } else {
                    current.width += spacing + size.width
                }
                current.items.append((index, size.width))
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
