# Setting up Orbit

This guide takes you from "the code is on GitHub" to "Orbit is running on my Mac and my iPhone".
Do the steps in order. Each one says what to click and what to copy. Budget about an hour and a half,
most of it waiting for downloads.

**You'll need**

- A Mac with macOS 15 (Sequoia) or later, ideally 16 GB of memory (for the offline AI models).
- Xcode 16 or later (free, from the Mac App Store).
- A paid Apple Developer Program membership (needed for iCloud sync, TestFlight and widgets).
- Your Google account (for Gmail and Google Calendar) and your Exeter account.
- The Orbit code on your Mac: `git clone` the repository, or pull the latest branch.

Throughout this guide the bundle ID is **`com.charliewytk.orbit`**. If you ever change
`ORBIT_BUNDLE_PREFIX` in `Config/Orbit.xcconfig`, use your new value everywhere it appears below.

---

## 1. Google Cloud (Gmail + Google Calendar)

Orbit needs its own "OAuth client" so Google lets it read your mail and calendar. It's free and
stays private to you.

1. Go to <https://console.cloud.google.com> and sign in with the Google account you use for Gmail.
2. At the top left, click the project picker, then **New project**. Name it `Orbit` and click **Create**.
   When it's ready, make sure `Orbit` is selected in the project picker.
3. Turn on the two APIs:
   1. Open the menu (☰) → **APIs & Services** → **Library**.
   2. Search for **Gmail API**, open it, click **Enable**.
   3. Go back to the Library, search for **Google Calendar API**, open it, click **Enable**.
4. Set up the consent screen (Google sometimes calls this section **Google Auth Platform**):
   1. Menu → **APIs & Services** → **OAuth consent screen** → **Get started**.
   2. App name: `Orbit`. User support email: your Gmail address. Click **Next**.
   3. Audience: choose **External**. Click **Next**.
   4. Contact information: your Gmail address. Click **Next**, tick the agreement, click **Create**.
   5. Open **Audience** (or **Test users**) → **Add users** → type your Gmail address → **Save**.
      Leave the publishing status on **Testing**. You are the only user, so no Google review is needed.
5. Create the client ID:
   1. Menu → **APIs & Services** → **Credentials** → **Create credentials** → **OAuth client ID**.
   2. Application type: **iOS**. (Yes, iOS, even for the Mac. Both Orbit apps share this one client.)
   3. Name: `Orbit`. Bundle ID: `com.charliewytk.orbit`. Leave the App Store ID and Team ID empty.
   4. Click **Create**. A box shows your **Client ID** (ends in `.apps.googleusercontent.com`) and,
      on the client's page, the **iOS URL scheme** (starts with `com.googleusercontent.apps.`).
6. Put them into Orbit's config:
   1. In Finder, open the Orbit folder, then `Config`.
   2. Duplicate `Secrets.example.xcconfig` and rename the copy to exactly `Secrets.xcconfig`.
      (This file is ignored by git, so your IDs never get uploaded.)
   3. Open `Secrets.xcconfig` in TextEdit or Xcode and fill in:
      ```
      GOOGLE_CLIENT_ID = 1234567890-abcdefg.apps.googleusercontent.com
      GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.1234567890-abcdefg
      ```
      Don't add quotes, and don't paste any `https://` links into this file (`//` starts a comment there).

> **Heads-up:** while the Google project is in "Testing", Google makes you sign in again about once a
> week. If that gets annoying, see "Google asks me to sign in every week" in Troubleshooting.

---

## 2. The AI on your Mac (OpenCode + Ollama)

Orbit never pays for AI. It uses **OpenCode** (which you already have) as its main brain and
**Ollama** as an offline backup that also reads your handwriting.

### OpenCode

1. Open **Terminal** and run:
   ```
   opencode --version
   ```
   If you see a version number, you're set. If you see "command not found", install it with
   ```
   curl -fsSL https://opencode.ai/install | bash
   ```
   (or `brew install opencode` if you use Homebrew), then close and reopen Terminal.
2. Make sure OpenCode has a model it can use: run `opencode` in Terminal, type `/models`, pick one
   (the free ones are fine), then quit with `Ctrl+C`. A quick test:
   ```
   opencode run "Say hello in five words"
   ```
3. That's all. Orbit starts `opencode serve` in the background by itself, restarts it if it stops,
   and lists OpenCode's models (free ones first) in **Settings → AI**.

### Ollama

1. Download Ollama from <https://ollama.com/download> and drag it to Applications. Open it once;
   a llama icon appears in the menu bar. Keep it running (it starts at login by default).
