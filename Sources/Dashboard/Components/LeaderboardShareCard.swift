//
//  LeaderboardShareCard.swift
//  Hourglass — Dashboard components
//
//  Beli-style share card: a small, popup-looking branded image rendered
//  on demand when the user hits a row's share control. The card is the
//  artifact people actually post — the plain-text line (LeaderboardShareCopy)
//  rides along beside it so the Hourglass link stays tappable in iMessage.
//
//  Design notes:
//  - Matches the APP ICON's identity, not a generic gradient: charcoal
//    black wash, silvery glass type, white hairlines. The brand chip is the
//    real app icon so the card and the dock/app read as one object.
//  - Fixed DARK appearance regardless of system theme, so the card looks
//    identical wherever it lands (Wrapped/Beli convention for share cards).
//  - Rendered at 2× via ImageRenderer only when the share picker opens —
//    never eagerly in list rows.
//

import SwiftUI
import AppKit

enum LeaderboardShareCard {

    /// Who this share is naturally addressed to — the ranked person, or the
    /// whole group. Lets the share picker put "Message <name>" first,
    /// pre-addressed, with their face on the row.
    struct Recipient {
        let name: String
        /// Reachable Messages handles — one for a person, every participant
        /// for a group (compose-to-set routes to the existing thread).
        let handles: [String]
        /// Contact/group photo bytes — drawn circular on the picker row.
        var avatarData: Data? = nil
    }

    /// Everything the card needs, resolved by the caller at row level.
    struct Spec {
        let kind: LeaderboardShareCopy.Kind
        let rank: Int
        let displayName: String
        /// Recipient-facing count breakdown, e.g. "512 from me · 516 from
        /// you" — a bare total reads ambiguous to the person receiving it.
        let detail: String
        let timeframe: String
        /// Person/group photo, drawn large on the card's right side.
        var avatarData: Data? = nil
        /// Fallback for groups with no set photo: up to three participant
        /// avatars drawn as an overlapping cluster (nil slots skipped).
        var compositeAvatars: [Data?] = []
        /// nil when there's nobody addressable.
        var recipient: Recipient? = nil
    }

    /// Point size of the card view; rendered at `scale`× into the PNG.
    static let cardSize = CGSize(width: 420, height: 250)
    static let scale: CGFloat = 2

    /// Render the card to an NSImage. MainActor because ImageRenderer is.
    @MainActor
    static func render(_ spec: Spec) -> NSImage? {
        let renderer = ImageRenderer(content: CardView(spec: spec))
        renderer.scale = scale
        return renderer.nsImage
    }

    // MARK: - The card itself

    struct CardView: View {
        let spec: Spec

        private var subjectLine: String {
            switch spec.kind {
            case .person:    return "most texted person"
            case .groupChat: return "most texted group chat"
            }
        }

        var body: some View {
            ZStack(alignment: .leading) {
                // Charcoal wash matching the app icon: faint light from the
                // top-left falling to near-black — same read as the icon tile.
                LinearGradient(
                    colors: [
                        Color(red: 0.145, green: 0.150, blue: 0.165),
                        Color(red: 0.075, green: 0.078, blue: 0.088),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // Soft specular bloom — the icon's glass highlight, not a
                // color accent.
                RadialGradient(
                    colors: [Color.white.opacity(0.07), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 300
                )

                VStack(alignment: .leading, spacing: 0) {
                    // Header: the REAL app icon + wordmark left, timeframe right.
                    HStack {
                        HStack(spacing: 8) {
                            Image(nsImage: NSApp.applicationIconImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 26, height: 26)
                            Text("Hourglass")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        Spacer()
                        Text(spec.timeframe)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.60))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                    }

                    Spacer(minLength: 0)

                    // The brag left, their face right.
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Silvery glass gradient, like the icon's
                            // hourglass triangles.
                            Text("#\(spec.rank)")
                                .font(.system(size: 58, weight: .black, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [
                                            Color(white: 0.99),
                                            Color(white: 0.58),
                                        ],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .padding(.bottom, -2)
                            Text(subjectLine)
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(spec.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                                .padding(.top, 4)
                                .lineLimit(1)
                            // Both directions — the recipient shouldn't have
                            // to guess what one bare number means.
                            Text(spec.detail)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.top, 1)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        cardAvatar
                    }

                    Spacer(minLength: 0)

                    // Link pill — the card IS the ad; this is the way in.
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10, weight: .semibold))
                        Text("ammesatyajit.github.io/hourglass")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.80))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                }
                .padding(24)
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }

        /// Their photo, big and circular with a glass ring. Groups without a
        /// set photo get an overlapping cluster of participant faces; the
        /// last resort is a monochrome initials disc (never a color accent).
        @ViewBuilder
        private var cardAvatar: some View {
            if let data = spec.avatarData, let image = NSImage(data: data) {
                circleImage(image, diameter: 88)
            } else if !compositeImages.isEmpty {
                // Up to three faces, overlapped like the app's group rows.
                HStack(spacing: -22) {
                    ForEach(Array(compositeImages.enumerated()), id: \.offset) { _, image in
                        circleImage(image, diameter: 58)
                            .background(
                                // Charcoal ring so overlaps read as depth,
                                // matching the card ground.
                                Circle()
                                    .fill(Color(red: 0.10, green: 0.104, blue: 0.115))
                                    .frame(width: 62, height: 62)
                            )
                    }
                }
            } else {
                Circle()
                    .fill(.white.opacity(0.09))
                    .frame(width: 88, height: 88)
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .overlay(
                        Text(initials(of: spec.displayName))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    )
            }
        }

        private var compositeImages: [NSImage] {
            spec.compositeAvatars.prefix(3).compactMap { $0.flatMap(NSImage.init(data:)) }
        }

        private func circleImage(_ image: NSImage, diameter: CGFloat) -> some View {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1))
        }

        private func initials(of name: String) -> String {
            let parts = name.split(separator: " ").prefix(2)
            return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        }
    }
}

// MARK: - Native share-picker presenter

/// Zero-size anchor that presents an `NSSharingServicePicker` (the native
/// macOS share popup) relative to the view it backgrounds. Items are built
/// lazily when the picker actually opens — this is what lets the card image
/// render on click instead of per-row.
///
/// When `recipient` is set, the picker's FIRST entry is "Message <name>",
/// which opens Messages pre-addressed to that person — sharing a ranking
/// with the person it's about is the whole gesture, so it comes first.
struct SharePickerAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// True from the moment the picker shows until the user chooses a
    /// service or dismisses it. The CALLER must keep this view mounted
    /// while active — the popover is anchored to this NSView, and AppKit
    /// tears the popover down if its anchor leaves the hierarchy (the
    /// "modal disappears when I move off the button" bug).
    @Binding var isActive: Bool
    var recipient: LeaderboardShareCard.Recipient? = nil
    let items: () -> [Any]

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onDismiss = { isActive = false }
        guard isPresented else { return }
        DispatchQueue.main.async {
            guard isPresented else { return }
            isPresented = false
            isActive = true
            let picker = NSSharingServicePicker(items: items())
            // Hold the picker + delegate for the duration of presentation.
            context.coordinator.recipient = recipient
            context.coordinator.activePicker = picker
            picker.delegate = context.coordinator
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var activePicker: NSSharingServicePicker?
        var recipient: LeaderboardShareCard.Recipient?
        var onDismiss: (() -> Void)?

        /// Fires on service choice AND on click-away dismissal (nil
        /// service) — the picker is gone either way, so release the
        /// caller's mount hold.
        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            activePicker = nil
            onDismiss?()
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            sharingServicesForItems items: [Any],
            proposedSharingServices proposedServices: [NSSharingService]
        ) -> [NSSharingService] {
            guard let recipient, !recipient.handles.isEmpty,
                  let compose = NSSharingService(named: .composeMessage) else {
                return proposedServices
            }
            // Pre-addressed Messages entry, first in the list, wearing the
            // person's face. (The avatar strip ABOVE the services is the
            // system's own recents row — there is no public API to pin an
            // entry there, so their photo on our row is the closest legal
            // equivalent.) The handler captures `items` (card + text) and
            // sends them to the person the ranking is about.
            let rowImage = recipient.avatarData.flatMap { Self.circularAvatar(from: $0) }
                ?? compose.image
            let direct = NSSharingService(
                title: "Message \(recipient.name)",
                image: rowImage,
                alternateImage: compose.alternateImage
            ) {
                compose.recipients = recipient.handles
                compose.perform(withItems: items)
            }
            return [direct] + proposedServices
        }

        /// Aspect-fill the contact photo into a circle at share-row size.
        private static func circularAvatar(from data: Data, diameter: CGFloat = 32) -> NSImage? {
            guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else {
                return nil
            }
            let target = NSImage(size: NSSize(width: diameter, height: diameter))
            target.lockFocus()
            defer { target.unlockFocus() }
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).addClip()
            // Center-crop the shorter edge so the face fills the circle.
            let side = min(source.size.width, source.size.height)
            let crop = NSRect(
                x: (source.size.width - side) / 2,
                y: (source.size.height - side) / 2,
                width: side, height: side
            )
            source.draw(
                in: NSRect(x: 0, y: 0, width: diameter, height: diameter),
                from: crop,
                operation: .sourceOver,
                fraction: 1.0
            )
            return target
        }
    }
}
