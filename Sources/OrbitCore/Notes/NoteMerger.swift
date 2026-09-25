import Foundation

/// Which handwriting a typed block summarises.
public struct NoteLink: Codable, Hashable, Sendable {
    /// Index of the `.typed` segment in `LectureNote.segments`.
    public var typedSegment: Int
    /// Indices of the handwriting/maths segments it summarises.
    public var handwritingSegments: [Int]
    public var regionIDs: [String]
    /// Mean share of the typed lines' words found in the handwriting (0–1).
    public var coverage: Double
    /// How many of the block's lines were found in the handwriting.
    public var alignedLines: Int

    public init(typedSegment: Int, handwritingSegments: [Int], regionIDs: [String], coverage: Double, alignedLines: Int) {
        self.typedSegment = typedSegment; self.handwritingSegments = handwritingSegments
        self.regionIDs = regionIDs; self.coverage = coverage; self.alignedLines = alignedLines
    }
}

/// Links between a note's key points and its full lecture detail. Stored beside
/// the `LectureNote` so the model type stays simple.
public struct NoteLinkMap: Codable, Hashable, Sendable {
    public var noteID: String
    public var links: [NoteLink]

    public init(noteID: String, links: [NoteLink] = []) { self.noteID = noteID; self.links = links }

    /// Handwriting segments summarised by a typed segment.
    public func handwriting(forTyped index: Int) -> [Int] {
        links.filter { $0.typedSegment == index }.flatMap(\.handwritingSegments)
    }

    /// Typed segments that summarise a handwriting segment.
    public func typed(forHandwriting index: Int) -> [Int] {
        links.filter { $0.handwritingSegments.contains(index) }.map(\.typedSegment)
    }
}

/// Where each segment came from on the page.
public struct NoteLayoutItem: Codable, Hashable, Sendable {
    public var segmentIndex: Int
    public var top: Double?
    public var left: Double?
    /// Graph `data-id` of the typed outline.
    public var blockDataID: String?
    public var regionID: String?
    /// Image resource URL for pictures/diagrams from the HTML.
    public var imageSrc: String?
}

/// A page merged into one note, plus everything the app needs to show and link it.
public struct MergedNote: Sendable {
    public var note: LectureNote
    public var links: NoteLinkMap
    /// One entry per segment, same order.
    public var layout: [NoteLayoutItem]
    /// The OCR'd handwriting (with raw text and images), for learning and review.
    public var handwriting: [TranscribedRegion]
    /// Segments whose confidence is below the merger's threshold.
    public var lowConfidenceSegments: [Int]

    public var needsReview: Bool { !lowConfidenceSegments.isEmpty }
    public var uncertainWords: [String] { note.segments.flatMap(\.uncertainWords) }
}

/// Everything about one page the merger needs.
public struct NotePageInput: Sendable {
    public var id: String
    public var title: String?
    public var notebook: String
    public var section: String
    public var created: Date?
    public var modified: Date?
    public var document: OneNotePageDocument
    public var handwriting: [TranscribedRegion]
    /// AI descriptions of pictures, keyed by `<img src>`.
    public var imageDescriptions: [String: String]

    public init(id: String, title: String? = nil, notebook: String = "", section: String = "",
                created: Date? = nil, modified: Date? = nil, document: OneNotePageDocument,
                handwriting: [TranscribedRegion] = [], imageDescriptions: [String: String] = [:]) {
        self.id = id; self.title = title; self.notebook = notebook; self.section = section
        self.created = created; self.modified = modified; self.document = document
        self.handwriting = handwriting; self.imageDescriptions = imageDescriptions
    }

    public init(fetched: OneNoteFetchedPage, handwriting: [TranscribedRegion], imageDescriptions: [String: String] = [:]) {
        // "Group › Section" when the section sits in a section group.
        let section = fetched.section.map { (($0.groupPath ?? []) + [$0.displayName]).joined(separator: " › ") }
        self.init(id: fetched.page.id, title: fetched.page.title, notebook: fetched.section?.notebookName ?? "",
                  section: section ?? fetched.page.parentSection?.displayName ?? "",
                  created: fetched.page.createdDateTime, modified: fetched.page.lastModifiedDateTime,
                  document: fetched.document, handwriting: handwriting, imageDescriptions: imageDescriptions)
    }
}

/// Builds a `LectureNote` from a page: typed blocks become `.typed` key points,
/// handwriting becomes `.handwriting` full lecture detail (plus `.math` and `.diagram`),
/// all ordered top to bottom as on the page, with typed blocks linked to the handwriting they summarise.
public struct NoteMerger: Sendable {
    public var learner: HandwritingLearner
    public var lowConfidence: Double
    /// Include pictures from the page as `.diagram` segments when they have a description or alt text.
    public var includeImages: Bool

    public init(learner: HandwritingLearner = HandwritingLearner(), lowConfidence: Double = 0.6, includeImages: Bool = true) {
        self.learner = learner; self.lowConfidence = lowConfidence; self.includeImages = includeImages
    }

