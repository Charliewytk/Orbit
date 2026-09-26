# Orbit Design Spec

Target: macOS 15+ (Sequoia), SwiftUI, Xcode 16. Goal: calm, dense, fast. It should feel like Things 3 in calm, Linear in speed and keyboard control, and Notion Calendar in how it handles time.

---

## 1. Principles

1. **Native first, custom second.** Use `NavigationSplitView`, the real toolbar, sidebar vibrancy, SF Pro and SF Symbols. Custom chrome only where it adds something. If a Mac user expects it to behave a certain way (⌘, for settings, ⌘F for search, ⌫ to delete, drag and drop, right-click), it does.
2. **Instant or it didn't happen.** Every action updates the UI in the same frame (optimistic), and persistence and network run afterwards. Target zero spinners for local data. Show skeletons only for remote fetches that take more than 300 ms.
3. **Keyboard is a first-class citizen.** Every screen can be driven without the mouse. ⌘K reaches everything, and single-key shortcuts work inside lists (Linear style).
4. **One accent, lots of grey.** Colour carries meaning (module colour, urgency, the accent for "you can act here"). It never decorates. About 90% of pixels are neutral.
5. **Dense but calm.** 28–32 pt rows, tight but consistent spacing, secondary info in `.secondary` or `.tertiary`, and no card-in-card-in-card nesting. Use whitespace to separate groups, not borders.
6. **Motion explains, never performs.** Springs are short (under 350 ms). Things move from where they came from. Nothing bounces for fun, and everything respects Reduce Motion.
7. **Now is always obvious.** Whatever screen you are on, you can tell what is next today within one second.
8. **Every empty state is an invitation.** It gets a symbol, one sentence and one action with its shortcut.

---

## 2. Visual system

### 2.1 Type scale (SF Pro, system font; never hardcode a family)

| Token | Size / weight | SwiftUI | Use |
|---|---|---|---|
| `display` | 28 / bold, tracking -0.4 | `.system(size: 28, weight: .bold)` | Screen hero ("Thursday, 26 Sep") on Today and Onboarding only |
| `title` | 20 / semibold | `.title3.weight(.semibold)` (macOS title3 is 15, so use size 20) | Screen titles in content |
| `headline` | 13 / semibold | `.headline` | Section headers, row titles when emphasised |
| `body` | 13 / regular | `.body` | Default everything (the macOS body size is 13) |
| `callout` | 12 / regular | `.callout` | Secondary row text, metadata |
| `caption` | 11 / medium | `.caption.weight(.medium)` | Chips, timestamps, badges |
| `micro` | 10 / semibold, uppercase, tracking +0.6 | `.system(size: 10, weight: .semibold)` | Sidebar group labels, "OVERDUE" |
| `mono` | 12 / regular | `.system(size: 12, design: .monospaced)` | Times in the timeline and countdowns (with `.monospacedDigit()`) |

Rules:
- Use at most 3 sizes in one view.
- Always put `.monospacedDigit()` on changing numbers such as timers and counts.
- Use `.foregroundStyle(.secondary)` or `.tertiary` for hierarchy, not new grey hexes.
- Don't lighten text with opacity inside materials. Use hierarchical styles so vibrancy works.

### 2.2 Spacing scale (4 pt base)

`xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32 · xxxl 48`

- Row vertical padding is 6 (a compact 28 pt row) or 8 (a 32 pt row). Row horizontal padding is 12.
- The gap between sections is 24. Content max width for reading screens (Notes, Chat) is 720.
- Window content inset is 20 horizontal and 16 top below the toolbar.

### 2.3 Corner radii

`xs 4` (chips, checkboxes) · `s 6` (rows, buttons, fields) · `m 10` (cards, popovers, timeline blocks) · `l 14` (sheets, the command palette) · `xl 20` (onboarding hero panels).
Always use `RoundedRectangle(cornerRadius: r, style: .continuous)`.

### 2.4 Colour tokens

Define these in the Asset Catalog with Any and Dark appearances, and expose them via `Color.orbit.*`.

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg.window` | system `windowBackgroundColor` | system | Main content |
| `bg.canvas` | `#FAFAF9` | `#161618` | Today, Plans canvas |
| `bg.elevated` | `#FFFFFF` | `#1F1F22` | Cards, popovers |
| `bg.subtle` | `#F2F2F0` | `#26262A` | Hover fill, input fields |
| `bg.selected` | accent at 12% | accent at 22% | Selected rows (non-sidebar) |
| `border.hairline` | `#000000` at 8% | `#FFFFFF` at 8% | Dividers, card strokes (0.5 pt) |
| `border.strong` | `#000000` at 14% | `#FFFFFF` at 14% | Focused inputs |
| `text.primary` | `.primary` | `.primary` | |
| `text.secondary` | `.secondary` | `.secondary` | |
| `accent` | `#5B5BF0` (indigo "orbit") | `#7C7CFF` | Primary actions, focus, now-line |
| `success` | `#1F9D55` | `#34C77B` | Done, submitted |
| `warning` | `#D97706` | `#F5A524` | Due soon (under 48 h) |
| `danger` | `#DC2626` | `#FF5A5F` | Overdue, destructive |
| `info` | `#0A84FF` | `#409CFF` | Links, calendar default |

