import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import OrbitCore

struct PlansView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredPlan.start) private var plans: [StoredPlan]
    /// One file importer for both kinds (SwiftUI only honours one `.fileImporter` per view).
    private enum ImportKind { case whatsApp, instagram }
    @State private var importKind: ImportKind = .whatsApp
    @State private var importing = false
    @State private var showPaste = false
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var tick = 0

    private var pending: [StoredPlan] { plans.filter { $0.status == .pending && $0.start > Date().addingTimeInterval(-3600) } }
    private var accepted: [StoredPlan] { plans.filter { $0.status == .accepted && $0.start > Date().addingTimeInterval(-86400) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                importCard

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Suggested plans", subtitle: "Found in your messages. Nothing's added until you tap.")
                    if pending.isEmpty {
                        Card {
                            EmptyState(systemImage: "person.2", title: "No plans waiting",
                                       message: "Import a chat or share a message to Orbit and any plans in it show up here.")
                        }
                    }
                    ForEach(pending) { plan in
                        PlanCard(plan: plan, onAccept: {
                            tick += 1
                            Task { await app.accept(plan) }
                        }, onDismiss: {
                            withAnimation(Theme.spring) { app.dismiss(plan) }
                        })
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }

                if !accepted.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Added")
                        ForEach(accepted) { plan in
                            HStack {
                                Image(systemName: plan.calendarEventID == nil ? "clock" : "checkmark.circle.fill")
                                    .foregroundStyle(plan.calendarEventID == nil ? Theme.warning : Theme.success)
                                Text(plan.title).font(Theme.callout)
                                Spacer()
                                Text(Fmt.dayTime(plan.start, app.calendar)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .padding(Theme.padding)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .animation(Theme.spring, value: pending.map(\.id))
        }
        .orbitBackground()
        .navigationTitle("Plans")
        .successHaptic(tick)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importKind == .whatsApp ? [.plainText, .zip, .text] : [.folder]) { result in
            guard case .success(let url) = result else { return }
            switch importKind {
            case .whatsApp: run("WhatsApp chat") { try await app.importWhatsApp(url: url) }
            case .instagram: run("Instagram export") { try await app.importInstagram(folder: url) }
            }
        }
        .sheet(isPresented: $showPaste) {
            PasteTextSheet { text in run("pasted text") { await app.importText(text) } }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            run("screenshot") {
                guard let data = try await item.loadTransferable(type: Data.self) else { return 0 }
                return try await app.importScreenshot(data)
            }
            photo = nil
        }
    }

    private var importCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Find plans in your messages", systemImage: "text.magnifyingglass")
                        .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                Text("Orbit never logs in to WhatsApp or Instagram. Export a chat, share a message, or drop in a screenshot.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Flow(spacing: 8) {
                    Button { importKind = .whatsApp; importing = true } label: { Label("WhatsApp export", systemImage: "phone.bubble") }
                    Button { importKind = .instagram; importing = true } label: { Label("Instagram folder", systemImage: "camera") }
                    Button { showPaste = true } label: { Label("Paste text", systemImage: "doc.on.clipboard") }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Screenshot", systemImage: "photo") }
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(busy)
                #if os(macOS)
                IMessageToggle()
                #endif
            }
        }
    }

    private func run(_ what: String, _ work: @escaping () async throws -> Int) {
        busy = true
        Task {
            do {
                let n = try await work()
                app.show(n == 0 ? "No new plans in that \(what)" : "Found \(n) plan\(n == 1 ? "" : "s") in that \(what)")
            } catch {
                app.show("Couldn't read that \(what): \(error.localizedDescription)")
            }
            busy = false
        }
    }
}

struct PlanCard: View {
    @Environment(AppModel.self) private var app
    var plan: StoredPlan
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(plan.sourceLabel, systemImage: plan.sourceSymbol)
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    if let kind = plan.kindLabel { Tag(text: kind, color: Theme.accent) }
                    Spacer()
                    Text("\(Int((plan.confidence * 100).rounded()))% sure")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Text(plan.title).font(Theme.title(20)).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 10) {
                    Label(Fmt.dayTime(plan.start, app.calendar), systemImage: "clock")
                    if let loc = plan.location, !loc.isEmpty { Label(loc, systemImage: "mappin") }
                }
                .font(Theme.callout).foregroundStyle(Theme.textSecondary)
                if !plan.people.isEmpty {
                    Label(plan.people.joined(separator: ", "), systemImage: "person.2")
                        .font(Theme.callout).foregroundStyle(Theme.textSecondary)
                }
                if !plan.quote.isEmpty {
                    Text("“\(plan.quote)”")
                        .font(Theme.callout.italic())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                }
                ForEach(plan.conflicts, id: \.self) { c in
                    Label("Clashes with \(c)", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.caption).foregroundStyle(Theme.warning)
                }
                HStack(spacing: 10) {
                    Button(action: onAccept) { Label("Add to calendar", systemImage: "calendar.badge.plus") }
                        .buttonStyle(PillButtonStyle())
                    Button(action: onDismiss) { Label("Dismiss", systemImage: "xmark") }
                        .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
                }
            }
        }
    }
}

struct PasteTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste a message or a few lines of chat. Orbit looks for plans like “dinner Sat 7pm?”.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $text)
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            .padding()
            .navigationTitle("Paste text")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Find plans") { onSubmit(text); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}
