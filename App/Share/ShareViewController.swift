import UIKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import OrbitCore

/// "Share to Orbit": text, links and screenshots. Runs the rule-based plan
/// finder and quick-add parser on the phone (no network), then leaves a small
/// JSON file in the App Group that the app picks up next time it opens.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(extensionContext: extensionContext)
        self.model = model
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
@Observable
final class ShareModel {
    @ObservationIgnored private weak var extensionContext: NSExtensionContext?
    var text = ""
    var image: Data?
    var plans: [ExtractedPlan] = []
    var task: QuickAddResult?
    var loading = true
    var savedPlanIDs: Set<UUID> = []
    var savedTask = false
    var savedOther = false
    var error: String?

    private let timeZone = TimeZone(identifier: "Europe/London")!

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
    }

    func load() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var pieces: [String] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    image = await loadImage(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                        pieces.append(url.absoluteString)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let s = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                        pieces.append(s)
                    }
                }
            }
            if pieces.isEmpty, let s = item.attributedContentText?.string, !s.isEmpty { pieces.append(s) }
        }
        text = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            var names: Set<String> = ["Me", "You"]
            if let name = AppGroup.defaults.string(forKey: "firstName"), !name.isEmpty { names.insert(name) }
            // Rule stage only: nothing leaves the phone from the extension.
            plans = await PlanExtractor(router: nil, timeZone: timeZone).extract(fromSharedText: text, myNames: names)
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
            task = QuickAddParser(now: Date(), timeZone: timeZone).parse(String(firstLine.prefix(200)))
        }
        loading = false
    }

    private func loadImage(_ provider: NSItemProvider) async -> Data? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) else { return nil }
        if let url = item as? URL { return try? Data(contentsOf: url) }
        if let data = item as? Data { return data }
        if let image = item as? UIImage { return image.jpegData(compressionQuality: 0.9) }
        return nil
    }

    func save(plan: ExtractedPlan) {
        do {
            try PendingInbox.save(PendingInboxItem(kind: .plan, text: text, title: plan.title, start: plan.start, end: plan.end,
                                                   location: plan.location, people: plan.people, quote: plan.quote,
                                                   confidence: plan.confidence))
            savedPlanIDs.insert(plan.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveTask() {
        guard let t = task?.task else { return }
        do {
            try PendingInbox.save(PendingInboxItem(kind: .task, text: text, title: t.title, estimateMinutes: t.estimateMinutes,
                                                   deadline: t.deadline, moduleCode: t.moduleCode))
            savedTask = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Screenshots (and text with no obvious plan) are read properly by the app.
    func saveForApp() {
        do {
            if let image {
                try PendingInbox.save(PendingInboxItem(kind: .image), imageData: image)
            } else {
                try PendingInbox.save(PendingInboxItem(kind: .text, text: text))
            }
            savedOther = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func done() { extensionContext?.completeRequest(returningItems: nil) }

    func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "Orbit.Share", code: NSUserCancelledError))
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.loading {
                        ProgressView("Reading…").frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        content
                    }
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(Theme.danger)
                    }
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Add to Orbit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { model.done() }.bold() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let data = model.image, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
            Button(model.savedOther ? "Saved: Orbit will read it next time it opens" : "Find plans in this screenshot") {
                model.saveForApp()
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.savedOther)
        }

        if !model.text.isEmpty {
            Text(model.text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(6)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        }

        if !model.plans.isEmpty {
            Text("Plans found").font(Theme.headline)
            ForEach(model.plans) { plan in
                let saved = model.savedPlanIDs.contains(plan.id)
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plan.title).font(Theme.headline)
                        Text(plan.start.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        if !plan.people.isEmpty {
                            Text(plan.people.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Button(saved ? "Added to suggestions" : "Suggest this plan") { model.save(plan: plan) }
                            .buttonStyle(SoftButtonStyle(color: saved ? Theme.success : Theme.accent))
                            .disabled(saved)
                    }
                }
            }
        }

        if let result = model.task, !result.task.title.isEmpty {
            Text("Or add as a to-do").font(Theme.headline)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.task.title).font(Theme.body.weight(.medium))
                    HStack(spacing: 6) {
                        Tag(text: "\(result.task.estimateMinutes) min", systemImage: "timer")
                        if let d = result.task.deadline {
                            Tag(text: d.formatted(date: .abbreviated, time: .shortened), color: Theme.warning, systemImage: "flag")
                        }
                        ModuleChip(code: result.task.moduleCode)
                    }
                    Button(model.savedTask ? "Added" : "Add to-do") { model.saveTask() }
                        .buttonStyle(SoftButtonStyle(color: model.savedTask ? Theme.success : Theme.accent))
                        .disabled(model.savedTask)
                }
            }
        }

        if model.plans.isEmpty && !model.text.isEmpty && model.image == nil {
            Button(model.savedOther ? "Saved for Orbit to read properly" : "Let Orbit read it properly later") { model.saveForApp() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.savedOther)
        }
    }
}
