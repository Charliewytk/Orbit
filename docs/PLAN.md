# Orbit — Build Plan

A personal AI assistant for uni life: it reads your email, runs your calendar, schedules your to‑dos,
tracks your Exeter degree (ELE), and reads your OneNote lecture notes. It's a native Swift app for Mac and
iPhone that syncs between the two.

---

## 1. Architecture

```
┌──────────────────────────── Mac app (the "brain") ────────────────────────────┐
│  SwiftUI UI · menu bar item · background agent loop (runs while Mac is awake) │
│                                                                               │
│  Connectors            AI layer                   Engines                     │
│  ├ Gmail API           ├ LLMRouter                ├ Email triage              │
│  ├ Google Calendar     │  ├ OpenCode (default)    ├ Smart scheduler           │
│  ├ ELE / Moodle        │  └ Ollama (backup)       ├ Study coach               │
│  ├ OneNote (Graph)     └ Prompt + tool layer      ├ Daily brief / review      │
│  └ Messages (import)                              └ Plan extractor (messages) │
│                                                                               │
│  SwiftData store ──────── CloudKit private DB (sync) ────────┐                │
└───────────────────────────────────────────────────────────────┼───────────────┘
                                                                │
┌──────────────────────────── iPhone app (TestFlight) ──────────▼───────────────┐
│  Same SwiftUI codebase: Today view, inbox highlights, tasks, chat, widgets    │
│  Push notifications for urgent mail, deadlines and schedule changes           │
│  Quick add: to-do, voice note, share-sheet ("add this to Orbit")              │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Why the Mac is the brain:** the local LLM, OneNote files and heavy background work all live there.
The phone mostly views synced data and captures input. If the Mac is asleep, the phone still works
with the last synced state. Chat typed on the phone is queued in CloudKit and answered by the Mac
(optionally live via a free Tailscale link between phone and Mac).

### Tech stack
| Area | Choice |
|---|---|
| UI | SwiftUI multiplatform (macOS 15+ / iOS 18+) with a custom design system (see §6) |
| Storage + sync | SwiftData backed by **CloudKit private database**: free, no server, uses your Apple ID |
| Secrets | Keychain (Google/Microsoft OAuth tokens), synced through iCloud Keychain |
| Google auth | OAuth 2.0 PKCE via `ASWebAuthenticationSession` |
| AI (main) | **OpenCode** running headless on the Mac (`opencode serve`, local HTTP API) using its free models |
| AI (backup) | **Ollama** with a small local model (e.g. Qwen 3 8B) |
| Background | Mac: `NSBackgroundActivityScheduler` + login item. iOS: `BGAppRefreshTask` + CloudKit pushes |
| Notifications | Local notifications from the Mac; CloudKit subscriptions trigger them on the phone |
| Widgets | WidgetKit: "Next up", "Due this week" |

### AI routing (free only: no paid API)
`LLMRouter` picks a provider per request, and **never uses a paid API**:
1. **OpenCode** by default. Orbit talks to `opencode serve` on `localhost`, which gives it whatever
   models your OpenCode setup has (its free models, or any account you've already connected).
   Orbit starts the server itself as a background helper if it isn't running.
2. **Ollama** fallback when OpenCode is down, rate-limited or offline, and for private/bulk jobs
   (e.g. first-pass sorting of 500 emails stays fully on-device).
3. Every feature is written against one `LLMProvider` protocol, so both get the same prompts.
   Structured outputs use JSON schemas and are validated/retried, so small local models stay reliable.
4. Heavy lifting stays in plain code (scheduler, parsers, date extraction) so the AI does only the
   judgement calls. This keeps it fast and works well with smaller models.

---

## 2. Features by phase

### Phase 1: Core (the foundation)
- Xcode multiplatform project, design system, SwiftData models, CloudKit sync Mac ↔ iPhone.
- Settings: connect Google, detect OpenCode and Ollama, pick models.
- **Google Calendar**: read all calendars, and write events to a dedicated "Orbit" calendar so the AI
  never edits your real events without asking.
- **To-dos**: title, estimate, deadline, priority, energy level, module tag. Natural-language quick add
  ("essay plan for BEM2031, 2h, before Friday").
- **Smart scheduler** (details in §3).
- **Chat**: "what's my week look like?", "move gym to tomorrow", with tool access to everything.
- **LLMRouter**: OpenCode → Ollama automatic fallback.

### Phase 2: Gmail intelligence
- Incremental sync via Gmail history IDs.
- Triage every new email into: 🔴 urgent / 🟠 needs reply / 📅 contains a date or plan / 📚 uni / ⚪ ignore.
- Extract action items → suggested to-dos (one tap to accept) and events → suggested calendar entries.
- Notify only on 🔴 and your chosen senders (lecturers, landlord, employer).
- Draft replies in your tone. Drafts are saved to Gmail; **the app never sends email without you.**

### Phase 3: Exeter degree integration (ELE)
ELE is Moodle. The plan, in order of preference:
1. **Moodle web-service token** (the same mechanism the official Moodle mobile app uses) → modules,
   assignments and due dates, resources, grades, forum announcements.
2. Fallback: **ELE calendar export (iCal URL)** for deadlines, plus a logged-in `WKWebView` session for pages.
- Also: timetable iCal feed from the Exeter timetable system, and reading lists (Talis Aspire,
  if Exeter uses it for your modules).
- **Study coach**:
  - Module weighting model: each assessment's % of the module and module credits → where marks matter most.
  - Breaks each assignment into scheduled chunks (research → plan → draft → edit) working back from the deadline.
  - Weekly "on track for a First?" review: coverage of readings, lectures reviewed, upcoming load.
  - Exam season: revision timetable plus spaced-repetition prompts generated from your notes.

### Phase 4: OneNote notes
Caveat: modern OneNote notebooks on OneDrive usually **aren't real files in Finder**. What you see is
often a shortcut, and the content lives in the cloud. Options:
1. **Microsoft Graph OneNote API** (best: full text per page, stays current). Needs sign-in with your
   Exeter Microsoft account. Exeter IT *may* require admin approval for third-party apps. We test this first.
2. If blocked: periodic **export of notebooks to PDF**, which Orbit watches in a folder and indexes.
3. Any real `.one`/PDF/Markdown files in your OneDrive folder are indexed directly.
- Notes get chunked and embedded locally (on-device embeddings) → "what did the lecture say about X?",
  auto-summaries per lecture, links between notes and assignments, and gap detection ("no notes for Week 6 of BEM2031").

### Phase 5: Messages → plans
Meta offers **no official API for personal WhatsApp or Instagram DMs**. Unofficial scrapers break
their terms and risk an account ban, so Orbit won't use them. Safe options:
- **Share sheet**: share a message or screenshot to Orbit → it extracts the plan ("Dinner w/ Sam, Sat 7pm") → calendar.
- **WhatsApp chat export** (.txt) → bulk plan extraction.
- **Screenshot OCR** (Vision framework) for Instagram DMs.
- **iMessage** (Mac only, with Full Disk Access) can be read locally and legitimately.

### Phase 6: Polish and extras
- Morning brief notification plus an end-of-day review (roll over unfinished tasks, log what got done).
- Widgets, Live Activity for the current focus block, Focus-mode integration.
- Habit and energy tracking to improve scheduling (learns when you actually do deep work).
- Siri / App Intents: "Hey Siri, add to Orbit…".

---

## 3. Smart scheduler

Hybrid design: a **deterministic solver** does the placing, and the **LLM** handles understanding and judgement.

1. Gather fixed events (Google Calendar, timetable, ELE deadlines) → free slots.
2. Apply your rules: sleep window, meals, commute buffers, max deep-work hours/day, no work after X.
3. Score each task: `deadline urgency × assessment weight × priority`, and split long tasks into blocks.
4. Greedy plus local-search placement; match high-energy slots to hard tasks.
5. The LLM reviews the proposed day, explains it in plain English, and handles fuzzy input
   ("I'm knackered today, lighten it").
6. Re-plan triggers: new event, missed block, new deadline, or you tapping "reshuffle".
7. Everything is written to the **Orbit calendar**. Your own events are never moved without confirmation.

---

## 4. Data model (SwiftData)
`Task`, `ScheduledBlock`, `CalendarEventRef`, `EmailDigest` (summary, category, actions, not full
bodies), `Module`, `Assessment`, `ReadingItem`, `NoteChunk` (Mac-local only), `Plan` (from messages),
`BriefEntry`, `UserPrefs`.
Raw email bodies and note text stay **on the Mac only**. Only summaries sync to iCloud.

## 5. Privacy and safety
- No backend server; data stays on your devices and in your private iCloud.
- Cloud models (via OpenCode) get only what each task needs. A "local-only mode" toggle forces Ollama.
- The AI can draft but never sends email, deletes anything, or edits your own events without confirmation.

## 6. Design direction
Calm, "aesthetic" and native: soft neutral backgrounds, one accent colour per module,
SF Pro Rounded headings, generous spacing, glass materials on Mac, a timeline-style Today view,
subtle haptics and spring animations. Light and dark mode from day one.

## 7. What you'll need to do (one-offs)
- Create a Google Cloud project → enable Gmail and Calendar APIs → OAuth client (I'll give exact steps).
  It stays in "testing" mode with you as the only user, so no Google review is needed.
- Have OpenCode installed (already done). Install Ollama and pull a small model (`ollama pull qwen3:8b`).
- Check whether the ELE mobile app / web services are enabled (try logging into the Moodle app with ELE).
- Sign in with your Exeter Microsoft account to test OneNote access.
- In Xcode: set your team ID, enable iCloud (CloudKit) and Push capabilities → archive → TestFlight.

## 8. Build limits from this environment
Code is written here, but **Xcode builds, signing and TestFlight uploads must run on your Mac**.
I'll keep the project buildable with `xcodebuild`, add unit tests for the scheduler/router/parsers
(these run on Linux via Swift Package Manager), and document every step.

## 9. Proposed order and rough effort
| Phase | Scope |
|---|---|
| 1 | Project, sync, Calendar, to-dos, scheduler, LLM router, chat |
| 2 | Gmail triage and notifications |
| 3 | ELE + study coach |
| 4 | OneNote |
| 5 | Messages import |
| 6 | Widgets, briefs, polish |

Each phase ships as its own PR that you can build and install from TestFlight.
