import Foundation

/// Makes sure the ELE crawl reads *everything* on each enrolled course: files, pages,
/// folders, books, assignments and quizzes (their descriptions), URLs, forums, labels,
/// and reading-list links — and reports what changed (added, renamed, removed).
public enum ELECoverage {
    /// Item kinds the crawler reads, and how.
    public enum Fetch: String, Sendable { case download, page, folder, bookPrint, inline }

    public static func fetch(for kind: ELEWebItem.Kind) -> Fetch? {
        switch kind {
        case .resource: .download
        case .page, .assign, .quiz, .forum, .turnitin: .page
        case .folder: .folder
        case .book: .bookPrint
        case .url, .label, .lti: .inline
        case .other: .page
        }
    }

    /// Every item worth reading, including the ones `resourceTargets` leaves out.
    public static func targets(kb: CourseKnowledgeBase, snap: ELEWebSnapshot) -> [ResourceTarget] {
        var out = kb.resourceTargets(from: snap)
        let known = Set(out.map(\.cmid))
        for (code, content) in snap.contents.sorted(by: { $0.key < $1.key }) {
            let term = kb.modules[code]?.term
            for s in content.sections {
                for item in s.items where [.assign, .quiz, .forum, .book, .turnitin, .other].contains(item.kind) {
                    guard let cmid = item.cmid, let url = item.url, !known.contains(cmid), item.role != .recording else { continue }
                    let week = s.kind == .week ? s.week : nil
                    out.append(ResourceTarget(cmid: cmid, moduleCode: code, term: week != nil ? (term ?? 1) : nil, week: week,
                                              section: s.title, name: item.name, kind: CourseDocKind.from(role: item.role, name: item.name),
                                              itemKind: item.kind, url: url))
                }
            }
        }
        return out
    }

    /// The URL to fetch for a target (books print as one page).
    public static func fetchURL(for target: ResourceTarget, site: String = "https://ele.exeter.ac.uk") -> URL? {
        if target.itemKind == .book { return URL(string: "\(site)/mod/book/tool/print/index.php?id=\(target.cmid)") }
        if target.itemKind == .resource {
            return ELEWebParser.downloadURL(for: ELEWebItem(cmid: target.cmid, name: target.name, kind: .resource, url: target.url))
        }
        return URL(string: target.url)
    }

    /// Items indexed straight from the course page (URLs, labels, LTI links): name + description.
    public static func inlineDocuments(snap: ELEWebSnapshot, kb: CourseKnowledgeBase) -> [CourseDocument] {
        var out: [CourseDocument] = []
        for (code, content) in snap.contents {
            let term = kb.modules[code]?.term
            for s in content.sections {
                for item in s.items where [.url, .lti].contains(item.kind) || (item.kind == .label && item.text.count > 120) {
                    let id = item.cmid.map { "ele-cm-\($0)" } ?? "ele-inline-\(code)-" + MD5.hex(s.title + item.name).prefix(10)
                    let week = s.kind == .week ? s.week : nil
                    let kind: CourseDocKind = item.role == .readingList ? .readingList : CourseDocKind.from(role: item.role, name: item.name)
                    let text = [item.name, item.text, item.url.map { "Link: \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                    out.append(CourseDocument(id: id, moduleCode: code, term: week != nil ? (term ?? 1) : nil, week: week, kind: kind,
                                              title: item.name, section: s.title, url: item.url, cmid: item.cmid, text: text,
                                              modified: snap.fetchedAt))
                }
            }
        }
        return out
    }

