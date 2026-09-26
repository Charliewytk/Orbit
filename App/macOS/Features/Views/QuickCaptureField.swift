import SwiftUI
import AppKit
import OrbitCore

/// The one-line field inside the quick-capture panel.
struct QuickCaptureField: View {
    let controller: QuickCaptureController
    @State private var text = ""
    @State private var confirmation: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ask or tell Orbit…   ·   e: event   ·   n: note", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .disabled(working)
                .onSubmit(submit)
            Text(confirmation ?? controller.preview(text) ?? "Return to add · Esc to close")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
        .onExitCommand { controller.close() }
        .onAppear { focused = true }
        .onChange(of: controller.openCount) {
            text = ""
            confirmation = nil
            focused = true
        }
    }

    private func submit() {
        let line = text
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !working else { return }
        // Questions go to Home's Ask Orbit conversation (the same box as ⌘N).
        if AskOrTell.classify(line) == .ask, !line.hasPrefix("e:"), !line.hasPrefix("n:") {
            text = ""
            controller.close()
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .orbitNavigate, object: Destination.home)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NotificationCenter.default.post(name: .orbitOpenAsk, object: line)
            }
            return
        }
        // Several requests or a constraint ("no work today… missed Friday…") → the planner on Home.
        if ConversationalPlanner.looksConversational(line) {
            text = ""
            controller.close()
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .orbitNavigate, object: Destination.home)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NotificationCenter.default.post(name: .orbitOpenPlanner, object: line)
            }
            return
        }
        working = true
        Task { @MainActor in
            let message = await controller.submit(line)
            working = false
            guard let message else { return }
            confirmation = message
            text = ""
            try? await Task.sleep(for: .milliseconds(900))
            if confirmation == message { controller.close() }
        }
    }
}
