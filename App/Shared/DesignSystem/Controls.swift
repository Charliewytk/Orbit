import SwiftUI
import OrbitCore

// App-only components (not compiled into the extensions).

// MARK: - Rows

/// Hover and selection fill for list rows (Things / Notion style: no boxes,
/// just a soft fill under the row).
struct HoverRowModifier: ViewModifier {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = Theme.Radius.s
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.selection : (hovering ? Theme.hover : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.fade, value: hovering)
            .animation(Motion.fade, value: isSelected)
    }
}

extension View {
    /// Adds the standard row hover / selection fill.
    func hoverRow(selected: Bool = false, cornerRadius: CGFloat = Theme.Radius.s) -> some View {
        modifier(HoverRowModifier(isSelected: selected, cornerRadius: cornerRadius))
    }
}

/// A standard 32 pt row: leading accessory, title (+ optional subtitle), trailing metadata.
struct ListRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var isSelected: Bool = false
    var dimmed: Bool = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .firstTextBaseline, spacing: Theme.Space.s) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(dimmed ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .hoverRow(selected: isSelected)
    }
}

extension ListRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, isSelected: Bool = false, dimmed: Bool = false,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, isSelected: isSelected, dimmed: dimmed,
                  leading: { EmptyView() }, trailing: trailing)
    }
}

// MARK: - Checkbox

/// Round checkbox: fills with the accent gradient, bounces and bursts when ticked.
struct CircleCheckbox: View {
    var isOn: Bool
    var color: Color = Theme.textTertiary
    var size: CGFloat = 18
    var action: () -> Void
    @State private var hovering = false
    @State private var bursts = 0
    @State private var pop = false

