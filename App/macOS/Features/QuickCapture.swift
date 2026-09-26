import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import SwiftData
import SwiftUI
import OrbitCore

/// A system-wide hotkey via Carbon's RegisterEventHotKey. Works while Orbit is in
/// the background and needs no Accessibility permission.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    let id: UInt32
    private static var handlerInstalled = false
    private static var actions: [UInt32: @MainActor () -> Void] = [:]

    init(id: UInt32) { self.id = id }

    /// `modifiers` is a Carbon mask (cmdKey, optionKey, controlKey, shiftKey).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        Self.installHandlerIfNeeded()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F52_4254), id: id) // "ORBT"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            Self.actions[id] = nil
            OrbitLog.log("capture", "couldn't register hotkey (status \(status)); another app may be using it")
        }
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr else { return status }
            let id = hotKey.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // MARK: Conversions

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func label(keyCode: UInt32, modifiers: UInt32, key: String?) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        switch Int(keyCode) {
        case kVK_Space: s += "Space"
        case kVK_Return: s += "↩"
        default: s += (key ?? "?").uppercased()
        }
        return s
    }
}

/// The floating quick-capture window.
final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

/// ⌥Space (configurable) → a one-line field. Enter adds a to-do; "e:" makes a calendar
/// event, "n:" a note. Esc closes.
@MainActor
@Observable
final class QuickCaptureController {
    @ObservationIgnored weak var hub: FeatureHub?
    @ObservationIgnored private let hotKey = GlobalHotKey(id: 1)
    @ObservationIgnored private var panel: QuickCapturePanel?
    private(set) var registered = false
    private(set) var shortcutLabel = "⌥Space"
    /// Bumped each time the panel opens, so the field clears and refocuses.
    private(set) var openCount = 0

    static let defaultKeyCode = UInt32(kVK_Space)
    static let defaultModifiers = UInt32(optionKey)

    func registerFromSettings() {
        let d = FeatureSettings.defaults
        guard FeatureSettings.bool(FeatureSettings.quickCaptureEnabled, default: true) else {
            hotKey.unregister()
            registered = false
            return
        }
        let code = d.object(forKey: FeatureSettings.quickCaptureKeyCode) == nil ? Self.defaultKeyCode
            : UInt32(d.integer(forKey: FeatureSettings.quickCaptureKeyCode))
        let mods = d.object(forKey: FeatureSettings.quickCaptureModifiers) == nil ? Self.defaultModifiers
            : UInt32(d.integer(forKey: FeatureSettings.quickCaptureModifiers))
        shortcutLabel = GlobalHotKey.label(keyCode: code, modifiers: mods, key: d.string(forKey: "features.quickCapture.keyLabel"))
        registered = hotKey.register(keyCode: code, modifiers: mods) { [weak self] in self?.toggle() }
        OrbitLog.log("capture", registered ? "hotkey \(shortcutLabel) registered" : "hotkey \(shortcutLabel) unavailable")
    }

    /// Saves a new shortcut (from the recorder in settings) and re-registers.
    func setShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let mods = GlobalHotKey.carbonModifiers(flags)
        guard mods != 0 else { return } // a bare key would steal typing everywhere
        let d = FeatureSettings.defaults
        d.set(Int(keyCode), forKey: FeatureSettings.quickCaptureKeyCode)
        d.set(Int(mods), forKey: FeatureSettings.quickCaptureModifiers)
        d.set(characters, forKey: "features.quickCapture.keyLabel")
        registerFromSettings()
    }

    func resetShortcut() {
        let d = FeatureSettings.defaults
        d.removeObject(forKey: FeatureSettings.quickCaptureKeyCode)
        d.removeObject(forKey: FeatureSettings.quickCaptureModifiers)
        d.removeObject(forKey: "features.quickCapture.keyLabel")
        registerFromSettings()
    }

    // MARK: Panel

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        openCount += 1
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.28))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 96),
                                      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = NSHostingView(rootView: QuickCaptureField(controller: self))
        return panel
    }

    // MARK: Submitting

    /// A short preview of what the line will become.
    func preview(_ text: String) -> String? {
        let tz = hub?.prefs.timeZone ?? .current
        let cal = DayCalendar(timeZone: tz)
        guard let intent = QuickCaptureParser(now: Date(), timeZone: tz).parse(text) else { return nil }
        switch intent {
        case .task(let t):
            var parts = ["To-do: \(t.title)", Fmt.duration(t.estimateMinutes)]
            if let d = t.deadline { parts.append("due \(cal.shortDay(d)) \(cal.time(d))") }
            if let m = t.moduleCode { parts.append(m) }
            return parts.joined(separator: " · ")
        case .event(let e):
            return "Event: \(e.title) · \(cal.shortDay(e.start)) \(e.hasTime ? cal.time(e.start) + "–" + cal.time(e.end) : "(no time: 12:00)")"
                + (e.location.map { " · \($0)" } ?? "")
        case .note(let n):
            return "Note" + (n.moduleCode.map { " (\($0))" } ?? "") + ": \(n.title)"
        }
    }

    /// Adds the line and returns a confirmation for the toast.
    func submit(_ text: String) async -> String? {
        guard let hub, let brain = hub.brain else { return nil }
        let tz = hub.prefs.timeZone
        let cal = DayCalendar(timeZone: tz)
        let now = Date()
        guard let intent = QuickCaptureParser(now: now, timeZone: tz).parse(text) else { return nil }
        let message: String
        switch intent {
        case .task(var task):
            let body = text.replacingOccurrences(of: "^\\s*(t|task):\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            if !QuickAddParser(now: now, timeZone: tz).parse(body).hasExplicitEstimate { task = hub.applyLearnedEstimate(task) }
            brain.app?.addTask(task)
            message = "Added “\(task.title)”" + (task.deadline.map { " · due \(cal.shortDay($0))" } ?? "")
        case .event(let e):
            let plan = StoredPlan(id: UUID().uuidString)
            plan.title = e.title
            plan.start = e.start
            plan.end = e.end
            plan.location = e.location
            plan.sourceRaw = "assistant"
            plan.quote = "Quick capture"
            plan.status = .accepted
            brain.context.insert(plan)
            brain.context.saveQuietly()
            Task { await brain.writeAcceptedPlans() }
            message = "Added “\(e.title)” · \(cal.shortDay(e.start)) \(cal.time(e.start))" + (e.hasTime ? "" : " (no time given)")
        case .note(let n):
            let note = LectureNote(id: "quick-\(UUID().uuidString)", title: n.title, notebook: "Quick notes",
                                   moduleCode: n.moduleCode, created: now, modified: now,
                                   segments: [NoteSegment(kind: .typed, text: n.body)])
            Task { await brain.store(note: note) }
            message = "Saved note “\(n.title)”"
        }
        OrbitLog.log("capture", message.components(separatedBy: " “").first ?? "captured")
        hub.toast(message)
        return message
    }
}
