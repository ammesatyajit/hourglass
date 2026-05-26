//
//  Handle.swift
//  Hourglass
//
//  A `Handle` is a normalized identifier for a conversation participant — a
//  phone number (E.164-ish) or an email address.
//
//  Normalization rules (matches `reference/scripts/*.py`):
//    - Phones: strip every non-digit. If the remaining length is 10, prepend
//      "1" (US-default). Always prefix with "+". So "(415) 555-0100" → "+14155550100".
//    - Emails: lowercased.
//    - Anything else: store the original string, lowercased if it contains "@".
//
//  This keys the contact-resolution map. Two iMessage handles with the same
//  normalized form resolve to the same contact (so "415-555-0100" and
//  "+1 415 555 0100" merge correctly).
//

import Foundation

public struct Handle: Hashable, Sendable {

    /// The normalized identifier string (e.g. "+14155550100" or "foo@bar.com").
    public let normalized: String

    /// The raw, un-normalized handle string as it appeared in chat.db
    /// (`handle.id`). Kept for display fallback when no contact matches.
    public let raw: String

    public init(raw: String) {
        self.raw = raw
        self.normalized = Self.normalize(raw)
    }

    // MARK: - Equatable / Hashable
    //
    // Two `Handle`s are considered equal if their NORMALIZED forms match,
    // regardless of how the original string was punctuated. This is the whole
    // point of the normalization pass — `(415) 555-0100` and `+14155550100`
    // identify the same person and must hash to the same bucket so contact
    // resolution works.
    //
    // The default synthesized Hashable would include `raw` and break this.

    public static func == (lhs: Handle, rhs: Handle) -> Bool {
        lhs.normalized == rhs.normalized
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
    }

    /// Normalize a phone-or-email string into the canonical form used as
    /// the map key for contact resolution.
    public static func normalize(_ input: String) -> String {
        // Email: presence of "@" is the signal. Lowercase, no further changes.
        if input.contains("@") {
            return input.lowercased()
        }
        // Phone: keep digits only, prepend country code if missing, prefix "+".
        let digits = input.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map { Character($0) }
        guard !digits.isEmpty else {
            // Couldn't extract digits; fall back to a lowercased raw value so
            // we still get *some* canonical form.
            return input.lowercased()
        }
        var d = String(digits)
        if d.count == 10 {
            d = "1" + d
        }
        return "+" + d
    }

    /// Is this a phone-style handle (i.e. starts with "+")?
    public var isPhone: Bool {
        normalized.hasPrefix("+")
    }

    /// Is this an email-style handle?
    public var isEmail: Bool {
        normalized.contains("@")
    }
}