2. In Terminal, download the three models Orbit uses (about 11 GB in total):
   ```
   ollama pull qwen3:8b
   ollama pull qwen2.5vl:7b
   ollama pull nomic-embed-text
   ```
   - `qwen3:8b` is the backup chat model and sorts email privately.
   - `qwen2.5vl:7b` reads handwriting and screenshots.
   - `nomic-embed-text` makes note search understand meaning, not just keywords.

   You can also do this later from **Orbit → Settings → AI → Download**.

---

## 3. Microsoft / your Exeter account (Exeter email, calendar, OneNote)

Orbit signs in to your Exeter Microsoft 365 account the same way any mail app does. First it needs
an "app registration" (free).

1. Go to <https://entra.microsoft.com> and sign in. Use a **personal** Microsoft account
   (outlook.com / hotmail.com; make one free if you need to). If it says you don't have access to a
   directory, try signing in with your Exeter account instead; if neither works, create a free Azure
   account at <https://azure.microsoft.com/free> (no charge), which gives you a directory.
2. Go to **Applications** → **App registrations** → **New registration**.
   - Name: `Orbit`.
   - Supported account types: **Accounts in any organizational directory (Any Microsoft Entra ID
     tenant – Multitenant) and personal Microsoft accounts**.
   - Redirect URI: choose the platform **Public client/native (mobile & desktop)** and enter
     ```
     msauth.com.charliewytk.orbit://auth
     ```
   - Click **Register**.
3. On the app's Overview page, copy the **Application (client) ID** and add it to
   `Config/Secrets.xcconfig`:
   ```
   MICROSOFT_CLIENT_ID = 11111111-2222-3333-4444-555555555555
   ```
4. Click **API permissions** → **Add a permission** → **Microsoft Graph** → **Delegated permissions**,
   tick these and click **Add permissions**:
   `offline_access`, `User.Read`, `Mail.Read`, `Mail.ReadWrite`, `Notes.Read`, `Calendars.Read`.
   Don't click "Grant admin consent"; you can't for Exeter and don't need to try.
5. Later, in Orbit (step 5), click **Settings → Connect** next to *Exeter (Microsoft 365)* and sign in
   with your `@exeter.ac.uk` account.

### If Exeter says "Need admin approval"

Some universities block third-party apps. That's fine; Orbit has fallbacks that need no approval:

- **Exeter email → Apple Mail.** Open the Mail app on your Mac → **Mail** → **Add Account…** →
  **Microsoft Exchange** → sign in with your Exeter account. Then in Orbit: **Settings → Read Exeter
  email from → Apple Mail on this Mac**, and give Orbit Full Disk Access (step 5.9).
- **OneNote → exported PDFs.** In OneNote, export or "Save as PDF" each section (or page) into one
  folder, for example `Documents/Orbit Notes/BEM2031/Week 5.pdf`. Putting the module code and week
  in folder or file names helps Orbit sort them. Then in Orbit: **Settings → Read notes from →
  Exported PDF / Markdown folder → Choose folder…**. Re-export whenever you add notes; Orbit picks up
  new files automatically.
- **Exeter calendar / timetable → calendar link.** If your timetable offers an iCal/"subscribe" link,
  paste it into **Settings → Timetable calendar link**.

---

## 4. ELE (Exeter's Moodle)

Nothing to set up in advance. In Orbit (step 5), click **Settings → Sign in to ELE**. A sign-in
window opens exactly like the Moodle mobile app's (Exeter's Microsoft login). Orbit then fetches your
modules, deadlines, grades, announcements and reading lists every hour.

**If that doesn't work** (the window loops, or Orbit says the Moodle app is switched off), use the
calendar export instead:

1. In a browser, open ELE → **Calendar** (<https://ele.exeter.ac.uk/calendar/view.php>).
2. Click **Import or export calendars** → **Export calendar**.
3. Choose **All events** and **Recent and next 60 days**, then click **Get calendar URL**.
4. Copy the long link it shows and paste it into Orbit: **Settings → ELE → "Or paste your ELE
   calendar export link"**, then press Return.

This gives Orbit all your deadlines (but not grades or reading lists).

**Module credits:** ELE doesn't publish credits. Check them in **Settings → Module credits** (most
modules are 15; year-long ones are often 30). Orbit uses them for "what do I need for a First?".

---

## 5. Xcode: build and run

1. Install **Xcode 16 or later** from the Mac App Store and open it once to finish installing.
   Go to **Xcode → Settings → Accounts** and add the Apple ID that has your Developer Program membership.
2. Find your **Team ID**: <https://developer.apple.com/account> → **Membership details** → *Team ID*
   (10 characters, like `ABCDE12345`).
