import SwiftUI
import AVFoundation
import Speech

/// Live dictation into a text field with Apple Speech (on-device when available).
@MainActor
@Observable
final class DictationRecorder {
    private(set) var isRecording = false
    var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start(onText: @escaping @MainActor (String) -> Void) async {
        error = nil
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")), recognizer.isAvailable else {
            error = "Allow Speech Recognition for Orbit in System Settings → Privacy & Security."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Allow the microphone for Orbit in System Settings → Privacy & Security."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        self.request = request
        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let done = err != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                if let text { onText(text) }
                if done { self?.stop() }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
    }
}

/// Mic button: dictation appends to `text` after what was already typed.
struct DictationButton: View {
    @Binding var text: String
    @State private var recorder = DictationRecorder()
    @State private var prefix = ""

    var body: some View {
        Button(action: toggle) {
            Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 15))
                .foregroundStyle(recorder.isRecording ? Theme.danger : Theme.textSecondary)
                .symbolEffect(.pulse, isActive: recorder.isRecording)
        }
        .buttonStyle(.plain)
        .help(recorder.error ?? (recorder.isRecording ? "Stop dictation" : "Dictate"))
        .onDisappear { recorder.stop() }
    }

    private func toggle() {
        if recorder.isRecording { recorder.stop(); return }
        prefix = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        Task { await recorder.start { text = prefix + $0 } }
    }
}
