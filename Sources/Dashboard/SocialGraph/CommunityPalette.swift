//
//  CommunityPalette.swift
//  Hourglass — Dashboard / Social Graph
//
//  A small, fixed palette of distinguishable hues for coloring social
//  circles. The brief permits per-community tints on the graph canvas (the
//  *container* still follows the solid + hairline content-layer rule via
//  `StatPanel`). Colors are picked for separation on both light and dark
//  backgrounds and cycle if there are more communities than entries.
//
//  Community id `-1` (the center "you" node) renders in the neutral system
//  accent — it belongs to every circle, so it gets none of their hues.
//

import SwiftUI

enum CommunityPalette {

    /// Ordered so the biggest community (dense id 0, see `CommunityDetector`)
    /// gets the most legible lead color. Twelve evenly-spread hues; beyond
    /// that we wrap (with a slight lightness shift so wrapped circles stay
    /// distinguishable from their base).
    static let hues: [Color] = [
        Color(hue: 0.58, saturation: 0.62, brightness: 0.90), // teal-blue
        Color(hue: 0.02, saturation: 0.68, brightness: 0.92), // coral
        Color(hue: 0.78, saturation: 0.55, brightness: 0.88), // violet
        Color(hue: 0.13, saturation: 0.78, brightness: 0.92), // amber
        Color(hue: 0.40, saturation: 0.58, brightness: 0.82), // green
        Color(hue: 0.92, saturation: 0.58, brightness: 0.90), // pink-magenta
        Color(hue: 0.50, saturation: 0.62, brightness: 0.84), // cyan
        Color(hue: 0.08, saturation: 0.72, brightness: 0.90), // orange
        Color(hue: 0.68, saturation: 0.52, brightness: 0.90), // periwinkle
        Color(hue: 0.33, saturation: 0.62, brightness: 0.78), // moss
        Color(hue: 0.85, saturation: 0.50, brightness: 0.86), // mauve
        Color(hue: 0.16, saturation: 0.30, brightness: 0.70), // khaki
    ]

    /// Neutral color for the center node (community id -1).
    static let centerColor = Color.accentColor

    /// Color for a community id. `-1` → the neutral center accent. Wrapping
    /// (>12 circles) reuses hues; that's acceptable because the force layout
    /// already separates the circles spatially, so two same-hued clusters
    /// never sit adjacent enough to be confused.
    static func color(for communityID: Int) -> Color {
        if communityID < 0 { return centerColor }
        return hues[communityID % hues.count]
    }
}
