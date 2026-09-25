import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct InkPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// An axis-aligned box in page px.
public struct InkRect: Codable, Hashable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public init?(points: [InkPoint]) {
        guard let f = points.first else { return nil }
        var r = InkRect(minX: f.x, minY: f.y, maxX: f.x, maxY: f.y)
        for p in points.dropFirst() {
            r.minX = min(r.minX, p.x); r.minY = min(r.minY, p.y)
            r.maxX = max(r.maxX, p.x); r.maxY = max(r.maxY, p.y)
        }
        self = r
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midY: Double { (minY + maxY) / 2 }

    public func union(_ o: InkRect) -> InkRect {
        InkRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    public static func union(_ rects: [InkRect]) -> InkRect? {
        guard let f = rects.first else { return nil }
        return rects.dropFirst().reduce(f) { $0.union($1) }
    }
}

public struct InkBrush: Codable, Hashable, Sendable {
    /// "#RRGGBB".
    public var color: String
    /// Pen width in page px.
    public var width: Double
    /// 0 (opaque) to 1 (invisible). Highlighters are partly transparent.
    public var transparency: Double
    public var isHighlighter: Bool { transparency > 0.3 }

    public init(color: String = "#000000", width: Double = 2, transparency: Double = 0) {
        self.color = color; self.width = width; self.transparency = transparency
    }
}

public struct InkStroke: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var points: [InkPoint]
    /// Normalised 0–1 pen pressure per point, if the trace has a force channel.
    public var pressure: [Double]?
    public var brush: InkBrush
    /// The enclosing `<traceGroup>`'s id, if any.
    public var groupID: String?

    public init(id: String, points: [InkPoint], pressure: [Double]? = nil, brush: InkBrush = InkBrush(),
                groupID: String? = nil) {
        self.id = id; self.points = points; self.pressure = pressure; self.brush = brush; self.groupID = groupID
    }

    public var bounds: InkRect { InkRect(points: points) ?? InkRect(minX: 0, minY: 0, maxX: 0, maxY: 0) }

    /// Total path length in px.
    public var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
}

public struct InkDocument: Codable, Hashable, Sendable {
    public var strokes: [InkStroke]
    public init(strokes: [InkStroke]) { self.strokes = strokes }
    public var bounds: InkRect? { InkRect.union(strokes.filter { !$0.points.isEmpty }.map(\.bounds)) }
}

public enum InkMLError: Error, CustomStringConvertible, Sendable {
    case invalidXML(String)
    public var description: String {
        switch self { case .invalidXML(let why): "InkML isn't valid XML: \(why)" }
    }
}

/// Parses W3C InkML as produced by OneNote (`includeInkML=true`).
///
/// Supports `<definitions>` with `<context>`/`<inkSource>`/`<traceFormat>` (any channel
/// order, X/Y/F used), `<brush>` properties, nested `<traceGroup>`s with inherited
/// `brushRef`/`contextRef`, channel resolution, and the trace value grammar:
/// explicit values, `'` first differences, `"` second differences, `!` explicit,
/// `*` repeat, `?` missing, and values run together without spaces ("12'3-4").
public struct InkMLParser: Sendable {
    /// Page px per InkML unit. nil works it out from the channel units
    /// (himetric → 96/2540, mm, cm, in, px); OneNote uses himetric.
    public var pixelsPerUnit: Double?
    /// Added after scaling, to line strokes up with HTML positions if needed.
    public var offset: InkPoint

    public static let himetricToPixels = 96.0 / 2540.0

    public init(pixelsPerUnit: Double? = nil, offset: InkPoint = InkPoint(x: 0, y: 0)) {
        self.pixelsPerUnit = pixelsPerUnit; self.offset = offset
    }

    public func parse(_ xml: String) throws -> InkDocument {
        try parse(Data(xml.utf8))
    }

