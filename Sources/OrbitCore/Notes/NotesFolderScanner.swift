import Foundation
#if canImport(PDFKit) && canImport(CoreGraphics) && canImport(ImageIO)
import PDFKit
import CoreGraphics
#endif

/// Finds note files in a folder the student chooses (e.g. "OneDrive/Orbit Notes Export"),
/// for when the Graph API is blocked and notebooks are exported to PDF instead.
///
/// Picks up `.pdf`, `.md`/`.markdown`, `.txt`, `.png`, `.jpg`/`.jpeg` and `.heic`.
/// OneNote's own `.one` section files are a proprietary binary format and are **not
/// parsed**: they're reported in `unsupported` so the app can suggest exporting to PDF.
public struct NotesFolderScanner: Sendable {
    public enum Kind: String, Codable, Sendable {
        case pdf, markdown, text, image
    }

    public struct Item: Codable, Hashable, Sendable {
        public var url: URL
        public var kind: Kind
        public var modified: Date
        public var size: Int
        /// Path below the root, e.g. "BEM2031/Week 5.pdf". Useful for module/week detection.
        public var relativePath: String
    }

    public struct Result: Sendable {
        public var items: [Item]
        /// `.one` / `.onetoc2` files found (not readable; export them to PDF).
        public var unsupported: [URL]
        /// Pass back as `since` next time.
        public var cursor: Date?
    }

    public var root: URL
    public var recursive: Bool
    public var includeHidden: Bool

    public init(root: URL, recursive: Bool = true, includeHidden: Bool = false) {
        self.root = root; self.recursive = recursive; self.includeHidden = includeHidden
    }

    public static func kind(forExtension ext: String) -> Kind? {
        switch ext.lowercased() {
        case "pdf": .pdf
        case "md", "markdown": .markdown
        case "txt": .text
        case "png", "jpg", "jpeg", "heic": .image
        default: nil
        }
    }

    /// Files modified after `since` (all files when nil), oldest first.
    public func scan(since: Date? = nil) throws -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        var options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let rootPath = root.standardizedFileURL.path
        var items: [Item] = [], unsupported: [URL] = []
        var newest = since
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "one" || ext == "onetoc2" { unsupported.append(url); continue }
            guard let kind = Self.kind(forExtension: ext) else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if let since, modified <= since { continue }
            var rel = url.standardizedFileURL.path
            if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            items.append(Item(url: url, kind: kind, modified: modified, size: values?.fileSize ?? 0, relativePath: rel))
            newest = max(newest ?? modified, modified)
        }
        items.sort { ($0.modified, $0.relativePath) < ($1.modified, $1.relativePath) }
        return Result(items: items, unsupported: unsupported.sorted { $0.path < $1.path }, cursor: newest)
    }

    /// A typed note from a Markdown or text file. Module and week come from the path.
    public static func note(fromText text: String, item: Item, notebook: String = "Notes folder") -> LectureNote {
        let name = item.url.deletingPathExtension().lastPathComponent
        var title = name
        if let first = text.split(separator: "\n").first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        let folders = item.relativePath.split(separator: "/").dropLast().map(String.init)
        let clues = [title, name] + folders.reversed()
        return LectureNote(id: "file:" + item.relativePath, title: title, notebook: notebook,
                           section: folders.last ?? "", moduleCode: NoteMetadataDetector.moduleCode(in: clues),
                           week: NoteMetadataDetector.week(in: clues), created: item.modified, modified: item.modified,
                           segments: [NoteSegment(kind: .typed, text: text.trimmingCharacters(in: .whitespacesAndNewlines))])
    }
}

#if canImport(PDFKit) && canImport(CoreGraphics) && canImport(ImageIO)
/// Renders pages of an exported OneNote PDF to PNGs for `HandwritingPipeline`,
/// and reads any real text the PDF contains (typed notes survive export as text).
public final class PDFPageImageSource {
    public let url: URL
    let document: PDFDocument

    public init?(url: URL) {
        guard let doc = PDFDocument(url: url) else { return nil }
        self.url = url; document = doc
    }

    public var pageCount: Int { document.pageCount }

    /// Selectable text on a page (typed notes); nil for pure ink/scans.
    public func text(page index: Int) -> String? {
        guard let s = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

    /// PNG of one page. `scale` 2 ≈ 144 dpi, which suits handwriting OCR.
    public func renderPage(_ index: Int, scale: CGFloat = 2) -> Data? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // PDFKit maps the media box (and page rotation) into the context itself.
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return AppleImageEncoding.png(image)
    }

    public func renderAll(scale: CGFloat = 2) -> [Data] {
        (0..<pageCount).compactMap { renderPage($0, scale: scale) }
    }
}
#endif
