//
//  PhraseQueryTests.swift
//  HourglassTests
//
//  Pins the contract for the new phrase AST: word-boundary default,
//  substring opt-out (`*term*`), regex (`/pattern/[i]`), and OR
//  (`a|b`/`a OR b`). Also guards backward-compat with `a+b` and quoted
//  multi-word phrases.
//
//  Add a new operator to PhraseQuery? Add a test here.
//

import XCTest
@testable import Hourglass

final class PhraseQueryTests: XCTestCase {

    // MARK: - 2-char queries

    func testTwoCharQueryProducesTerm() throws {
        // Regression: 2-char queries used to silently fail when the
        // FTS path was active (trigram tokenizer floor). The parser
        // itself never had a minimum, but tests pin the invariant.
        let ast = try PhraseQuery.parse("ok", caseSensitive: false)
        XCTAssertEqual(ast.groups.count, 1)
        guard case .term(let t, let mode) = ast.groups[0].needles[0] else {
            return XCTFail("Expected a single term")
        }
        XCTAssertEqual(t, "ok")
        XCTAssertEqual(mode, .word)
        XCTAssertTrue(ast.containsShortTerm(minLength: 3),
                      "2-char term must trip the FTS fallback flag.")
    }

    func testSingleCharQueryProducesTerm() throws {
        let ast = try PhraseQuery.parse("a", caseSensitive: false)
        XCTAssertFalse(ast.isEmpty)
        XCTAssertTrue(ast.containsShortTerm(minLength: 3))
    }

    // MARK: - Word boundary default

    func testBareWordIsWordBoundary() throws {
        let ast = try PhraseQuery.parse("the", caseSensitive: false)
        XCTAssertEqual(ast.groups.count, 1)
        guard case .term(let t, let mode) = ast.groups[0].needles[0] else {
            return XCTFail()
        }
        XCTAssertEqual(t, "the")
        XCTAssertEqual(mode, .word, "Bare terms must default to word-boundary.")
    }

    func testWordBoundaryMatchesIsolatedWord() throws {
        let ast = try PhraseQuery.parse("the", caseSensitive: false)
        XCTAssertTrue(ast.matches(body: "the cat sat", caseSensitive: false))
        XCTAssertTrue(ast.matches(body: "Welcome to the show.", caseSensitive: false))
        XCTAssertTrue(ast.matches(body: "the!", caseSensitive: false))
    }

    func testWordBoundaryRejectsSubstring() throws {
        let ast = try PhraseQuery.parse("the", caseSensitive: false)
        XCTAssertFalse(ast.matches(body: "another", caseSensitive: false),
                       "'the' must NOT match inside 'another'.")
        XCTAssertFalse(ast.matches(body: "fathered", caseSensitive: false))
        XCTAssertFalse(ast.matches(body: "northern lights", caseSensitive: false))
    }

    // MARK: - Substring opt-out

    func testStarStarOptsIntoSubstring() throws {
        let ast = try PhraseQuery.parse("*cactus*", caseSensitive: false)
        guard case .term(let t, let mode) = ast.groups[0].needles[0] else {
            return XCTFail()
        }
        XCTAssertEqual(t, "cactus")
        XCTAssertEqual(mode, .substring)
    }

    func testSubstringMatchesInsideWord() throws {
        let ast = try PhraseQuery.parse("*cactus*", caseSensitive: false)
        XCTAssertTrue(ast.matches(body: "I bought cactuses", caseSensitive: false))
        XCTAssertTrue(ast.matches(body: "cactusly", caseSensitive: false))
        XCTAssertTrue(ast.matches(body: "cactus", caseSensitive: false))
    }

    func testQuotedTermIsSubstring() throws {
        let ast = try PhraseQuery.parse("\"cactus\"", caseSensitive: false)
        guard case .term(let t, let mode) = ast.groups[0].needles[0] else {
            return XCTFail()
        }
        XCTAssertEqual(t, "cactus")
        XCTAssertEqual(mode, .substring, "Quoted single-word terms have substring semantics.")
    }

    func testQuotedMultiWordPhrase() throws {
        let ast = try PhraseQuery.parse("\"happy birthday\"", caseSensitive: false)
        XCTAssertEqual(ast.groups.count, 1)
        guard case .term(let t, let mode) = ast.groups[0].needles[0] else {
            return XCTFail()
        }
        XCTAssertEqual(t, "happy birthday")
        XCTAssertEqual(mode, .substring)
        XCTAssertTrue(ast.matches(body: "Wishing you a happy birthday today!", caseSensitive: false))
    }

    // MARK: - Regex

