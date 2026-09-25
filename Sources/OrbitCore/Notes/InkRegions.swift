import Foundation

/// A block of handwriting (a paragraph, an equation, or a drawing) that is
/// rendered and OCR'd on its own, then placed among the typed blocks by `bounds.minY`.
public struct InkRegion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var strokes: [InkStroke]
    /// Line boxes, top to bottom.
    public var lines: [InkRect]
    public var bounds: InkRect

    public init(id: String, strokes: [InkStroke], lines: [InkRect], bounds: InkRect) {
        self.id = id; self.strokes = strokes; self.lines = lines; self.bounds = bounds
    }

    /// Typical line height in px (median), used to scale rendering.
    public var lineHeight: Double {
        let hs = lines.map(\.height).filter { $0 > 0 }.sorted()
        return hs.isEmpty ? max(bounds.height, 1) : hs[hs.count / 2]
    }

    public var features: InkRegionFeatures { InkRegionFeatures(self) }
}

/// Shape statistics that hint whether a region is prose, maths or a drawing.
public struct InkRegionFeatures: Codable, Hashable, Sendable {
    public var strokeCount: Int
    public var lineCount: Int
    /// Share of long, nearly straight strokes (arrows, axes, box sides). Handwritten
    /// words are long too, but their paths wiggle far more than their extent.
    public var longStrokeRatio: Double
    /// Share of strokes taller than 1.8 lines (brackets, integrals, axes).
    public var tallStrokeRatio: Double
    /// Region height divided by (lines × line height). Near 1 for tidy text.
    public var verticalSpread: Double

    public init(_ r: InkRegion) {
        strokeCount = r.strokes.count
        lineCount = r.lines.count
        let h = max(r.lineHeight, 1)
        let n = Double(max(r.strokes.count, 1))
        longStrokeRatio = Double(r.strokes.filter { s in
            let extent = max(s.bounds.width, s.bounds.height)
            return extent > 3 * h && s.length < 1.6 * extent
        }.count) / n
        tallStrokeRatio = Double(r.strokes.filter { $0.bounds.height > 1.8 * h }.count) / n
        verticalSpread = r.bounds.height / (Double(max(r.lines.count, 1)) * h)
    }

    /// Few text lines but big, long strokes: probably a diagram.
    public var looksLikeDiagram: Bool {
        strokeCount >= 3 && (longStrokeRatio > 0.3 || tallStrokeRatio > 0.25 || verticalSpread > 2.5)
    }
}

/// Clusters strokes into lines (by vertical overlap) and lines into regions
/// (by vertical gaps and horizontal overlap).
public struct InkRegionGrouper: Sendable {
    /// Lines further apart than this many line heights start a new region.
    public var paragraphGap: Double
    /// A horizontal gap this many line heights wide splits a line (side-by-side columns).
    public var columnGap: Double
    /// Strokes smaller than this (px) in both directions count as dots, not line evidence.
    public var dotSize: Double
    /// Skip highlighter strokes, which cover text rather than write it.
    public var ignoreHighlighter: Bool

    public init(paragraphGap: Double = 1.1, columnGap: Double = 6, dotSize: Double = 3, ignoreHighlighter: Bool = true) {
        self.paragraphGap = paragraphGap; self.columnGap = columnGap
        self.dotSize = dotSize; self.ignoreHighlighter = ignoreHighlighter
    }

    struct Line {
        var strokes: [Int]
        var box: InkRect
    }

    public func regions(from document: InkDocument) -> [InkRegion] { regions(from: document.strokes) }

    public func regions(from allStrokes: [InkStroke]) -> [InkRegion] {
        let strokes = allStrokes.filter { !$0.points.isEmpty && !(ignoreHighlighter && $0.brush.isHighlighter) }
        guard !strokes.isEmpty else { return [] }
        let boxes = strokes.map(\.bounds)
        let heights = boxes.map(\.height).filter { $0 > dotSize }.sorted()
        let typical = heights.isEmpty ? 10 : max(heights[heights.count / 2], dotSize)

        // 1. Lines: merge the core vertical bands of normal-sized strokes.
        let isCore = boxes.map { $0.height > dotSize || $0.width > dotSize }.enumerated()
            .map { $0.element && boxes[$0.offset].height <= 2.5 * typical }
        var bands: [(lo: Double, hi: Double, members: [Int])] = []
        for i in boxes.indices.filter({ isCore[$0] }).sorted(by: { boxes[$0].midY < boxes[$1].midY }) {
            // Trim ascenders/descenders so neighbouring lines don't touch.
            let b = boxes[i], trim = b.height * 0.2
            let lo = b.minY + trim, hi = b.maxY - trim
            if var last = bands.last, lo <= last.hi {
                last.hi = max(last.hi, hi); last.members.append(i)
                bands[bands.count - 1] = last
            } else {
                bands.append((lo, hi, [i]))
            }
        }
        if bands.isEmpty { bands = [(boxes[0].minY, boxes[0].maxY, [])] }
        // Tall strokes and dots join the band they overlap most (or the nearest).
        for i in boxes.indices where !isCore[i] {
            let b = boxes[i]
            let best = bands.indices.max { a, c in
                score(b, bands[a]) < score(b, bands[c])
            }!
            bands[best].members.append(i)
        }

        // 2. Split each band where there's a wide horizontal gap.
        var lines: [Line] = []
        for band in bands where !band.members.isEmpty {
            let members = band.members.sorted { boxes[$0].minX < boxes[$1].minX }
            var current: [Int] = []
            var right = -Double.infinity
            for i in members {
                if !current.isEmpty, boxes[i].minX - right > columnGap * typical {
                    lines.append(Line(strokes: current, box: InkRect.union(current.map { boxes[$0] })!))
                    current = []
                }
                current.append(i)
                right = max(right, boxes[i].maxX)
            }
            if !current.isEmpty { lines.append(Line(strokes: current, box: InkRect.union(current.map { boxes[$0] })!)) }
        }
        lines.sort { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }

        // 3. Regions: consecutive lines that are close vertically and overlap horizontally.
        var groups: [[Line]] = []
        for line in lines {
            let lh = max(line.box.height, typical)
            if let gi = groups.lastIndex(where: { g in
                let last = g.last!.box
                let gap = line.box.minY - last.maxY
                let overlapX = min(line.box.maxX, last.maxX) - max(line.box.minX, last.minX)
                return gap <= paragraphGap * lh && overlapX > -columnGap * typical
            }) {
                groups[gi].append(line)
            } else {
                groups.append([line])
            }
        }

        return groups.enumerated().map { n, g in
            let idx = g.flatMap(\.strokes).sorted()
            let bounds = InkRect.union(g.map(\.box))!
            return InkRegion(id: "ink-\(n + 1)", strokes: idx.map { strokes[$0] }, lines: g.map(\.box), bounds: bounds)
        }
        .sorted { $0.bounds.minY < $1.bounds.minY }
    }

    /// How well a box fits a band: overlap, or negative distance when apart.
    func score(_ b: InkRect, _ band: (lo: Double, hi: Double, members: [Int])) -> Double {
        let overlap = min(b.maxY, band.hi) - max(b.minY, band.lo)
        return overlap > 0 ? overlap : -abs(b.midY - (band.lo + band.hi) / 2)
    }
}
