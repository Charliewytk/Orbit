import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OrbitCore

/// A lightweight rich editor for a typed note (.rtfd in ~/Documents/Orbit Notes/<Subject>/):
/// headings, bullet and numbered lists (Return continues, Tab / Shift-Tab indent),
/// bold / italic, and pasted or dragged-in images (stored inside the .rtfd package).
/// Autosaves a second after typing stops; on close the note goes to the AI pipeline.
struct RichNoteEditor: View {
    @Environment(OrbitBrain.self) private var brain
    var url: URL
    @State private var controller = RichTextController()
    @State private var saveTask: Task<Void, Never>?
    @State private var dirty = false
    @State private var edited = false
    @State private var lastSaved: Date?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            RichNoteToolbar(title: url.deletingPathExtension().lastPathComponent, controller: controller, status: status,
                            isError: error != nil)
            Hairline()
            RichTextView(url: url, controller: controller) { changed() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { finish() }
        .background {
            Button("") { finish() }.keyboardShortcut("s", modifiers: .command).hidden()
        }
    }

    private var status: String {
        if let error { return error }
        if dirty { return "Editing…" }
        return lastSaved.map { "Saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "Saved"
    }

    private func changed() {
        dirty = true
        edited = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    private func write() {
        guard let text = controller.textView?.attributedString() else { return }
        do {
            try RichNoteFile.write(text, to: url)
            dirty = false
            lastSaved = Date()
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Save now and hand the note to the brain (knowledge store, to-dos, review).
    private func finish() {
        saveTask?.cancel()
        if dirty { write() }
        guard edited else { return }
        edited = false
        let noteURL = url
        Task { await brain.typedNoteChanged(noteURL) }
    }
}

// MARK: - Toolbar

private struct RichNoteToolbar: View {
    var title: String
    var controller: RichTextController
    var status: String
    var isError: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(status)
                .font(Theme.caption)
                .foregroundStyle(isError ? Theme.danger : Theme.textTertiary)
                .lineLimit(1)
            formatButtons
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    private var formatButtons: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Title") { controller.setHeading(1) }
                Button("Heading") { controller.setHeading(2) }
                Button("Subheading") { controller.setHeading(3) }
                Button("Body") { controller.setHeading(nil) }
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Heading")
            iconButton("bold", help: "Bold (⌘B)", key: "b") { controller.toggleTrait(.boldFontMask) }
            iconButton("italic", help: "Italic (⌘I)", key: "i") { controller.toggleTrait(.italicFontMask) }
            iconButton("list.bullet", help: "Bulleted list (⇧⌘8)", key: "8", shift: true) { controller.toggleList(numbered: false) }
            iconButton("list.number", help: "Numbered list (⇧⌘7)", key: "7", shift: true) { controller.toggleList(numbered: true) }
            iconButton("photo", help: "Insert image…", key: nil) { controller.insertImageFromPanel() }
        }
    }

    private func iconButton(_ symbol: String, help: String, key: Character?, shift: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
            .modifier(OptionalShortcut(key: key, shift: shift))
    }
}

private struct OptionalShortcut: ViewModifier {
    var key: Character?
    var shift: Bool
    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: shift ? [.command, .shift] : .command)
        } else {
            content
        }
    }
}

// MARK: - NSTextView bridge

struct RichTextView: NSViewRepresentable {
    var url: URL
    var controller: RichTextController
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 28, height: 20)
        tv.typingAttributes = RichNoteStyle.body
        tv.delegate = context.coordinator
        context.coordinator.onChange = onChange
        load(into: tv, coordinator: context.coordinator)
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard let tv = nsView.documentView as? NSTextView else { return }
        if context.coordinator.loadedURL != url { load(into: tv, coordinator: context.coordinator) }
    }

    private func load(into tv: NSTextView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        coordinator.loading = true
        let text = RichNoteFile.read(url) ?? NSAttributedString(string: "", attributes: RichNoteStyle.body)
        tv.textStorage?.setAttributedString(text)
        tv.undoManager?.removeAllActions()
        coordinator.loading = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: RichTextController
        var onChange: () -> Void = {}
        var loadedURL: URL?
        var loading = false

        init(controller: RichTextController) { self.controller = controller }

        func textDidChange(_ notification: Notification) {
            guard !loading else { return }
            onChange()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return controller.handleNewline()
            case #selector(NSResponder.insertTab(_:)): return controller.indent(by: 1)
            case #selector(NSResponder.insertBacktab(_:)): return controller.indent(by: -1)
            default: return false
            }
        }
    }
}

// MARK: - Formatting commands