    func testRegexSlashesProduceRegexNeedle() throws {
        let ast = try PhraseQuery.parse("/cact.*/", caseSensitive: false)
        guard case .regex(let cr) = ast.groups[0].needles[0] else {
            return XCTFail("Expected a regex needle")
        }
        XCTAssertEqual(cr.source, "cact.*")
        // Defaults to case-insensitive when global mode is insensitive.
        XCTAssertTrue(cr.caseInsensitive)
    }

    func testRegexExplicitInsensitiveFlag() throws {
        let ast = try PhraseQuery.parse("/foo/i", caseSensitive: true)
        guard case .regex(let cr) = ast.groups[0].needles[0] else {
            return XCTFail()
        }
        XCTAssertTrue(cr.caseInsensitive, "Explicit /i overrides global case-sensitive mode.")
    }

    func testRegexInCaseSensitiveModeWithoutFlag() throws {
        let ast = try PhraseQuery.parse("/foo/", caseSensitive: true)
        guard case .regex(let cr) = ast.groups[0].needles[0] else {
            return XCTFail()
        }
        XCTAssertFalse(cr.caseInsensitive)
    }

    func testRegexMatches() throws {
        let ast = try PhraseQuery.parse("/cact.*/", caseSensitive: false)
        XCTAssertTrue(ast.matches(body: "Visit cactus garden", caseSensitive: false))
        XCTAssertTrue(ast.matches(body: "Cactuses everywhere", caseSensitive: false))
    }

    func testInvalidRegexThrows() {
        // Unbalanced brackets — NSRegularExpression rejects.
        XCTAssertThrowsError(try PhraseQuery.parse("/[unclosed/", caseSensitive: false)) { err in
            guard case PhraseQuery.Error.invalidRegex(let src, _) = err else {
                return XCTFail("Expected invalidRegex, got \(err)")
            }
            XCTAssertEqual(src, "[unclosed")
        }
    }

    // MARK: - OR

    func testPipeOR() throws {
        let ast = try PhraseQuery.parse("cactus|saguaro", caseSensitive: false)
        XCTAssertEqual(ast.groups.count, 1)
        XCTAssertEqual(ast.groups[0].needles.count, 2)
    }

    func testWhitespaceOR() throws {
        let ast = try PhraseQuery.parse("cactus OR saguaro", caseSensitive: false)
        XCTAssertEqual(ast.groups.count, 1)
        XCTAssertEqual(ast.groups[0].needles.count, 2)
    }

    func testORMatchesEither() throws {
        let ast = try PhraseQuery.parse("cactus|saguaro", caseSensitive: false)
        XCTAssertTrue(ast.matches(body: "I love cactus", caseSensitive: false))
        XCTAssertTrue(ast.matches(body: "Tall saguaro forest", caseSensitive: false))
        XCTAssertFalse(ast.matches(body: "Just a tree", caseSensitive: false))
    }

    func testORCaseInsensitiveByDefault() throws {
        let ast = try PhraseQuery.parse("cactus OR saguaro", caseSensitive: false)
        XCTAssertTrue(ast.matches(body: "CACTUS forest", caseSensitive: false))
    }

    func testORWithRegex() throws {
        // Mixed: literal OR regex. Both branches must compile and the
        // matcher honors both.
        let ast = try PhraseQuery.parse("cactus|/sag.+/", caseSensitive: false)
        XCTAssertEqual(ast.groups[0].needles.count, 2)
        XCTAssertTrue(ast.matches(body: "Saguaro National Park", caseSensitive: false))
        XCTAssertTrue(ast.matches(body: "cactus", caseSensitive: false))
        XCTAssertFalse(ast.matches(body: "tree", caseSensitive: false))
    }

    // MARK: - Backward-compat: A+B

    func testPlusANDBackwardCompat() throws {
        let ast = try PhraseQuery.parse("cactus+water", caseSensitive: false)
        // Two AND groups, each with one needle.
        XCTAssertEqual(ast.groups.count, 2)
        XCTAssertEqual(ast.groups[0].needles.count, 1)
        XCTAssertEqual(ast.groups[1].needles.count, 1)
        XCTAssertTrue(ast.matches(body: "the cactus needs water", caseSensitive: false))
        XCTAssertFalse(ast.matches(body: "only cactus here", caseSensitive: false))
    }

    func testWhitespaceIsAND() throws {
        // Without OR, whitespace-separated tokens AND together too —
        // backward compat with the old `a b` → `a AND b` interpretation.
        let ast = try PhraseQuery.parse("cactus water", caseSensitive: false)
        XCTAssertEqual(ast.groups.count, 2)
        XCTAssertTrue(ast.matches(body: "cactus needs water", caseSensitive: false))
        XCTAssertFalse(ast.matches(body: "only water", caseSensitive: false))
    }