**Module palette** (auto-assigned; the user can change it). This gives 8 hues at equal perceived lightness, each with a tint for the block background.

| Name | Solid (L / D) | Tint bg (L / D) |
|---|---|---|
| indigo | `#5B5BF0` / `#7C7CFF` | `#EEF0FF` / `#262747` |
| teal | `#0F9488` / `#2DD4BF` | `#E6F6F4` / `#16312E` |
| orange | `#EA6A12` / `#FB923C` | `#FDF0E6` / `#3A2616` |
| pink | `#DB2777` / `#F472B6` | `#FCE8F1` / `#3A1A2A` |
| green | `#16A34A` / `#4ADE80` | `#E8F6EC` / `#17301F` |
| purple | `#9333EA` / `#C084FC` | `#F3E8FD` / `#2E1C40` |
| blue | `#2563EB` / `#60A5FA` | `#E8EFFD` / `#18253D` |
| amber | `#CA8A04` / `#FACC15` | `#FBF3DC` / `#352C12` |

Event and assessment blocks use the tint background, a 3 pt leading bar in the solid colour, and primary-coloured text. Never put white text on a coloured fill (except the accent button).

Also respect the user's system accent: offer "Use system accent" (`Color.accentColor`) as a setting and make it the default when the user has picked a non-multicolour accent.

### 2.5 Materials

- **Sidebar:** the default `NavigationSplitView` sidebar material. Don't paint over it.
- **Toolbar:** the system unified toolbar (`.windowToolbarStyle(.unified(showsTitle: false))`), with the title in content.
- **Popovers, command palette, quick add, toasts:** `.regularMaterial` (palette: `.thickMaterial`) plus a 0.5 pt `border.hairline` stroke plus shadow `s2`.
- **Menu bar extra:** `MenuBarExtra(...).menuBarExtraStyle(.window)` with the default material.
- **Content areas:** opaque (`bg.window` or `bg.canvas`). Materials over scrolling content cost GPU time and reduce legibility.
- **Liquid Glass (macOS 26 Tahoe):** when running on 26, the system sidebar and toolbar become glass automatically as long as we use standard containers. Gate custom floating controls (palette, toasts) with `if #available(macOS 26, *) { .glassEffect(.regular, in: .rect(cornerRadius: 14)) } else { .background(.thickMaterial, in: ...) }`. Keep glass to the navigation and floating layer, never content. Don't stack glass on glass.

### 2.6 Shadows (use sparingly; dark mode relies on the border instead)

- `s1` (hover-lifted card): `.shadow(color: .black.opacity(0.06), radius: 2, y: 1)`
- `s2` (popover, toast): `.shadow(color: .black.opacity(0.12), radius: 12, y: 6)`
- `s3` (command palette, sheet): `.shadow(color: .black.opacity(0.22), radius: 32, y: 16)`

In dark mode, halve the opacity and always add the hairline border.

### 2.7 Iconography

- SF Symbols only. Use `.symbolRenderingMode(.hierarchical)` by default and `.monochrome` in dense rows.
- Sidebar icons use the system default size. Inline row icons are 13 pt `.medium` in `.secondary`. Toolbar icons use the system size.
- Use one icon per concept everywhere:

| Concept | Symbol |
|---|---|
| Today | `sun.max` |
| Inbox | `tray` |
| Tasks | `checklist` |
| Uni | `graduationcap` |
| Notes | `note.text` |
| Plans | `map` |
| Chat | `bubble.left.and.text.bubble.right` |
| Settings | `gearshape` |
| Assessment | `doc.text` |
| Lecture | `person.wave.2` |
| Deadline | `flag` |

- Use outline symbols by default and `.fill` for the selected or active state (`.symbolVariant(.fill)` on selection).
- Never use emoji as UI icons.

---

## 3. Layouts

Global shell: `NavigationSplitView` with a sidebar (220 pt, collapsible with ⌘⌃S) and a detail pane. Inbox, Tasks and Notes use a three-column layout (sidebar | list | detail). The minimum window size is 900×600.

