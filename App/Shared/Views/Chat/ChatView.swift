import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredChatMessage.createdAt) private var allMessages: [StoredChatMessage]
    @State private var draft = ""
    @State private var sent = 0
    @FocusState private var focused: Bool

    static let suggestions = [
        "What's my week look like?",
        "I'm knackered, lighten today",
        "What's due for BEM2031?",
        "Quiz me on last week's lectures",
    ]

    private var messages: [StoredChatMessage] {
        allMessages.filter { $0.role != .command }.suffix(200).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty { intro }
                        ForEach(messages) { m in
                            ChatBubble(message: m).id(m.id)
                        }
                        if app.backend.isThinking {
                            TypingIndicator().id("typing")
                        }
                    }
                    .padding(Theme.padding)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: app.backend.isThinking) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy, animated: false) }
            }
            composer
        }
        .orbitBackground()
        .navigationTitle("Chat")
        .successHaptic(sent)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text("Ask Orbit anything").font(Theme.title(24)).foregroundStyle(Theme.textPrimary)
            Text(app.backend.isBrain
                 ? "Orbit can see your calendar, to-dos, deadlines, inbox and notes, and can add, move and plan things for you."
                 : "Messages go to your Mac, which answers when it's awake. Add your Mac's address in Settings for instant replies.")
                .font(Theme.callout).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 24)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { send(s) }
                            .buttonStyle(SoftButtonStyle())
                    }
                }
                .padding(.horizontal, Theme.padding)
            }
            HStack(spacing: 10) {
                TextField("Message Orbit…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { send(draft) }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.textTertiary : Theme.accent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, Theme.padding)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .background(.bar)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        sent += 1
        Task { await app.backend.sendChat(trimmed) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: String? = app.backend.isThinking ? "typing" : messages.last?.id
        guard let target else { return }
        if animated {
            withAnimation(Theme.spring) { proxy.scrollTo(target, anchor: .bottom) }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

struct ChatBubble: View {
    var message: StoredChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(LocalizedStringKey(message.text))
                    .font(Theme.body)
                    .foregroundStyle(isUser ? Color.white : Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        isUser ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay {
                        if !isUser {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5)
                        }
                    }
                if !message.toolsUsed.isEmpty {
                    Flow(spacing: 4) {
                        ForEach(Array(Set(message.toolsUsed)).sorted(), id: \.self) { tool in
                            Tag(text: tool.replacingOccurrences(of: "_", with: " "), color: Theme.accent, systemImage: "wrench.and.screwdriver")
                        }
                    }
                }
                footer
            }
            if !isUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            if isUser {
                switch message.status {
                case .queued:
                    Label("Waiting for your Mac", systemImage: "clock").foregroundStyle(Theme.warning)
                case .processing:
                    Label("Your Mac is thinking…", systemImage: "ellipsis").foregroundStyle(Theme.accent)
                case .failed:
                    Label("Couldn't answer", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                case .answered:
                    EmptyView()
                }
            } else if let provider = message.provider {
                Label(provider, systemImage: provider.localizedCaseInsensitiveContains("ollama") ? "desktopcomputer" : "sparkles")
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(message.createdAt, style: .time).foregroundStyle(Theme.textTertiary)
        }
        .font(.caption2)
    }
}

struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.textTertiary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(1 + 0.35 * sin(t * 5 + Double(i) * 0.9))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surface, in: Capsule())
        }
    }
}
