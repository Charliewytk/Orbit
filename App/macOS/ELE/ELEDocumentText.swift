import AppKit
import Foundation
import OrbitCore
import PDFKit

/// Plain text from assessment briefs downloaded from ELE (DOCX, PDF, HTML, text).
enum ELEDocumentText {
    static func text(from data: Data, contentType: String, url: String) -> String? {
        let type = contentType.lowercased()
        let path = (URL(string: url)?.path ?? url).lowercased()
        if type.contains("pdf") || path.hasSuffix(".pdf") || data.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return PDFDocument(data: data)?.string
        }
        if type.contains("officedocument.wordprocessingml") || path.hasSuffix(".docx") {
            return attributed(data, .officeOpenXML)
        }
        if type.contains("msword") || path.hasSuffix(".doc") { return attributed(data, .docFormat) }
        if type.contains("rtf") || path.hasSuffix(".rtf") { return attributed(data, .rtf) }
        if type.contains("html") { return UniHTML.text(String(decoding: data, as: UTF8.self)) }
        if type.hasPrefix("text/") || path.hasSuffix(".txt") { return String(decoding: data, as: UTF8.self) }
        // ZIP container without a helpful type: try DOCX.
        if data.starts(with: [0x50, 0x4B]) { return attributed(data, .officeOpenXML) }
        return nil
    }

    private static func attributed(_ data: Data, _ type: NSAttributedString.DocumentType) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string
    }
}