```
┌──────────┬─────────────────────────────────────────────┐
│ ● ● ●    │  ‹ ›  Title             [search] [+]  [⋯]   │  unified toolbar
├──────────┼─────────────────────────────────────────────┤
│ Today  3 │                                             │
│ Inbox 12 │                                             │
│ Tasks  7 │                 content                     │
│ ──────── │                                             │
│ UNI      │                                             │
│  ● CS201 │                                             │
│  ● MA210 │                                             │
│ ──────── │                                             │
│ Notes    │                                             │
│ Plans    │                                             │
│ Chat     │                                             │
│          │                                             │
│ ⌘K Search│                                             │
└──────────┴─────────────────────────────────────────────┘
```
Sidebar counts are `caption` in `.tertiary`. Only Today and Inbox show counts by default. Modules are listed under UNI with their colour dot.

### Today (the home screen)
**Primary:** the "Now / Next" card and today's timeline. **Secondary:** the due-soon strip and today's tasks.
```
 Thursday, 26 Sep                           ☀ 14°  [Plan day]
 3 classes · 2 due soon · 5 tasks

 ┌ NOW ─────────────────────────────────────────────────┐
 │▌CS201 Lecture · LT3        10:00–11:00   ends in 24m │
 │ Next: Lunch w/ Sam 12:30                             │
 └──────────────────────────────────────────────────────┘

 TIMELINE                           │  TODAY'S TASKS
 09 ─────────────────────────       │  ○ Read ch.4 notes    CS201
 10 ▌CS201 Lecture          LT3     │  ○ Email tutor        today
 11 ━━━━━━━━━━━ now 10:36 ━━━━━━    │  ○ Gym                 18:00
 12 ▌Lunch w/ Sam                   │  + Add task…  (N)
 13                                 │
 14 ▌MA210 Tutorial                 │  DUE SOON
 ...                                │  ⚑ MA210 PS3      Fri · 1d
                                    │  ⚑ CS201 Essay    Mon · 4d
```
- Two columns at widths of 1100 or more. Below that, the columns stack (timeline first).
- The timeline shows 07:00–22:00 at 48 pt per hour, auto-scrolled so "now" sits at one third of the height. Past events are dimmed to 55%.
- The now-line is a 1.5 pt accent line with a 6 pt dot, updated by `TimelineView(.periodic(from:by: 60))`.
- Dragging on empty space creates an event. Dragging a task onto the timeline time-blocks it (Structured/Amie pattern).

### Inbox
**Primary:** the message list, grouped as Today / Yesterday / Earlier. **Secondary:** the reader pane.
```
 Inbox  [All ▾ Uni · Email · Moodle]      ┆ Re: PS3 extension
 ● Dr Patel     Re: PS3 extension   10:02 ┆ Dr Patel · 10:02
   Moodle       New grade: Quiz 2    9:40 ┆ ──────────────────
   Sam          lunch?               9:15 ┆ body…
                                          ┆ [Reply R] [→ Task T] [Done E]
```
- Rows are 2 lines (sender `headline` plus subject `body`, with the preview in `.secondary` on one line). The source icon sits on the left and the unread dot is the accent colour.
- **E** marks done (the row slides out, and ⌘Z undoes it). **T** converts to a task. **S** snoozes. **J/K** or ↑↓ move the selection.
- The empty state is "Inbox zero. Nice." with a `checkmark.circle` symbol animated via `.symbolEffect(.bounce)` once.

### Tasks
**Primary:** the list with a quick-add field at the top. **Secondary:** filters and the detail inspector.
```
 Tasks   [Today] [Upcoming] [Anytime] [Done]          ⌘N
 ┌──────────────────────────────────────────────────────┐
 │ + read ch 5 for cs201 fri 3pm #reading     ⏎         │
 │   → "read ch 5"  ● CS201  📅 Fri 15:00  #reading     │ parsed preview chips
 └──────────────────────────────────────────────────────┘
 OVERDUE
 ○ Submit lab report            ● CS201   Yesterday  ⚑
 TODAY
 ○ Email tutor                              today
 ○ Gym                                      18:00
```
- The checkbox is an 18 pt circle. On completion it fills with a spring, the text gets struck through, and after 600 ms the row collapses out. The completion sound is optional.
- The inspector (⌘⌥I) is a right-hand `.inspector` with the title, notes, due, module, subtasks and repeat.
- Reorder by dragging. ⌘↑/⌘↓ moves a task. ⌘D opens the due-date picker.

