# Setting up Orbit

Most people only need steps 1 to 5. None of it needs a developer account, and you never have to
register an app with Google or Microsoft.

---

## 1. Install Orbit

1. Download **Orbit-mac.dmg** from the repository's **Releases** page ("Orbit for Mac (latest)").
2. Open it and drag **Orbit** into **Applications**.
3. The first time: right-click Orbit in Applications → **Open** → **Open**. (macOS warns because Orbit
   isn't from the App Store. After this, open it normally.)
4. Orbit opens with a short welcome tour. You can skip any step and come back in **Settings**.

## 2. Google (Gmail + Google Calendar)

1. Click **Connect** next to Google.
2. A Google sign-in window opens. Sign in and click **Allow**.
3. Orbit shows **Connected as you@gmail.com**, syncs straight away, and tells you how many emails and
   events it found.

If it says something went wrong, the message appears right under the button. See Troubleshooting.

## 3. Your Exeter email and timetable

Orbit doesn't sign in to Exeter itself. Your Mac does, and Orbit reads from there.

1. **Add your Exeter account to your Mac.** Click **Open Internet Accounts** (or open **System
   Settings → Internet Accounts**), click **Add Account… → Microsoft Exchange**, and sign in with
   your `@exeter.ac.uk` email and password. When it asks which apps to use, tick **Mail** and
   **Calendars**.
2. **Open the Mail app once** so it downloads your Exeter email.
3. **Let Orbit read your mail.** Click **Grant Full Disk Access**. In the list, switch **Orbit** on
   (if it isn't there, click **+** and pick Orbit from Applications). Come back to Orbit.
4. **Let Orbit see your calendars.** Click **Allow calendar access** and then **OK**.
5. Click **Check again**. You should see ✓ *Exeter mail found* and ✓ *Exeter calendar found*.

This also brings in any other calendars on your Mac (iCloud and so on), so Orbit works for calendars
even without Google.

**OneNote:** in OneNote, choose **File → Export**, pick **PDF**, and save into one folder (for example
`Documents/Orbit Notes`). Putting the module code in the folder or file name helps. Then in Orbit click
**Pick your OneNote export folder…**. Export again whenever you add notes; Orbit notices new files.

> **Advanced (optional):** builds that include a Microsoft client ID also show a Microsoft sign-in
> under **Settings → University of Exeter → Advanced**, for syncing OneNote directly. You don't need it.

## 4. ELE (Exeter's Moodle)

Nothing to set up in advance. In Orbit, click **Settings → Sign in to ELE**. A sign-in
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

## 5. The AI on your Mac (CleanAPIs + OpenCode + Ollama)

Orbit's chat & reasoning brain prefers **CleanAPIs** (cloud, `claude-opus-5.5`) when a key is
configured. **OpenCode** (`opencode serve` on localhost) is the next hop, and **Ollama** stays the
offline / bulk / vision / private-data path. Private data (full email, full notes, handwriting)
never leaves this Mac — only summaries/digests go to cloud. Toggle CleanAPIs off in Settings for
fully offline; nothing breaks.

| Purpose | Order |
|---|---|
| Chat / reasoning | CleanAPIs → OpenCode → Ollama |
| Bulk / vision / privateData | Ollama (local) first; cloud excluded for privateData |

### CleanAPIs (cloud brain)

1. Get a key at <https://cleanapis.com> (`cc_…`).
2. Any one of:
   - **Orbit → Settings → AI → CleanAPIs** — paste the key (Show/Hide + Paste), pick model, press **Test**
   - `~/.local/share/opencode/auth.json` → `{ "cleanapis": {"type":"api","key":"cc_…"} }` (same file `opencode auth` uses)
   - env `CLEANAPIS_API_KEY` / `CLEANAPI_API_KEY`
   - `Config/Secrets.xcconfig` → `CLEANAPIS_API_KEY` (see `Config/Secrets.example.xcconfig`)
3. Settings should say **Reachable ✓** after Test. Chat & reasoning then use cloud first.

See `docs/CLEANAPIS_INTEGRATION.md` for the provider design, privacy rails, and fallback table.

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

## 6. Building Orbit yourself (developers only)

The Google client ID is already in `Config/Orbit.xcconfig` (an iOS-type OAuth client; its redirect is
`com.googleusercontent.apps.<id>:/oauth2redirect`). To use your own, put `GOOGLE_CLIENT_ID` and
`GOOGLE_REVERSED_CLIENT_ID` in `Config/Secrets.xcconfig`. `MICROSOFT_CLIENT_ID` is optional; leave it
empty and the Microsoft sign-in stays hidden.

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

## 7. Optional extras

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

### Focus mode and Do Not Disturb

macOS only lets apps change Focus through Shortcuts, so make two tiny shortcuts once:

1. Open **Shortcuts** → **File → New Shortcut**, name it exactly **Orbit Focus On**, add the action
   **Set Focus** → **Do Not Disturb** → **Turn On** (until turned off).
2. Make a second one named exactly **Orbit Focus Off** with **Set Focus** → **Do Not Disturb** → **Turn Off**.

Orbit runs them with `shortcuts run "Orbit Focus On"` when a focus session starts and "Off" when it pauses or
ends (Settings → Extras → Focus shows whether it found them). Without them focus sessions still work.

### Quick capture

Press **⌥Space** anywhere (change it in Settings → Extras). Type a to-do and press Return; start with `e:` for a
calendar event (`e: dinner with Sam Fri 7pm @ Côte`) or `n:` for a note. Esc closes. No Accessibility
permission is needed.

### Money (stays on your Mac)

- **Monzo:** go to [developers.monzo.com](https://developers.monzo.com), sign in → **Clients → New OAuth Client**.
  Name: Orbit. Redirect URL: `http://127.0.0.1:53682/monzo/callback`. Confidentiality: **Confidential**.
  Paste the Client ID and secret into Orbit → Money → settings, **Save client**, then **Connect Monzo**, sign in
  in the browser and approve Orbit in the Monzo app. Orbit imports your full history straight away (Monzo only
  allows that for 5 minutes after approval), then syncs every 30 minutes. Monzo asks you to reconnect every 90 days.
  Monzo Flex may not be available through the developer API; add what you owe as a manual account.
- **Or import a CSV:** Monzo app → your account → Statements / Export transactions → CSV, then **Import CSV…**.
  Re-importing skips transactions already there. Other banks' CSVs work with a column-mapping step.
- **Trading 212:** in the Trading 212 app, Settings → API → Generate API key (read-only is enough), then paste the
  key (and secret, if shown) into Money settings.

Keys and tokens are stored in your Keychain (or an owner-only file if the Keychain refuses) and never leave the
Mac. Money data is never synced to iCloud and is only ever shown to the AI running on your Mac, when you ask.

### Updates

Orbit checks the "Orbit for Mac (latest)" release on GitHub when it starts and every 6 hours. When a newer build
is out, Settings → Extras → Updates (or the menu bar) offers **Install update and restart**: Orbit downloads
`Orbit-mac.zip`, replaces the app, clears the quarantine flag and reopens. Local Xcode builds don't update themselves.

## Troubleshooting

**First: get the log.** **Settings → Diagnostics → Copy log** copies Orbit's log (what it tried and
any errors; never passwords). Paste it to us. **Reveal log in Finder** shows the file
(`~/Library/Logs/Orbit/orbit.log`).

**Google: I click Connect and nothing seems to happen**
Look for a sign-in window behind other windows. Orbit now shows "Waiting for Google…" while that
window is open and any error under the button. If there's still nothing, copy the log and send it.

**Google: "Access blocked" or "This app isn't verified"**
Click **Advanced → Go to Orbit**. If it says access is blocked, the Google account isn't on Orbit's
test-user list yet; tell us which address you use.

**macOS keeps asking "Orbit wants to use your confidential information"**
Click **Always Allow**. That's Orbit saving your Google sign-in in your Mac's keychain. (If the
keychain refuses, Orbit keeps the sign-in in a private file instead, so you stay signed in.)

**No ✓ next to "Exeter mail found"**
- Full Disk Access must be switched on for Orbit (step 3.3). After switching it on, quit and reopen
  Orbit if it still says no.
- Open the Mail app and check your Exeter inbox is there and has downloaded.

**No ✓ next to "Exeter calendar found"**
In **System Settings → Internet Accounts → Exchange**, make sure **Calendars** is ticked, then open the
Calendar app once. If you said no to calendar access, turn Orbit on in **System Settings → Privacy &
Security → Calendars**.

**ELE sign-in loops or fails**
Use the ELE calendar export link (step 4).

**"No AI available" / the chat can't answer**
- **Settings → AI** shows CleanAPIs, OpenCode and Ollama status. Press **Test** on CleanAPIs or **Restart** next to OpenCode.
- `opencode --version` must work in Terminal. Orbit looks in `~/.opencode/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin` and `~/.local/bin`.
- **Settings → Diagnostics → OpenCode log** shows what went wrong.
- Open the Ollama app so its menu bar icon is visible.

**Widgets are empty**
Open Orbit once; widgets show the snapshot the app writes after each sync.

**Where does Orbit keep things?**
- Mac only (`~/Library/Application Support/Orbit`): full email text, note transcriptions, the search
  index, sync cursors and logs.
- Keychain: your Google and ELE sign-ins, Monzo and Trading 212 keys.
- Mac only (`~/Library/Application Support/Orbit/Features` and `/Money`): flashcard metadata, focus log,
  weekly reports and all money data.
- Log: `~/Library/Logs/Orbit/orbit.log`.