3. Open `Config/Orbit.xcconfig` and set it:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```
4. Double-click **`Orbit.xcodeproj`** to open it in Xcode. Xcode fetches the local `OrbitCore`
   package automatically (a few seconds).
   - If you ever change `project.yml`, regenerate the project with
     `brew install xcodegen && xcodegen generate` in the Orbit folder.
5. Check the capabilities (Xcode usually sets these up by itself because signing is automatic):
   1. Click the blue **Orbit** project at the top of the file list, then the **Orbit-macOS** target →
      **Signing & Capabilities**.
   2. You should see **iCloud** (with *CloudKit* ticked and the container
      `iCloud.com.charliewytk.orbit`), **Push Notifications**, **App Groups**
      (`group.com.charliewytk.orbit`), **Keychain Sharing** and **Hardened Runtime**.
   3. If the iCloud container is red or missing, click **+** under Containers, type
      `iCloud.com.charliewytk.orbit`, and make sure it's ticked. If App Groups is red, click the
      refresh button next to it.
   4. Do the same for **Orbit-iOS** (it also has **Background Modes**: Background fetch, Remote
      notifications, Background processing) and check that **OrbitWidgets-iOS**,
      **OrbitWidgets-macOS** and **OrbitShare** have the App Group ticked.
6. Choose the **Orbit-macOS** scheme and **My Mac** at the top of the window, then press **⌘R**.
7. Orbit opens with a short welcome tour: connect Google, Exeter and ELE, pick where your notes
   come from, check the AI, and set your preferences. You can skip anything and come back later
   in **Settings**. Allow notifications when asked.
8. Orbit adds itself to **Login Items** so it starts with your Mac, and keeps running in the menu bar
   (the ◎ icon) when you close its window. Your Mac is Orbit's brain: syncing, planning and AI all
   happen there, so the more it's awake, the fresher everything is.
9. **Full Disk Access** (only if you use Apple Mail for Exeter email, or want iMessage plans):
   1. Put a copy of Orbit in Applications: in Xcode, **Product → Archive**, then in the Organizer
      **Distribute App → Custom → Copy App**, save it, and drag `Orbit.app` into **Applications**.
      Open that copy from now on.
   2. **System Settings → Privacy & Security → Full Disk Access → +**, choose
      `Applications/Orbit.app`, and switch it on. (Orbit's **Settings → Mac → Open Full Disk Access**
      button jumps straight there.)
   3. In Orbit, turn on **Watch iMessage for plans** if you want it.
10. **Before your first TestFlight build**, publish the iCloud database layout (TestFlight uses the
    "production" iCloud database, which starts empty):
    1. Run the Mac app once (step 6) and add a to-do, so every record type exists.
    2. Go to <https://icloud.developer.apple.com> → **CloudKit Database** → choose
       `iCloud.com.charliewytk.orbit`.
    3. Click **Deploy Schema Changes…** → **Deploy**.
    Do this again whenever a new Orbit version adds new kinds of data.

### Put Orbit on your iPhone with TestFlight

1. Go to <https://appstoreconnect.apple.com> → **Apps** → **+** → **New App**.
   - Platform **iOS**. Name: something unique like `Orbit Study Planner` (the App Store needs a unique
     name; your home screen still says "Orbit").
   - Language English (UK). Bundle ID: pick `com.charliewytk.orbit`. SKU: `orbit`. Click **Create**.
2. In Xcode choose the **Orbit-iOS** scheme and **Any iOS Device (arm64)** as the destination.
3. **Product → Archive**. When the Organizer window opens, select the new archive →
   **Distribute App** → **TestFlight Internal Only** (or **App Store Connect**) → **Distribute**.
4. Wait for the email saying the build has finished processing (10–30 minutes).
5. In App Store Connect → your app → **TestFlight** → **Internal Testing** → **+** → add yourself.
6. On your iPhone, install **TestFlight** from the App Store, open the invite, and install Orbit.
7. Open Orbit on the iPhone and allow notifications. Your data arrives through iCloud within a
   minute or two (same Apple ID on both devices, iCloud turned on).

Quicker for testing: plug your iPhone into the Mac, pick it as the destination and press **⌘R**
(the first time, turn on **Settings → Privacy & Security → Developer Mode** on the iPhone).

---

## 6. Optional extras

### Instant chat from your iPhone (Tailscale)

Normally chat typed on the iPhone waits for your Mac to pick it up through iCloud (a few seconds to
a minute). For instant replies:

1. Install **Tailscale** (free) on the Mac and the iPhone and sign in to the same account.
2. In Orbit on the Mac: **Settings → AI → Share AI with iPhone**. Note the password it shows.
3. So the iPhone can reach Ollama too, run this in Terminal on the Mac, then quit and reopen Ollama:
   ```
   launchctl setenv OLLAMA_HOST 0.0.0.0
   ```
4. In Orbit on the iPhone: **Settings → iPhone instant chat** → enter the Mac's Tailscale address
   (the `100.x.y.z` number in the Tailscale app) and the password.

### Share to Orbit

On the iPhone, share a message, link or screenshot to **Orbit** from any app's share sheet. Orbit
suggests plans it finds ("Dinner with Sam, Sat 19:00") or adds it as a to-do. Screenshots are read
when you next open Orbit.

### Siri and Shortcuts

Say "Add to Orbit" or "What's next in Orbit". Both also appear in the Shortcuts app.

### Widgets

Long-press the home screen (or the Mac desktop) → **Edit** → **Add Widget** → **Orbit** → *Next up*
or *Due this week*.

---

## Troubleshooting

**Clicking Connect for Google/Microsoft says "isn't set up yet"**
`Config/Secrets.xcconfig` is missing, misnamed, or has a typo. Check the file name exactly, then in
Xcode **Product → Clean Build Folder** (⇧⌘K) and run again.

**Google: "Access blocked: Orbit has not completed the Google verification process"**
Add your Gmail address as a test user (step 1.4.5).

**Google: "Error 400: invalid_request" or a redirect/URI error**
The client must be of type **iOS** with bundle ID exactly `com.charliewytk.orbit`, and
`GOOGLE_REVERSED_CLIENT_ID` must match the client's iOS URL scheme.

**Google asks me to sign in every week**
That's Google's rule for apps in "Testing". To stop it: Google Cloud → **OAuth consent screen /
Audience** → **Publish app**. You'll then see a "Google hasn't verified this app" warning when signing
in; click **Advanced → Go to Orbit (unsafe)**. It's your own app, so that's expected.

**Microsoft: "AADSTS50011: redirect URI mismatch"**
In the app registration → **Authentication**, the redirect URI must be exactly
`msauth.com.charliewytk.orbit://auth` under *Mobile and desktop applications*.

