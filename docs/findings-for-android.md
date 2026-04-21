# Omni Recorder: Architecture & Findings for Android Port

Context for building the same app on Android. Written after shipping a working iOS version over 2026-04-21. Copy the relevant sections into your Android repo's context.

---

## TL;DR — the architecture that works

```
[Mic] → AAC m4a 48 kHz mono 96 kbps file
         ↓
     Upload to Deepgram /v1/listen (nova-2-conversationalai, diarize=true, smart_format=true, paragraphs=true, utterances=true)
         ↓
     Deepgram returns transcript + per-word speaker labels
         ↓
     IF unique speakers >= 2: group consecutive same-speaker words into turns → render
     IF unique speakers <= 1: send word list + transcript to Groq llama-3.3-70b-versatile for LLM-based speaker inference → apply inferred turns → render
         ↓
     Persist transcript JSON next to audio file
     API keys stored in OS-native secure storage (Keychain on iOS → EncryptedSharedPreferences on Android)
```

That flow is the whole thing. Everything else is polish.

---

## What we tried — matrix

| Component | Option | Verdict | Notes |
|---|---|---|---|
| **Local STT (on-device)** | WhisperKit (OpenAI Whisper via CoreML) | ⚠️ Works but slow and lower quality than cloud. Retained for offline-only fallback. | `openai_whisper-small.en` model. Must pin package to stable version (we pinned `0.9.0` after newer releases had package-product resolution issues). |
| **Cloud STT** | **Deepgram** | ✅ **Primary choice.** `nova-2-conversationalai` is the right model for phone-captured conversational audio. `nova-3` and `nova-2-meeting` under-detected speakers on our test audio. | $200 free credit, ~$0.43/hr after. Fast (~30s for 30-min audio). |
| **Cloud STT** | Groq Whisper-large-v3 | ✅ For speed-critical transcript-only needs. ❌ Does not do diarization — speaker labels NOT included. | Very fast on free tier. Only use if you don't need speakers. |
| **Cloud STT** | AssemblyAI | ⏸ Not evaluated on this project. Listed in original plan as secondary fallback. Similar tier to Deepgram with diarization. | Free credits available. |
| **Diarization (acoustic)** | **Deepgram built-in** (`diarize=true`) | ✅ **Primary choice.** Included in same response as transcript. Saves a whole service. | Struggles on single-mic two-similar-voice audio — see LLM fallback below. |
| **Diarization (acoustic)** | Pyannote.audio 3.1 on Hugging Face Space | ❌ **Don't use.** Too slow on free CPU tier (minutes per request), imperfect boundaries, requires gated model terms acceptance for `pyannote/speaker-diarization-3.1` AND `pyannote/segmentation-3.0`, and needs a wrapper service on a Docker HF Space. Also required an explicit `huggingface_hub<0.26` pin because pyannote 3.3.x still calls `hf_hub_download(use_auth_token=...)` which newer hub versions removed. | Kept dormant as architectural reference. |
| **LLM speaker inference** | **Groq llama-3.3-70b-versatile** | ✅ **Primary fallback** when acoustic diarization fails. Returns structured JSON with `start_word`/`end_word` boundaries. Can also infer real speaker names from conversational context (e.g. "Thank you Nathan" → other speaker is Nathan). | Free tier generous for personal use. OpenAI-compatible API at `https://api.groq.com/openai/v1/chat/completions`. |
| **Audio format** | AAC m4a, 48 kHz mono, 96 kbps | ✅ Works. | See next section — this was the result of a critical bugfix. |
| **Audio format** | AAC m4a, 16 kHz mono, 32 kbps | ❌ **Too compressed.** Transcription quality was fine but diarization failed across all models. Voice fingerprints got stripped. Do NOT start with this config. | |

---

## Audio recording config — critical finding

**The single most important decision:** record at enough quality that diarizers have voice signature to work with.

- **Don't:** 16 kHz / 32 kbps / mono. Strips too much voice-fingerprint information. All diarizers we tested (Pyannote, Deepgram nova-3, nova-2-meeting, nova-2-conversationalai) returned 1 speaker even when 2 distinct people were speaking.
- **Do:** 48 kHz / 96 kbps / mono AAC. ~12 KB/s. A 90-minute meeting is ~65 MB — fine for mobile. This was the config that made diarization start working at all.
- **Single-mic ceiling:** even at 48k/96k, two similar voices (same gender, same pitch, same room, same distance from mic) is a fundamentally hard case for acoustic diarization. This is where the LLM fallback (below) earns its keep.

