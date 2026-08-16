import XCTest
@testable import Hourglass

final class LeaderboardShareCopyTests: XCTestCase {
    func testOrdinalSuffixes() {
        let cases = [
            1: "1st", 2: "2nd", 3: "3rd", 4: "4th",
            11: "11th", 12: "12th", 13: "13th",
            21: "21st", 22: "22nd", 23: "23rd", 111: "111th"
        ]
        for (rank, expected) in cases {
            XCTAssertEqual(LeaderboardShareCopy.ordinal(rank), expected)
        }
    }

    func testPersonMessageIncludesTimeframeAndHourglassLink() {
        XCTAssertEqual(
            LeaderboardShareCopy.message(
                rank: 2,
                kind: .person,
                timeframe: "the last 30 days"
            ),
            "you were my 2nd most texted person of the last 30 days :)\n\nhttps://ammesatyajit.github.io/hourglass/"
        )
    }

    func testGroupMessageUsesGroupCopy() {
        XCTAssertEqual(
            LeaderboardShareCopy.message(
                rank: 11,
                kind: .groupChat,
                timeframe: "all time"
            ),
            "yall were my 11th most texted group chat of all time :)\n\nhttps://ammesatyajit.github.io/hourglass/"
        )
    }
}
