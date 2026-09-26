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

    private var pending: [StoredPlan] { plans.filter { !$0.isTicketDrop && $0.status == .pending && $0.start > Date().addingTimeInterval(-3600) } }
    private var drops: [StoredPlan] { plans.filter { $0.isTicketDrop && $0.status == .pending && $0.start > Date().addingTimeInterval(-3600) } }
    private var accepted: [StoredPlan] { plans.filter { $0.status == .accepted && $0.start > Date().addingTimeInterval(-86400) } }

    var body: some View {
        Page {
            PageHeader(title: "Plans", subtitle: pending.isEmpty ? "Nothing waiting" : "\(pending.count) suggestion\(pending.count == 1 ? "" : "s") from your messages")

            importRow

            PageSection(title: "Suggested", count: pending.isEmpty ? nil : pending.count) {
                if pending.isEmpty {
                    EmptyState(title: "No plans waiting.",
                               message: "Import a chat or share a message to Orbit and any plans in it show up here.")
                }
                VStack(spacing: 0) {
                    ForEach(pending) { plan in
                        PlanCard(plan: plan, onAccept: {
                            tick += 1
                            Task { await app.accept(plan) }
                        }, onDismiss: {
                            withAnimation(Motion.smooth) { app.dismiss(plan) }
                        })
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                        if plan.id != pending.last?.id { Hairline() }
                    }
                }
            }

            if !drops.isEmpty {
                PageSection(title: "Tickets on sale", count: drops.count) {
                    VStack(spacing: 0) {
                        ForEach(drops) { drop in
                            TicketDropCard(drop: drop)
                            if drop.id != drops.last?.id { Hairline() }
                        }
                    }
                }
            }

            if !accepted.isEmpty {
                PageSection(title: "Added", count: accepted.count) {
                    VStack(spacing: 0) {
                        ForEach(accepted) { plan in
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: plan.calendarEventID == nil ? "clock" : "checkmark")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 16)
                                Text(plan.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(Fmt.dayTime(plan.start, app.calendar))
                                    .font(Theme.caption.monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .frame(height: 32)
                            .hoverRow()
                            .help(plan.calendarEventID == nil ? "Waiting to be added to your calendar" : "On your calendar")
                        }
                    }
                }
            }
        }
        .animation(Motion.smooth, value: pending.map(\.id))
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

    private var importRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Orbit never logs in to WhatsApp or Instagram. Export a chat, share a message, or drop in a screenshot.")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.xs) {
                Button("WhatsApp export…") { importKind = .whatsApp; importing = true }
                Button("Instagram folder…") { importKind = .instagram; importing = true }
                Button("Paste text…") { showPaste = true }
                PhotosPicker(selection: $photo, matching: .images) { Text("Screenshot…") }
                if busy { ProgressView().controlSize(.small).padding(.leading, Theme.Space.s) }
            }
            .buttonStyle(SoftButtonStyle(color: Theme.accent))
            .padding(.leading, -Theme.Space.s)
            .disabled(busy)
            #if os(macOS)
            IMessageToggle()
            #endif
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
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(plan.title)
                    .font(Theme.large.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s)
                Text("\(plan.sourceLabel) · \(Int((plan.confidence * 100).rounded()))% sure")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(details)
                .font(Theme.body.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            if !plan.quote.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Rectangle().fill(Theme.border).frame(width: 2)
                    Text(plan.quote)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.Space.xs)
            }
            ForEach(plan.conflicts, id: \.self) { c in
                Text("Clashes with \(c)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Add to calendar", action: onAccept)
                    .buttonStyle(.borderedProminent)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
            }
            .controlSize(.small)
            .padding(.top, Theme.Space.xs)
        }
        .padding(.vertical, Theme.Space.m)
    }

    private var details: String {
        var parts = [Fmt.dayTime(plan.start, app.calendar)]
        if let kind = plan.kindLabel { parts.insert(kind, at: 0) }
        if let loc = plan.location, !loc.isEmpty { parts.append(loc) }
        if !plan.people.isEmpty { parts.append(plan.people.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// A promo / ticket drop from messages: info with a Buy link, not a plan.
struct TicketDropCard: View {
    @Environment(AppModel.self) private var app
    var drop: StoredPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Label(drop.title, systemImage: "ticket")
                    .font(Theme.large.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s)
                Text("\(drop.kindLabel ?? "Tickets on sale") · \(drop.sourceLabel)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text([Fmt.dayTime(drop.start, app.calendar), drop.location].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.body.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Text("A promo, not a plan. Orbit won't add it unless you get a ticket.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
            actions
        }
        .padding(.vertical, Theme.Space.m)
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            if let url = drop.buyURL.flatMap(URL.init(string:)) {
                Button("Buy") { openExternal(url) }.buttonStyle(.borderedProminent)
            }
            Button("Remind me before it sells out") { app.remindToBuy(drop) }.buttonStyle(.bordered)
            Menu("Add if I buy") {
                Button("Add when my ticket email arrives") { app.addIfBought(drop) }
                Button("I've got a ticket, add it now") { Task { await app.boughtTicket(drop) } }
            }
            .fixedSize()
            Button("Dismiss") { withAnimation(Motion.smooth) { app.dismiss(drop) } }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
        }
        .controlSize(.small)
        .padding(.top, Theme.Space.xs)
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
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $text)
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.s)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
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
