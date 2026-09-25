import XCTest
@testable import OrbitCore

final class TalisReadingListTests: XCTestCase {
    static let base = "https://rl.talis.com/3/exeter"
    static let rdfType = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    static let seq = "http://www.w3.org/1999/02/22-rdf-syntax-ns#_"
    static let rl = "http://purl.org/vocab/resourcelist/schema#"

    static func uri(_ s: String) -> String { #"[{"type":"uri","value":"\#(s)"}]"# }
    static func lit(_ s: String) -> String { #"[{"type":"literal","value":"\#(s)"}]"# }

    static let rdfJSON: String = {
        let b = base, t = rdfType, s = seq, r = rl
        return """
        {
          "\(b)/lists/L1": {"\(t)": \(uri(r + "List")), "\(s)1": \(uri(b + "/sections/S1")), "\(s)2": \(uri(b + "/sections/S2"))},
          "\(b)/sections/S1": {"\(t)": \(uri(r + "Section")), "http://rdfs.org/sioc/spec/name": \(lit("Week 1: Introduction")),
                               "\(s)1": \(uri(b + "/items/I1")), "\(s)2": \(uri(b + "/items/I2"))},
          "\(b)/sections/S2": {"\(t)": \(uri(r + "Section")), "http://rdfs.org/sioc/spec/name": \(lit("Week 3 - Regression")),
                               "\(s)1": \(uri(b + "/items/I3"))},
          "\(b)/items/I1": {"\(t)": \(uri(r + "Item")), "\(r)resource": \(uri(b + "/resources/R1")),
                            "\(r)importance": \(uri("http://readinglists.exeter.ac.uk/config/importance10"))},
          "\(b)/items/I2": {"\(t)": \(uri(r + "Item")), "\(r)resource": \(uri(b + "/resources/R2")),
                            "\(r)importance": \(uri("http://readinglists.exeter.ac.uk/config/importance20"))},
          "\(b)/items/I3": {"\(t)": \(uri(r + "Item")), "\(r)resource": \(uri(b + "/resources/R3"))},
          "\(b)/resources/R1": {"http://purl.org/dc/terms/title": \(lit("Business Analytics: Data Analysis &amp; Decision Making"))},
          "\(b)/resources/R2": {"http://purl.org/dc/terms/title": \(lit("Naked Statistics"))},
          "\(b)/resources/R3": {"http://purl.org/dc/terms/title": \(lit("Regression basics")),
                                "http://purl.org/ontology/bibo/doi": \(lit("10.1000/xyz"))},
          "http://readinglists.exeter.ac.uk/config/importance10": {"http://www.w3.org/2000/01/rdf-schema#label": \(lit("Essential"))},
          "http://readinglists.exeter.ac.uk/config/importance20": {"http://www.w3.org/2000/01/rdf-schema#label": \(lit("Recommended"))}
        }
        """
    }()

    static let html = """
    <html><body><h1>BEM2031 Reading list</h1>
    <h2 class="sectionHeading">Week 2: Probability</h2>
    <ul>
      <li class="item" id="item_ABC"><a class="itemLink" href="https://rl.talis.com/3/exeter/items/ABC.html">Probability for Dummies</a>
        <span class="importance">Essential</span></li>
      <li class="item"><a href="/3/exeter/items/DEF.html">Further &amp; Deeper</a> <span>Further reading</span></li>
    </ul>
    <h2>Week 4</h2>
    <ul><li class="list-item item"><span class="title">Stats Book</span> <span>Recommended</span></li></ul>
    </body></html>
    """

    func testParsesRDFJSON() throws {
        let entries = try TalisReadingList.parseRDFJSON(Data(Self.rdfJSON.utf8), moduleCode: "BEM2031")
        XCTAssertEqual(entries.map(\.item.title), ["Business Analytics: Data Analysis & Decision Making", "Naked Statistics", "Regression basics"])
        XCTAssertEqual(entries.map(\.importance), [.essential, .recommended, .unknown])
        XCTAssertEqual(entries.map(\.item.essential), [true, false, false])
        XCTAssertEqual(entries.map(\.item.week), [1, 1, 3])
        XCTAssertEqual(entries[2].item.url, "https://doi.org/10.1000/xyz")
        XCTAssertEqual(entries[0].item.id, "talis-I1")
        XCTAssertEqual(entries[0].item.moduleCode, "BEM2031")
    }

    func testParsesHTML() {
        let entries = TalisReadingList.parseHTML(Self.html, moduleCode: "BEM2031",
                                                 baseURL: URL(string: "https://rl.talis.com/3/exeter/lists/L1.html"))
        XCTAssertEqual(entries.map(\.item.title), ["Probability for Dummies", "Further & Deeper", "Stats Book"])
        XCTAssertEqual(entries.map(\.importance), [.essential, .further, .recommended])
        XCTAssertEqual(entries.map(\.item.week), [2, 2, 4])
        XCTAssertEqual(entries[1].item.url, "https://rl.talis.com/3/exeter/items/DEF.html")
        XCTAssertEqual(entries[0].item.id, "talis-ABC")
    }

    func testFetchPrefersJSONThenFallsBackToHTML() async throws {
        let listURL = URL(string: "https://rl.talis.com/3/exeter/lists/L1.html?lang=en-GB")!
        XCTAssertEqual(TalisReadingList.urls(for: listURL).json.absoluteString, "https://rl.talis.com/3/exeter/lists/L1.json")

        let jsonOK = UniStubTransport { req, _ in
            req.url!.path.hasSuffix(".json") ? (200, Self.rdfJSON) : (500, "")
        }
        let viaJSON = try await TalisReadingList(http: HTTPClient(transport: jsonOK)).fetch(listURL: listURL, moduleCode: "BEM2031")
        XCTAssertEqual(viaJSON.count, 3)

        let htmlOnly = UniStubTransport { req, _ in
            req.url!.path.hasSuffix(".json") ? (404, "Not found") : (200, Self.html)
        }
        let viaHTML = try await TalisReadingList(http: HTTPClient(transport: htmlOnly)).fetch(listURL: listURL, moduleCode: "BEM2031")
        XCTAssertEqual(viaHTML.count, 3)
    }

    func testWeekParsing() {
        XCTAssertEqual(TalisReadingList.week(in: "Week 3"), 3)
        XCTAssertEqual(TalisReadingList.week(in: "Wk 11: Ethics"), 11)
        XCTAssertNil(TalisReadingList.week(in: "Core texts"))
    }
}