    public func parse(_ data: Data) throws -> InkDocument {
        let delegate = InkMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw InkMLError.invalidXML(parser.parserError.map { "\($0)" } ?? "unknown error")
        }
        return InkDocument(strokes: delegate.traces.enumerated().compactMap { build($0.element, index: $0.offset, delegate) })
    }

    // MARK: Building strokes

    func build(_ t: InkMLDelegate.RawTrace, index: Int, _ d: InkMLDelegate) -> InkStroke? {
        let format = d.format(forContext: t.contextRef) ?? .default
        let rows = Self.decode(t.text, channels: format.channels.count)
        guard !rows.isEmpty else { return nil }
        let xi = format.channels.firstIndex { $0.name == "X" } ?? 0
        let yi = format.channels.firstIndex { $0.name == "Y" } ?? 1
        let fi = format.channels.firstIndex { $0.name == "F" }
        let sx = scale(for: format.channels[ifPresent: xi]), sy = scale(for: format.channels[ifPresent: yi])
        let points = rows.map { r in
            InkPoint(x: (r[ifPresent: xi] ?? 0) * sx + offset.x, y: (r[ifPresent: yi] ?? 0) * sy + offset.y)
        }
        var pressure: [Double]?
        if let fi, let ch = format.channels[ifPresent: fi] {
            let maxF = ch.max ?? rows.compactMap { $0[ifPresent: fi] }.max() ?? 1
            pressure = rows.map { max(0, min(1, ($0[ifPresent: fi] ?? 0) / max(maxF, 1))) }
        }
        var brush = InkBrush()
        if let ref = t.brushRef, let props = d.brushes[Self.stripHash(ref)] {
            let unitScale = pixelsPerUnit ?? Self.pixelsPerUnit(forUnits: props["width.units"] ?? format.channels[ifPresent: xi]?.units)
            if let w = props["width"].flatMap(Double.init) { brush.width = w * unitScale }
            if let c = props["color"] { brush.color = c.hasPrefix("#") ? c.uppercased() : c }
            if let tr = props["transparency"].flatMap(Double.init) { brush.transparency = tr > 1 ? tr / 255 : tr }
        }
        return InkStroke(id: t.id ?? "trace\(index)", points: points, pressure: pressure, brush: brush, groupID: t.groupID)
    }

    func scale(for channel: InkMLDelegate.Channel?) -> Double {
        let resolution = channel?.resolution ?? 1
        let perUnit = pixelsPerUnit ?? Self.pixelsPerUnit(forUnits: channel?.resolutionUnits ?? channel?.units)
        return perUnit / (resolution == 0 ? 1 : resolution)
    }

    static func pixelsPerUnit(forUnits units: String?) -> Double {
        switch units?.lowercased().replacingOccurrences(of: "1/", with: "") {
        case "himetric", nil: himetricToPixels
        case "mm": 96 / 25.4
        case "cm": 96 / 2.54
        case "in": 96
        case "pt": 96.0 / 72.0
        case "px", "dev": 1
        default: himetricToPixels
        }
    }

    static func stripHash(_ s: String) -> String { s.hasPrefix("#") ? String(s.dropFirst()) : s }

    // MARK: Trace value grammar

    enum Mode { case explicit, first, second }
    enum Value { case number(Double, Mode?), repeatPrevious(Mode?), missing }

    /// Decodes a trace's text into rows of absolute channel values.
    static func decode(_ text: String, channels: Int) -> [[Double]] {
        let n = max(1, channels)
        var modes = [Mode](repeating: .explicit, count: n)
        var last = [Double?](repeating: nil, count: n)
        var velocity = [Double](repeating: 0, count: n)
        var rows: [[Double]] = []
        for pointText in text.split(separator: ",") {
            let values = tokenize(pointText)
            if values.isEmpty { continue }
            var row = [Double](repeating: 0, count: n)
            for c in 0..<n {
                let v: Value = c < values.count ? values[c] : .missing
                var raw: Double?
                switch v {
                case .number(let x, let m): if let m { modes[c] = m }; raw = x
                case .repeatPrevious(let m): if let m { modes[c] = m }; raw = modes[c] == .explicit ? last[c] : nil
                case .missing: raw = nil
                }
                let prev = last[c]
                let value: Double
                switch (modes[c], raw) {
                case (_, nil):
                    // Missing or "*": keep going the same way.
                    value = (prev ?? 0) + (modes[c] == .explicit ? 0 : velocity[c])
                case (.explicit, let x?):
                    value = x
                case (.first, let dx?):
                    value = (prev ?? 0) + dx
                case (.second, let ddx?):
                    value = (prev ?? 0) + velocity[c] + ddx
                }
                velocity[c] = prev.map { value - $0 } ?? 0
                last[c] = value
                row[c] = value
            }
            rows.append(row)
        }
        return rows
    }

    /// Splits one point ("1 2 3", "'12'-3", "\"1\"2", "!5 7") into values.
    static func tokenize<S: StringProtocol>(_ s: S) -> [Value] {
        var out: [Value] = []
        var number = ""
        var pendingMode: Mode?
        func flush() {
            guard !number.isEmpty else { return }
            if let d = Double(number) {
                out.append(.number(d, pendingMode))
            } else if number == "T" || number == "F" {
                out.append(.number(number == "T" ? 1 : 0, pendingMode))
            }
            number = ""; pendingMode = nil
        }
        for ch in s {
            switch ch {
            case " ", "\t", "\n", "\r":
                flush()
            case "'", "\"", "!":
                flush()
                pendingMode = ch == "'" ? .first : ch == "\"" ? .second : .explicit
            case "-", "+":
                // A sign starts a new number unless it follows an exponent.
                if !number.isEmpty, !(number.last == "e" || number.last == "E") { flush() }
                number.append(ch)
            case ".":
                if number.contains(".") { flush() }
                number.append(ch)
            case "*":
                flush(); out.append(.repeatPrevious(pendingMode)); pendingMode = nil
            case "?":
                flush(); out.append(.missing); pendingMode = nil
            case "T", "F":
                flush(); number = String(ch); flush()
            default:
                if ch.isNumber || ((ch == "e" || ch == "E") && number.contains(where: \.isNumber)) {
                    number.append(ch)
                } else {
                    flush()
                }
            }
        }
        flush()
        return out
    }
}

