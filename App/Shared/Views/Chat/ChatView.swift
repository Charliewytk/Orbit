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
                            Text("Thinking…")
                                .font(Theme.body)
                                .foregroundStyle(Theme.textTertiary)
                                .id("typing")
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
            Text("Ask Orbit")
                .font(Theme.pageTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(app.backend.isBrain
                 ? "Orbit can see your calendar, tasks, deadlines, inbox and notes, and can add, move and plan things for you."
                 : "Messages go to your Mac, which answers when it's awake. Add your Mac's address in Settings for instant replies.")
                .font(Theme.large)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button(s) { send(s) }
                        .buttonStyle(.orbitLink)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(empty ? Theme.textTertiary : Color.white)
                    .frame(width: 24, height: 24)
                    .background(empty ? Theme.hover : Theme.accent,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            .strokeBorder(focused ? Theme.textTertiary : Theme.border, lineWidth: focused ? 1 : Theme.hairline))
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
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
                status
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(LocalizedStringKey(message.text))
                    .font(Theme.large)
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                footer
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
