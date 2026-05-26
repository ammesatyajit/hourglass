import SwiftUI

/// Design tokens for Hourglass. Owned by design-agent.
///
/// Other agents: please use these constants instead of inventing new ones.
/// See `docs/design-notes.md` for the rationale behind each value.

// MARK: - Corner Radius

enum Radius {
    /// 8pt — avatars, tiny pills, count badges
    static let small: CGFloat = 8
    /// 12pt — filter chips, sidebar items
    static let medium: CGFloat = 12
    /// 16pt — default for GlassCard, result rows
    static let large: CGFloat = 16
    /// 22pt — search field
    static let xlarge: CGFloat = 22
    /// 28pt — reserved for hero modals
    static let huge: CGFloat = 28
}

// MARK: - Spacing (4pt grid)

enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Semantic colors

extension Color {
    /// Hairline border for content cards. Adapts to light/dark via `.primary`.
    static var hairline: Color { .primary.opacity(0.08) }

    /// Subtle background for unobtrusive content surfaces.
    static var contentBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    /// Window-chrome background; matches the toolbar/title area.
    static var chromeBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

// MARK: - Animation presets

extension Animation {
    /// Default snappy UI animation — buttons, hovers, taps.
    static var bmDefault: Animation { .smooth(duration: 0.22) }

    /// Glass morph for chips appearing/disappearing.
    static var bmGlassMorph: Animation { .bouncy(duration: 0.32, extraBounce: 0.1) }

    /// Subtle hover/press feedback.
    static var bmHover: Animation { .snappy(duration: 0.18) }
}

// MARK: - Filter category tints

/// Tint colors for different filter categories. Used at low opacity on glass chips.
enum FilterCategory: String, Hashable, CaseIterable, Sendable {
    case person
    case dateRange
    case chat
    case freeText
    case reaction
    case type

    var tint: Color {
        switch self {
        case .person: return .blue
        case .dateRange: return .purple
        case .chat: return .orange
        case .freeText: return .gray
        case .reaction: return .pink
        case .type: return .teal
        }
    }

    var icon: String {
        switch self {
        case .person: return "person.crop.circle"
        case .dateRange: return "calendar"
        case .chat: return "bubble.left.and.bubble.right"
        case .freeText: return "text.magnifyingglass"
        case .reaction: return "heart.fill"
        case .type: return "doc.richtext"
        }
    }
}
