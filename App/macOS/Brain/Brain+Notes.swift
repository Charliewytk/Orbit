import Foundation
import SwiftData
import OrbitCore

extension OrbitBrain {
    /// "graph" (OneNote via Microsoft Graph), "folder" (exported PDFs/Markdown) or "none".
    var noteSource: String {
        MacPrefs.string(MacPrefs.noteSource)
            ?? (accounts.microsoftConnected ? "graph" : MacPrefs.string(MacPrefs.notesFolderPath) != nil ? "folder" : "none")
    }

    func syncNotes() async {
        guard noteSource != "none", begin(.notes) else { return }
        defer { end(.notes) }
        switch noteSource {
        case "graph": await syncOneNote()
        case "folder": await syncNotesFolder()
        default: break
        }
        saveIndex()
        local.save(handwritingProfile, "handwriting-profile.json")
    }

    // MARK: OneNote (Graph)

    private func syncOneNote() async {
        guard accounts.microsoftConnected, let session = accounts.microsoft else {
            record(.notes, error: "Pick your OneNote export folder in Settings (Read notes from → Exported PDF folder).")
            return
        }
        let client = OneNoteClient(tokens: session)
        do {
            let sections = try await client.allSections()
            let changes = try await client.changes(since: state.oneNoteCursor ?? OneNoteSyncCursor(), in: sections)
            let merger = NoteMerger()
            var processed = 0, failed = 0
            for (section, page) in changes.pages {
                let stamp = page.lastModifiedDateTime ?? .distantPast
                if let done = state.oneNotePageStamps[page.id], done >= stamp { continue }
                do {
                    let pipeline = HandwritingPipeline.standard(router: router, profile: handwritingProfile)
                    let fetched = try await client.fetchPage(page, section: section)
                    let merged = try await merger.build(fetched, pipeline: pipeline)
                    learn(from: merged, typed: fetched.document.typedText, pageID: page.id)
                    await store(note: merged.note)
                    state.oneNotePageStamps[page.id] = stamp
                    saveState()
                    processed += 1
                } catch let error as OneNoteError {
                    throw error
                } catch {
                    failed += 1
                }
            }
            state.oneNoteCursor = changes.cursor
            saveState()
            record(.notes, error: failed > 0 ? "\(failed) page(s) couldn't be read; they'll be retried." : nil,
                   detail: "\(processed) page(s) updated, \(noteIndex.noteIDs.count) indexed")
        } catch OneNoteError.unauthorized {
            record(.notes, error: "Microsoft sign-in expired. Reconnect your Exeter account.")
        } catch let error as OneNoteError {
            record(.notes, error: error.description)
        } catch let error as HTTPError where error.status == 403 {
            record(.notes, error: "Exeter blocked OneNote access. Export your notebooks to PDF and choose that folder in Settings.")
        } catch {
            record(.notes, error: "OneNote: \(error)")
        }
    }

    /// Typed-up sections are a free answer key for the handwriting above them.
    private func learn(from merged: MergedNote, typed: String, pageID: String) {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !merged.handwriting.isEmpty else { return }
        var profile = handwritingProfile
        HandwritingLearner().learn(regions: merged.handwriting.map(\.learnerRegion), typed: typed, pageID: pageID, into: &profile)
        handwritingProfile = profile
    }

    // MARK: Exported folder (PDF / Markdown / images)

    private func syncNotesFolder() async {
        guard let path = MacPrefs.string(MacPrefs.notesFolderPath) else {
            record(.notes, error: "Choose your exported notes folder in Settings.")
            return
        }
        let scanner = NotesFolderScanner(root: URL(fileURLWithPath: path))
        do {
            let result = try scanner.scan(since: state.notesFolderCursor)
            let pipeline = HandwritingPipeline.standard(router: router, profile: handwritingProfile)
            var failed = 0
            for item in result.items {
                do {
                    if let note = try await note(from: item, pipeline: pipeline) { await store(note: note) }
                } catch {
                    failed += 1
                }
            }
            state.notesFolderCursor = result.cursor ?? state.notesFolderCursor
            saveState()
            var detail = "\(result.items.count) file(s) read"
            if !result.unsupported.isEmpty { detail += "; \(result.unsupported.count) .one file(s) skipped (export them to PDF)" }
            record(.notes, error: failed > 0 ? "\(failed) file(s) couldn't be read" : nil, detail: detail)
        } catch {
            record(.notes, error: "Notes folder: \(error.localizedDescription)")
        }
    }

