# Orbit

A personal AI assistant for university life, built as a native SwiftUI app for Mac and iPhone.
Orbit reads your Gmail and Exeter email, runs your calendar, schedules your to-dos into free time,
tracks ELE (Moodle) deadlines and marks, reads your OneNote lecture notes (typed *and* handwritten),
spots plans in your messages, and coaches you towards a First.

Everything is free to run: the AI comes from **OpenCode** (`opencode serve`) on your Mac, with
**Ollama** as an offline backup. There is no server; your data lives on your devices and in your
private iCloud.

- **Plan and design:** [docs/PLAN.md](docs/PLAN.md)
- **Step-by-step setup (Google, Exeter, ELE, AI):** [docs/SETUP.md](docs/SETUP.md)

## What it does

| Area | Highlights |
|---|---|
| Today | Morning brief, a timeline of events and planned study blocks, "next up" with start/done/skip, due-soon strip, "Lighten my day", "Reshuffle", evening review |
| Tasks | Natural-language quick add ("essay plan BEM2031 2h before Friday") with a live preview; the smart scheduler finds the slots |
| Inbox | Gmail + Exeter mail sorted into urgent / needs reply / dates / uni, one-line summaries, one-tap suggested to-dos and events, reply drafts saved to your Drafts folder (never sent) |
| Uni | Modules, weights, marks, "what do I need for a First?", upcoming assessments with on-track status, reading lists, ELE announcements, "Plan this assessment", revision timetables |
| Notes | OneNote typed + handwritten notes merged, handwriting read on your Mac (Apple Vision + a local vision model), hybrid search, "Ask your notes", flashcards (SM-2), gap detection |
| Plans | Plans found in WhatsApp exports, Instagram downloads, pasted text, screenshots, iMessage and the share sheet, each one tap from your calendar |
| Chat | An assistant that can see and change your schedule, to-dos, deadlines, inbox and notes |
| Extras | Menu bar item, widgets ("Next up", "Due this week"), Siri / Shortcuts ("Add to Orbit", "What's next"), share extension |

Orbit only writes to its own **Orbit** Google calendar, saves email replies as **drafts**, and asks
for one tap before adding anything it found in your email or messages.

## Architecture

```
            ┌──────────────── Mac: the brain ────────────────┐
 Gmail ─────┤ OrbitBrain                                      │
 Exeter ────┤  ├ AccountManager (Google / Microsoft / ELE)    │
 Calendars ─┤  ├ OpenCodeLauncher → opencode serve  ┐        │
 ELE ───────┤  ├ OllamaManager    → ollama          ├ LLMRouter
 OneNote ───┤  ├ sync jobs on timers, scheduler, briefs       │
 iMessage ──┤  └ Assistant (answers chat, incl. the iPhone's) │
            │ Application Support: full text, note index      │
            └───────────────┬─────────────────────────────────┘
                            │ SwiftData ⇄ CloudKit private database
            ┌───────────────┴──────────── iPhone: the remote ─┐
            │ Same SwiftUI screens · quick add · plans ·       │
            │ flashcards · chat (queued to the Mac, or direct  │
            │ over Tailscale) · widgets · share extension      │
            └──────────────────────────────────────────────────┘
```

- **OrbitCore** (`Sources/OrbitCore`) is a Swift package with all the logic: models, the scheduler,
  AI routing, email/calendar/ELE/OneNote clients, parsers, handwriting pipeline, study coach and the
  chat assistant. It builds and tests on Linux too.
- **The apps** (`App/`) are thin SwiftUI layers over OrbitCore:
  - The **Mac app** owns the AI, the sign-ins and every sync job, and runs the scheduler. It starts at
    login and lives in the menu bar.
  - The **iPhone app** shows the synced data and captures input. Anything that needs the Mac (AI,
    replanning, calendar writes, drafts) is sent to it through the synced store.
  - **SwiftData + CloudKit** syncs summaries between them (never full email bodies or full note text).
  - **Widgets** read a small JSON snapshot in the shared App Group; the **share extension** drops items
    there for the app to pick up.

## Repository layout

```
Package.swift              OrbitCore Swift package
Sources/OrbitCore/         All app logic (see docs/PLAN.md)
Tests/OrbitCoreTests/      Unit tests (run on macOS or Linux)
App/
  Shared/
    Common/                Shared with widgets + share extension (App Group, widget snapshot, share inbox)
    DesignSystem/          Theme, components, small UI helpers
    Store/                 SwiftData models (Stored…) and conversions to OrbitCore types
    Services/              AppModel, backend protocol, agenda, plan import, assistant data source
    Views/                 Today, Inbox, Tasks, Uni, Notes, Plans, Chat, Settings, onboarding
    Intents/               App Intents and Siri phrases
    Resources/             Asset catalogue (app icon, accent colour)
  macOS/                   Mac app: OrbitBrain + sync jobs, OpenCode/Ollama managers, menu bar, settings
  iOS/                     iPhone app: remote backend, background refresh, notifications
  Widgets/                 WidgetKit extension (iOS + macOS)
  Share/                   iOS share extension
  Supporting/              Generated Info.plists and entitlements (from project.yml)
Config/                    Orbit.xcconfig (+ your git-ignored Secrets.xcconfig)
project.yml                XcodeGen spec → Orbit.xcodeproj
Tools/handwriting/         Optional TrOCR / Texify helpers for handwriting
docs/                      PLAN.md, SETUP.md
```

## Running the tests

OrbitCore's tests run anywhere Swift 5.10+ is installed (macOS or Linux):

```
swift test
```

## Building the apps

Follow [docs/SETUP.md](docs/SETUP.md). In short:

1. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and add your Google and
   Microsoft client IDs.
2. Set `DEVELOPMENT_TEAM` in `Config/Orbit.xcconfig`.
3. Open `Orbit.xcodeproj` (or regenerate it with `xcodegen generate`), run **Orbit-macOS** on your
   Mac, and archive **Orbit-iOS** for TestFlight.

Targets: `Orbit-macOS`, `Orbit-iOS`, `OrbitWidgets-macOS`, `OrbitWidgets-iOS`, `OrbitShare`.
macOS 15+ and iOS 18+, Swift 5 language mode.

## Privacy

- No backend server and no paid AI. Cloud models are only used through your own OpenCode setup,
  and **local-only mode** forces everything through Ollama on your Mac.
- Email bodies, full note text and message history stay on the Mac. Only summaries sync to iCloud.
- Orbit never sends email, deletes anything, or edits your own calendar events.
