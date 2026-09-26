import SwiftUI
import AppKit
import PDFKit

/// Drives a `PDFKitView` from SwiftUI: zoom, search, page jumps.
@MainActor
@Observable
final class PDFViewController {
    @ObservationIgnored weak var pdfView: PDFView?
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex = 0

    func attach(_ view: PDFView) {
        pdfView = view
        pageCount = view.document?.pageCount ?? 0
        updatePage()
    }

    func updatePage() {
        guard let view = pdfView, let doc = view.document, let page = view.currentPage else { return }
        pageIndex = doc.index(for: page)
        pageCount = doc.pageCount
    }

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }
    func zoomToFit() {
        guard let view = pdfView else { return }
        view.autoScales = true
    }

    func go(to index: Int) {
        guard let view = pdfView, let page = view.document?.page(at: index) else { return }
        view.go(to: page)
    }

    /// Finds `text` in the PDF's text layer and highlights every match.
    func search(_ text: String) {
        guard let view = pdfView, let doc = view.document else { return }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            matches = []
            view.highlightedSelections = nil
            return
        }
        matches = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for m in matches { m.color = NSColor.systemYellow.withAlphaComponent(0.55) }
        view.highlightedSelections = matches
        matchIndex = 0
        show()
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + 1) % matches.count
        show()
    }

    private func show() {
        guard let view = pdfView, matches.indices.contains(matchIndex) else { return }
        view.setCurrentSelection(matches[matchIndex], animate: true)
        view.scrollSelectionToVisible(nil)
    }
}

/// A PDFKit `PDFView` (continuous, auto-scaled) with an optional thumbnail strip.
struct PDFKitView: NSViewRepresentable {
    var url: URL
    var controller: PDFViewController
    var showThumbnails: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displaysPageBreaks = true
        pdf.backgroundColor = .clear
        pdf.translatesAutoresizingMaskIntoConstraints = false
        let thumbs = PDFThumbnailView()
        thumbs.pdfView = pdf
        thumbs.thumbnailSize = CGSize(width: 64, height: 84)
        thumbs.backgroundColor = .clear
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbs)
        container.addSubview(pdf)
        let thumbWidth = thumbs.widthAnchor.constraint(equalToConstant: showThumbnails ? 92 : 0)
        NSLayoutConstraint.activate([
            thumbs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbs.topAnchor.constraint(equalTo: container.topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbWidth,
            pdf.leadingAnchor.constraint(equalTo: thumbs.trailingAnchor),
            pdf.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdf.topAnchor.constraint(equalTo: container.topAnchor),
            pdf.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.pdfView = pdf
        context.coordinator.thumbWidth = thumbWidth
        context.coordinator.observe(pdf)
        load(url, into: pdf, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let pdf = context.coordinator.pdfView else { return }
        context.coordinator.thumbWidth?.constant = showThumbnails ? 92 : 0
        if context.coordinator.loadedURL != url { load(url, into: pdf, coordinator: context.coordinator) }
    }

    private func load(_ url: URL, into pdf: PDFView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        pdf.document = PDFDocument(url: url)
        controller.attach(pdf)
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: PDFViewController
        weak var pdfView: PDFView?
        var thumbWidth: NSLayoutConstraint?
        var loadedURL: URL?
        nonisolated(unsafe) private var token: NSObjectProtocol?

        init(controller: PDFViewController) { self.controller = controller }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.updatePage() }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
