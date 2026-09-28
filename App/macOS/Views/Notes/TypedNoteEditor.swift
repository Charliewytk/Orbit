import SwiftUI
import AppKit
import OrbitCore

/// A clean Markdown editor for an Orbit typed note. Autosaves a second after typing stops;
/// when the editor closes (or ⌘S), the note is merged with its handwriting, indexed,
/// scanned for to-dos and reviewed against the slides.
struct TypedNoteEditor: View {
    @Environment(OrbitBrain.self) private var brain
    var url: URL
    @State private var text = ""
    @State private var loaded = false
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSaved: Date?
    @State private var error: String?
    @AppStorage("typedNotesMonospaced") private var monospaced = false
    @AppStorage("typedNotesPreview") private var preview = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            Group {
                if preview {
                    ScrollView {
                        MarkdownPreview(text: text)
                            .padding(Theme.Space.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(monospaced ? .system(size: Theme.Size.large, design: .monospaced) : .system(size: Theme.Size.large))
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) { load() }
        .onChange(of: text) { _, _ in
            guard loaded else { return }
            dirty = true
            scheduleSave()
        }
        .onDisappear { finish() }
        .background {
            Button("") { finish() }.keyboardShortcut("s", modifiers: .command).hidden()
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "doc.text")
                .foregroundStyle(Destination.notes.color)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(url.deletingLastPathComponent().lastPathComponent)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(1)
            } else {
                Text(dirty ? "Editing…" : lastSaved.map { "Saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "Saved")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Toggle(isOn: $monospaced) { Image(systemName: "textformat.size.smaller") }
                .toggleStyle(.button)
                .help("Monospaced font")
                .disabled(preview)
            Picker("", selection: $preview) {
                Text("Edit").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    private func load() {
        loaded = false
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        dirty = false
        error = nil
        // Let the onChange from the assignment above pass before tracking edits.
        DispatchQueue.main.async { loaded = true }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    private func write() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
            lastSaved = Date()
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Save now and hand the note to the brain (merge, index, to-dos, review).
    private func finish() {
        saveTask?.cancel()
        let changed = dirty || lastSaved != nil
        if dirty { write() }
        guard changed else { return }
        let url = url
        Task { await brain.typedNoteChanged(url) }
    }
}

/// Markdown preview: headings, bullets, checkboxes and quotes by line; inline styles
/// (bold, italics, code, links) via `AttributedString(markdown:)`.
struct MarkdownPreview: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [String] {
        text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .reduce(into: [String]()) { out, line in
                // Collapse runs of blank lines.
                if line.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.isEmpty ?? true { return }
                out.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : line)
            }
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if let level = headingLevel(trimmed) {
            Text(inline(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                .font(.system(size: level == 1 ? Theme.Size.title2 : (level == 2 ? Theme.Size.title3 : Theme.Size.large), weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, level == 1 ? 0 : Theme.Space.s)
        } else if let box = checkbox(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: box.done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(box.done ? Theme.success : Theme.textTertiary)
                Text(inline(box.rest)).font(Theme.large).foregroundStyle(Theme.textPrimary)
            }
            .padding(.leading, indent(line))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("•").foregroundStyle(Destination.notes.color)
                Text(inline(String(trimmed.dropFirst(2)))).font(Theme.large).foregroundStyle(Theme.textPrimary)
            }
            .padding(.leading, indent(line))
        } else if trimmed.hasPrefix(">") {
            Text(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                .font(Theme.large.italic())
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, Theme.Space.m)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 3) }
        } else {
            Text(inline(trimmed))
                .font(Theme.large)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private func checkbox(_ s: String) -> (done: Bool, rest: String)? {
        for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false), ("* [x] ", true)]
        where s.hasPrefix(prefix) {
            return (done: done, rest: String(s.dropFirst(prefix.count)))
        }
        return nil
    }

    private func indent(_ line: String) -> CGFloat {
        CGFloat(line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2) * 14
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