**Microsoft: "Need admin approval" / "Approval required"**
Exeter blocks third-party apps for your account. Use the fallbacks in step 3.

**ELE sign-in loops or fails**
Use the ELE calendar export link (step 4). Reconnect ELE from Settings if it says your sign-in expired.

**"No AI available" / the chat can't answer**
- **Settings → AI** shows OpenCode and Ollama status. Press **Restart** next to OpenCode.
- `opencode --version` must work in Terminal. Orbit looks in `~/.opencode/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin` and `~/.local/bin`.
- **Settings → Diagnostics → OpenCode log** shows what went wrong. If port 4096 is busy, quit any
  other `opencode serve` you started yourself (Orbit will happily use it if it's on port 4096).
- Open the Ollama app so its menu bar icon is visible.

**Handwriting isn't being read, or summaries are missing**
Both need Ollama with `qwen2.5vl:7b` and `qwen3:8b` downloaded. Local-only mode also needs Ollama.

**The iPhone shows nothing**
- Same Apple ID on both devices, and iCloud turned on (Settings → your name → iCloud).
- **Settings → Diagnostics → Storage** should say "iCloud sync". If it says "This device only", the
  iCloud capability or container isn't set up (step 5.5).
- TestFlight builds use the production iCloud database: deploy the schema (step 5.10).
- The Mac must have run at least once and be signed in to your accounts.

**Exeter mail via Apple Mail isn't showing up**
Check Full Disk Access (step 5.9), that the Exeter account is in the Mail app and has downloaded mail,
and that **Settings → Read Exeter email from** says **Apple Mail on this Mac**.

**Widgets are empty**
Open Orbit once; widgets show the snapshot the app writes after each sync.

**"Orbit would like to access data from other apps" on the Mac**
Click **Allow**. That's Orbit reading its own shared App Group folder (used by the widgets).

**Build errors about signing, team, App Groups or iCloud**
Make sure `DEVELOPMENT_TEAM` is set (step 5.3), your Apple ID is in Xcode's Accounts, and click
**Try Again** in *Signing & Capabilities*. If a capability is red, remove it and add it back with **+
Capability**.

**Where does Orbit keep things?**
- Synced (iCloud, private to you): to-dos, plans, calendar summaries, email *summaries*, note
  *summaries and key points*, flashcards, chat.
- Mac only (`~/Library/Application Support/Orbit`): full email text, full handwriting transcriptions,
  the note search index, your handwriting profile, sync cursors and the OpenCode log.
- Keychain: your Google, Microsoft and ELE sign-ins.
