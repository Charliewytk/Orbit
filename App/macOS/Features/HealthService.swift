import AppKit
import Foundation
import Observation
import SwiftData
import UserNotifications
import OrbitCore

/// One row of the health check: a connection or job, how it's doing, and the exact fix.
struct HealthRow: Identifiable {
    enum Level: Int, Comparable {
        case ok = 0, warning = 1, broken = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var title: String
    var symbol: String
    var level: Level
    /// Last successful sync / check.
    var lastOK: Date?
    /// Short status or error.
    var detail: String
    var fixTitle: String?
    var fix: (@MainActor () async -> Void)?
}

/// Builds the health check (Settings → Health, and the status pill on Home) from the
/// services' own status: sync records, sign-ins, permissions, AI, money and backups.
@MainActor
@Observable
final class HealthService {
    @ObservationIgnored weak var hub: FeatureHub?
    private(set) var rows: [HealthRow] = []
    private(set) var checkedAt: Date?
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var checking = false

    var worst: HealthRow.Level { rows.map(\.level).max() ?? .ok }
    var problems: [HealthRow] { rows.filter { $0.level != .ok } }

    /// Refreshes the permission checks, then rebuilds the rows.
    func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        notificationStatus = await Notifier.authorizationStatus()
        MacCalendarAccess.shared.refresh()
        await ExeterMailStatus.shared.check()
        if let brain = hub?.brain {
            await brain.ollama.refresh()
            await brain.accounts.refreshStatus()
        }
        rebuild()
    }