### Uni
**Primary:** a module grid with the next assessment for each module. **Secondary:** the week strip.
```
 Uni       Semester 1 · Week 4 of 12  ▓▓▓▓░░░░░░░░
 ┌ CS201 ──────────┐ ┌ MA210 ──────────┐ ┌ PH110 ─────────┐
 │ Algorithms      │ │ Linear Algebra  │ │ Physics I      │
 │ ⚑ Essay · 4d    │ │ ⚑ PS3 · 1d  !   │ │ nothing due    │
 │ ▓▓▓▓▓░ 62%      │ │ ▓▓░░░░ 30%      │ │ ▓▓▓▓▓▓ 100%    │
 └─────────────────┘ └─────────────────┘ └────────────────┘
 ASSESSMENTS (all)   sortable table: Module · Title · Due · Weight · Status
```
- Cards use `bg.elevated`, radius `m`, a hairline border, and a top stripe in the module tint. Hovering a card lifts it with shadow `s1` and a 1.01 scale.
- Clicking a card opens the module detail (weeks as a vertical list, with the current week expanded and pinned). The card zooms into the header using `matchedGeometryEffect`, or `.navigationTransition(.zoom)` where available.
- The assessments view uses `Table` with sortable columns.

### Notes
Three columns: folder list, notes list (title plus 2-line preview plus date), and an editor capped at 720 pt wide and centred. The editor has no chrome: the title field is 20 pt semibold, the body is 14 pt with a line height of 1.45. Saving is automatic (debounced to 500 ms) with a subtle "Saved" caption in the toolbar.

### Plans
A board or outline of longer-term plans (goals, trips, projects). The default view is cards in columns ("Now / Next / Later"), draggable, and each card shows its progress ring. There is a toggle for list view. Keep it simpler than Tasks: no due-date clutter on cards, just the next step.

### Chat
**Primary:** the conversation, centred at 720 pt max. **Secondary:** the history sidebar, collapsed by default.
```
            ┌──────────────────────────────────────┐
            │ You: what's due this week?           │  (right, bg.subtle bubble)
            │ Orbit: 2 things — MA210 PS3 (Fri)…   │  (left, no bubble, full text)
            │   [Open PS3] [Add study block]       │  (action chips)
            └──────────────────────────────────────┘
 ┌──────────────────────────────────────────────────────┐
 │ Ask Orbit…                                   ⌘⏎  ↑   │ floating composer, material, radius l
 └──────────────────────────────────────────────────────┘
```
- Stream tokens with plain text appends and no per-token animation. Keep the view pinned to the bottom with `.defaultScrollAnchor(.bottom)`.
- Tool results (created a task, and so on) render as compact cards with Undo.

### Settings
A native `Settings { }` scene with a `TabView`: General, Accounts, Uni, Appearance, Shortcuts, Advanced. Use `Form` with `.formStyle(.grouped)`. The window is 560 wide. Don't build a custom settings UI.

### Onboarding (first launch, 4 steps, skippable)
A centred 640×480 panel on `bg.canvas`. There is a large hero symbol with `.symbolEffect(.bounce)`, a `display` title, one line of copy and one primary button. Steps slide horizontally with `.push(from: .trailing)` and page dots.
1. "Your semester, in orbit." → Continue
2. Connect calendar and email (toggles, with permission prompts inline)
3. Add modules (paste a timetable, or type "CS201 Algorithms"; chips appear as you type)
4. Try quick add: a live demo field ("finish essay fri 5pm #CS201" parses into chips) → Start
The last step lands on Today with a confetti-free, gentle fade-in of the populated timeline.

### Menu bar extra
A window-style extra at 320 wide.
```
 Now: CS201 Lecture · ends 11:00
 Next: Lunch w/ Sam · 12:30
 ────────────────────────────
 Due soon
   ⚑ MA210 PS3        1d
 ────────────────────────────
 + Quick add…              ⌥Space
 Open Orbit                 ⌘O
```
The menu bar label shows the icon plus the next event countdown ("CS201 in 12m"), and the user can switch that to icon only. The global quick-add hotkey is ⌥Space, which is configurable.

---

## 4. Interaction and motion

### 4.1 Animation tokens
```swift
enum Motion {
    static let snappy  = Animation.spring(response: 0.25, dampingFraction: 0.86) // selection, toggles, checkbox
    static let smooth  = Animation.spring(response: 0.35, dampingFraction: 0.90) // layout changes, list insert/remove
    static let bouncy  = Animation.spring(response: 0.40, dampingFraction: 0.72) // rare delight: completion, onboarding
    static let fade    = Animation.easeOut(duration: 0.15)                       // hover, opacity
    static let palette = Animation.spring(response: 0.22, dampingFraction: 0.90) // ⌘K open/close
}
```
- Every durational animation is under 350 ms. Hover responds in 100–150 ms. Never animate on first paint of data.
- Check `@Environment(\.accessibilityReduceMotion)`. When it is on, swap springs for `.easeOut(0.12)` and slides for opacity.

