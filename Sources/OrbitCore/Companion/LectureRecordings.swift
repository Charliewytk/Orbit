import Foundation

/// A lecture recording found on ELE (Panopto, Echo360, or a plain media link).
public struct LectureRecording: Codable, Hashable, Sendable, Identifiable {
    public enum Platform: String, Codable, Sendable { case panopto, echo360, media }

    /// Stable id: platform + session id (or URL hash).
    public var id: String
    public var platform: Platform
    public var url: String
    public var title: String
    public var moduleCode: String?
    public var date: Date?
    /// Caption/transcript URLs seen next to the recording (VTT/SRT/TXT).
    public var captionURLs: [String]

    public init(id: String, platform: Platform, url: String, title: String, moduleCode: String? = nil,
                date: Date? = nil, captionURLs: [String] = []) {
        self.id = id; self.platform = platform; self.url = url; self.title = title
        self.moduleCode = moduleCode; self.date = date; self.captionURLs = captionURLs
    }

    /// Panopto's caption download for a session (works for the signed-in browser session).
    public var panoptoCaptionURL: String? {
        guard platform == .panopto, let host = URL(string: url)?.host else { return nil }
        let sid = String(id.dropFirst("panopto:".count))
        return "https://\(host)/Panopto/Pages/Transcription/GenerateSRT.ashx?id=\(sid)&language=0"
    }

    /// Panopto's podcast (audio/video) download for the session.
    public var panoptoPodcastURL: String? {
        guard platform == .panopto, let host = URL(string: url)?.host else { return nil }
        let sid = String(id.dropFirst("panopto:".count))
        return "https://\(host)/Panopto/Podcast/Download/\(sid).mp4?mediaTargetType=audioPodcast"
    }
}

/// Finds recordings in ELE page HTML.
public enum RecordingDetector {
    static let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    public static func detect(html: String, pageTitle: String = "", moduleCode: String? = nil) -> [LectureRecording] {
        var out: [String: LectureRecording] = [:]
        let text = html.replacingOccurrences(of: "&amp;", with: "&")
        let captions = matches("(https?://[^\"'\\s<>]+\\.(?:vtt|srt)(?:\\?[^\"'\\s<>]*)?)", in: text)

        for url in matches("(https?://[^\"'\\s<>]*panopto[^\"'\\s<>]*(?:Viewer|Embed)\\.aspx\\?[^\"'\\s<>]*id=" + uuid + "[^\"'\\s<>]*)", in: text) {
            guard let sid = firstGroup("id=(" + uuid + ")", in: url) else { continue }
            let id = "panopto:\(sid.lowercased())"
            out[id] = LectureRecording(id: id, platform: .panopto, url: url, title: title(near: url, in: text) ?? pageTitle,
                                       moduleCode: moduleCode, captionURLs: captions)
        }
        for url in matches("(https?://[^\"'\\s<>]*echo360[^\"'\\s<>]*/(?:media|lesson|public/media)/[^\"'\\s<>]+)", in: text) {
            let sid = firstGroup("(" + uuid + ")", in: url) ?? MD5.hex(url)
            let id = "echo360:\(sid.lowercased())"
            out[id] = LectureRecording(id: id, platform: .echo360, url: url, title: title(near: url, in: text) ?? pageTitle,
                                       moduleCode: moduleCode, captionURLs: captions)
        }
        for url in matches("(https?://[^\"'\\s<>]+\\.(?:mp4|m4a|mp3|m4v)(?:\\?[^\"'\\s<>]*)?)", in: text) where !url.contains("panopto") {
            let id = "media:\(MD5.hex(url))"
            out[id] = LectureRecording(id: id, platform: .media, url: url, title: title(near: url, in: text) ?? pageTitle,
                                       moduleCode: moduleCode, captionURLs: captions)
        }
        return out.values.sorted { $0.id < $1.id }
    }

    /// Link text of an <a> pointing at `url`, or the iframe's title attribute.
    static func title(near url: String, in html: String) -> String? {
        let esc = NSRegularExpression.escapedPattern(for: url)
        if let t = firstGroup("<a[^>]*href=[\"']" + esc + "[\"'][^>]*>([^<]{3,200})</a>", in: html) { return clean(t) }
        if let t = firstGroup("<iframe[^>]*title=[\"']([^\"']{3,200})[\"'][^>]*src=[\"']" + esc, in: html) { return clean(t) }
        if let t = firstGroup("<iframe[^>]*src=[\"']" + esc + "[\"'][^>]*title=[\"']([^\"']{3,200})[\"']", in: html) { return clean(t) }
        return nil
    }

    static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            let s = ns.substring(with: m.range(at: 1))
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }
}

/// WebVTT / SRT captions → plain transcript.
public enum CaptionParser {
    public struct Cue: Hashable, Sendable {
        public var start: TimeInterval
        public var text: String
    }