    func rebuild() {
        guard let hub, let brain = hub.brain else { return }
        let sync = brain.context.existingSettings?.syncStatus ?? [:]
        let accounts = brain.accounts
        func entry(_ s: SyncSource) -> SyncStatusEntry? { sync[s.rawValue] }
        func level(_ e: SyncStatusEntry?, connected: Bool, staleAfter hours: Double = 6) -> HealthRow.Level {
            guard connected else { return .broken }
            guard let e else { return .warning }
            if e.lastError != nil { return e.lastSuccess == nil ? .broken : .warning }
            if let ok = e.lastSuccess, Date().timeIntervalSince(ok) > hours * 3600 { return .warning }
            return e.lastSuccess == nil ? .warning : .ok
        }
        func text(_ e: SyncStatusEntry?, fallback: String) -> String {
            if let err = e?.lastError { return Self.short(err) }
            return e?.detail ?? fallback
        }
        var out: [HealthRow] = []

        // ELE
        let eleNeedsSignIn = MacPrefs.defaults.bool(forKey: MacPrefs.eleWebNeedsSignIn)
        let ele = entry(.ele)
        out.append(HealthRow(id: "ele", title: "ELE", symbol: "graduationcap.fill",
                             level: eleNeedsSignIn ? .broken : level(ele, connected: accounts.eleConnected, staleAfter: 3),
                             lastOK: ele?.lastSuccess,
                             detail: eleNeedsSignIn ? "Signed out of ELE" : accounts.eleConnected ? text(ele, fallback: "Connected") : "Not signed in",
                             fixTitle: "Open ELE login", fix: { _ = await brain.accounts.connectELE(); await brain.syncELE() }))

        // Ed
        let ed = hub.ed
        out.append(HealthRow(id: "ed", title: "Ed Discussion", symbol: "bubble.left.and.bubble.right.fill",
                             level: !ed.connected || ed.needsSignIn ? .broken : ed.lastError != nil ? .warning : .ok,
                             lastOK: ed.state.lastSync,
                             detail: ed.needsSignIn ? "Needs signing in again" : ed.lastError.map(Self.short) ?? (ed.connected ? "Connected" : "Not connected"),
                             fixTitle: "Sign in to Ed", fix: { await ed.signIn() }))

        // Google
        let gmail = entry(.gmail)
        out.append(HealthRow(id: "gmail", title: "Gmail", symbol: "envelope.fill",
                             level: level(gmail, connected: accounts.googleConnected, staleAfter: 1),
                             lastOK: gmail?.lastSuccess,
                             detail: accounts.googleConnected ? text(gmail, fallback: accounts.googleEmail ?? "Connected") : "Google not connected",
                             fixTitle: "Reconnect Google", fix: { if await brain.accounts.connectGoogle() { await brain.syncMail() } }))
        let gcal = entry(.calendar)
        out.append(HealthRow(id: "gcal", title: "Google Calendar", symbol: "calendar",
                             level: level(gcal, connected: accounts.googleConnected, staleAfter: 1),
                             lastOK: gcal?.lastSuccess,
                             detail: accounts.googleConnected ? text(gcal, fallback: "Connected") : "Google not connected",
                             fixTitle: "Reconnect Google", fix: { if await brain.accounts.connectGoogle() { await brain.syncCalendar() } }))

        // Exeter mail (Apple Mail, needs Full Disk Access)
        let mail = ExeterMailStatus.shared
        let exMail = entry(.exeterMail)
        let mailLevel: HealthRow.Level = !mail.fullDiskAccess ? .broken : !mail.exeterMailFound ? .warning : level(exMail, connected: true, staleAfter: 1)
        out.append(HealthRow(id: "exmail", title: "Exeter mail (Apple Mail)", symbol: "building.columns.fill", level: mailLevel,
                             lastOK: exMail?.lastSuccess,
                             detail: !mail.fullDiskAccess ? "Full Disk Access is off" : !mail.exeterMailFound ? "No Exeter account in Mail yet" : text(exMail, fallback: "Reading Mail"),
                             fixTitle: mail.fullDiskAccess ? "Open Internet Accounts" : "Open Full Disk Access",
                             fix: { if mail.fullDiskAccess { MacCalendarAccess.openInternetAccounts() } else { OrbitBrain.openFullDiskAccessSettings() } }))

        // Exeter calendar (EventKit)
        let ek = MacCalendarAccess.shared
        out.append(HealthRow(id: "excal", title: "Exeter calendar", symbol: "calendar.badge.clock",
                             level: !ek.granted ? .broken : !ek.exeterCalendarFound ? .warning : level(gcal, connected: true, staleAfter: 1),
                             lastOK: entry(.calendar)?.lastSuccess,
                             detail: ek.denied ? "Calendar access denied" : !ek.granted ? "Calendar access not allowed yet"
                                : ek.exeterCalendarFound ? "\(ek.calendarNames.count) calendars" : "No Exeter calendar on this Mac",
                             fixTitle: ek.denied ? "Open Calendar privacy" : !ek.granted ? "Allow calendar access" : "Open Internet Accounts",
                             fix: {
                                 if ek.denied { MacCalendarAccess.openCalendarPrivacySettings() }
                                 else if !ek.granted { if await ek.requestAccess() { await brain.syncCalendar() } }
                                 else { MacCalendarAccess.openInternetAccounts() }
                             }))

        // Notability backup folder
        let folder = MacPrefs.string(MacPrefs.notesFolderPath)
        let folderOK = folder.map { FileManager.default.isReadableFile(atPath: $0) } ?? false
        let notes = entry(.notes)
        out.append(HealthRow(id: "notability", title: "Notability backup folder", symbol: "folder.fill",
                             level: folder == nil ? .broken : !folderOK ? .broken : level(notes, connected: true, staleAfter: 24),
                             lastOK: notes?.lastSuccess,
                             detail: folder == nil ? "No folder chosen" : !folderOK ? "Can't read \((folder! as NSString).lastPathComponent)" : text(notes, fallback: (folder! as NSString).lastPathComponent),
                             fixTitle: "Choose folder…", fix: { await Self.chooseNotesFolder(brain: brain) }))

        // OpenCode
        let oc = brain.launcher.status
        out.append(HealthRow(id: "opencode", title: "OpenCode", symbol: "cpu.fill",
                             level: oc.isRunning ? .ok : (brain.ollama.available ? .warning : .broken),
                             lastOK: entry(.ai)?.lastSuccess, detail: oc.label,
                             fixTitle: "Start OpenCode", fix: { await brain.launcher.ensureRunning(); await brain.checkAI() }))

        // Ollama + models
        let ollama = brain.ollama
        let missing = ollama.missingRecommended
        out.append(HealthRow(id: "ollama", title: "Ollama", symbol: "shippingbox.fill",
                             level: !ollama.available ? .warning : missing.isEmpty ? .ok : .warning,
                             lastOK: ollama.lastSeen,
                             detail: !ollama.available ? "Not running" : missing.isEmpty ? "\(ollama.installed.count) models" : "Missing \(missing.joined(separator: ", "))",
                             fixTitle: !ollama.available ? "Get Ollama" : missing.isEmpty ? nil : "Pull \(missing.first!)",
                             fix: {
                                 if !ollama.available { openExternal(URL(string: "https://ollama.com/download/mac")!) }
                                 else if let m = ollama.missingRecommended.first { await ollama.pull(m) }
                             }))

        // Monzo
        let money = hub.money
        let monzoLevel: HealthRow.Level
        if case .error = money.monzoState { monzoLevel = .broken } else if !money.hasMonzoToken { monzoLevel = .warning } else { monzoLevel = .ok }
        out.append(HealthRow(id: "monzo", title: "Monzo", symbol: "creditcard.fill", level: monzoLevel,
                             lastOK: money.data.lastMonzoSync, detail: money.monzoState.label,
                             fixTitle: money.hasMonzoToken && monzoLevel == .ok ? nil : "Reconnect Monzo", fix: { await money.connectMonzo() }))

        // Trading 212
        let t212Bad = money.t212Status.lowercased().contains("couldn") || money.t212Status.lowercased().contains("error")
        out.append(HealthRow(id: "t212", title: "Trading 212", symbol: "chart.line.uptrend.xyaxis",
                             level: !money.hasT212Key ? .warning : t212Bad ? .broken : .ok,
                             lastOK: money.data.lastT212Sync,
                             detail: !money.hasT212Key ? "No API key" : money.t212Status.isEmpty ? "Connected" : Self.short(money.t212Status),
                             fixTitle: "Re-enter key", fix: { Self.openSettings(tab: "money") }))

        // Trackr
        let careers = hub.careers
        out.append(HealthRow(id: "trackr", title: "Trackr (careers)", symbol: "briefcase.fill",
                             level: careers.lastError != nil ? .warning : careers.lastSync == nil ? .warning : .ok,
                             lastOK: careers.lastError == nil ? careers.lastSync : nil,
                             detail: careers.lastError ?? (careers.lastSync == nil ? "Not checked yet" : "\(careers.opportunities.count) programmes"),
                             fixTitle: "Check now", fix: { await careers.sync() }))

        // Notifications
        let n = notificationStatus
        out.append(HealthRow(id: "notifications", title: "Notifications", symbol: "bell.badge.fill",
                             level: n == .authorized || n == .provisional ? .ok : .broken, lastOK: nil,
                             detail: n == .authorized ? "Allowed" : n == .denied ? "Turned off for Orbit" : "Not asked yet",
                             fixTitle: n == .authorized ? nil : n == .denied ? "Open Notifications settings" : "Allow notifications",
                             fix: {
                                 if n == .denied {
                                     openExternal(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                                 } else {
                                     await Notifier.requestAuthorization()
                                     await self.refresh()
                                 }
                             }))

        // Backups
        let backups = hub.backups
        let last = backups.lastBackup
        let backupLevel: HealthRow.Level = backups.lastError != nil ? .broken
            : last == nil ? .warning : Date().timeIntervalSince(last!) > 36 * 3600 ? .warning : .ok
        out.append(HealthRow(id: "backups", title: "Backups", symbol: "externaldrive.fill.badge.timemachine", level: backupLevel,
                             lastOK: last, detail: backups.lastError.map(Self.short) ?? "\(backups.destination.label)",
                             fixTitle: "Run backup", fix: { await backups.backUp() }))

        rows = out
        checkedAt = Date()
    }

    // MARK: Fixes

    static func chooseNotesFolder(brain: OrbitBrain) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use this folder"
        panel.message = "Choose your Notability (or GoodNotes) auto-backup folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MacPrefs.defaults.set(url.path, forKey: MacPrefs.notesFolderPath)
        MacPrefs.defaults.set("folder", forKey: MacPrefs.noteSource)
        await brain.syncNotes()
    }

    /// Opens Settings on a tab (see `MacSettingsView.Tab`).
    static func openSettings(tab: String) {
        UserDefaults.standard.set(tab, forKey: MacSettingsView.tabKey)
        NSApp.activate(ignoringOtherApps: true)
        // The app menu's "Settings…" item (⌘,) works on every macOS version.
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    static func short(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return line.count > 90 ? String(line.prefix(88)) + "…" : line
    }
}