/// Formatting on the live NSTextView. Lists are real `NSTextList`s with their marker text
/// ("\t•\t", "\t1.\t") at the start of each item, the way TextEdit stores them.
@MainActor
@Observable
final class RichTextController {
    /// Strong, so the editor can still save the text as it disappears (the text view holds no reference back).
    @ObservationIgnored var textView: NSTextView?

    static let indentStep: CGFloat = 26
    private static let markerPattern = #"^\t[^\t\n]*\t"#

    private var storage: NSTextStorage? { textView?.textStorage }

    /// Paragraph ranges covering the selection.
    private func selectedParagraphs() -> [NSRange] {
        guard let tv = textView else { return [] }
        let ns = tv.string as NSString
        let whole = ns.paragraphRange(for: tv.selectedRange())
        var out: [NSRange] = []
        var loc = whole.location
        while loc < NSMaxRange(whole) {
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            out.append(r)
            loc = NSMaxRange(r)
        }
        return out.isEmpty ? [whole] : out
    }

    private func style(at location: Int) -> NSMutableParagraphStyle {
        guard let s = storage, s.length > 0 else { return NSMutableParagraphStyle() }
        let loc = min(location, s.length - 1)
        let base = s.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle ?? .default
        return (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
    }

    private func attributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let s = storage, s.length > 0 else { return RichNoteStyle.body }
        return s.attributes(at: min(max(0, location), s.length - 1), effectiveRange: nil)
    }

    private func markerLength(in paragraph: NSRange) -> Int {
        guard let tv = textView else { return 0 }
        let text = (tv.string as NSString).substring(with: paragraph)
        guard let r = text.range(of: Self.markerPattern, options: .regularExpression) else { return 0 }
        return (text[r] as Substring).utf16.count
    }

    private func list(numbered: Bool, level: Int) -> NSTextList {
        if numbered { return NSTextList(markerFormat: .decimal, options: 0) }
        let formats: [NSTextList.MarkerFormat] = [.disc, .circle, .square]
        return NSTextList(markerFormat: formats[(level - 1) % formats.count], options: 0)
    }

    private func marker(_ list: NSTextList, number: Int) -> String { "\t" + list.marker(forItemNumber: number) + "\t" }

    private func listStyle(_ base: NSMutableParagraphStyle, lists: [NSTextList]) -> NSMutableParagraphStyle {
        let level = CGFloat(lists.count)
        base.textLists = lists
        base.headIndent = Self.indentStep * level
        base.firstLineHeadIndent = 0
        base.tabStops = lists.isEmpty ? [] : [NSTextTab(textAlignment: .natural, location: Self.indentStep * level - 16),
                                              NSTextTab(textAlignment: .natural, location: Self.indentStep * level)]
        return base
    }

