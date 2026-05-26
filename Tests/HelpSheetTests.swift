//
//  HelpSheetTests.swift
//  HourglassTests
//
//  Sanity tests for the help-sheet content. The cheatsheet is the *only*
//  place users can discover the full grammar — keeping it complete is a
//  contract, so we pin it with a test rather than a code review checkbox.
//

import XCTest
@testable import Hourglass

final class HelpSheetTests: XCTestCase {

    /// The help sheet covers every `TokenPrefix` defined for the query
    /// grammar. If a new prefix lands in `QueryAutocomplete.TokenPrefix`,
    /// this test fails until the cheatsheet is updated.
    func testEveryTokenPrefixIsDocumented() {
        let allTokens = HelpSection.allSections
            .flatMap(\.entries)
            .map { $0.token.lowercased() }

        for prefix in TokenPrefix.allCases {
            let raw = prefix.rawValue // e.g. "from:"
            let documented = allTokens.contains { $0.hasPrefix(raw) }
            XCTAssertTrue(documented,
                          "TokenPrefix '\(raw)' has no entry in HelpSection.allSections — add a cheatsheet row for it.")
        }
    }

    /// Every entry should provide a non-empty example that the user can
    /// click to insert. We rely on this contract in the panel's
    /// click-to-insert handler.
    func testEveryEntryHasUsableExample() {
        for section in HelpSection.allSections {
            for entry in section.entries {
                XCTAssertFalse(entry.example.trimmingCharacters(in: .whitespaces).isEmpty,
                               "Entry '\(entry.token)' has no example")
                XCTAssertFalse(entry.description.trimmingCharacters(in: .whitespaces).isEmpty,
                               "Entry '\(entry.token)' has no description")
            }
        }
    }

    /// Section ids are unique so SwiftUI's `ForEach` doesn't collapse rows.
    func testSectionIdsAreUnique() {
        let ids = HelpSection.allSections.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "Help sections must have unique ids")
    }

    /// Entry tokens are unique within a section (no accidental duplicates).
    func testEntryTokensAreUniqueAcrossAllSections() {
        let tokens = HelpSection.allSections
            .flatMap(\.entries)
            .map(\.token)
        XCTAssertEqual(Set(tokens).count, tokens.count,
                       "Help entry tokens must be globally unique")
    }
}