    // MARK: - Precedence

    /// `+` binds tighter than `|`. So `a|b+c` is `a OR (b AND c)`.
    /// We document a softer v1 semantic: a single-token OR branch
    /// containing `+` (no whitespace) compresses to substring of the
    /// joined form. That's a tradeoff to keep parsing simple.
    func testPrecedence_v1_PlusInORBranchCompressesToSubstring() throws {
        let ast = try PhraseQuery.parse("a|b+c", caseSensitive: false)
        XCTAssertEqual(ast.groups.count, 1, "Single OR group.")
        XCTAssertEqual(ast.groups[0].needles.count, 2)
        // The `b+c` branch collapses to a substring needle "b c".
        var sawA = false
        var sawBC = false
        for n in ast.groups[0].needles {
            if case .term(let t, _) = n {
                if t == "a" { sawA = true }
                if t == "b c" { sawBC = true }
            }
        }
        XCTAssertTrue(sawA)
        XCTAssertTrue(sawBC)
    }

    // MARK: - Edge cases

    func testEmptyInput() throws {
        let ast = try PhraseQuery.parse("", caseSensitive: false)
        XCTAssertTrue(ast.isEmpty)
    }

    func testWhitespaceOnly() throws {
        let ast = try PhraseQuery.parse("   ", caseSensitive: false)
        XCTAssertTrue(ast.isEmpty)
    }

    func testStrayOR() throws {
        // Bare `OR` at start or end should not crash, and should not
        // produce a malformed group.
        let ast1 = try PhraseQuery.parse("OR cactus", caseSensitive: false)
        // "OR cactus" reads as: empty branch + "cactus" branch. The
        // empty branch drops; we keep just one needle. Whether this
        // ends up as a 1-group/1-needle AST or stays as an OR group is
        // a parser detail; we just need it not to crash and to match
        // bodies containing "cactus".
        XCTAssertTrue(ast1.matches(body: "the cactus", caseSensitive: false))

        let ast2 = try PhraseQuery.parse("cactus OR", caseSensitive: false)
        XCTAssertTrue(ast2.matches(body: "the cactus", caseSensitive: false))
    }

    func testUnicodeWordBoundary() throws {
        // NSRegularExpression's \b is Unicode-aware. Emoji and CJK
        // characters form their own runs; ASCII letters are word chars.
        let ast = try PhraseQuery.parse("cat", caseSensitive: false)
        XCTAssertTrue(ast.matches(body: "🐱 cat here", caseSensitive: false))
        XCTAssertFalse(ast.matches(body: "category", caseSensitive: false))
    }

    // MARK: - longestLiteralFragment

    func testLongestLiteralFragment_literalRegex() {
        XCTAssertEqual(MessageSearch.longestLiteralFragment(of: "cact"), "cact")
    }

    func testLongestLiteralFragment_withMetachar() {
        XCTAssertEqual(MessageSearch.longestLiteralFragment(of: "cact.*"), "cact")
        // Tie between "hello" and "world" — implementation returns the
        // first when lengths match. Both are valid coarse anchors.
        let either = MessageSearch.longestLiteralFragment(of: "(hello)world")
        XCTAssertTrue(either == "hello" || either == "world",
                      "Expected 'hello' or 'world', got \(either ?? "nil")")
        // A clear winner: "category" beats "x".
        XCTAssertEqual(MessageSearch.longestLiteralFragment(of: "x|category"), "category")
    }

    func testLongestLiteralFragment_alternation() {
        // Alternation kills the run.
        XCTAssertEqual(MessageSearch.longestLiteralFragment(of: "abc|def"), "abc")
    }

    func testLongestLiteralFragment_anchorsOnly() {
        XCTAssertNil(MessageSearch.longestLiteralFragment(of: "^$"))
        XCTAssertNil(MessageSearch.longestLiteralFragment(of: ".+"))
    }

    func testLongestLiteralFragment_escape() {
        // Escapes consume both chars, so `a\.b` has runs "a" and "b".
        // The longer is whichever; both are length 1.
        let frag = MessageSearch.longestLiteralFragment(of: "a\\.b")
        XCTAssertTrue(frag == "a" || frag == "b")
    }

    // MARK: - parseNeedles legacy shim

    func testLegacyParseNeedlesStillReturnsStrings() {
        // The shim hands back term-only strings, lowercased by default.
        XCTAssertEqual(
            MessageSearch.parseNeedles("cactus+water"),
            ["cactus", "water"]
        )
    }

    func testLegacyParseNeedlesPreserveCase() {
        XCTAssertEqual(
            MessageSearch.parseNeedles("Henry+Cactus", preserveCase: true),
            ["Henry", "Cactus"]
        )
    }
}