### 4.2 Transitions
- List insert and remove: `.transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity.combined(with: .scale(0.98))))`
- Switching screens in the detail pane: plain `.opacity` crossfade (120 ms). Don't slide whole screens.
- Changing numbers (counts, countdowns): `.contentTransition(.numericText())`
- Symbols: `.contentTransition(.symbolEffect(.replace))` when an icon swaps (for example, checkbox to checkmark).
- Card to detail: `matchedGeometryEffect` (in-place), or `.matchedTransitionSource` plus `.navigationTransition(.zoom)` for navigation.
- Selection highlight follows the selected row with a matched-geometry background ("sliding pill") in segmented filters.
- Sections scrolling in on Today: `.scrollTransition { c, p in c.opacity(p.isIdentity ? 1 : 0.6) }`. Keep it subtle.

### 4.3 Hover and press
- Rows get a `bg.subtle` fill on hover, radius `s`, with a `.fade` animation. Row action buttons (⋯, date, delete) appear only on hover at 0 to 1 opacity.
- Buttons: a custom `OrbitButtonStyle` scales to 0.97 and dims to 0.85 opacity on press, using `Motion.snappy`.
- Use `.onHover` plus `.pointerStyle(.link)` for links (macOS 15). Show help text via `.help("Complete (Space)")` on every icon button.
- Focus ring: the system ring for fields. List focus uses the selection colour, and `.focusable()` plus `.focusEffectDisabled()` apply where a custom ring is drawn.

### 4.4 Keyboard map
| Global | |
|---|---|
| ⌘K | Command palette |
| ⌘N | Quick add (in-window) |
| ⌥Space | Global quick add (anywhere) |
| ⌘1…⌘7 | Today, Inbox, Tasks, Uni, Notes, Plans, Chat |
| ⌘F | Search in the current screen |
| ⌘, | Settings |
| ⌘⌃S | Toggle sidebar |
| ⌘⌥I | Toggle inspector |
| ⌘Z / ⇧⌘Z | Undo / Redo (every mutation is undoable) |
| ⌘T | Jump to today (Today/Plans) |

| In lists | |
|---|---|
| ↑↓ / J K | Move the selection |
| ⏎ | Open or edit |
| Space | Complete a task / Quick Look |
| E | Done or archive |
| T | Convert to a task |
| S | Snooze |
| D | Set a due date |
| M | Set a module |
| ⌫ | Delete (with an undo toast) |
| ⌘↑ ⌘↓ | Reorder |

Implement global shortcuts via `.commands { CommandMenu("Go") { … .keyboardShortcut("1") } }` so they appear in the menu bar, which also makes them discoverable. Implement list keys via `.onKeyPress`.

### 4.5 ⌘K command palette
- A centred floating panel 640 wide, 96 pt from the top of the window, radius `l`, `.thickMaterial` (glass on 26) plus `s3`. The window content behind it dims to 8% black. It opens and closes with `Motion.palette`, scaling 0.97→1 with opacity.
- It has a 44 pt search field (17 pt text, `magnifyingglass` icon), with results below it up to 8 visible at 36 pt per row.
- **Sections:** Top hit · Actions ("New task", "Plan my day", "Toggle dark mode") · Navigate (screens, modules) · Tasks · Notes · Events · Ask Orbit ("Ask: <query>" is always the last row and sends to Chat).
- Matching is fuzzy with a subsequence score plus a recency boost. Results update on every keystroke with no debounce for local data, so the index has to stay in memory.
- Each row has an icon, a title with matched characters in `.primary` bold and the rest in `.secondary`, a right-aligned context (module, date) and a shortcut hint.
- Keys: ↑↓ move, ⏎ runs, ⌘⏎ runs in the background, Tab drills into an item (for example, task → "Set due…"), Esc goes back or closes, and ⌘1–9 picks directly.
- An empty query shows recent items plus suggested actions for now ("Start focus on CS201 Essay").

### 4.6 Quick add
- The field parses live and shows the parsed tokens as chips under the text: date/time (`calendar`), module (coloured dot), `#tag`, `!` priority, and `every mon` recurrence. Recognised text in the field gets a tinted background (Things/Todoist style).
- ⏎ creates the item, clears the field and keeps focus (for rapid entry). The new row animates in at its sorted position with `Motion.smooth` and highlights `bg.selected` for 800 ms.
- ⌘⏎ creates the item and opens its detail. Esc clears the field, and a second Esc closes it.
- The global ⌥Space opens a 560-wide floating `NSPanel` (non-activating, `.floating` level). It confirms with a toast "Added to Tasks · Fri 15:00" and then closes.

