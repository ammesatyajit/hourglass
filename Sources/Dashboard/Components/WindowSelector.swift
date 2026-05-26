//
//  WindowSelector.swift
//  Hourglass — Dashboard components
//
//  Pill row for the time window: 30d / 12m / All. Subtle glass on the
//  selected pill, hairline on the unselected ones. Uses the system accent
//  for selection so the OS-level tint propagates.
//

import SwiftUI

struct WindowSelector: View {
    @Binding var selection: DashboardLoader.Window

    /// True when the active window range was set by manual brush drag
    /// (none of the preset segments accurately describes it). The pills
    /// remain clickable (each snaps the brush to its preset) but the
    /// whole control is desaturated so no segment looks "active" — it
    /// would be misleading to highlight one when the user is actually
    /// viewing a custom range.
    var customRangeActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DashboardLoader.Window.allCases) { window in
                pill(for: window)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        )
        .opacity(customRangeActive ? 0.55 : 1.0)
        .animation(.bmDefault, value: customRangeActive)
    }

    /// One pill in the segmented row.
    ///
    /// **Z-order note**: `.glassEffect(_:in:)` is applied to the BUTTON
    /// itself, not to a background `Shape`. When you do
    /// `.background { Shape().glassEffect(...) }` the shape becomes a glass
    /// element rendered on top of the underlying chrome — and SwiftUI ends
    /// up compositing the text *under* the blur. Applying glassEffect to
    /// the button puts the glass behind the button's foreground (label) as
    /// intended.
    @ViewBuilder
    private func pill(for window: DashboardLoader.Window) -> some View {
        // A pill is visually "active" only when it matches `selection`
        // AND no custom range overrides it. During a custom range the
        // selection variable still tracks the LAST preset the user
        // clicked (so a return-to-preset click has somewhere to land),
        // but we don't want to highlight that stale match.
        let isSelected = selection == window && !customRangeActive
        Button {
            withAnimation(.bmGlassMorph) {
                selection = window
            }
        } label: {
            Text(window.label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Space.md)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .background {
            // Selected pill: solid tinted fill behind the text. Sits in the
            // chrome layer per HIG ("glass = navigation, content = solid").
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium))
        .accessibilityLabel("Show \(window.label) window")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("WindowSelector", traits: .fixedLayout(width: 360, height: 80)) {
    StatefulPreviewWrapper(DashboardLoader.Window.last30Days) { selection in
        WindowSelector(selection: selection)
            .padding(Space.lg)
            .background(Color.chromeBackground)
    }
}

/// Tiny helper for previews — wraps state so we can drive @Binding.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
