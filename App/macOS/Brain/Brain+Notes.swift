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
        guard begin(.notes) else { return }
        defer { end(.notes) }
        loadNotesLibraryIfNeeded()
        switch noteSource {
        case "graph": await syncOneNote()
        case "folder": await syncNotesFolder()
        default: break
        }
        // Orbit's own typed notes (~/Documents/Orbit Notes) are read whatever the source.
        await syncTypedNotes()
        saveNotesLibrary()
        await refreshLibrary()
        saveIndex()
        local.save(handwritingProfile, "handwriting-profile.json")
        await academicAfterNotesSync()
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
        // GoodNotes auto-backups: one PDF per notebook, one note per page.
        let pageMode = GoodNotesBackup.isGoodNotesPath(path)
        // Notability auto-backups: one PDF per note (Subject/Week 3.pdf), one note per file.
        // The scanner's mtime cursor means a PDF is only re-read when it changes.
        let notabilityMode = !pageMode && GoodNotesBackup.isNotabilityPath(path)
        do {
            let result = try scanner.scan(since: state.notesFolderCursor)
            let pipeline = HandwritingPipeline.standard(router: router, profile: handwritingProfile)
            var failed = 0
            for item in result.items {
                do {
                    if notabilityMode && item.kind == .pdf {
                        if let note = try await notabilityNote(from: item, pipeline: pipeline) { await store(note: note) }
                    } else if pageMode && item.kind == .pdf {
                        for note in try await pageNotes(from: item, pipeline: pipeline) { await store(note: note) }
                    } else if let note = try await note(from: item, pipeline: pipeline) {
                        await store(note: note)
                    }
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
            // Text layer first (typed boxes, text an app already recognised); OCR only
            // pages, or the parts of pages, the text layer doesn't cover.
            let pages = await Self.renderPDF(item.url)
            var segments: [NoteSegment] = []
            for page in pages {
                segments += try await read(page, item: item, pipeline: pipeline)
            }
            recordReadStatus(noteID: "file:" + item.relativePath, pages: pages.count,
                             textPages: pages.filter { $0.text != nil }.count,
                             ocrPages: pages.filter { $0.plan.usesOCR }.count,
                             lowConfidence: segments.contains { $0.kind != .typed && $0.confidence < 0.6 })
            return Self.makeNote(item, segments: segments)
        case .image:
            let data = try Data(contentsOf: item.url)
            let region = try await pipeline.transcribe(image: data, regionID: item.relativePath)
            return Self.makeNote(item, segments: region.segments)
        }
    }

    /// Module names Orbit knows (ELE + stored), for matching notebook / subject names.
    private func notebookMatcher() -> NotebookModuleMatcher {
        var modules = academic.modules.map { (code: $0.code, name: $0.name) }
        for m in context.all(StoredModule.self) where !modules.contains(where: { $0.code == m.id }) {
            modules.append((code: m.id, name: m.name))
        }
        return NotebookModuleMatcher(modules: modules)
    }

    /// A Notability note PDF → one lecture note. The nearest subject folder picks the
    /// module ("Introduction to Statistics" → BEE1022); the filename gives the week
    /// ("Week 3"), else the academic calendar week of the file's date.
    private func notabilityNote(from item: NotesFolderScanner.Item, pipeline: HandwritingPipeline) async throws -> LectureNote? {
        guard var note = try await note(from: item, pipeline: pipeline) else { return nil }
        let meta = NotabilityNote.metadata(relativePath: item.relativePath, matcher: notebookMatcher())
        note.title = meta.title
        note.notebook = "Notability"
        note.section = meta.subject ?? "Notability"
        note.moduleCode = meta.moduleCode ?? note.moduleCode
        note.week = meta.week ?? academic.calendar.week(for: item.modified)?.week
        // Keep the handwriting as read, then fold in the typed-up version of this week if there is one.
        local.saveRawNote(note)
        if let typed = typedCompanion(for: note) {
            let merged = NoteMerger().combine(handwritten: note, typed: typed)
            learn(fromCombined: merged, typed: typed.keyPoints)
            if local.note(id: typed.id) != nil {
                local.deleteNote(id: typed.id)
                noteIndex.remove(noteID: typed.id)
                if let s = context.record(StoredNote.self, id: typed.id) { context.delete(s) }
            }
            return merged.note
        }
        return note
    }

    /// One PDF page → segments: the text layer as `.typed`, OCR of the rest as handwriting.
    private func read(_ page: PDFPageRead, item: NotesFolderScanner.Item,
                      pipeline: HandwritingPipeline) async throws -> [NoteSegment] {
        var segments: [NoteSegment] = []
        if let text = page.text { segments.append(NoteSegment(kind: .typed, text: text)) }
        if page.plan.usesOCR, let image = page.ocrImage {
            let hint = page.text.map { String($0.prefix(300)) }
            do {
                let region = try await pipeline.transcribe(image: image, regionID: "\(item.relativePath)#\(page.index)", hint: hint)
                // Blanked-out text leaves nothing to read on some pages: that's fine.
                segments += region.segments
            } catch where page.text != nil {
                // The text layer alone is still a good note.
            }
        }
        return segments
    }

    /// A GoodNotes notebook PDF → one note per page. The notebook name picks the
    /// module ("Mathematics for Economists" → BEE1024); the page header gives the
    /// date and week ("Week 1 Monday, 21 September 2026"), else the file's date.
    /// Pages whose rendering hasn't changed since last time are skipped (no re-OCR).
    private func pageNotes(from item: NotesFolderScanner.Item, pipeline: HandwritingPipeline) async throws -> [LectureNote] {
        let notebook = item.url.deletingPathExtension().lastPathComponent
        let folders = item.relativePath.split(separator: "/").dropLast().map(String.init)
        var modules = academic.modules.map { (code: $0.code, name: $0.name) }
        for m in context.all(StoredModule.self) where !modules.contains(where: { $0.code == m.id }) {
            modules.append((code: m.id, name: m.name))
        }
        let moduleCode = NotebookModuleMatcher(modules: modules).moduleCode(forNotebook: notebook)
            ?? NoteMetadataDetector.moduleCode(in: [notebook] + folders.reversed().map { Optional($0) })
        let tz = prefs.timeZone
        let pages = await Self.renderPDF(item.url)
        var hashes = state.notePageHashes ?? [:]
        var out: [LectureNote] = []
        for (i, page) in pages.enumerated() {
            let id = "file:\(item.relativePath)#p\(i + 1)"
            let hash = page.ocrImage.map { MD5.digest($0).map { String(format: "%02x", $0) }.joined() } ?? MD5.hex(page.text ?? "")
            if hashes[id] == hash, local.note(id: id) != nil { continue }
            let segments = try await read(page, item: item, pipeline: pipeline)
            recordReadStatus(noteID: id, pages: 1, textPages: page.text == nil ? 0 : 1, ocrPages: page.plan.usesOCR ? 1 : 0,
                             lowConfidence: segments.contains { $0.kind != .typed && $0.confidence < 0.6 })
            let text = segments.map(\.text).joined(separator: "\n")
            let header = PageHeaderDate.parse(text, timeZone: tz, reference: item.modified)
            let date = header.date ?? item.modified
            let week = header.week ?? academic.calendar.week(for: date)?.week
            let day = DayCalendar(timeZone: tz)
            let title = header.date.map { "\(notebook) · \(day.format($0, "EEE d MMM"))" } ?? "\(notebook) · page \(i + 1)"
            out.append(LectureNote(id: id, title: title, notebook: notebook, section: folders.last ?? "GoodNotes",
                                   moduleCode: moduleCode, week: week, created: date, modified: item.modified,
                                   segments: segments))
            hashes[id] = hash
        }
        state.notePageHashes = hashes
        return out
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

    /// Each page's meaningful text layer and, where OCR is needed, a PNG of what the
    /// text layer doesn't cover. Rendered off the main thread.
    private nonisolated static func renderPDF(_ url: URL) async -> [PDFPageRead] {
        await Task.detached(priority: .utility) { () -> [PDFPageRead] in
            guard let source = PDFPageImageSource(url: url) else { return [] }
            return (0..<source.pageCount).map { source.read(page: $0) }
        }.value
    }

    // MARK: Storing a note

    /// Saves the full note locally, indexes it, summarises it, makes flashcards,
    /// and syncs a summary-only copy.
    func store(note incoming: LectureNote) async {
        var note = incoming
        let previous = local.note(id: note.id)
        let textChanged = previous?.allText != note.allText
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
        // To-dos and notes-to-self ("homework: …", "→ ask … at end") → tasks and suggestions.
        if textChanged, hasText { await extractNoteActions(from: note) }
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
