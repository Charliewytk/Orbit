# Orbit Design Spec — "Orbit Glass"

Orbit is the student's home base: the first thing opened in the morning, the thing
glanced at between lectures. It should feel like Apple's own apps on macOS 26 Tahoe
(Liquid Glass), with the energy of Raycast, Arc, Things 3 and Apple Fitness: vivid,
alive, rewarding to come back to. Not a blank slate, not a 2015 app.

This replaces the earlier Notion-minimal direction (flat neutrals, no glass), which the
owner found "tacky… way too minimalist".

## 0. Owner's direction (overrides anything below)

- **One dashboard first.** Home opens on launch and shows the whole day: today and
  tomorrow, to-dos (with instant add), rings and streak, what's next, deadlines, uni,
  inbox, careers, money, flashcards, Ask Orbit. Every card opens its full screen.
- **Liquid Glass, not minimalism.** Translucent glass cards over a softly moving,
  time-of-day backdrop. Depth from glass, rims and soft shadows.
- **Addictive, in a good way.** Three daily rings (study minutes, to-dos, flashcard
  reviews), a streak flame, an 18-week heatmap, satisfying check animations.
- **Colourful and tasteful.** Indigo → violet → pink accent, vivid module colours,
  colour icon tiles like macOS Settings. No "AI sparkle" clichés (no ✨ icons).
- **Where work came from is always visible**: blue "You set", violet "Orbit
  recommends", orange "Required", hot-pink "Do now" for the block scheduled right now.

### Checklist (every screen)

1. Sits on the ambient backdrop (`.orbitBackground()` / `.orbitScreen()`), content in glass.
2. Bold large title (30 pt) with the gradient underline, or a rounded display greeting.
3. Numbers in SF Pro Rounded (`Theme.number`), tabular.
4. Primary action is `.orbitGlassProminentButton()`, secondary `.orbitGlassButton()`.
5. Lists animate insert/remove; checkboxes bounce; cards stagger in.
6. Works in light and dark; readable over every backdrop phase.
7. Nothing stacks more than two glass layers (card → control).

## 1. Toolchain and availability

- Built with **Xcode 26 / macOS 26 SDK** on GitHub's `macos-26` runner (see
  `.github/workflows/release-mac.yml`). Deployment target stays **macOS 15**.
- Every macOS 26 symbol is referenced only inside `#if compiler(>=6.2)` (so Xcode 16
  still compiles) **and** `if #available(macOS 26.0, iOS 26.0, *)` (so macOS 15 runs the
  fallback). All of that lives in `App/Shared/DesignSystem/Glass.swift`:

| Helper | macOS 26 | Fallback (macOS 15) |
|---|---|---|
| `.orbitGlass(in:tint:interactive:)` | `.glassEffect(Glass.regular.tint().interactive(), in:)` | `.ultraThinMaterial` + tint + gradient rim + soft shadow |
| `.orbitGlassCard(radius:tint:)` | same, continuous rounded rect (24) | same |
| `.orbitGlassButton()` | `.buttonStyle(.glass)` | `GlassCapsuleButtonStyle` |
| `.orbitGlassProminentButton(color)` | `.buttonStyle(.glassProminent).tint(color)` | `PillButtonStyle` (gradient capsule) |
| `OrbitGlassContainer` | `GlassEffectContainer(spacing:)` | plain content |
| `.orbitBackgroundExtension()` | `.backgroundExtensionEffect()` | no-op |

Never call the macOS 26 APIs directly from screens; add a helper here instead.

## 2. Visual system

### 2.1 Backdrop

`AmbientBackdrop`: a 3 × 3 `MeshGradient` (macOS 15+) whose middle points drift in slow
loops (15 fps `TimelineView`, paused with Reduce Motion) under a faint veil (white 22 %
light, black 18 % dark). Colours follow the time of day (`DayPhase`): dawn 05–09 (peach,
rose, lavender), day 09–17 (sky, periwinkle, mint), dusk 17–21 (apricot, magenta,
violet), night (deep navy, indigo, plum). One backdrop per screen: screens inside a
`TwoPane` glass pane don't draw their own (`\.inGlassPane`).

### 2.2 Colour tokens (`Theme`)

- Accent `#6246EA` / dark `#9B8CFF`; gradient `indigo #4F6BFF → violet #8B5CF6 → pink #EC4899`.
- Text: primary `#15122A` / white 95 %; secondary `#57536E` / `#BDB9D2`; tertiary `#928EA8` / `#7D7995`.
- Meaning: success `#10A874`, warning `#F08C00`, danger `#EF3B5D`, now-line `#FF2D55`.
- Rings: study `#FA114F → #FF5E9C`, to-dos `#5BC21E → #B6F03D`, reviews `#00A9D6 → #5CE1F5`.
- Modules (vivid, stable hash of the code): red, orange, yellow, green, cyan, blue, violet, pink.
- Origin: You set `#2F7BF6`, Orbit recommends `#8B5CF6`, Required `#F06A00`, Do now `#FF2D55`.
- Sidebar icon tiles: one colour per destination (`Destination.color`).

### 2.3 Type

System font. Page titles 30 bold; Home greeting 38 bold rounded; section titles 17
bold; body 13 (Mac); captions 11. Numbers: `Theme.number(size)` = SF Pro Rounded,
bold, monospaced digits.

### 2.4 Shape and depth

