import XCTest
@testable import OrbitCore

final class HTMLToTextTests: XCTestCase {
    func testStripsScriptsStylesAndKeepsBlockBreaks() {
        let html = """
        <html><head><style>p { color: red }</style><title>Ignore me</title></head>
        <body><p>Hello&nbsp;there &amp; welcome</p><div>Line<br>two</div>
        <ul><li>One</li><li>Two</li></ul><script type="text/javascript">alert("<p>no</p>")</script>
        It&#39;s &#x2014; done &lt;3</body></html>
        """
        XCTAssertEqual(HTMLToText.convert(html),
                       "Hello there & welcome\n\nLine\ntwo\n\n• One\n• Two\n\nIt's — done <3")
    }

    func testCommentsAttributesAndLooseAngles() {
        let html = #"<!-- hidden --><a href="x>y" title='a > b'>Link</a> if a < b &unknown; &pound;5"#
        XCTAssertEqual(HTMLToText.convert(html), "Link if a < b &unknown; £5")
    }

    func testCollapsesWhitespaceAndUppercaseTags() {
        let html = "<P>  lots\n\n   of\t space </P><BR/><TABLE><TR><TD>a</TD><TD>b</TD></TR></TABLE>"
        XCTAssertEqual(HTMLToText.convert(html), "lots of space\n\na b")
    }

    func testDecodeEntitiesOnly() {
        XCTAssertEqual(HTMLToText.decodeEntities("Tom &amp; Jerry&#39;s &quot;show&quot;"), "Tom & Jerry's \"show\"")
    }
}