// MARK: - XML delegate

final class InkMLDelegate: NSObject, XMLParserDelegate {
    struct Channel {
        var name: String
        var units: String?
        var max: Double?
        var resolution: Double?
        var resolutionUnits: String?
    }
    struct Format {
        var channels: [Channel]
        static let `default` = Format(channels: [Channel(name: "X"), Channel(name: "Y")])
    }
    struct RawTrace {
        var id: String?
        var contextRef: String?
        var brushRef: String?
        var groupID: String?
        var text: String
    }
    struct Group { var id: String?; var brushRef: String?; var contextRef: String? }

    var traces: [RawTrace] = []
    /// Brush properties by brush id ("width", "width.units", "color", "transparency").
    var brushes: [String: [String: String]] = [:]
    /// Formats keyed by traceFormat, inkSource and context ids.
    var formats: [String: Format] = [:]
    var contextLinks: [String: String] = [:]
    var firstFormat: Format?

    private var groups: [Group] = []
    private var currentTrace: RawTrace?
    private var currentBrush: String?
    private var currentChannels: [Channel]?
    private var formatOwners: [String] = []
    private var bodyContextRef: String?
    private var bodyBrushRef: String?

    func format(forContext ref: String?) -> Format? {
        guard var key = ref.map(InkMLParser.stripHash) else { return firstFormat }
        var seen: Set<String> = []
        while formats[key] == nil, let next = contextLinks[key], !seen.contains(key) {
            seen.insert(key); key = next
        }
        return formats[key] ?? firstFormat
    }

    static func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        let id = a["xml:id"] ?? a["id"]
        switch Self.local(elementName) {
        case "context":
            formatOwners.append(id ?? "")
            if let id {
                for ref in [a["inkSourceRef"], a["traceFormatRef"]].compactMap({ $0 }) {
                    contextLinks[id] = InkMLParser.stripHash(ref)
                }
            } else {
                // A body-level <context> changes the current context/brush for later traces.
                if let r = a["contextRef"] { bodyContextRef = r }
                if let r = a["brushRef"] { bodyBrushRef = r }
            }
        case "inkSource":
            formatOwners.append(id ?? "")
        case "traceFormat":
            formatOwners.append(id ?? "")
            currentChannels = []
        case "channel":
            currentChannels?.append(Channel(name: a["name"] ?? "?", units: a["units"],
                                            max: a["max"].flatMap(Double.init)))
        case "channelProperty":
            guard let chName = a["channel"], a["name"] == "resolution",
                  let value = a["value"].flatMap(Double.init) else { break }
            // channelProperties come after the traceFormat; patch the owner's format.
            for owner in formatOwners where !owner.isEmpty {
                guard var f = formats[owner], let i = f.channels.firstIndex(where: { $0.name == chName }) else { continue }
                f.channels[i].resolution = value
                f.channels[i].resolutionUnits = a["units"]
                formats[owner] = f
            }
        case "brush":
            currentBrush = id ?? "brush\(brushes.count)"
            brushes[currentBrush!] = brushes[currentBrush!] ?? [:]
        case "brushProperty":
            guard let b = currentBrush, let name = a["name"], let value = a["value"] else { break }
            brushes[b]?[name] = value
            if let units = a["units"] { brushes[b]?[name + ".units"] = units }
        case "traceGroup":
            groups.append(Group(id: id, brushRef: a["brushRef"], contextRef: a["contextRef"]))
        case "trace":
            if a["type"] == "penUp" { currentTrace = nil; break }
            currentTrace = RawTrace(
                id: id,
                contextRef: a["contextRef"] ?? groups.reversed().compactMap(\.contextRef).first ?? bodyContextRef,
                brushRef: a["brushRef"] ?? groups.reversed().compactMap(\.brushRef).first ?? bodyBrushRef,
                groupID: groups.last?.id, text: "")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentTrace?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch Self.local(elementName) {
        case "traceFormat":
            let f = Format(channels: currentChannels ?? [])
            currentChannels = nil
            guard !f.channels.isEmpty else { break }
            if firstFormat == nil { firstFormat = f }
            for owner in formatOwners where !owner.isEmpty && formats[owner] == nil { formats[owner] = f }
            formatOwners.removeLast()
        case "context", "inkSource":
            if !formatOwners.isEmpty { formatOwners.removeLast() }
        case "brush":
            currentBrush = nil
        case "traceGroup":
            if !groups.isEmpty { groups.removeLast() }
        case "trace":
            if let t = currentTrace { traces.append(t) }
            currentTrace = nil
        default:
            break
        }
    }
}

fileprivate extension Array {
    subscript(ifPresent i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