    public static func cues(_ raw: String) -> [Cue] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var out: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let start = time(lines[timing].components(separatedBy: "-->")[0])
            let text = lines[(timing + 1)...].map(stripTags).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(Cue(start: start, text: text)) }
        }
        return out
    }

    /// Joins cues into text, dropping consecutive duplicate lines (common in auto-captions).
    public static func transcript(_ raw: String) -> String {
        var last = ""
        var parts: [String] = []
        for c in cues(raw) where c.text != last { parts.append(c.text); last = c.text }
        return parts.joined(separator: " ")
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// "00:01:02.500" / "01:02,500" → seconds.
    static func time(_ s: String) -> TimeInterval {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}

/// How a recording's text will be obtained.
public enum TranscriptSource: String, Codable, Sendable {
    case captions, appleSpeech, whisper, unavailable

    /// Captions first; then on-device speech; then whisper.cpp if installed.
    public static func choose(hasCaptions: Bool, appleSpeechOnDevice: Bool, whisperPath: String?) -> TranscriptSource {
        if hasCaptions { return .captions }
        if appleSpeechOnDevice { return .appleSpeech }
        if whisperPath != nil { return .whisper }
        return .unavailable
    }

    /// Arguments for whisper.cpp's CLI (text output next to the audio file).
    public static func whisperArguments(model: String, audio: String, outputBase: String) -> [String] {
        ["-m", model, "-f", audio, "-l", "en", "-otxt", "-of", outputBase, "-np"]
    }
}

/// What Orbit made from one recording.
public struct LectureDigest: Codable, Hashable, Sendable, Identifiable {
    public struct Card: Codable, Hashable, Sendable { public var front: String; public var back: String
        public init(front: String, back: String) { self.front = front; self.back = back } }

    public var id: String { recordingID }
    public var recordingID: String
    public var title: String
    public var moduleCode: String?
    public var transcriptSource: TranscriptSource
    public var summary: String
    public var keyPoints: [String]
    public var questions: [String]
    public var flashcards: [Card]
    /// Notes comparison, when notes for that lecture were found.
    public var gaps: NotesGapReport?
    public var createdAt: Date

    public init(recordingID: String, title: String, moduleCode: String?, transcriptSource: TranscriptSource,
                summary: String, keyPoints: [String], questions: [String], flashcards: [Card],
                gaps: NotesGapReport? = nil, createdAt: Date = Date()) {
        self.recordingID = recordingID; self.title = title; self.moduleCode = moduleCode
        self.transcriptSource = transcriptSource; self.summary = summary; self.keyPoints = keyPoints
        self.questions = questions; self.flashcards = flashcards; self.gaps = gaps; self.createdAt = createdAt
    }
}

/// "What you might have missed": terms and points from the recording that don't appear in the notes.
public struct NotesGapReport: Codable, Hashable, Sendable {
    public var coverage: Double
    public var missedTerms: [String]
    public var missedPoints: [String]
    public var suggestions: [String]
}

public enum LectureDigester {
    /// Frequent, meaningful terms (unigrams and bigrams) in a text.
    public static func keyTerms(_ text: String, limit: Int = 25) -> [String] {
        let words = tokens(text)
        var counts: [String: Int] = [:]
        for w in words where w.count > 3 && !stopwords.contains(w) { counts[w, default: 0] += 1 }
        for (a, b) in zip(words, words.dropFirst()) where !stopwords.contains(a) && !stopwords.contains(b) && a.count > 2 && b.count > 2 {
            counts["\(a) \(b)", default: 0] += 2
        }
        return counts.filter { $0.value >= 3 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(\.key)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && $0 != "-" }.map(String.init).filter { $0.count > 1 }
    }

    /// Sentences carrying the most key terms (a deterministic summary fallback).
    public static func keySentences(_ text: String, terms: [String], limit: Int = 5) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 30 && $0.count < 300 }
        let scored = sentences.enumerated().map { i, s -> (Int, Int, String) in
            let l = s.lowercased()
            return (terms.filter { l.contains($0) }.count, -i, s)
        }
        return scored.filter { $0.0 > 0 }.sorted { ($0.0, $0.1) > ($1.0, $1.1) }.prefix(limit).sorted { $0.1 > $1.1 }.map { $0.2 + "." }
    }

    /// Compares a recording transcript with the student's notes for the same lecture.
    public static func compare(transcript: String, notes: String) -> NotesGapReport {
        let terms = keyTerms(transcript)
        let notesLower = notes.lowercased()
        let notesTokens = Set(tokens(notes))
        func covered(_ term: String) -> Bool {
            if notesLower.contains(term) { return true }
            let parts = term.split(separator: " ").map(String.init)
            return parts.count > 1 && parts.allSatisfy { notesTokens.contains($0) || notesTokens.contains(String($0.prefix(5))) }
        }
        let missed = terms.filter { !covered($0) }
        let coverage = terms.isEmpty ? 1 : Double(terms.count - missed.count) / Double(terms.count)
        let points = keySentences(transcript, terms: Array(missed.prefix(8)), limit: 4)
        var suggestions: [String] = []
        if coverage < 0.5 { suggestions.append("Your notes cover under half of the lecture's main terms. Rewatch the sections on \(missed.prefix(3).joined(separator: ", ")).") }
        for t in missed.prefix(4) { suggestions.append("Add a line defining \u{201C}\(t)\u{201D} and how it links to the rest of the lecture.") }
        if !points.isEmpty { suggestions.append("Add a worked example or diagram for the points listed under 'might have missed'.") }
        if suggestions.isEmpty { suggestions.append("Good coverage. Try writing a 3-line summary from memory to test recall.") }
        return NotesGapReport(coverage: coverage, missedTerms: Array(missed.prefix(10)), missedPoints: points, suggestions: suggestions)
    }

    struct AIOutput: Decodable {
        var summary: String?
        var keyPoints: [String]?
        var questions: [String]?
        var flashcards: [LectureDigest.Card]?
    }

    public static func request(title: String, moduleCode: String?, transcript: String) -> LLMRequest {
        let clipped = String(transcript.prefix(24_000))
        return LLMRequest(messages: [
            .system("""
            You help a first-year Economics student at Exeter aiming for a top First. From a lecture transcript, reply ONLY with JSON:
            {"summary": "5-7 sentence summary", "keyPoints": ["..."], "questions": ["exam-style questions, 5"],
             "flashcards": [{"front": "...", "back": "..."}]} (8-12 flashcards, UK English, precise economics).
            """),
            .user("Lecture: \(title)\(moduleCode.map { " (\($0))" } ?? "")\n\nTranscript:\n\(clipped)"),
        ], purpose: .reasoning, json: true, temperature: 0.2)
    }

    /// Builds the digest with the AI, falling back to a deterministic version.
    public static func digest(recording: LectureRecording, transcript: String, source: TranscriptSource,
                              notes: String?, router: LLMRouter?, now: Date = Date()) async -> LectureDigest {
        let terms = keyTerms(transcript)
        var d = LectureDigest(recordingID: recording.id, title: recording.title, moduleCode: recording.moduleCode,
                              transcriptSource: source, summary: keySentences(transcript, terms: terms).joined(separator: " "),
                              keyPoints: Array(terms.prefix(8)), questions: terms.prefix(5).map { "Explain \($0) and why it matters in this lecture." },
                              flashcards: [], createdAt: now)
        if let router, let out = try? await router.completeJSON(AIOutput.self, request(title: recording.title, moduleCode: recording.moduleCode, transcript: transcript)) {
            if let s = out.summary, !s.isEmpty { d.summary = s }
            if let k = out.keyPoints, !k.isEmpty { d.keyPoints = k }
            if let q = out.questions, !q.isEmpty { d.questions = q }
            d.flashcards = out.flashcards ?? []
        }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            d.gaps = compare(transcript: transcript, notes: notes)
        }
        return d
    }

    static let stopwords: Set<String> = [
        "the", "and", "that", "this", "with", "have", "from", "they", "what", "which", "there", "their", "about", "would",
        "will", "into", "then", "than", "them", "these", "those", "when", "where", "your", "you're", "just", "like", "really",
        "okay", "going", "gonna", "know", "think", "because", "so", "we", "is", "it", "to", "of", "a", "in", "on", "for",
        "are", "be", "as", "at", "or", "an", "if", "but", "not", "can", "do", "all", "our", "was", "were", "its", "it's",
        "also", "some", "more", "very", "here", "right", "well", "yeah", "actually", "basically", "thing", "things", "look",
        "let's", "want", "does", "been", "being", "each", "other", "over", "only", "same", "such", "much", "many", "make",
        "take", "get", "got", "say", "said", "see", "one", "two", "you", "i", "me", "my", "he", "she", "his", "her", "him",
        "has", "had", "how", "why", "who", "any", "now", "out", "up", "no", "yes", "by", "could", "should", "might", "must",
        "mean", "sort", "kind", "bit", "lot", "come", "go", "put", "time", "way", "need", "okay", "slide", "slides", "lecture",
        "week", "today", "question", "questions", "people",
    ]
}

/// Tracks which recordings were processed, so new ones run automatically.
public struct RecordingLedger: Codable, Hashable, Sendable {
    public var known: [String: LectureRecording] = [:]
    public var processed: Set<String> = []
    public var failed: [String: String] = [:]
    public init() {}

    /// Adds newly seen recordings and returns the ones still to process (oldest first).
    public mutating func register(_ found: [LectureRecording]) -> [LectureRecording] {
        for r in found where known[r.id] == nil { known[r.id] = r }
        return pending
    }

    public var pending: [LectureRecording] {
        known.values.filter { !processed.contains($0.id) && failed[$0.id] == nil }
            .sorted { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
    }
}