    private func note(from item: NotesFolderScanner.Item, pipeline: HandwritingPipeline) async throws -> LectureNote? {
        switch item.kind {
        case .markdown, .text:
            let text = try String(contentsOf: item.url, encoding: .utf8)
            return NotesFolderScanner.note(fromText: text, item: item)
        case .pdf:
            let pages = await Self.renderPDF(item.url)
            var segments: [NoteSegment] = []
            for (i, page) in pages.enumerated() {
                if let text = page.text { segments.append(NoteSegment(kind: .typed, text: text)) }
                if let image = page.image {
                    let hint = page.text.map { String($0.prefix(300)) }
                    let region = try await pipeline.transcribe(image: image, regionID: "\(item.relativePath)#\(i)", hint: hint)
                    segments += region.segments
                }
            }
            return Self.makeNote(item, segments: segments)
        case .image:
            let data = try Data(contentsOf: item.url)
            let region = try await pipeline.transcribe(image: data, regionID: item.relativePath)
            return Self.makeNote(item, segments: region.segments)
        }
    }

    private static func makeNote(_ item: NotesFolderScanner.Item, segments: [NoteSegment]) -> LectureNote {
        let title = item.url.deletingPathExtension().lastPathComponent
        let folders = item.relativePath.split(separator: "/").dropLast().map(String.init)
        var clues: [String?] = [title]
        clues += folders.reversed().map { Optional($0) }
        return LectureNote(id: "file:" + item.relativePath, title: title, notebook: "Exported notes",
                           section: folders.last ?? "", moduleCode: NoteMetadataDetector.moduleCode(in: clues),
                           week: NoteMetadataDetector.week(in: clues), created: item.modified, modified: item.modified,
                           segments: segments)
    }

    /// Text and a PNG for each page, rendered off the main thread.
    private nonisolated static func renderPDF(_ url: URL) async -> [(text: String?, image: Data?)] {
        await Task.detached(priority: .utility) { () -> [(text: String?, image: Data?)] in
            guard let source = PDFPageImageSource(url: url) else { return [] }
            return (0..<source.pageCount).map { i -> (text: String?, image: Data?) in
                (text: source.text(page: i), image: source.renderPage(i))
            }
        }.value
    }

    // MARK: Storing a note

    /// Saves the full note locally, indexes it, summarises it, makes flashcards,
    /// and syncs a summary-only copy.
    func store(note incoming: LectureNote) async {
        var note = incoming
        let previous = local.note(id: note.id)
        if let previous, previous.allText == note.allText { note.summary = previous.summary }
        let hasText = !note.allText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if note.summary == nil, hasText {
            note.summary = try? await NoteInsights.summarise(note, router: router)
        }
        local.saveNote(note)

        var index = noteIndex
        index.remove(noteID: note.id)
        index.add(note)
        _ = try? await index.embedMissing(using: embedder)
        noteIndex = index

        let stored = context.record(StoredNote.self, id: note.id) ?? {
            let s = StoredNote(id: note.id)
            context.insert(s)
            return s
        }()
        stored.apply(note)

        let hasCards = context.all(StoredFlashcard.self).contains { $0.noteID == note.id }
        if !hasCards, note.hasTyped || hasText,
           let cards = try? await NoteInsights.flashcards(from: note, router: router, count: 6) {
            for card in cards { context.insert(StoredFlashcard(card: card)) }
        }
        context.saveQuietly()
    }

    // MARK: Search & answers

    func searchNotes(_ query: String, moduleCode: String?) async -> [NoteHit] {
        let index = noteIndex
        guard !index.isEmpty else {
            return StoreDataSource.keywordSearch(context.all(StoredNote.self), query: query, moduleCode: moduleCode, limit: 12)
                .map { NoteHit(id: $0.id, noteID: $0.id, title: $0.title, moduleCode: $0.moduleCode, week: $0.week,
                               snippet: String(($0.summary ?? $0.keyPoints).prefix(220)), isTyped: $0.hasTyped) }
        }
        let hits = await index.search(query, moduleCode: moduleCode, limit: 12, embedder: embedder)
        return hits.map { h in
            NoteHit(id: h.chunk.id, noteID: h.chunk.noteID, title: h.chunk.noteTitle, moduleCode: h.chunk.moduleCode,
                    week: h.chunk.week, snippet: h.snippet, isTyped: h.chunk.kind == .typed)
        }
    }

    func askNotes(_ question: String, moduleCode: String?) async throws -> NotesAnswer? {
        isThinking = true
        defer { isThinking = false }
        let index = noteIndex
        let answer = try await index.answer(question, using: router, moduleCode: moduleCode, embedder: embedder)
        return NotesAnswer(text: answer.text, citations: answer.citations.map {
            NotesAnswer.Citation(index: $0.index, noteID: $0.noteID, title: $0.title, moduleCode: $0.moduleCode, week: $0.week)
        })
    }

    func fullNote(id: String) -> LectureNote? { local.note(id: id) }
}
