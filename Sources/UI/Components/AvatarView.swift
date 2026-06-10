import AppKit
import SwiftUI

/// Renders a contact's profile photo as a circular avatar, or falls back to
/// initials on a tinted circle when no photo is available.
///
/// Two-state design (no in-between):
/// - `imageData` non-nil and decodes to a valid `NSImage` → photo, scaled to
///   fill the circle, smooth interpolation, hairline border. This is the
///   "we know who this is and have a face" state.
/// - everything else → tinted circle + monogram initials. This is what the
///   browse window and the panel showed before avatars landed; keeping the
///   exact look means the data-layer rollout doesn't visually change unknown
///   handles.
///
/// **Why not `Image(nsImage:)` with a placeholder modifier?** SwiftUI's
/// async-image apparatus is built for URL fetches. Here the bytes are already
/// in memory (or available synchronously from disk). A bare `NSImage(data:)`
/// is faster, simpler, and never flashes a placeholder.
public struct AvatarView: View {

    /// Raw PNG / JPEG bytes for the contact photo, when known. Pass nil to
    /// always show the initials fallback.
    let imageData: Data?

    /// The fallback monogram. Caller computes this so we don't re-derive
    /// from a name string we don't have.
    let initials: String

    /// Diameter of the circle in points. The image is rendered at the
    /// natural device scale via SwiftUI's interpolation pipeline.
    let size: CGFloat

    /// Background tint for the initials fallback. Has no effect when a photo
    /// is shown (the photo fills the circle).
    let tint: Color

    /// Foreground color for the initials text in the fallback state. Defaults
    /// to `.secondary`, which reads well against the default low-opacity
    /// `tint`. Callers using a saturated tint (e.g. the browse window's
    /// per-contact hue) should pass `.white` for legibility.
    let initialsForeground: Color

    public init(
        imageData: Data?,
        initials: String,
        size: CGFloat,
        tint: Color = Color.secondary.opacity(0.4),
        initialsForeground: Color = .secondary
    ) {
        self.imageData = imageData
        self.initials = initials
        self.size = size
        self.tint = tint
        self.initialsForeground = initialsForeground
    }

    public var body: some View {
        Group {
            if let nsImage = decodedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(tint)
                    Text(initials)
                        .font(.system(size: initialsFontSize, weight: .semibold))
                        .foregroundStyle(initialsForeground)
                }
                .frame(width: size, height: size)
            }
        }
        // Hairline border. Matches `ResultRow`'s avatar border (0.5pt) and
        // sits in front of either fill — the photo gets a subtle edge that
        // reads as "rendered, not raw bitmap"; the monogram looks identical
        // to what we used to draw.
        .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 0.5))
    }

    /// Decoded-image cache keyed by the raw bytes. `NSImage(data:)` returns a
    /// NEW image identity on every call, so an uncached decode forces AppKit
    /// to re-rasterize the photo on every body re-evaluation (hover toggles,
    /// scroll-driven re-renders) — visible as scroll hitches on avatar-heavy
    /// lists. Same bytes → same `NSImage` instance keeps the texture reusable.
    /// NSCache is thread-safe and evicts under memory pressure.
    private static let decodeCache: NSCache<NSData, NSImage> = {
        let c = NSCache<NSData, NSImage>()
        c.countLimit = 768
        return c
    }()

    /// Garbage-in (corrupt bytes, non-image data) returns nil and we fall
    /// through to initials cleanly — never a crash, never a flashing black
    /// square. Failed decodes aren't cached; they're rare and cheap to retry.
    private var decodedImage: NSImage? {
        guard let imageData, !imageData.isEmpty else { return nil }
        let key = imageData as NSData
        if let cached = Self.decodeCache.object(forKey: key) { return cached }
        guard let image = NSImage(data: imageData) else { return nil }
        Self.decodeCache.setObject(image, forKey: key)
        return image
    }

    /// Initials font scales linearly with diameter so a 28pt avatar reads
    /// the same density as a 36pt one. Chosen empirically: at 28pt, 11pt
    /// font matches the panel's `SpotlightResultRow` look; at 36pt, 14pt
    /// matches `ResultRow`'s.
    private var initialsFontSize: CGFloat {
        size * 0.40
    }
}

// MARK: - Previews

#Preview("AvatarView — variants", traits: .fixedLayout(width: 320, height: 220)) {
    HStack(spacing: Space.lg) {
        // No photo → initials fallback.
        AvatarView(imageData: nil, initials: "MA", size: 36)
        AvatarView(imageData: nil, initials: "P", size: 36)

        // Simulated photo — a one-pixel PNG renders as a colored disc.
        AvatarView(imageData: AvatarView.placeholderPNG, initials: "X", size: 36)
        AvatarView(imageData: AvatarView.placeholderPNG, initials: "X", size: 28)
        AvatarView(imageData: AvatarView.placeholderPNG, initials: "X", size: 48)
    }
    .padding(Space.lg)
    .background(Color.chromeBackground)
}

extension AvatarView {
    /// One-pixel solid-color PNG, used in previews to stand in for a real
    /// contact photo. Not exposed publicly — preview-only.
    static var placeholderPNG: Data {
        Data([
            // PNG signature
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            // IHDR chunk: 1x1 RGB
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
            // IDAT chunk: one orange pixel
            0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
            0x08, 0x99, 0x63, 0xF8, 0xCF, 0xC0, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01,
            0x83, 0xB3, 0xCC, 0xA1,
            // IEND chunk
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
    }
}
