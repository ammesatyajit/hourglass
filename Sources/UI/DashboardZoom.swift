//
//  DashboardZoom.swift
//  Hourglass — ⌘+/⌘− content zoom for the dashboard window (0.3.1)
//
//  Browser-style zoom: the window content scales as a whole, width- and
//  height-compensated so layout math stays in unscaled coordinates and the
//  scroll views keep working. Persisted across launches.
//

import SwiftUI

@MainActor
public final class DashboardZoom: ObservableObject {
    public static let shared = DashboardZoom()

    private static let key = "dashboard.zoom"
    public static let minScale = 0.7
    public static let maxScale = 1.8

    @Published public var scale: Double {
        didSet { UserDefaults.standard.set(scale, forKey: Self.key) }
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.key)
        scale = saved > 0 ? min(max(saved, Self.minScale), Self.maxScale) : 1.0
    }

    public func zoomIn()  { scale = min(Self.maxScale, ((scale + 0.1) * 10).rounded() / 10) }
    public func zoomOut() { scale = max(Self.minScale, ((scale - 0.1) * 10).rounded() / 10) }
    public func reset()   { scale = 1.0 }
}

/// Wraps the dashboard root and applies the zoom: content is laid out at
/// (size / scale) then scaled up, so 1.2× reads like a browser's ⌘+ — text
/// and charts grow, layout reflows to the visible width.
public struct ZoomContainer<Content: View>: View {
    @ObservedObject private var zoom = DashboardZoom.shared
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            content
                .frame(
                    width: proxy.size.width / zoom.scale,
                    height: proxy.size.height / zoom.scale
                )
                .scaleEffect(zoom.scale, anchor: .topLeading)
        }
    }
}