### 4.7 Toasts
- The toast appears bottom-centre, 16 pt above the edge, as a capsule with `.regularMaterial` plus `s2`. It has 13 pt text, an optional action ("Undo ⌘Z") and optional progress.
- It enters with `.move(edge: .bottom).combined(with: .opacity)` and `Motion.smooth`, and dismisses automatically after 4 s (6 s with an action). Hovering pauses the timer.
- Only one toast shows at a time. A new toast replaces the old one with `.contentTransition(.opacity)`.
- Every destructive or bulk action gets a toast with Undo. Don't use confirmation alerts, except for irreversible account actions.

---

## 5. SwiftUI implementation notes

### 5.1 APIs to use (macOS 15)
- **Structure:** `NavigationSplitView(columnVisibility:)`, `.navigationSplitViewColumnWidth(min:ideal:max:)`, `.inspector(isPresented:)`, `Settings {}`, `MenuBarExtra(...).menuBarExtraStyle(.window)`, `Window` / `WindowGroup(id:)`, `.windowToolbarStyle(.unified(showsTitle: false))`, `.containerBackground(.thinMaterial, for: .window)` (macOS 15) for special windows, `.toolbarBackgroundVisibility`.
- **Lists:** `List(selection:)` with `.listStyle(.sidebar)` in the sidebar and `.listStyle(.plain)` or `.inset` elsewhere. Add `.scrollContentBackground(.hidden)` when drawing a custom background. Use `Table` for assessments. Use `.contextMenu` everywhere, and `.draggable` / `.dropDestination`.
- **Scrolling:** `ScrollViewReader` / `.scrollPosition(id:)` to jump to now, `.defaultScrollAnchor(.bottom)` for Chat, `.scrollTransition`, and `.onScrollGeometryChange` (macOS 15) for the collapsing header.
- **Motion:** `withAnimation(Motion.smooth)`, `.animation(_, value:)` (always pass a value), `matchedGeometryEffect`, `.navigationTransition(.zoom(sourceID:in:))` with `.matchedTransitionSource`, `.contentTransition(.numericText())`, `.symbolEffect(.bounce / .pulse / .replace)`, `PhaseAnimator` for onboarding hero loops, `KeyframeAnimator` for the completion checkmark, and `.sensoryFeedback(.success, trigger:)` for trackpad haptics on completion.
- **Input:** `.onKeyPress(keys:phases:)`, `.keyboardShortcut`, `@FocusState` plus `.focused`, `.defaultFocus`, `.onSubmit`, `.searchable` (⌘F) with `.searchFocused` (macOS 15), `.focusedSceneValue` for menu commands that act on the current selection.
- **Time:** `TimelineView(.periodic(from: .now, by: 60))` for the now-line and countdowns. Use `Text(date, style: .timer)` / `.relative` for countdowns, which cost nothing to re-render.
- **State:** the `@Observable` macro (Observation) instead of `ObservableObject`, which gives property-level invalidation. Use SwiftData or the existing store behind a repository, and do writes off the main actor.
- **Liquid Glass (when building on the macOS 26 SDK):** `.glassEffect()`, `GlassEffectContainer`, `.buttonStyle(.glass)`, all behind `#available(macOS 26, *)`. Everything else adopts it for free when using standard components.