    struct Item {
        var segment: NoteSegment
        var layout: NoteLayoutItem
        var sortTop: Double
        var seq: Int
    }

    public func merge(_ page: NotePageInput) -> MergedNote {
        var items: [Item] = []
        for b in page.document.blocks {
            switch b.kind {
            case .text:
                items.append(Item(segment: NoteSegment(kind: .typed, text: b.text),
                                  layout: NoteLayoutItem(segmentIndex: 0, top: b.top, left: b.left, blockDataID: b.dataID),
                                  sortTop: b.top ?? .infinity, seq: b.order))
            case .image:
                guard includeImages else { continue }
                let described = b.src.flatMap { page.imageDescriptions[$0] }
                let text = described ?? b.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                items.append(Item(segment: NoteSegment(kind: .diagram, text: "[Image: \(text)]", confidence: described == nil ? 1 : 0.8),
                                  layout: NoteLayoutItem(segmentIndex: 0, top: b.top, left: b.left, blockDataID: b.dataID, imageSrc: b.src),
                                  sortTop: b.top ?? .infinity, seq: b.order))
            case .attachment, .ink:
                continue
            }
        }
        for (ri, region) in page.handwriting.enumerated() {
            for (si, seg) in region.segments.enumerated() {
                let top = region.bounds.map { $0.minY + Double(si) * 0.001 }
                items.append(Item(segment: seg,
                                  layout: NoteLayoutItem(segmentIndex: 0, top: top, left: region.bounds?.minX, regionID: region.regionID),
                                  sortTop: top ?? .infinity, seq: 1_000_000 + ri * 1000 + si))
            }
        }
        items.sort { ($0.sortTop, $0.seq) < ($1.sortTop, $1.seq) }
        let segments = items.map(\.segment)
        let layout = items.enumerated().map { i, item -> NoteLayoutItem in
            var l = item.layout; l.segmentIndex = i; return l
        }

        let title = [page.title, page.document.title].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Untitled page"
        let clues = [title, page.section, page.notebook]
        let modified = page.modified ?? page.created ?? page.document.created ?? Date()
        let note = LectureNote(id: page.id, title: title, notebook: page.notebook, section: page.section,
                               moduleCode: NoteMetadataDetector.moduleCode(in: clues),
                               week: NoteMetadataDetector.week(in: [title, page.section]),
                               created: page.document.created ?? page.created ?? modified, modified: modified,
                               segments: segments)
        let links = link(segments: segments, layout: layout, regions: page.handwriting, noteID: page.id)
        let low = segments.indices.filter { segments[$0].kind != .typed && segments[$0].confidence < lowConfidence }
        return MergedNote(note: note, links: links, layout: layout, handwriting: page.handwriting, lowConfidenceSegments: low)
    }

    /// Aligns each typed segment's lines with the handwriting regions to find what it summarises.
    func link(segments: [NoteSegment], layout: [NoteLayoutItem], regions: [TranscribedRegion], noteID: String) -> NoteLinkMap {
        guard !regions.isEmpty else { return NoteLinkMap(noteID: noteID) }
        let texts = regions.map(\.text)
        var links: [NoteLink] = []
        for (i, seg) in segments.enumerated() where seg.kind == .typed {
            let alignments = learner.align(typed: seg.text, handwriting: texts)
            guard !alignments.isEmpty else { continue }
            let ids = Set(alignments.flatMap(\.regions).map { regions[$0].regionID })
            let hw = layout.indices.filter { j in
                segments[j].kind != .typed && layout[j].regionID.map(ids.contains) == true
            }
            let coverage = alignments.map(\.coverage).reduce(0, +) / Double(alignments.count)
            links.append(NoteLink(typedSegment: i, handwritingSegments: hw,
                                  regionIDs: regions.map(\.regionID).filter(ids.contains),
                                  coverage: coverage, alignedLines: alignments.count))
        }
        return NoteLinkMap(noteID: noteID, links: links)
    }

    /// The full pipeline for one fetched page: group ink into regions, OCR them
    /// (with the page's typed text as a hint), and merge.
    public func build(_ fetched: OneNoteFetchedPage, pipeline: HandwritingPipeline,
                      grouper: InkRegionGrouper = InkRegionGrouper(),
                      imageDescriptions: [String: String] = [:]) async throws -> MergedNote {
        let regions = fetched.ink.map(grouper.regions(from:)) ?? []
        let hint = ([fetched.page.title ?? fetched.document.title] + [String(fetched.document.typedText.prefix(500))])
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let transcribed = try await pipeline.transcribe(regions, hint: hint.isEmpty ? nil : hint)
        return merge(NotePageInput(fetched: fetched, handwriting: transcribed, imageDescriptions: imageDescriptions))
    }
}

extension TranscribedRegion {
    /// This region as input for `HandwritingLearner.learn(regions:typed:…)` (raw OCR, before corrections).
    public var learnerRegion: HandwritingLearner.Region {
        HandwritingLearner.Region(id: regionID, ocrText: UncertainMarkers.strip(rawText).text, image: image)
    }
}
