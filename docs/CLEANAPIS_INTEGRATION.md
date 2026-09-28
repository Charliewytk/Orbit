# CleanAPIs brain — design & patch notes (2026-09-28)

## What was there before
- `LLMRouter` tried `OpenCode (localhost:4096, opencode serve)` first for `chat`/`reasoning`, then `Ollama` (`qwen3:8b` fallback). For `bulk`/`vision`/`privateData` it preferred local.
- Prior handoff work (see `~/Downloads/orbit1.json` ~886 msgs, `orbit2.json`) set `opencode`'s default model to `cleanapis/*` via `~/.config/opencode/opencode.json` and leaned on `opencode serve` as a proxy. That made chat depend on `opencode serve` being up, added a hop, and hid auth errors behind `UnknownError err_*` from the local server.
- Cheap local models felt "dumb" for reasoning; there was no dedicated cloud-brain provider.

## What this patch does
Adds a first-class `CleanAPIsProvider` (OpenAI-compatible `POST /chat/completions`) as Orbit's primary online brain, keeps the existing offline path fully intact.

### New file
- `Sources/OrbitCore/LLM/CleanAPIsProvider.swift`
  - `HTTPClient` + `HTTPTransport` based (stub-friendly, Linux-ready).
  - `baseURL` default `https://cleanapis.com/v1`, model default `claude-opus-5.5` (accepts `cleanapis/claude-opus-5.5` and strips prefix).
  - Auth: `Authorization: Bearer <key>` resolved as `init(apiKey:)` → `CLEANAPIS_API_KEY` / `CLEANAPI_API_KEY` env → `UserDefaults cleanapis_api_key` → `~/.local/share/opencode/auth.json` (`cleanapis`/`cleanapi` key, same file `opencode auth` uses) → legacy `~/.config/opencode/auth.json`. `keyPreview` is redacted.
  - Vision: when `LLMMessage.images` is non-empty, sends OpenAI multipart `content: [{type:text},{type:image_url,data:...}]`; respects `supportsVision`.
  - JSON mode: `response_format: {type:"json_object"}` when `request.json == true` (compatible with `LLMRouter.completeJSON`).
  - Retry: up to 3 attempts on 429 / 5xx / `NSURLErrorDomain` transport errors; exponential backoff + `Retry-After` body field when present; logs on retry.
  - Cost/token logging: `usage.prompt_tokens / completion_tokens` from the response → `os.log` (`com.charliewytk.orbit/CleanAPIs`) + `CleanAPIsProvider.totalPromptTokens/totalCompletionTokens` counters (process lifetime, diagnostics).
  - `isAvailable()` does `GET /models` with the key (5s timeout) — doesn't gate on a specific model existing, just on auth+reachability.

### Modified files
- `Sources/OrbitCore/LLM/LLM.swift` — `LLMProviderKind` now `cleanapis | opencode | ollama | mock`.
- `Sources/OrbitCore/LLM/LLMRouter.swift`
  - `order(for:)` now cloud-first for `chat`/`reasoning` (CleanAPIs sorted ahead of OpenCode, then local), local-first for `bulk`/`vision`/`privateData`. `localOnly` / `.privateData` still filters to `isLocal` only, so cloud never sees private data even when CleanAPIs is configured.
  - Cool-down semantics unchanged (failed providers sink to the back).
- `Sources/OrbitCore/LLM/CleanAPIsProvider.swift` also defines `CleanAPIKeys` (single source of truth for UserDefaults keys, reused by `App`).
- `App/macOS/Brain/LocalStore.swift` — `MacPrefs` gains `cleanapisKey/Model/BaseURL/Enabled` (mirrors `CleanAPIKeys`) + `bool(_:default:)` helper.
- `App/macOS/Brain/OrbitBrain.swift`
  - `rebuildRouter()` builds `[CleanAPIs?, OpenCode, Ollama]` (CleanAPIs first when enabled; enabled defaults to "on if a key exists, off otherwise" so fresh installs stay offline).
  - `providerName` handles `.cleanapis`.
- `App/macOS/Views/MacSettingsSections.swift`
  - New `CleanAPIsStatusPanel` at the top of the AI section (enabled toggle, model picker, key field with Show/Hide + Paste, redacted `keyPreview`, `Test` → `isAvailable()`, privacy note). Shown before the existing `AIStatusPanel`.
- `Config/Secrets.example.xcconfig` — documents `CLEANAPIS_API_KEY` / `CLEANAPIS_MODEL`.
- `docs/SETUP.md` — new §2 intro table + **CleanAPIs** subsection (key sources, Settings flow, fallback table, privacy note). OpenCode/Ollama subsections retitled to `local, free` / `offline backup + vision + private`.

### Privacy
- `LLMRouter.order` excludes cloud providers for `.privateData` and when `localOnlyMode` is on — enforced at the router, not just by convention.
- Docs note that full email bodies / full note text / search index / handwriting stay in `~/Library/Application Support/Orbit` (Mac only) and are never sent to cloud; cloud receives summaries/digests.
- No secrets are committed: `Config/Secrets.xcconfig` + `~/.local/share/opencode/auth.json` are git-ignored.

### Fallback & failure modes
- `LLMRouter.complete` tries `order(for:)` in sequence, cool-down on failure, `emptyResponse` treated as failure → next provider.
- `CleanAPIsProvider.complete` retries 429/5xx + transport errors; final error surfaces as `HTTPError` / `LLMError`, so the router can fall through to OpenCode → Ollama.
- `isAvailable()` short-circuits when no key is present (so `checkAI()` doesn't claim cloud is up).

### Costs
- Per-call `usage` logged to `os.log`; running totals in `CleanAPIsProvider.total*` (reset on launch). No persistence yet — add a persisted daily counter if you want budget caps later.
- No streaming yet (non-stream `chat/completions` only) — matches the existing `LLMRouter.complete` contract.

## How to enable (also in docs/SETUP.md §2)
1. Get a key at https://cleanapis.com (`cc_…`).
2. Any one of: Settings → AI → CleanAPIs (paste), or `~/.local/share/opencode/auth.json` `{ "cleanapis": {"type":"api","key":"cc_…"} }`, or env `CLEANAPIS_API_KEY`, or `Config/Secrets.xcconfig`.
3. Settings → AI → CleanAPIs should say **Reachable ✓** after Test. Chat & reasoning use cloud first; toggle off to go fully offline.

## What wasn't done / future
- No streaming (`stream:true` + SSE) — add when `LLMRouter` gains a streaming API.
- No persisted spend ledger / budget cap — add `BrainState.cleanapisSpend` if needed.
- No per-request privacy classifier beyond purpose-based routing — add a redactor if you want stricter prompt scrubbing.

## Verification
- `swift build` — ok (warning fixed: removed unused `usage` local).
- `swift test` — 296 tests, 0 failures (Linux + macOS).