    /// Changes text through the text view so undo and delegate notifications work.
    private func replace(_ range: NSRange, with text: NSAttributedString) {
        guard let tv = textView, tv.shouldChangeText(in: range, replacementString: text.string) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: text)
        tv.didChangeText()
    }

    private func setStyle(_ style: NSParagraphStyle, on range: NSRange) {
        guard let tv = textView, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        tv.textStorage?.addAttribute(.paragraphStyle, value: style, range: range)
        tv.didChangeText()
    }

    // MARK: Lists

    func toggleList(numbered: Bool) {
        guard let tv = textView else { return }
        let paragraphs = selectedParagraphs()
        let first = style(at: paragraphs.first?.location ?? 0)
        let isSame = first.textLists.last.map { ($0.markerFormat == .decimal) == numbered } ?? false
        tv.undoManager?.beginUndoGrouping()
        // Work backwards so earlier ranges stay valid.
        for (i, p) in paragraphs.enumerated().reversed() {
            let current = style(at: p.location)
            let strip = markerLength(in: p)
            let attrs = attributes(at: p.location + strip)
            if isSame {
                replace(NSRange(location: p.location, length: strip), with: NSAttributedString(string: ""))
                let r = (tv.string as NSString).paragraphRange(for: NSRange(location: p.location, length: 0))
                setStyle(listStyle(current, lists: []), on: r)
            } else {
                let l = list(numbered: numbered, level: 1)
                let style = listStyle(current, lists: [l])
                var a = attrs
                a[.paragraphStyle] = style
                replace(NSRange(location: p.location, length: strip), with: NSAttributedString(string: marker(l, number: i + 1), attributes: a))
                let r = (tv.string as NSString).paragraphRange(for: NSRange(location: p.location, length: 0))
                setStyle(style, on: r)
            }
        }
        tv.undoManager?.endUndoGrouping()
    }

    /// Return in a list item: a new item (next number), or leave the list on an empty item.
    func handleNewline() -> Bool {
        guard let tv = textView, tv.selectedRange().length == 0 else { return false }
        let ns = tv.string as NSString
        let p = ns.paragraphRange(for: tv.selectedRange())
        let current = style(at: p.location)
        guard let list = current.textLists.last else {
            // Return after a heading goes back to body text.
            let font = attributes(at: max(p.location, tv.selectedRange().location - 1))[.font] as? NSFont
            guard RichNoteStyle.headingLevel(of: font) != nil else { return false }
            let sel = tv.selectedRange()
            replace(sel, with: NSAttributedString(string: "\n", attributes: RichNoteStyle.body))
            tv.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            tv.typingAttributes = RichNoteStyle.body
            return true
        }
        let strip = markerLength(in: p)
        let content = ns.substring(with: NSRange(location: p.location + strip, length: max(0, p.length - strip)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            // Empty item: step out one level (or out of the list).
            return indent(by: -1)
        }
        let number = (storage?.itemNumber(in: list, at: p.location) ?? 1) + 1
        var attrs = tv.typingAttributes
        attrs[.paragraphStyle] = current
        let insert = NSAttributedString(string: "\n" + marker(list, number: number), attributes: attrs)
        let sel = tv.selectedRange()
        replace(sel, with: insert)
        tv.setSelectedRange(NSRange(location: sel.location + insert.length, length: 0))
        return true
    }

    /// Tab / Shift-Tab in a list item: nest or un-nest it. Returns false outside lists.
    @discardableResult
    func indent(by delta: Int) -> Bool {
        guard let tv = textView else { return false }
        let ns = tv.string as NSString
        let p = ns.paragraphRange(for: tv.selectedRange())
        let current = style(at: p.location)
        guard let last = current.textLists.last else { return false }
        var lists = current.textLists
        let numbered = last.markerFormat == .decimal
        if delta > 0 {
            guard lists.count < 6 else { return true }
            lists.append(list(numbered: numbered, level: lists.count + 1))
        } else {
            lists.removeLast()
        }
        let strip = markerLength(in: p)
        let caret = tv.selectedRange().location - p.location - strip
        let style = listStyle(current, lists: lists)
        var attrs = tv.typingAttributes
        attrs[.paragraphStyle] = style
        let newMarker = lists.last.map { l in
            marker(l, number: (storage?.itemNumber(in: l, at: max(0, p.location - 1)) ?? 0) + 1)
        } ?? ""
        tv.undoManager?.beginUndoGrouping()
        replace(NSRange(location: p.location, length: strip), with: NSAttributedString(string: newMarker, attributes: attrs))
        let r = (tv.string as NSString).paragraphRange(for: NSRange(location: p.location, length: 0))
        setStyle(style, on: r)
        tv.undoManager?.endUndoGrouping()
        tv.typingAttributes = attrs
        tv.setSelectedRange(NSRange(location: p.location + (newMarker as NSString).length + max(0, caret), length: 0))
        return true
    }

    // MARK: Headings, bold, italic

    func setHeading(_ level: Int?) {
        guard let tv = textView else { return }
        tv.undoManager?.beginUndoGrouping()
        for p in selectedParagraphs().reversed() where p.length > 0 {
            let attrs = level.map(RichNoteStyle.heading) ?? RichNoteStyle.body
            guard tv.shouldChangeText(in: p, replacementString: nil) else { continue }
            tv.textStorage?.addAttributes(attrs, range: p)
            tv.didChangeText()
        }
        tv.undoManager?.endUndoGrouping()
        tv.typingAttributes = level.map(RichNoteStyle.heading) ?? RichNoteStyle.body
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView, let s = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        if range.length == 0 {
            let font = tv.typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: RichNoteStyle.bodySize)
            let has = fm.traits(of: font).contains(trait)
            tv.typingAttributes[.font] = has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            return
        }
        var allHave = true
        s.enumerateAttribute(.font, in: range) { value, _, _ in
            if let f = value as? NSFont, !fm.traits(of: f).contains(trait) { allHave = false }
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        s.enumerateAttribute(.font, in: range) { value, r, _ in
            let f = value as? NSFont ?? NSFont.systemFont(ofSize: RichNoteStyle.bodySize)
            s.addAttribute(.font, value: allHave ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: r)
        }
        tv.didChangeText()
    }

    // MARK: Images

    func insertImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { insertImage(url) }
    }

    func insertImage(_ url: URL) {
        guard let tv = textView, let wrapper = try? FileWrapper(url: url, options: .immediate) else { return }
        wrapper.preferredFilename = url.lastPathComponent
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        text.addAttributes(RichNoteStyle.body, range: NSRange(location: 0, length: text.length))
        replace(tv.selectedRange(), with: text)
    }
}
