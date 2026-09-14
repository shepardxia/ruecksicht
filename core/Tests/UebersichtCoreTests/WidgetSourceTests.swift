import XCTest
@testable import UebersichtCore

final class RefreshFrequencyTests: XCTestCase {
    func testReadsAPlainNumberAsMilliseconds() {
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: 5000"), .every(5))
    }

    func testReadsAnExportedConstant() {
        XCTAssertEqual(
            WidgetSource.refreshFrequency(in: "export const refreshFrequency = 2000;"),
            .every(2)
        )
    }

    func testReadsTheMsShorthand() {
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: '10s'"), .every(10))
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: \"2.5 hrs\""), .every(9000))
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: '1d'"), .every(86400))
    }

    func testEvaluatesProductsAndSumsOfLiterals() {
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: 5 * 60 * 1000"), .every(300))
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: 1000 + 500"), .every(1.5))
    }

    func testFalseMeansNever() {
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: false"), .never)
    }

    /// Anything the scan cannot evaluate has to stay unreadable rather than
    /// guess: an interval hoisted wrong runs a widget's command at the wrong
    /// rate forever, while an unreadable one just keeps its timer on the page.
    func testAnythingElseIsUnreadable() {
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: interval"), .unreadable)
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: 60 * rate"), .unreadable)
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "refreshFrequency: 0"), .unreadable)
        XCTAssertEqual(WidgetSource.refreshFrequency(in: "export const command = 'date'"), .unreadable)
    }
}

final class LiteralCommandTests: XCTestCase {
    func testReadsAnExportedCommand() {
        XCTAssertEqual(WidgetSource.literalCommand(in: "export const command = \"date\";"), "date")
        XCTAssertEqual(WidgetSource.literalCommand(in: "export var command = 'uptime'"), "uptime")
        XCTAssertEqual(WidgetSource.literalCommand(in: "export let command = `whoami`"), "whoami")
    }

    func testReadsAClassicObjectLiteral() {
        XCTAssertEqual(WidgetSource.literalCommand(in: "command: 'echo hi'"), "echo hi")
    }

    func testUnescapesOnlyWhatChangesMeaning() {
        XCTAssertEqual(
            WidgetSource.literalCommand(in: #"export const command = "echo \"hi\"""#),
            "echo \"hi\""
        )
        XCTAssertEqual(
            WidgetSource.literalCommand(in: #"export const command = "grep \d""#),
            #"grep \d"#
        )
    }

    /// A function command closes over the page, so there is nothing to hoist.
    func testRefusesAnythingButAStringLiteral() {
        XCTAssertNil(WidgetSource.literalCommand(in: "export const command = (dispatch) => run('date')"))
        XCTAssertNil(WidgetSource.literalCommand(in: "export const command = ''"))
        XCTAssertNil(WidgetSource.literalCommand(in: "export const render = () => null"))
    }
}

final class ScheduleTests: XCTestCase {
    func testHoistsAWidgetThatSaysBothThings() throws {
        let path = try write("export const command = 'date';\nexport const refreshFrequency = 3000;\n")
        let schedule = try XCTUnwrap(WidgetSource.schedule(forSourceAt: path))
        XCTAssertEqual(schedule.command, "date")
        XCTAssertEqual(schedule.interval, 3)
    }

    func testHoistsNothingWhenEitherHalfIsUnreadable() throws {
        XCTAssertNil(WidgetSource.schedule(
            forSourceAt: try write("export const command = 'date';\nexport const refreshFrequency = false;\n")
        ))
        XCTAssertNil(WidgetSource.schedule(
            forSourceAt: try write("export const command = (d) => d();\nexport const refreshFrequency = 1000;\n")
        ))
        XCTAssertNil(WidgetSource.schedule(forSourceAt: "/nonexistent/widget.jsx"))
    }

    private func write(_ source: String, line: UInt = #line) throws -> String {
        let path = NSTemporaryDirectory() + "ubtest-\(line)-\(UUID().uuidString).jsx"
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }
}
