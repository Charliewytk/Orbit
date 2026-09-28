import SwiftUI
import OrbitCore

/// Lecture recordings found on ELE: summaries, questions, flashcards and "what you might have missed".
struct LecturesView: View {
    @State private var selection: String?
    @AppStorage(CompanionHub.Keys.recordingsAuto) private var auto = true
    private var companion: CompanionHub { .shared }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .orbitBackground()
        .navigationTitle("Lectures")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Process automatically", isOn: $auto)
                    .toggleStyle(.switch)
                    .help("Check ELE for new recordings every couple of hours and process them")
                Button {
                    Task {
                        await companion.scanRecordings(now: Date())
                        await companion.processPendingRecordings(limit: 3)
                    }
                } label: { Label("Check ELE now", systemImage: "arrow.clockwise") }
            }
        }
    }

    private var recordings: [LectureRecording] {
        companion.state.recordings.known.values.sorted { ($0.moduleCode ?? "", $0.week ?? 0, $0.title) > ($1.moduleCode ?? "", $1.week ?? 0, $1.title) }
    }

    private var list: some View {
        List(selection: $selection) {
            if !companion.status.isEmpty {
                Text(companion.status).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(recordings) { r in
                RecordingRow(recording: r).tag(r.id)
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if recordings.isEmpty {
                EmptyState(systemImage: "play.rectangle", title: "No recordings found yet",
                           message: "Orbit looks for Panopto and Echo360 recordings on your ELE pages after each sync.")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let digest = companion.state.digests.first(where: { $0.recordingID == id }) {
            LectureDigestView(digest: digest)
        } else if let id = selection, let r = companion.state.recordings.known[id] {
            VStack(spacing: Theme.Space.m) {
                Text(r.title).font(Theme.headline)
                if let why = companion.state.recordings.failed[id] {
                    Text(why).font(Theme.body).foregroundStyle(Theme.textSecondary)
                    Button("Try again") { companion.retry(id) }
                } else {
                    Button("Process now") { Task { await companion.process(r) } }
                        .disabled(companion.processingRecording != nil)
                }
                Link("Open recording", destination: URL(string: r.url) ?? URL(string: "https://ele.exeter.ac.uk")!)
            }
            .padding()
        } else {
            EmptyState(systemImage: "waveform", title: "Pick a lecture",
                       message: "Captions are used when provided; otherwise audio is transcribed on this Mac.")
        }
    }
}

struct RecordingRow: View {
    var recording: LectureRecording
    private var companion: CompanionHub { .shared }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ModuleDot(code: recording.moduleCode, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(Theme.body).lineLimit(2)
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Image(systemName: icon).foregroundStyle(Theme.textTertiary)
        }
    }

    private var subtitle: String {
        [recording.moduleCode, recording.week.map { "week \($0)" }, recording.platform.rawValue.capitalized].compactMap { $0 }.joined(separator: " · ")
    }

    private var icon: String {
        if companion.processingRecording == recording.id { return "hourglass" }
        if companion.state.recordings.processed.contains(recording.id) { return "checkmark.circle.fill" }
        if companion.state.recordings.failed[recording.id] != nil { return "exclamationmark.circle" }
        return "circle.dotted"
    }
}

struct LectureDigestView: View {
    var digest: LectureDigest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(digest.title).font(Theme.pageTitle)
                Text("From \(digest.transcriptSource == .captions ? "provided captions" : "an on-device transcript")")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                DigestSection(title: "Summary") { Text(digest.summary).font(Theme.body).textSelection(.enabled) }
                DigestSection(title: "Key points") { BulletList(items: digest.keyPoints) }
                if let gaps = digest.gaps { GapReportView(report: gaps) }
                DigestSection(title: "Practice questions") { BulletList(items: digest.questions) }
                if !digest.flashcards.isEmpty {
                    DigestSection(title: "Flashcards (\(digest.flashcards.count), added to your deck)") {
                        ForEach(digest.flashcards, id: \.front) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.front).font(Theme.body.weight(.semibold))
                                Text(c.back).font(Theme.body).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct GapReportView: View {
    var report: NotesGapReport

    var body: some View {
        DigestSection(title: "What you might have missed (\(Int(report.coverage * 100))% of key terms in your notes)") {
            if !report.missedTerms.isEmpty {
                Text(report.missedTerms.joined(separator: " · ")).font(Theme.body).foregroundStyle(Theme.warning)
            }
            BulletList(items: report.missedPoints)
            Text("Suggestions").font(Theme.headline).padding(.top, 4)
            BulletList(items: report.suggestions)
        }
    }
}

struct DigestSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitGlassCard()
    }
}

struct BulletList: View {
    var items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(Theme.textTertiary)
                    Text(item).font(Theme.body).textSelection(.enabled)
                }
            }
        }
    }
}