### 5.2 Performance do's
- Give every `ForEach` element a stable `Identifiable` id (a UUID from the model, never `\.self` on structs or indices).
- Keep views small, so each piece of state lives in the smallest subview that reads it. With `@Observable`, pass models down and read properties at leaf level.
- Precompute derived data (grouping, sorting, date formatting) in the model or view model and cache it. Never sort or filter inside `body`.
- Use `LazyVStack` / `LazyVGrid` inside `ScrollView` for long custom lists, and `List` for very long ones (it's backed by `NSTableView`).
- Reuse `Date.FormatStyle` / `.formatted()` and never create `DateFormatter` in `body`.
- Apply `.drawingGroup()` only to static, heavily layered decorative views (onboarding art, progress rings), never to text-heavy or interactive views.
- Use `.geometryGroup()` when a parent animates size and children jump.
- Use `.task(id:)` for async loads, which cancels automatically, and run debounced search with `try await Task.sleep`.
- Profile with Instruments → SwiftUI template (View Body, View Properties, Hitches). Target 0 hitches when scrolling Today and Inbox, and first paint of Today under 100 ms after launch.

### 5.3 Performance don'ts
- Don't wrap everything in `GeometryReader`. Use `containerRelativeFrame`, `.onGeometryChange` (macOS 15) or `ViewThatFits`.
- Don't use `AnyView` in lists, and don't use conditional `if` that swaps view identity when `.opacity` or a modifier would do.
- Don't use implicit `.animation()` without a value, and don't animate the whole screen when one row changes.
- Don't use materials or blur inside scrolling rows, and don't put shadows on every row.
- Don't use `onAppear` for data loading in rows. Load in the parent or the model.
- Don't block the main thread on network, parsing or disk. Parse natural-language dates synchronously only if they take under 2 ms. Otherwise, move parsing off the main thread.

### 5.4 Component library (`Sources/.../DesignSystem/`)
| Component | Purpose |
|---|---|
| `Theme` / `Color.orbit`, `Spacing`, `Radius`, `Motion`, `OrbitFont` | Tokens from §2 and §4.1 |
| `OrbitButtonStyle(.primary/.secondary/.ghost/.destructive)` | Buttons with press scale |
| `HoverRow` | Row container with hover fill, selection, and hover-revealed trailing actions |
| `SectionHeader` | `micro` uppercase label plus optional count and action |
| `ModuleDot` / `ModuleChip` | Coloured dot or chip for a module |
| `DueBadge` | Relative due text coloured by urgency (danger/warning/secondary) |
| `TaskCheckbox` | Animated circular checkbox (keyframes plus haptic) |
| `TaskRow` | Title, metadata chips, hover actions, and swipe/keys |
| `EventBlock` | Timeline block (tint background, leading bar, title, time, location) |
| `TimelineView` (`DayTimeline`) | Hour grid, now-line, drag-to-create |
| `NowNextCard` | Today hero card |
| `ModuleCard` | Uni grid card with progress |
| `ProgressBarThin` / `ProgressRing` | 4 pt bars and 20 pt rings |
| `QuickAddField` | NL input with live token highlighting and a parsed chip row |
| `TokenChip` | Parsed token chip (date, module, tag, priority) |
| `CommandPalette` + `CommandItem` / `CommandProvider` protocol | ⌘K |
| `ToastCenter` (`@Observable`) + `ToastView` | Global toasts with undo |
| `EmptyState` | Symbol, sentence, and action button with shortcut hint |
| `SkeletonRow` | Shimmer placeholder (`.redacted(reason: .placeholder)` plus a phase animation) |
| `KeyHint` | Rendered shortcut (for example "⌘K") in a `bg.subtle` capsule, `caption` mono |
| `FloatingPanel` | `NSPanel` wrapper for global quick add |
| `Card` | `bg.elevated`, radius m, hairline border, optional hover lift |

---

## 6. Top 10 changes, ranked by impact

1. **Adopt the token system (type, spacing, colour, radius)** and delete ad-hoc values. This alone fixes most of the "feels cheap" problem.
2. **Build the ⌘K command palette plus the full keyboard map** (with the menu-bar `CommandMenu`s). Speed you can feel.
3. **Make every mutation optimistic with toasts and Undo** (complete, delete, archive, move). This removes spinners and confirm dialogs.
4. **Rebuild Today around "Now/Next" plus a real timeline** with a live now-line and drag-to-timeblock.
5. **Standardise on native structure:** `NavigationSplitView` with the sidebar material, a unified toolbar, `.inspector`, a native `Settings` scene and `Table`.
6. **Quick add with live NL chips**, both in-app (⌘N) and global (⌥Space `FloatingPanel`).
7. **Motion pass:** apply the `Motion` tokens, list insert and remove transitions, `numericText`, symbol effects and the checkbox animation, all respecting Reduce Motion.
8. **Hover and press states on every interactive element** (`HoverRow`, `OrbitButtonStyle`, `.help` tooltips).
9. **Performance pass:** `@Observable`, stable ids, precomputed groupings, lazy containers and Instruments hitch profiling.
10. **Empty states, onboarding and the menu bar extra** as polish that makes it feel finished.

---

## Sources
- Apple Human Interface Guidelines: Designing for macOS, Sidebars, Toolbars, Materials, Typography (macOS body text is 13 pt), SF Symbols, Motion, Keyboards. developer.apple.com/design/human-interface-guidelines
- Apple, "Meet Liquid Glass" / "Build a SwiftUI app with the new design" (WWDC25), and the `glassEffect` docs.
- WWDC23 "Animate with springs" (spring response/damping model, `.snappy`/`.smooth`/`.bouncy`) and "Wind your way through advanced animations in SwiftUI" (PhaseAnimator, KeyframeAnimator).
- WWDC23 "Demystify SwiftUI performance", WWDC25 "Optimize SwiftUI performance with Instruments", and WWDC24 "What's new in SwiftUI" (zoom transitions, `onScrollGeometryChange`, `pointerStyle`, window APIs).
- WWDC23 "Discover Observation in SwiftUI".
- Linear: "How we redesigned the Linear UI" (2024) and linear.app/method (keyboard-first, speed, restrained colour).
- Things 3 (Cultured Code) for quick entry, completion animation and calm density. Raycast and Superhuman for command-palette and keyboard-first patterns. Notion Calendar (Cron), Amie and Structured for timeline, time-blocking and the now-line. Fantastical for natural-language parsing with a live token preview. Arc for sidebar-centric navigation and restrained motion.
- Refactoring UI (Wathan & Schoger) for spacing scales, grey-dominant palettes and hierarchy through colour and weight rather than size.

---

## 0. Owner's direction (overrides anything above)

**Reference apps:** Notion, Notion Calendar (Cron), Fantastical, Apple Calendar/Reminders, Things 3.
Clean, quiet, typographic, native. It must **not look AI-generated**.

### Owner's checklist (every screen must pass)
- **Space:** generous, consistent whitespace on a strict 4/8 pt grid. One primary thing per screen; secondary things quieter. Content is the star and chrome stays out of the way. Edges and columns align.
- **Type:** system font only. Size scale limited to **11 / 13 / 15 / 17 / 22 / 26**. Strong heading/body contrast, comfortable line length and line height, no bold/italic overuse.
- **Colour:** mostly neutrals, with soft off-white/soft-black backgrounds (never pure #FFF/#000 for large areas). One accent, used only for primary actions. Excellent text contrast. Separators are hairlines or just space.
- **Details:** minimal borders and boxes, soft elevation only where depth is needed, consistent intentional corner radii, and one icon style (SF Symbols, regular weight). No gradients, glows or sparkle.
- **Motion:** instant response, short non-bouncy springs, clear hover and pressed states.
- **Feel:** calm, native to macOS, hand-made, nothing template-y.
- **Rule of thumb:** if you can remove something and the screen still works, remove it. Every element earns its place.

### Avoid (the "AI-generated app" look)
- No gradients (backgrounds, buttons, text), no glows, no neon.
- No purple/indigo "AI" accent. Use a restrained accent: **Notion-style blue `#2383E2`** (dark: `#529CCA`) used sparingly, for selection/links/primary actions only.
- No sparkles ✨, robot or magic-wand icons, and no "AI-powered" labels. The assistant is just "Ask Orbit".
- No emoji as UI decoration (replace the inbox category emojis with small monochrome SF Symbols or plain text labels).
- No cards-inside-cards, heavy drop shadows, or everything in rounded "bubbles". Prefer flat surfaces separated by hairline dividers (0.5 pt, `separatorColor`) and whitespace.
- No oversized rounded pill buttons everywhere; use native `.bordered`/`.borderless` controls and plain text buttons.
- No filler copy ("Supercharge your productivity!"). Short, plain, human labels.
- No random colourful badges. Colour only carries meaning (module colour dot, overdue red).

### Do
- **Typography does the work:** system font, 13 pt body, clear weight hierarchy, generous line height, left-aligned; page titles like Notion (large, bold, lots of top padding).
- **Neutral palette:** light `#FFFFFF` content on `#F7F7F5` sidebar (Notion); dark `#191919` content on `#202020` sidebar; text `#37352F` / `#FFFFFFCF`; secondary text `#787774` / `#9B9A97`.
- **Module colours as small dots or thin left bars**, muted Notion-like tones (e.g. `#E03E3E` red, `#D9730D` orange, `#DFAB01` yellow, `#0F7B6C` green, `#0B6E99` blue, `#6940A5` purple, `#AD1A72` pink, `#64473A` brown), never as big filled cards.
- **Calendar views like Fantastical/Notion Calendar:** a real time grid (hour lines, day columns), events as flat tinted blocks with a coloured left edge, a red "now" line, and a week view as well as day.
- **Lists like Things/Notion:** rows with hover highlight, circle checkboxes, inline metadata in secondary text, and no boxes around rows.
- **Native macOS chrome:** a real `NavigationSplitView` sidebar with the standard sidebar material, unified toolbar, SF Symbols (regular weight, monochrome), and standard sheets and popovers.
- Motion: subtle and quick (≈0.2 s ease-out / snappy spring). Nothing bouncy or showy.
