//
//  GlassCompat.swift
//  Hourglass
//
//  Compatibility wrappers around the macOS 26 (Tahoe) liquid-glass APIs.
//  These let us target macOS 14 (Sonoma) as the deployment floor while
//  still using the full glass aesthetic on Tahoe.
//
//  Why two helpers, not one
//  ------------------------
//  - `.glassEffect(_:in:)` is a method modifier — easy to wrap in a
//    `@ViewBuilder` extension on `View`.
//  - `GlassEffectContainer` is a container View struct — can't be wrapped
//    by a method, needs its own ViewBuilder helper.
//  Both helpers branch on `#available(macOS 26, *)` so callers don't have
//  to do the dance themselves.
//
//  Fallback look (Sonoma + earlier)
//  --------------------------------
//  - `glassOrMaterial` swaps in `.regularMaterial` as the background and
//    overlays the tint with `.plusLighter` blend mode. The result reads as
//    a tinted frosted-material surface — close to glass in feel, just
//    without the morph/distortion. Color family is preserved so the
//    accent-tinted CTAs still look "blue" on Sonoma.
//  - `glassEffectContainerCompat` just drops the container on older OS.
//    The morph-blur is the only thing it does at the container level;
//    children still render fine without it.
//
//  Liquid Glass policy is preserved: glass = navigation layer only.
//

import SwiftUI

extension View {

    /// Apply a glass surface on macOS 26 (Tahoe) or a tinted material
    /// fallback on macOS 14–25.
    ///
    /// Parameters:
    ///   - tint: accent color for the surface. Pass `.clear` for an
    ///     untinted glass / plain material look.
    ///   - tintOpacity: opacity hint for the tint. On macOS 26 this is
    ///     applied via `Glass.regular.tint(_:)`. On older OS it's used
    ///     to weight the overlay blend.
    ///   - shape: the surface shape (typically a rounded rectangle).
    @ViewBuilder
    func glassOrMaterial<S: Shape & InsettableShape>(
        tint: Color = .clear,
        tintOpacity: Double = 0.18,
        in shape: S
    ) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint.opacity(tintOpacity)), in: shape)
        } else {
            // Sonoma fallback: opaque material + tinted overlay.
            // `.regularMaterial` is closest in feel to the new glass
            // effect. The tint goes on top via plusLighter at a slightly
            // higher opacity than glass's native tint since material
            // alone doesn't carry color — the multiplier (1.6) brings it
            // back into the same visual ballpark.
            self
                .background(.regularMaterial, in: shape)
                .overlay(
                    shape
                        .fill(tint.opacity(tintOpacity * 1.6))
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
        }
    }
}

/// Builder-style wrapper around `GlassEffectContainer`. On macOS 26 it's
/// a real container that lets glass surfaces inside morph together; on
/// older OS it's a passthrough (children render unchanged).
///
/// Use this anywhere you'd write `GlassEffectContainer(spacing: N) { ... }`.
@ViewBuilder
func glassEffectContainerCompat<Content: View>(
    spacing: CGFloat = 0,
    @ViewBuilder content: () -> Content
) -> some View {
    if #available(macOS 26, *) {
        // Hoist the closure call OUT of the GlassEffectContainer's
        // own builder. Otherwise Swift 6 strict-concurrency complains
        // that the @ViewBuilder closure (non-Sendable) is being passed
        // into GlassEffectContainer's @Sendable expecting context.
        let body = content()
        GlassEffectContainer(spacing: spacing) { body }
    } else {
        content()
    }
}
