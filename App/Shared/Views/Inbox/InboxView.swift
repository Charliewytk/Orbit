import SwiftUI
import SwiftData
import OrbitCore

struct InboxView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredEmailDigest.date, order: .reverse) private var digests: [StoredEmailDigest]
    @State private var accountFilter: MailAccount?
    @State private var showHandled = false
    @State private var drafting: StoredEmailDigest?

    private static let order: [EmailCategory] = [.urgent, .needsReply, .hasDate, .uni, .other, .ignore]

    private var visible: [StoredEmailDigest] {
        digests.filter { d in
            (showHandled || !d.handled) && (accountFilter == nil || d.account == accountFilter)
                && d.date > Date().addingTimeInterval(-21 * 86400)
        }
    }

    var body: some View {
        List {
            if visible.isEmpty {
                EmptyState(systemImage: "tray", title: "Inbox zero-ish",
                           message: app.backend.isBrain
                               ? "Connect Gmail or Exeter in Settings and Orbit will sort your mail here."
                               : "Mail your Mac has sorted shows up here.")
                    .listRowBackground(Color.clear)
            }
            ForEach(Self.order, id: \.self) { category in
                let group = visible.filter { $0.category == category }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { digest in
                            DigestRow(digest: digest, onDraft: { drafting = digest })
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        withAnimation(Theme.spring) { app.markHandled(digest, !digest.handled) }
                                    } label: {
                                        Label(digest.handled ? "Unhide" : "Done", systemImage: digest.handled ? "tray.and.arrow.up" : "checkmark")
                                    }
                                    .tint(Theme.success)
                                }
                                .contextMenu {
                                    Button(digest.handled ? "Show in inbox" : "Mark as done") { app.markHandled(digest, !digest.handled) }
                                    if let url = digest.webURL { Button("Open in browser") { openExternal(url) } }
                                }
                        }
                    } header: {
                        Text("\(category.emoji)  \(title(category))")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .orbitBackground()
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Account", selection: $accountFilter) {
                        Text("All accounts").tag(MailAccount?.none)
                        Text("Gmail").tag(MailAccount?.some(.gmail))
                        Text("Exeter").tag(MailAccount?.some(.exeter))
                    }
                    Toggle("Show done", isOn: $showHandled)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(item: $drafting) { digest in
            DraftReplySheet(digest: digest)
        }
    }

    private func title(_ c: EmailCategory) -> String {
        switch c {
        case .urgent: "Urgent"
        case .needsReply: "Needs a reply"
        case .hasDate: "Dates & plans"
        case .uni: "Uni"
        case .other: "Other"
        case .ignore: "Low priority"
        }
    }
}

struct DigestRow: View {
    @Environment(AppModel.self) private var app
    var digest: StoredEmailDigest
    var onDraft: () -> Void
    @State private var added = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(digest.from)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                AccountBadge(account: digest.account)
                Spacer()
                Text(Fmt.day(digest.date, app.calendar) == "Today" ? app.calendar.time(digest.date) : Fmt.day(digest.date, app.calendar))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(digest.subject)
                .font(Theme.callout.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if !digest.summary.isEmpty {
                Text(digest.summary)
                    .font(Theme.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
            }

            let tasks = digest.suggestedTasks
            let events = digest.suggestedEvents
            if !tasks.isEmpty || !events.isEmpty {
                Flow {
                    ForEach(Array(tasks.enumerated()), id: \.offset) { i, t in
                        suggestionButton(title: t.title, symbol: "checklist", done: digest.addedSuggestions.contains("task:\(i)")) {
                            app.addSuggestedTask(digest, index: i)
                        }
                    }
                    ForEach(Array(events.enumerated()), id: \.offset) { i, e in
                        suggestionButton(title: "\(e.title) · \(Fmt.dayTime(e.start, app.calendar))", symbol: "calendar.badge.plus",
                                         done: digest.addedSuggestions.contains("event:\(i)")) {
                            Task { await app.addSuggestedEvent(digest, index: i) }
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                Button(action: onDraft) {
                    Label(digest.draftReply == nil ? "Draft reply" : "View draft", systemImage: "square.and.pencil")
                }
                if let url = digest.webURL {
                    Button { openExternal(url) } label: {
                        Label(digest.account == .gmail ? "Open in Gmail" : "Open in Outlook", systemImage: "arrow.up.right.square")
                    }
                }
                Spacer()
                if digest.draftSavedAt != nil {
                    Label("Draft saved", systemImage: "checkmark.seal").foregroundStyle(Theme.success)
                }
            }
            .font(Theme.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 6)
        .opacity(digest.handled ? 0.5 : 1)
        .successHaptic(added)
    }

    private func suggestionButton(title: String, symbol: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button {
            added += 1
            withAnimation(Theme.spring) { action() }
        } label: {
            Label(done ? "Added" : title, systemImage: done ? "checkmark" : symbol)
                .lineLimit(1)
        }
        .buttonStyle(SoftButtonStyle(color: done ? Theme.success : Theme.accent))
        .disabled(done)
    }
}

/// Shows (or asks the Mac for) a reply draft, lets you edit it, then saves it
/// as a draft in the right mailbox. Nothing is ever sent.
struct DraftReplySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var digest: StoredEmailDigest
    @State private var text = ""
    @State private var loading = false
    @State private var queued = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Re: \(digest.subject)").font(Theme.headline).lineLimit(2)
                    Text("To \(digest.from)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                if loading {
                    HStack { ProgressView(); Text("Drafting in your tone…").foregroundStyle(Theme.textSecondary) }
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if queued && (digest.draftReply ?? "").isEmpty {
                    EmptyState(systemImage: "desktopcomputer", title: "Your Mac is drafting this",
                               message: "It'll appear here when your Mac has written it (it needs to be awake).")
                } else {
                    TextEditor(text: $text)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                        .frame(minHeight: 240)
                }
                if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.danger) }
                Text("Saved as a draft in \(digest.account == .gmail ? "Gmail" : "your Exeter mailbox"). Orbit never sends email.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding()
            .navigationTitle("Draft reply")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save draft") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 440)
        .task { await load() }
        .onChange(of: digest.draftReply) { _, new in
            if let new, text.isEmpty { text = new; queued = false }
        }
    }

    private func load() async {
        if let existing = digest.draftReply, !existing.isEmpty { text = existing; return }
        loading = true
        defer { loading = false }
        do {
            if let draft = try await app.backend.draftReply(digestID: digest.id) {
                text = draft
            } else {
                queued = true
            }
        } catch {
            self.error = "Couldn't draft a reply: \(error.localizedDescription)"
        }
    }

    private func save() {
        let body = text
        Task {
            do {
                try await app.backend.saveDraft(digestID: digest.id, body: body)
                app.show(app.backend.isBrain ? "Draft saved" : "Your Mac will save the draft")
                dismiss()
            } catch {
                self.error = "Couldn't save the draft: \(error.localizedDescription)"
            }
        }
    }
}