Android equivalent: `MediaRecorder` with:
```kotlin
setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
setAudioSamplingRate(48000)
setAudioChannels(1)
setAudioEncodingBitRate(96_000)
setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
```

Or `AudioRecord` for finer control. `MediaRecorder` is simpler and sufficient.

---

## Deepgram API — exact request that works

```
POST https://api.deepgram.com/v1/listen
Authorization: Token <DEEPGRAM_KEY>
Content-Type: audio/mp4   (for m4a — Deepgram also auto-detects, but setting it is cleaner)

Query params (all boolean strings "true"/"false"):
  model=nova-2-conversationalai
  diarize=true
  smart_format=true
  paragraphs=true
  punctuate=true
  utterances=true
  filler_words=false
  language=en

Body: raw audio bytes
```

### Critical parser detail: use WORDS, not PARAGRAPHS

Deepgram's `paragraphs` array groups by sentence/pause. Each paragraph has ONE `speaker` field — which is the dominant speaker in that paragraph. A paragraph spanning multiple speaker turns collapses to one label.

**Don't** build segments from `paragraphs` — you lose mid-paragraph speaker changes.

**Do** group consecutive same-speaker WORDS into segments. Each word in the response has its own `speaker` integer when `diarize=true`. Iterate the word array, start a new segment whenever the word's `speaker` changes, end segment on next change. This preserves all speaker boundaries.

Response shape we consume (simplified):
```json
{
  "results": {
    "channels": [{
      "alternatives": [{
        "transcript": "full text",
        "words": [
          {"word": "hello", "punctuated_word": "Hello,", "start": 0.1, "end": 0.4, "confidence": 0.99, "speaker": 0},
          {"word": "world", "punctuated_word": "world.", "start": 0.5, "end": 0.9, "confidence": 0.99, "speaker": 1}
        ],
        "paragraphs": { /* exists but we ignore speaker field here */ }
      }]
    }]
  }
}
```

Use `punctuated_word` when present (includes smart-format punctuation); fall back to `word` otherwise.

---

## LLM speaker inference (the "Groq fallback")

When `uniqueSpeakers(deepgram_words) <= 1`, assume acoustic diarization failed. Post-process with an LLM.

### Groq request

```
POST https://api.groq.com/openai/v1/chat/completions
Authorization: Bearer <GROQ_KEY>
Content-Type: application/json

{
  "model": "llama-3.3-70b-versatile",
  "temperature": 0,
  "response_format": {"type": "json_object"},
  "messages": [
    {"role": "system", "content": "<inference rules — see prompt below>"},
    {"role": "user", "content": "Indexed words:\n0:Hello 1:welcome 2:to 3:the 4:show ..."}
  ]
}
```

### The prompt (system message) that converged

After multiple iterations. Key techniques:

