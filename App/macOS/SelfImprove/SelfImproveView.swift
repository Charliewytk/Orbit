import SwiftUI
import OrbitCore

/// Settings → Improve: type a change, let the local OpenCode agent edit Orbit's
/// source, verify and rebuild it, then review the diff and install or discard.
struct SelfImproveSettingsTab: View {
    @State private var service = SelfImproveService.shared
    @AppStorage(SelfImproveService.Keys.autoFix) private var autoFix = true
    @AppStorage(SelfImproveService.Keys.localChangesPolicy) private var policyRaw = LocalChangesPolicy.ask.rawValue
    @State private var showPatch = false

    var body: some View {
        Form {
            setupSection
            sourceSection
            requestSection
            if case .review(let diff) = service.phase { reviewSection(diff) }
            logSection
            safetySection
        }
        .formStyle(.grouped)
        .task {
            if service.checks.contains(where: { $0.ok == nil }) { await service.runChecks() }
            service.refreshBackups()
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            ForEach(service.checks) { r in
                HStack(alignment: .top) {
                    Image(systemName: r.ok == nil ? "circle.dotted" : (r.ok! ? "checkmark.circle.fill" : "xmark.circle.fill"))
                        .foregroundStyle(r.ok == nil ? Color.secondary : (r.ok! ? Color.green : Color.red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.check.title)
                        if !r.detail.isEmpty {
                            Text(r.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if r.ok == false, r.check.brewPackage != nil {
                        Button("Install with Homebrew") { Task { await service.brewInstall(r.check) } }
                            .disabled(service.phase.isBusy)
                    }
                }
            }
            Button(service.checking ? "Checking…" : "Check again") { Task { await service.runChecks() } }
                .disabled(service.checking)
        } header: {
            Text("Setup")
        } footer: {
            Text("Improve Orbit uses Xcode, git, XcodeGen and the OpenCode CLI on this Mac. Nothing is sent to Claude.")
        }
    }

    // MARK: Source

    private var sourceSection: some View {
        Section("Source") {
            LabeledContent("Folder") {
                Text(service.sourceDir).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            HStack {
                Button("Choose…") { service.chooseSourceFolder() }
                Button(service.hasSource ? "Pull updates from GitHub" : "Download source") {
                    service.updateSource()
                }
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: service.sourceDir) }
                    .disabled(!service.hasSource)
            }
            .disabled(service.phase.isBusy || service.sourceBusy)
            Text("Changes are kept on the local branch \(SelfImproveConfig.localBranch); pulling merges GitHub's main into it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Request

    private var requestSection: some View {
        Section("What should change?") {
            TextEditor(text: $service.request)
                .font(.body)
                .frame(minHeight: 80)
                .disabled(service.phase.isBusy)
            Toggle("If the build fails, let OpenCode try to fix it (up to 2 times)", isOn: $autoFix)
            LabeledContent("Model") {
                Text("\(service.model ?? OpenCodeModelResolver.preferredName) · \(service.variant)").foregroundStyle(.secondary)
            }
            HStack {
                statusLabel
                Spacer()
                if service.phase.isBusy {
                    Button("Cancel", role: .cancel) { service.cancel() }
                } else {
                    Button("Improve Orbit") { service.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!service.allChecksPass || service.sourceBusy
                                  || service.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if case .failed = service.phase {
                Button("Discard changes") { service.discard() }
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            if service.phase.isBusy { ProgressView().controlSize(.small) }
            Text(service.phase.label).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Review

    private func reviewSection(_ diff: DiffSummary) -> some View {
        Section("Review") {
            Text(diff.headline).font(.headline)
            ForEach(diff.files, id: \.path) { f in
                HStack {
                    Text(f.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if f.isBinary { Text("binary").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Text("+\(f.added ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                        Text("−\(f.removed ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                    }
                }
            }
            if !diff.suspiciousPaths.isEmpty {
                Label("Check these files for secrets before accepting: \(diff.suspiciousPaths.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            DisclosureGroup("Full diff", isExpanded: $showPatch) {
                ScrollView([.vertical, .horizontal]) {
                    Text(service.patch).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            HStack {
                Button("Discard", role: .destructive) { service.discard() }
                Spacer()
                Button("Accept, install and restart") { service.accept() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Log

    private var logSection: some View {
        Section("Log") {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(service.log.isEmpty ? "Output from OpenCode and the build appears here." : service.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(service.log.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 220)
                .onChange(of: service.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    // MARK: Safety

    private var safetySection: some View {
        Section {
            Picker("When a GitHub update arrives", selection: $policyRaw) {
                Text("Ask me").tag(LocalChangesPolicy.ask.rawValue)
                Text("Keep my local changes (merge and rebuild)").tag(LocalChangesPolicy.keepLocal.rawValue)
                Text("Install the GitHub version").tag(LocalChangesPolicy.useRelease.rawValue)
            }
            Text(service.isLocalBuildInstalled ? "This copy of Orbit was built locally by Improve Orbit." : "This copy of Orbit is the GitHub build.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Roll back to previous version") { service.rollBack() }
                    .disabled(service.backups.isEmpty || service.phase.isBusy)
                Spacer()
                if let latest = service.backups.first { Text(latest).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Updates and roll back")
        } footer: {
            Text("Before each install the current app is copied to \(service.backupsDir) (the last 5 are kept).")
        }
    }
}
