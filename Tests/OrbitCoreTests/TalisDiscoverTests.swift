import XCTest
@testable import OrbitCore

final class TalisDiscoverTests: XCTestCase {
    func testFindsListsInRDFJSONAndHTML() {
        let json = #"{"http:\/\/exeter.rl.talis.com\/modules\/bee1022":{"x":[{"value":"http:\/\/exeter.rl.talis.com\/lists\/1A2B-3C4D","type":"uri"}]}}"#
        XCTAssertEqual(TalisReadingList.listURLs(in: json, tenant: "exeter").map(\.absoluteString),
                       ["http://exeter.rl.talis.com/lists/1A2B-3C4D"])
        let html = #"<a href="https://rl.talis.com/3/exeter/lists/ABCD-1234.html">List</a>"#
        XCTAssertEqual(TalisReadingList.listURLs(in: html, tenant: "exeter").map(\.absoluteString),
                       ["https://rl.talis.com/3/exeter/lists/ABCD-1234"])
    }
}
