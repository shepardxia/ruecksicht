import XCTest
@testable import UebersichtCore

final class StaticFileTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "ub-static-\(UUID().uuidString).gif"
        FileManager.default.createFile(atPath: path, contents: Data("first".utf8))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func request(ifNoneMatch: String? = nil) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/x.gif", headers: ifNoneMatch.map { ["if-none-match": $0] } ?? [:], body: Data())
    }

    func testServesTheFileWithAValidator() throws {
        let response = try XCTUnwrap(HTTPResponse.file(at: path, for: request()))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "image/gif")
        XCTAssertEqual(response.body, Data("first".utf8))
        XCTAssertNotNil(response.headers["ETag"])
        XCTAssertEqual(response.headers["Cache-Control"], "no-cache")
    }

    func testAnswersAMatchingValidatorWithoutTheBody() throws {
        let etag = try XCTUnwrap(HTTPResponse.file(at: path, for: request())?.headers["ETag"])
        let response = try XCTUnwrap(HTTPResponse.file(at: path, for: request(ifNoneMatch: etag)))
        XCTAssertEqual(response.status, 304)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(response.headers["ETag"], etag)
    }

    func testAnEditedFileNoLongerMatches() throws {
        let etag = try XCTUnwrap(HTTPResponse.file(at: path, for: request())?.headers["ETag"])
        try Data("second, and longer".utf8).write(to: URL(fileURLWithPath: path))
        let response = try XCTUnwrap(HTTPResponse.file(at: path, for: request(ifNoneMatch: etag)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("second, and longer".utf8))
    }

    func testFollowsASymlinkToTheFile() throws {
        let link = path + ".link.gif"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertEqual(HTTPResponse.file(at: link, for: request())?.body, Data("first".utf8))
    }

    func testADirectoryOrAMissingFileIsNotServed() {
        XCTAssertNil(HTTPResponse.file(at: NSTemporaryDirectory(), for: request()))
        XCTAssertNil(HTTPResponse.file(at: path + ".missing", for: request()))
    }
}