1. **Indexed word list as input.** Every word prefixed with its 0-based index. Ask LLM to return `start_word`/`end_word` integer ranges. This makes attribution deterministic — you can look up timestamps from the original word array at those indices.
2. **Explicit backward-propagation rule.** LLMs will identify speakers by name based on later context but forget to re-label their earlier turns. Explicit "if you figured out name X later, apply it to earlier turns too" rule prevents this.
3. **`reasoning` field before `turns` field in the required JSON schema.** Classic chain-of-thought technique: forces the LLM to commit to a framework before assigning turns, which tightens the turn assignments.
4. **Explicit rule against over-fragmentation.** Multi-sentence continuations like "Thanks Nathan, thank you for having me" are ONE turn. Without this rule, LLMs split on every sentence.
5. **Concrete example in the prompt.** Showed the exact reasoning pattern (host-introduces-guest, guest-thanks-host → backward-infer host's name) with expected output. Dramatically improved first-turn labeling on short audio.
6. **Rule #8: "if reasoning names the speakers, you MUST use those names in turns, never generic labels."** Without this, the LLM would reason correctly but still output "Speaker A" in the structured response.

The full system prompt is in `OmniRecorder/Pipeline/SpeakerInference.swift` — copy it verbatim, it's the result of the debugging pass.

### Response parsing

```json
{
  "reasoning": "Speaker 1 says 'It's Fernando' — introducing Fernando. Fernando then says 'Thank you Nathan' — so Speaker 1 is Nathan.",
  "turns": [
    {"speaker": "Nathan", "start_word": 0, "end_word": 24},
    {"speaker": "Fernando", "start_word": 25, "end_word": 32},
    ...
  ]
}
```

Map each turn to a segment using the original word array: `segment.start = words[turn.start_word].start`, `segment.end = words[turn.end_word].end`, `segment.text = words[start_word..end_word].map(punctuated_word).joined(" ")`, `segment.speaker = turn.speaker`.

Log the `reasoning` field to your debugger — immensely useful for diagnosing when the LLM misattributes.

### When to trigger

We only invoke the LLM when `Deepgram returned < 2 unique speakers`. This saves API calls on recordings where acoustic diarization already worked. If you want names even when acoustic diarization succeeded (auto-name Speaker A → "Nathan"), run the LLM pass always but with a different prompt that preserves existing turn boundaries and only infers names.

---

## Transcript data model

Final persisted JSON (per recording, saved alongside the audio file):

```json
{
  "audioFilename": "recording_2026-04-21_16-53-37.m4a",
  "modelId": "deepgram-nova-2-conversationalai+groq",
  "language": "en",
  "createdAt": "2026-04-21T20:22:00Z",
  "fullText": "...",
  "segments": [
    {"start": 3.1, "end": 14.2, "text": "...", "speaker": "SPEAKER_00"}
  ],
  "words": [
    {"start": 3.1, "end": 3.5, "text": "So", "probability": 0.99}
  ],
  "rawSpeakers": ["SPEAKER_00", "SPEAKER_01"],
  "speakerNames": {"SPEAKER_00": "Nathan", "SPEAKER_01": "Fernando"}
}
```

- `rawSpeakers`: ordered list of internal speaker IDs (first appearance order).
- `speakerNames`: raw-id → display-name map. User edits via inline-rename UI mutate this.
- `displayName(rawId)` logic: if `speakerNames[rawId]` exists and non-empty, use it. Else fall back to `"Speaker " + "ABC…"[index]` where index is position in `rawSpeakers`.

### Re-transcribe carry-over semantics (non-obvious, we hit a bug here)

When user re-transcribes an existing recording:
1. Run the new transcription → get fresh `Transcript` with fresh `speakerNames`.
2. For each `(rawId, name)` in the PREVIOUS transcript's `speakerNames`:
   - Carry it over ONLY IF:
     - `rawId` still exists in the new `rawSpeakers`, AND
     - the new transcript doesn't already have a name for that `rawId`, AND
     - the name isn't a generic label (matches regex `^Speaker[\s_-]*[\dA-Za-z]$`).
3. Save.

This ensures fresh inference wins, legacy bugged names get dropped, and real user renames are preserved when the new run couldn't improve on them.

---

## Secret storage

**iOS:** `Security.framework` (Keychain Services). Service name `com.nruberto.OmniRecorder`, per-provider keys `deepgram_api_key`, `groq_api_key`.

**Android equivalent:** `androidx.security:security-crypto` — `EncryptedSharedPreferences`. Same get/set/clear surface. Wrap it in a store class with the same API.

**Dev-ergonomic pattern:** we have a pre-build script (`tools/embed-dev-secrets.py`) that reads a gitignored `.env` at the repo root and generates a gitignored `DevSecrets.swift` with compiled constants. On first app launch, if Keychain is empty and `DevSecrets` has values, seed the Keychain. Settings UI overrides always win. Android analog: a Gradle task that reads `.env` and generates `DevSecrets.kt` (gitignored), plus a seeding block in your `Application.onCreate`. Don't ship this to end users — strip it from release builds.

---

## Architecture decisions we pivoted AWAY from (and why)

1. **Originally:** WhisperKit (local, on-device Whisper) for STT + Pyannote on HF Space (free CPU) for diarization + custom word-level merge algorithm.
   **Problem:** Pyannote CPU-free tier was too slow (~5 min per 30-min clip), and diarization quality was unreliable on phone-mic audio.
   **Pivot:** Deepgram as primary. Drop the HF Space from the runtime path (kept dormant as reference).

2. **Originally:** "Cloud is fallback for when local fails."
   **Problem:** Local was always slow. Cloud was always going to be the primary path for any realistic meeting length.
   **Pivot:** Cloud-first. Local as offline-mode fallback only.

3. **Originally:** Merge Whisper's segments with Pyannote's turn boundaries by "max-overlap wins per Whisper segment."
   **Problem:** Whisper segments are often 20-30 seconds long and contain multiple speakers. Attributing a whole segment to one speaker lost mid-segment turn changes.
   **Pivot:** Word-level merge. For each word, find the diarizer's speaker at the word's midpoint. Group consecutive same-speaker words into segments. This is the algorithm to port if you ever need offline fallback. (Same approach applies if you use Deepgram + external diarization instead of Deepgram's built-in.)

4. **Originally:** Expected paragraph-level speaker info from Deepgram.
   **Problem:** Paragraphs carry a single dominant-speaker label; multi-speaker paragraphs collapse.
   **Pivot:** Always use word-level speaker info. Paragraphs are fine for text cleanup but NOT for speaker grouping.

---

## Android-specific translation table

| iOS piece | Android equivalent |
|---|---|
| `AVAudioRecorder` | `MediaRecorder` (simpler) or `AudioRecord` (finer control) |
| `UIBackgroundModes: [audio]` to record while screen locked | Foreground Service with `FOREGROUND_SERVICE_TYPE_MICROPHONE` and an ongoing notification |
| `Security.framework` Keychain | `EncryptedSharedPreferences` (androidx.security.crypto) |
| `URLSession` | `OkHttp` or `Ktor Client` |
| `URLSession` background config (for surviving app suspension during long uploads) | `WorkManager` with `NetworkType.CONNECTED`, or a Foreground Service. `WorkManager` is the more idiomatic answer for "kick off upload, survive app kill, notify on completion" |
| `beginBackgroundTask` (~30s grace) | `android:foregroundServiceType="dataSync"` or just rely on WorkManager |
| `AVAudioSession.setActive` + mode | No equivalent needed — Android doesn't have this session concept, just request mic permission |
| SwiftUI `@FocusState` | Compose's `FocusRequester` / `FocusManager` |
| `NavigationStack` + `navigationDestination` | Jetpack Navigation Compose |
| XcodeGen | N/A — Gradle is already declarative |
| `AVAudioPlayer` for playback | `MediaPlayer` or `ExoPlayer` |

---

## What we didn't build (untested on iOS; open question for Android)

1. **AssemblyAI as tertiary fallback.** Listed in original plan but never wired up. Deepgram free credit was enough.
2. **True background URLSession.** On iOS we used `beginBackgroundTask` (~30s grace). Full background-session implementation deferred. Android's `WorkManager` gives you this for free, so it's arguably easier there.
3. **Storage management UI.** Delete-all, storage-by-recording view, etc.
4. **Tagging / searching transcripts.** Deferred to Phase 6.
5. **Export (markdown / plain text).** Deferred.
6. **Watch / wearable companion app.** Deferred. The iOS plan specified `WCSession.transferFile` for Apple Watch → iPhone sync. Wear OS equivalent is `MessageClient.sendRequest` or `ChannelClient` for large files.

---

## One-paragraph summary for a junior AI or developer

> Record audio as AAC m4a, 48 kHz mono, 96 kbps — lower bitrates kill diarization. Send the file to Deepgram at `/v1/listen` with `model=nova-2-conversationalai`, `diarize=true`, `paragraphs=true`, `smart_format=true`, `utterances=true`. Build speaker-labeled segments by walking the `words[]` array and grouping consecutive same-speaker words — don't trust paragraph-level speaker labels. If Deepgram returns only one unique speaker on a multi-speaker recording, send the transcript's word list to Groq's `llama-3.3-70b-versatile` (OpenAI-compatible API) with a prompt that demands structured JSON with `reasoning` field first, then word-indexed turn ranges. Apply the LLM's turns back to the original word timestamps. Store API keys in platform-native secure storage (Keychain / EncryptedSharedPreferences). Persist each transcript as JSON next to its audio file so re-opening doesn't re-hit the API.