Radii: chips 6, rows 10, small cards 14, sheets 18, **glass cards 24**, hero panels 28.
Glass cards have a bright top-left rim and a soft coloured shadow (`Theme.glassShadow`).
Capsules for chips, segmented controls, toasts and the sidebar selection.

### 2.5 Icons

SF Symbols, filled, in colour tiles (`IconTile`) in the sidebar, card headers,
onboarding and activity rows. Hierarchical rendering inside tiles.

## 3. Layouts

### Sidebar (`GlassSidebar`)

Grouped: Home · Calendar · Inbox · Tasks / University: Uni · Notes · Flashcards ·
Progress / Focus and life: Focus · Plans · Money · Careers / Assistant: Ask Orbit.
Colour icon tile + title + count badge. Selection is a **tinted glass capsule** that
slides between rows (`matchedGeometryEffect`); hover is a faint capsule. ↑/↓ move the
selection; ⌘1…⌘8 follow `Destination.macSidebar` (Home first). Brain status sits in a
glass capsule at the bottom.

### Home (`HomeView`, first screen)

Header: date, "Week N · Term T" chip, "Good evening, Charles" (name in the gradient),
the morning brief (or a computed one-liner), and the streak flame on the right.
Then the **quick-add bar** (natural language, ⌘N focuses it, live parsed chips, the
plus turns into a green check with a burst), the origin legend, and the bento grid:

| Wide (3 cols) | | |
|---|---|---|
| Today and tomorrow (2) | | Your day: rings, heatmap |
| Today's to-dos | Next up / Focus | Deadlines |
| Uni this week (2) | | Flashcards |
| Inbox | Careers | Money |
| ELE and Ed (2) | | Ask Orbit |

Two columns under 1180 pt, one under 720 pt; rows are equal height. Cards stagger in
and lift on hover; the header row of a card (or a double-click) opens its screen.

### Other screens

- **Calendar**: rounded-title header with the origin legend, the time grid inside a
  glass card; blocks tinted by origin, "Do now" block outlined and glowing.
- **Tasks**: quick add in glass, origin filter chips, groups (Today / This week /
  Later / Someday) as glass cards, origin bar per row, "Do now" badge.
- **Inbox, Notes, Uni**: `TwoPane` = two glass panes over the backdrop.
- **Ask Orbit**: gradient user bubbles, glass assistant bubbles with the Orbit tile,
  typing dots, glass composer.
- **Flashcards**: 3D flip card, graded with coloured glass buttons (1–4).
- **Focus**: 300 pt ring timer in SF Pro Rounded, presets, glass controls.
- **Careers**: category segmented control with counts, status control, filter toggles
  (Watchlist, Eligible for me, First-year, Diversity), glass rows with firm logos
  (favicon via `FirmDomains` + disk cache, monogram fallback), countdowns.
- **Money, Progress, Settings**: segmented glass header; forms with hidden
  backgrounds over the backdrop.

### Onboarding (`MacOnboardingView`)

Full window, glass card over the backdrop, progress dots (ticks when a step is done),
slide transitions. Steps: Welcome (name) → Your uni (Exeter, programme, year, term
dates: week 1 = Mon 21 Sep 2026) → ELE → Ed Discussion (US region) → Google → Exeter
mail and calendar (Internet Accounts, Full Disk Access, Calendar) → Notes (GoodNotes
auto-backup found in OneDrive or Google Drive; OneNote as the alternative) → AI
(OpenCode / Ollama) → Money (optional) → Careers (year, diversity groups, star firms)
→ Focus and notifications → Routine and ring goals → Done (rings + burst). Every step
skippable; re-run from Settings → General → "Run setup again".

### Menu bar extra

Material popover with a soft gradient: date + streak capsule, mini rings with numbers,
next up, due soon, focus controls, glass quick add.

## 4. Motion

`Motion.snappy` (selection), `.smooth` (layout), `.bouncy` (checks, rings, add
confirmation), `.arrive` (cards, staggered 45 ms), `.fade` (hover). Animate transforms
and opacity only. Rings fill with a spring on appear. Checkbox: gradient fill, 1.25×
pop, 10-dot burst, strike-through. Respect Reduce Motion (backdrop pauses, cards don't rise).

## 5. Performance

- One `AmbientBackdrop` per window; `TwoPane` panes opt out.
- Glass cards in the bento grid share one `OrbitGlassContainer`.
- Home computes its data once a minute (`HomeContext` inside `TimelineView(.everyMinute)`).
- Logos are cached in memory and on disk (`~/Library/Caches/Orbit/Logos`).
- Lists stay lazy (`LazyVStack`) where they can be long (Careers, Tasks, Chat).

## 6. Components (`App/Shared/DesignSystem`)

`Glass.swift` (glass helpers, `GlassCard`, `AmbientBackdrop`, `IconTile`, `RingArc`,
`ActivityRings`, `ActivityHeatmap`, `StaggeredAppear`, `HoverLift`, `CheckBurst`,
`GlassSegmented`), `Origin.swift` (origin colours, `OriginDot`, `OriginChip`,
`DoNowBadge`, `OriginLegend`, `OriginFilterChips`), `Controls.swift` (`Page`,
`PageHeader`, `PageSection` as glass card, `CircleCheckbox`, `SidebarItem`, `TwoPane`,
toasts), `Components.swift` (shared with widgets: `Card`, `Tag`, `ModuleChip`,
`ProgressRing`, `ThinProgressBar`, `EmptyState`, `PillButtonStyle`), `Theme.swift`.
