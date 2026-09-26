import SwiftUI
import SwiftData

/// Ask Orbit: a plain, document-like conversation. Your messages sit on the
/// right in a subtle grey; Orbit's answers are full-width text.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredChatMessage.createdAt) private var allMessages: [StoredChatMessage]
    @State private var draft = ""
    @State private var sent = 0
    @FocusState private var focused: Bool

    static let suggestions = [
        "What does my week look like?",
        "I'm knackered, lighten today",
        "What's due for BEM2031?",
        "Quiz me on last week's lectures",
    ]

    private var messages: [StoredChatMessage] {
        allMessages.filter { $0.role != .command }.suffix(200).map { $0 }
    }

    var body: some View {
        let list = messages
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
                        if list.isEmpty { intro }
                        ForEach(list) { m in
                            ChatMessageView(message: m).id(m.id)
                        }
                        if app.backend.isThinking {
                            TypingBubble().id("typing")
                        }
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.xl)
                    .frame(maxWidth: 720 + Theme.Space.xl * 2)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: list.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: app.backend.isThinking) { _, _ in scrollToEnd(proxy) }
            }
            composer
        }
        .orbitBackground()
        .navigationTitle("Ask Orbit")
        .successHaptic(sent)
        .onAppear { focused = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            IconTile(symbol: Destination.chat.symbol, color: Destination.chat.color, size: 56)
                .padding(.bottom, Theme.Space.s)
            Text("Ask Orbit")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(app.backend.isBrain
                 ? "Orbit can see your calendar, tasks, deadlines, inbox and notes, and can add, move and plan things for you."
                 : "Messages go to your Mac, which answers when it's awake. Add your Mac's address in Settings for instant replies.")
                .font(Theme.large)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Flow(spacing: Theme.Space.s) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button(s) { send(s) }
                        .buttonStyle(GlassCapsuleButtonStyle(tint: Theme.accent))
                }
            }
            .padding(.top, Theme.Space.l)
        }
        .padding(.top, Theme.Space.xxl)
    }

    private var composer: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Ask Orbit…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { send(draft) }
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(empty ? Theme.textTertiary : Color.white)
                    .frame(width: 30, height: 30)
                    .background(empty ? AnyShapeStyle(Theme.hover) : AnyShapeStyle(Theme.accentGradient), in: Circle())
                    .shadow(color: empty ? .clear : Theme.violet.opacity(0.4), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .orbitGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: focused ? Theme.accent : nil, interactive: true)
        .animation(Motion.fade, value: focused)
        .frame(maxWidth: 720)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .frame(maxWidth: .infinity)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        sent += 1
        Task { await app.backend.sendChat(trimmed) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: String? = app.backend.isThinking ? "typing" : messages.last?.id
        guard let target else { return }
        withAnimation(Motion.smooth) { proxy.scrollTo(target, anchor: .bottom) }
    }
}

struct ChatMessageView: View {
    var message: StoredChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if isUser {
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                Text(message.text)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, 10)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Theme.violet.opacity(0.3), radius: 10, y: 4)
                    .frame(maxWidth: 520, alignment: .trailing)
                status
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                IconTile(symbol: "circle.circle.fill", color: Theme.accent, size: 26)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(LocalizedStringKey(message.text))
                        .font(Theme.large)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    footer
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .orbitGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer(minLength: Theme.Space.xxl)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch message.status {
        case .queued:
            Text("Waiting for your Mac").font(Theme.caption).foregroundStyle(Theme.textTertiary)
        case .processing:
            Text("Your Mac is thinking…").font(Theme.caption).foregroundStyle(Theme.textTertiary)
        case .failed:
            Text("Couldn't answer").font(Theme.caption).foregroundStyle(Theme.danger)
        case .answered:
            EmptyView()
        }
    }

    private var footer: some View {
        var parts: [String] = []
        if !message.toolsUsed.isEmpty {
            parts.append("Used " + Array(Set(message.toolsUsed)).sorted()
                .map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
        }
        if let provider = message.provider { parts.append(provider) }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        return Text(parts.joined(separator: " · "))
            .font(Theme.caption)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Three bouncing dots in a glass bubble while Orbit thinks.
struct TypingBubble: View {
    @State private var phase = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            IconTile(symbol: "circle.circle.fill", color: Theme.accent, size: 26)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 8, height: 8)
                        .offset(y: phase ? -4 : 2)
                        .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: phase)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 14)
            .orbitGlass(in: Capsule())
        }
        .onAppear { phase = true }
    }
}