    var body: some View {
        Button {
            if !isOn { bursts += 1; pop = true }
            action()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(isOn ? Color.clear : (hovering ? Theme.accent : color), lineWidth: 1.5)
                Circle()
                    .fill(Theme.accentGradient)
                    .scaleEffect(isOn ? 1 : 0.3)
                    .opacity(isOn ? 1 : 0)
                    .shadow(color: Theme.violet.opacity(isOn ? 0.45 : 0), radius: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .scaleEffect(isOn ? 1 : 0.3)
                    .opacity(isOn ? 1 : 0)
                CheckBurst(trigger: bursts)
            }
            .frame(width: size, height: size)
            .scaleEffect(pop ? 1.25 : 1)
            .contentShape(Circle().inset(by: -5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.bouncy, value: isOn)
        .animation(Motion.fade, value: hovering)
        .onChange(of: pop) { _, new in
            guard new else { return }
            withAnimation(Motion.bouncy.delay(0.12)) { pop = false }
        }
        .accessibilityLabel(isOn ? "Done" : "Not done")
        .help(isOn ? "Mark not done" : "Complete")
    }
}

// MARK: - Module

/// Coloured dot + code (and optionally the module name) in secondary text.
struct ModuleTag: View {
    var code: String?
    var name: String? = nil

    var body: some View {
        if let code, !code.isEmpty {
            HStack(spacing: 5) {
                ModuleDot(code: code, size: 7)
                Text(name.map { "\(code) \($0)" } ?? code)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Due text: secondary normally, red when overdue or due within a day.
struct DueText: View {
    var date: Date
    var calendar: DayCalendar
    var now: Date = Date()
    var style: Style = .relative

    enum Style { case relative, short }

    var body: some View {
        let urgent = date < now.addingTimeInterval(86400)
        Text(style == .relative ? Fmt.due(date, calendar, now: now) : Fmt.shortDue(date, calendar, now: now))
            .font(Theme.caption.monospacedDigit())
            .foregroundStyle(date < now || urgent ? Theme.danger : Theme.textSecondary)
            .lineLimit(1)
    }
}

// MARK: - Page structure

/// Page header: a big bold title, a gradient underline and one line of metadata.
struct PageHeader<Accessory: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.pageTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: 44, height: 4)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.body.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.l)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

/// A scrollable, centred page column over the ambient backdrop.
struct Page<Content: View>: View {
    var maxWidth: CGFloat = Theme.readingWidth
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, Theme.Space.xxxl)
            .frame(maxWidth: maxWidth + horizontalPadding * 2, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .orbitBackground()
    }

    private var horizontalPadding: CGFloat {
        #if os(macOS)
        return Theme.Space.xxl
        #else
        return Theme.Space.l
        #endif
    }
}

/// A titled glass card on a page.
struct PageSection<Content: View, Accessory: View>: View {
    var title: String
    var count: Int? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(title).font(Theme.sectionTitle).foregroundStyle(Theme.textPrimary)
                if let count {
                    Text("\(count)")
                        .font(Theme.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                accessory
            }
            .padding(.bottom, Theme.Space.xs)
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitGlassCard()
        .padding(.top, Theme.Space.l)
    }
}

extension PageSection where Accessory == EmptyView {
    init(title: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, accessory: { EmptyView() }, content: content)
    }
}

/// A capsule segmented control for switching views inside a page.
struct SegmentedHeader<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    init(options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    var body: some View {
        GlassSegmented(options: options, selection: $selection)
    }
}

/// A rendered shortcut such as ⌘K.
struct KeyHint: View {
    var keys: String
    var body: some View {
        Text(keys)
            .font(Theme.caption.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Plain accent text button (links, inline suggestions).
struct TextLinkButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body)
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TextLinkButtonStyle {
    static var orbitLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var quiet: SoftButtonStyle { SoftButtonStyle() }
}

// MARK: - Sidebar

/// A sidebar row: colour icon tile, title and a count badge.
struct SidebarItem: View {
    var title: String
    var systemImage: String
    var color: Color = Theme.accent
    var count: Int = 0
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: systemImage, color: color, size: 22)
            Text(title)
                .font(Theme.body.weight(selected ? .semibold : .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.s)
            if count > 0 {
                Text("\(count)")
                    .font(Theme.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(selected ? .white : Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(selected ? AnyShapeStyle(color) : AnyShapeStyle(Theme.hover), in: Capsule())
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: count)
            }
        }
    }
}

// MARK: - Two panes (list + detail)

/// Mail-style two panes on the Mac; list → pushed detail on the iPhone.
struct TwoPane<Selection: Hashable, ListContent: View, Detail: View>: View {
    @Binding var selection: Selection?
    var listWidth: CGFloat = 320
    @ViewBuilder var list: ListContent
    @ViewBuilder var detail: (Selection?) -> Detail

    var body: some View {
        #if os(macOS)
        HStack(spacing: Theme.Space.m) {
            list
                .environment(\.inGlassPane, true)
                .scrollContentBackground(.hidden)
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .orbitGlassCard()
            detail(selection)
                .environment(\.inGlassPane, true)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .orbitGlassCard()
        }
        .padding(Theme.Space.m)
        .orbitBackground()
        #else
        list
            .navigationDestination(item: $selection) { value in
                detail(value)
            }
        #endif
    }
}

// MARK: - Toast

struct ToastView: View {
    var toast: Toast
    var onUndo: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accentGradient)
            Text(toast.text)
                .font(Theme.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if toast.undo != nil {
                Button("Undo", action: onUndo)
                    .buttonStyle(.orbitLink)
                    .font(Theme.body.weight(.medium))
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 10)
        .orbitGlass(in: Capsule(), tint: Theme.accent)
        .shadow(color: Theme.glassShadow, radius: 16, y: 6)
        .onTapGesture(perform: onDismiss)
    }
}

struct ToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(toast: toast, onUndo: { app.undoToast() }, onDismiss: { app.dismissToast() })
                    .id(toast.id)
                    .padding(.bottom, Theme.Space.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: app.toast)
    }
}

extension View {
    /// Shows `AppModel.toast` at the bottom of the view.
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}

// MARK: - Environment

private struct DedicatedTaskIDsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    /// Task ids shown in their own section elsewhere on the page (e.g. homework on
    /// the Mac's Today), so generic lists can leave them out.
    var dedicatedTaskIDs: Set<String> {
        get { self[DedicatedTaskIDsKey.self] }
        set { self[DedicatedTaskIDsKey.self] = newValue }
    }
}