    /// Reading-list links per module (Talis and others) from the course pages.
    public static func readingListLinks(_ snap: ELEWebSnapshot) -> [(moduleCode: String, url: String)] {
        var out: [(String, String)] = []
        for (code, content) in snap.contents.sorted(by: { $0.key < $1.key }) {
            for item in content.sections.flatMap(\.items) {
                guard let u = item.url else { continue }
                if item.role == .readingList || TalisReadingList.isTalisURL(u) { out.append((code, u)) }
            }
            // Talis links pasted into section summaries/labels.
            for s in content.sections {
                for m in s.items.map(\.text) + [s.summary] {
                    if let hit = UniRegex.first("(https?://[a-z0-9.]*rl\\.talis\\.com/[^\\s\"'<>)]+)", in: m)?[1] { out.append((code, hit)) }
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.1).inserted }
    }

    /// Per kind: items on the course pages vs items the crawler will read.
    public static func report(_ snap: ELEWebSnapshot) -> [(kind: ELEWebItem.Kind, total: Int, covered: Int)] {
        var total: [ELEWebItem.Kind: Int] = [:], covered: [ELEWebItem.Kind: Int] = [:]
        for item in snap.contents.values.flatMap({ $0.sections.flatMap(\.items) }) {
            total[item.kind, default: 0] += 1
            if fetch(for: item.kind) != nil, item.role != .recording || item.kind == .label { covered[item.kind, default: 0] += 1 }
        }
        return total.keys.sorted { $0.rawValue < $1.rawValue }.map { ($0, total[$0] ?? 0, covered[$0] ?? 0) }
    }

    /// Renamed and removed items and new sections — on top of `ELEActivityFeed.changes` (new items, deadlines, weeks).
    public static func extraChanges(from old: ELEWebSnapshot?, to new: ELEWebSnapshot) -> [ELEActivityItem] {
        guard let old else { return [] }
        var out: [ELEActivityItem] = []
        for (code, content) in new.contents {
            guard let before = old.contents[code] else {
                out.append(ELEActivityItem(id: "course-\(code)-new", kind: .newContent, moduleCode: code,
                                           title: "New course page on ELE", detail: new.modules.first { $0.moduleCode == code }?.name ?? code,
                                           date: new.fetchedAt, important: true))
                continue
            }
            let oldItems = Dictionary(before.sections.flatMap(\.items).compactMap { i in i.cmid.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
            let newItems = Dictionary(content.sections.flatMap(\.items).compactMap { i in i.cmid.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
            for (cmid, item) in newItems {
                guard let o = oldItems[cmid], o.name != item.name, item.kind != .label else { continue }
                out.append(ELEActivityItem(id: "cm-\(cmid)-renamed-\(MD5.hex(item.name).prefix(6))", kind: .newContent, moduleCode: code,
                                           title: "Renamed: \(item.name)", detail: "was “\(o.name)”", date: new.fetchedAt, url: item.url))
            }
            for (cmid, item) in oldItems where newItems[cmid] == nil && item.kind != .label {
                out.append(ELEActivityItem(id: "cm-\(cmid)-removed", kind: .other, moduleCode: code,
                                           title: "Removed from ELE: \(item.name)", date: new.fetchedAt))
            }
            let oldTitles = Set(before.sections.map(\.title))
            for s in content.sections where !oldTitles.contains(s.title) && !s.items.isEmpty {
                out.append(ELEActivityItem(id: "section-\(code)-\(MD5.hex(s.title).prefix(8))", kind: .weekUpdated, moduleCode: code,
                                           title: "New section: \(s.title)", detail: "\(s.items.count) item(s)", date: new.fetchedAt,
                                           url: s.url, important: s.kind == .week || s.kind == .assessment))
            }
        }
        return out
    }
}

// MARK: - Ed ↔ ELE

public enum EdLinker {
    /// Useful student Q&A and staff posts (worth keeping in the knowledge store).
    public static func isUseful(_ item: EdItem) -> (useful: Bool, reason: String) {
        if item.kind == .announcement { return (true, "announcement") }
        if item.authorIsStaff { return (true, "staff post") }
        if item.kind == .pinned { return (true, "pinned") }
        let reasons = item.importance.reasons.joined(separator: " ").lowercased()
        if reasons.contains("staff answered") || reasons.contains("endorsed") { return (true, "answered Q&A") }
        let isQuestion = item.title.contains("?") || item.category?.lowercased().contains("question") == true
            || ["how do", "why does", "what is", "can someone", "confused", "stuck"].contains { (item.title + " " + item.text).lowercased().contains($0) }
        if isQuestion && item.text.count >= 80 && item.importance.level >= .normal { return (true, "student Q&A") }
        return (false, "")
    }

    /// The ELE week an Ed thread is about: an explicit "week N" / "problem set N", else the best-matching week page.
    public static func week(for item: EdItem, kb: CourseKnowledgeBase) -> Int? {
        let text = item.title + " " + item.text.prefix(600)
        if let w = UniRegex.first("\\b(?:week|wk)\\s*(\\d{1,2})\\b", in: text)?[1].flatMap(Int.init) { return w }
        let hits = kb.search(item.title + " " + item.text.prefix(300), moduleCode: item.moduleCode, kinds: [.elePage, .slides, .homework], limit: 3)
        return hits.first(where: { $0.document.week != nil && $0.score > 0 })?.document.week
    }

    /// A knowledge-store document for a useful thread, tagged with its ELE week.
    public static func document(_ item: EdItem, kb: CourseKnowledgeBase) -> CourseDocument? {
        let (useful, reason) = isUseful(item)
        guard useful, item.kind != .reply, !item.text.isEmpty else { return nil }
        let header = "Ed Discussion (\(reason)) in \(item.courseCode)\(item.category.map { " (\($0))" } ?? "")"
            + (item.author.map { " by \($0)" } ?? "") + "."
        return CourseDocument(id: "ed-\(item.threadID)", moduleCode: item.moduleCode, week: week(for: item, kb: kb), kind: .announcement,
                              title: "Ed: \(item.title)", section: item.category, url: item.url,
                              text: header + "\n\n" + item.text, modified: item.date)
    }
}
