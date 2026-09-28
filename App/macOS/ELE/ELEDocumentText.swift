import AppKit
import Foundation
import OrbitCore
import PDFKit

/// Plain text from files downloaded from ELE: PDF, PowerPoint (PPTX), Word
/// (DOCX/DOC/RTF), Excel (XLSX), HTML and text.
enum ELEDocumentText {
    static func text(from data: Data, contentType: String, url: String) -> String? {
        text(from: data, contentType: contentType, url: url, asSlides: false)
    }

    /// With `asSlides`, PDFs come back as "# Slide N: title" sections (the format the
    /// knowledge base cites slide numbers from). PPTX always does.
    static func text(from data: Data, contentType: String, url: String, asSlides: Bool) -> String? {
        let type = contentType.lowercased()
        let path = (URL(string: url)?.path ?? url).lowercased()
        if type.contains("pdf") || path.hasSuffix(".pdf") || data.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            guard let pdf = PDFDocument(data: data) else { return nil }
            if asSlides {
                let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
                return SlideDeckText.fromPages(pages).text
            }
            return pdf.string
        }
        if type.contains("presentationml") || path.hasSuffix(".pptx") || path.hasSuffix(".ppsx") {
            return pptx(data)
        }
        if type.contains("spreadsheetml") || path.hasSuffix(".xlsx") { return xlsx(data) }
        if type.contains("officedocument.wordprocessingml") || path.hasSuffix(".docx") {
            return attributed(data, .officeOpenXML)
        }
        if type.contains("msword") || path.hasSuffix(".doc") { return attributed(data, .docFormat) }
        if type.contains("rtf") || path.hasSuffix(".rtf") { return attributed(data, .rtf) }
        if type.contains("html") { return UniHTML.text(String(decoding: data, as: UTF8.self)) }
        if type.hasPrefix("text/") || path.hasSuffix(".txt") || path.hasSuffix(".csv") || path.hasSuffix(".md") {
            return String(decoding: data, as: UTF8.self)
        }
        // ZIP container without a helpful type: look inside.
        if data.starts(with: [0x50, 0x4B]) {
            let entries = ZipArchive.withTemporaryFile(data) { ZipArchive.entries($0) } ?? []
            if entries.contains(where: { $0.hasPrefix("ppt/slides/") }) { return pptx(data) }
            if entries.contains(where: { $0.hasPrefix("xl/") }) { return xlsx(data) }
            return attributed(data, .officeOpenXML)
        }
        return nil
    }

    /// Slides and speaker notes, in slide order.
    static func pptx(_ data: Data) -> String? {
        ZipArchive.withTemporaryFile(data) { file -> String? in
            let entries = ZipArchive.entries(file)
            let slides = PPTXText.orderedSlidePaths(entries)
            guard !slides.isEmpty else { return nil }
            let xmls = slides.map { ZipArchive.read(file, $0).map { String(decoding: $0, as: UTF8.self) } ?? "" }
            // Notes follow the slide's own number (notesSlideN usually matches slideN).
            let notesPaths = Set(entries.filter { $0.hasPrefix("ppt/notesSlides/notesSlide") && $0.hasSuffix(".xml") })
            let notes: [String?] = slides.map { path in
                let n = path.replacingOccurrences(of: "ppt/slides/slide", with: "ppt/notesSlides/notesSlide")
                guard notesPaths.contains(n) else { return nil }
                return ZipArchive.read(file, n).map { String(decoding: $0, as: UTF8.self) }
            }
            let text = PPTXText.extract(slideXMLs: xmls, notesXMLs: notes).text
            return text.isEmpty ? nil : text
        } ?? nil
    }

    static func xlsx(_ data: Data) -> String? {
        ZipArchive.withTemporaryFile(data) { file -> String? in
            let entries = ZipArchive.entries(file)
            let shared = ZipArchive.read(file, "xl/sharedStrings.xml").map { String(decoding: $0, as: UTF8.self) }
            let sheets = PPTXText.orderedSlidePaths(entries, folder: "xl/worksheets/", prefix: "sheet")
                .prefix(10).compactMap { ZipArchive.read(file, $0).map { String(decoding: $0, as: UTF8.self) } }
            guard !sheets.isEmpty else { return nil }
            return XLSXText.extract(sharedStringsXML: shared, sheetXMLs: Array(sheets))
        } ?? nil
    }

    private static func attributed(_ data: Data, _ type: NSAttributedString.DocumentType) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string
    }
}

/// Reads ZIP entries with /usr/bin/unzip (always present on macOS; the app isn't sandboxed).
enum ZipArchive {
    /// Writes `data` to a temporary file, runs `body`, then deletes the file.
    static func withTemporaryFile<T>(_ data: Data, _ body: (URL) -> T) -> T? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-\(UUID().uuidString).zip")
        do { try data.write(to: url) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return body(url)
    }

    /// Entry paths ("ppt/slides/slide1.xml", …).
    static func entries(_ file: URL) -> [String] {
        guard let out = run(["-Z1", file.path]) else { return [] }
        return String(decoding: out, as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    /// One entry's bytes.
    static func read(_ file: URL, _ entry: String) -> Data? {
        guard let out = run(["-p", file.path, entry]), !out.isEmpty else { return nil }
        return out
    }

    private static func run(_ arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read before waiting so a large entry can't fill the pipe and block.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
