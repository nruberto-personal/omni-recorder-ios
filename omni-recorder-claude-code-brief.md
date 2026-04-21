# Omni-Recorder: Claude Code Project Brief

## Context for Claude Code
You are starting a new project. Read this entire brief before writing any code or creating files. Propose the repo structure, confirm the tech stack choices below, then execute **phase by phase** — do not attempt to build everything at once. After each phase, stop and let me verify before moving on.

---

## 1. What we're building

A personal tool for capturing **business meetings** on an Apple Watch SE, transcribing them accurately, and producing a transcript that labels **who said what** (speaker diarization). The transcripts are for my own review and learning — they don't need to be shared or published anywhere.

**Why this doesn't already exist for me:** Paid options (Otter.ai, Notta) either cap free tiers at 3–30 min per session (too short for real meetings) or cost $14–17/mo. This build eliminates that SaaS tax by leaning on local models + free-tier developer APIs.

**Use case specifics that shape the design:**
- Meetings are typically 30–90 minutes — longer than most free tiers allow.
- 2–6 speakers is the common case.
- Recording happens on the wrist discreetly (no phone out on the table).
- Transcripts are consumed later, not in real time. Latency is not critical.
- Audio quality will be imperfect (watch mic, ambient room noise, varying distance).

---

## 2. Architecture: Local-First, Cloud-Fallback

```
[Apple Watch SE]                [iPhone]                    [Free Cloud Fallbacks]
   SwiftUI app                  Controller app               (hit only when local fails
   AVAudioRecorder              - WhisperKit (local STT)      or is too slow)
   ↓                            - Pyannote microservice      - Groq (Whisper-large-v3)
   WCSession.transferFile ────► - Results viewer             - Deepgram
   (.m4a to phone)              - Provider Manager ─────────►- AssemblyAI
                                  (API rotation + retry)
                                                             [Diarization]
                                                             - Pyannote.audio on
                                                               Hugging Face Space (CPU free tier)
```

**Priority logic on the iPhone controller:**

1. **Transcription — Priority 1 (local):** WhisperKit (CoreML, Apple Neural Engine). $0, private, offline-capable.
2. **Transcription — Priority 2 (cloud fallback):** If local fails or is too slow, rotate through Groq → Deepgram → AssemblyAI.
3. **Diarization (always):** Pyannote.audio microservice on a Hugging Face Space. Run **in parallel** with transcription and merge timestamps afterward.

---

## 3. Tech stack (decided — don't substitute without flagging)

| Layer | Choice | Notes |
|---|---|---|
| Watch app | SwiftUI + watchOS 10+ | `AVAudioRecorder` for capture, `WCSession` for transfer |
| iPhone app | SwiftUI + iOS 17+ | Receives files, orchestrates pipeline, displays results |
| Local STT | [WhisperKit](https://github.com/argmaxinc/WhisperKit) | Start with `base` or `small` model — fast on ANE, good enough for clear audio |
| Diarization | [pyannote.audio](https://github.com/pyannote/pyannote-audio) 3.x | Requires HF token for model download (free) |
| Diarization host | Hugging Face Space (CPU tier, free) | Exposes a simple POST endpoint |
| Cloud STT fallbacks | Groq, Deepgram, AssemblyAI | All have generous free tiers / dev credits |
| Audio format | `.m4a` (AAC) | Native to AVAudioRecorder, small files, wide support |

---

## 4. Proposed repo structure

```
omni-recorder/
├── OmniRecorder.xcodeproj
├── OmniRecorder-iOS/          # iPhone controller app
│   ├── Pipeline/              # WhisperKit + API rotator + merge logic
│   ├── Providers/             # One file per cloud STT provider
│   ├── Diarization/           # HTTP client for HF Space
│   ├── Views/                 # Recording list, transcript viewer
│   └── Session/               # WCSessionDelegate (phone side)
├── OmniRecorder-Watch/        # watchOS app
│   ├── Views/                 # Record button, status UI
│   ├── Recording/             # AVAudioRecorder wrapper
│   └── Session/               # WCSessionDelegate (watch side)
├── Shared/                    # Models, transcript types, constants
├── diarization-service/       # Python service deployed to HF Space
│   ├── app.py                 # FastAPI or Gradio endpoint
│   ├── requirements.txt
│   └── README.md              # Deployment instructions
└── README.md
```

Confirm this structure (or propose a better one) before creating files.

---

## 5. Phased build plan

**Stop after each phase. Verify with me before continuing.**

### Phase 1 — Watch-to-Phone audio pipeline
**Goal:** Record on watch, get `.m4a` onto phone reliably, even when screen dims.

- Minimal watch UI: big record button, timer, stop button.
- `AVAudioRecorder` configured for AAC, mono, 16kHz (sufficient for speech, keeps files small).
- `WCSession.transferFile()` — **not** `sendMessage` or `transferUserInfo` — because file transfer is the only method that survives backgrounding and throttling.
- Phone-side `WCSessionDelegate.session(_:didReceive:)` to catch incoming files and store them in the app's documents directory.
- Simple iOS view listing received recordings.

**Definition of done:** I can record a 10+ minute audio on the watch, lower my wrist, and reliably see the `.m4a` file appear on the phone.

### Phase 2 — Local transcription with WhisperKit
**Goal:** Transcribe a recording on-device.

- Integrate WhisperKit via SPM.
- Load the `base` model on first run (lazy-download, show progress).
- Transcribe a selected recording, show the plain transcript.
- Store transcripts as JSON alongside the audio file.

**Definition of done:** Tap a recording → get transcript text on screen within a reasonable time for a 10-min clip.

### Phase 3 — Pyannote diarization microservice
**Goal:** Given an audio file, return speaker-labeled time segments.

- Python service (FastAPI preferred over Gradio for clean JSON API).
- Endpoint: `POST /diarize` accepts a file, returns `[{"start": 0.5, "end": 2.0, "speaker": "SPEAKER_00"}, ...]`.
- Dockerfile + HF Space deployment instructions in `diarization-service/README.md`.
- Include a simple Python client script for local testing.

**Definition of done:** I can `curl` the HF Space URL with an audio file and get back a diarization JSON.

### Phase 4 — Merge: "zip" transcription + diarization
**Goal:** Combine Whisper's word timestamps with Pyannote's speaker timestamps.

- The "double-pass" trick: for each Whisper segment, find the Pyannote speaker whose time range overlaps most, assign that speaker label.
- Handle edge cases: overlapping speakers, gaps, single-word misattribution.
- Produce final transcript format:
  ```
  [00:12] Speaker A: Thanks for joining today.
  [00:15] Speaker B: No problem, happy to be here.
  ```
- Run transcription and diarization **in parallel** (async) to minimize wall time.

**Definition of done:** A real meeting recording produces a readable, speaker-labeled transcript.

### Phase 5 — Provider Manager (cloud fallback + rotation)
**Goal:** If local transcription is unavailable or too slow, gracefully fall back to cloud.

- `TranscriptionProvider` protocol: `func transcribe(audio: URL) async throws -> Transcript`.
- Implementations: `WhisperKitProvider`, `GroqProvider`, `DeepgramProvider`, `AssemblyAIProvider`.
- `ProviderManager` iterates the priority list; on `429` or network failure, falls through to the next. Logs which provider served each request.
- API keys stored in Keychain, not in code. Config UI to paste keys.

**Definition of done:** I can disable the local WhisperKit path and recordings still transcribe via Groq; I can simulate a 429 and watch it roll over to Deepgram.

### Phase 6 — UX polish (only after 1–5 work)
- Rename recordings, tag meetings, search transcripts.
- Export to Markdown or plain text.
- Delete / storage management.

---

## 6. Key technical gotchas to get right

- **`WCSession.transferFile` is the only reliable way** to move audio off the watch. `sendMessage` drops when the app backgrounds; `transferUserInfo` has size limits. This is the single most common failure mode in watchOS audio apps.
- **Apple Watch cannot run WhisperKit locally** — the SE has no Neural Engine worth speaking of. All ML happens on the phone. Do not attempt on-watch inference.
- **Pyannote requires a Hugging Face token** with access to the `pyannote/speaker-diarization-3.1` gated model. Document this clearly in the HF Space README.
- **Double-pass merging is where accuracy lives.** Pyannote's speaker boundaries and Whisper's word boundaries will never align perfectly. Use "max-overlap wins" for segment-to-speaker assignment, and prefer Whisper segments (sentences) over words for the final merge granularity.
- **Audio config matters for meetings.** Mono, 16kHz, AAC @ ~32kbps is ideal: small files, good speech quality, works well for both Whisper and Pyannote. Stereo and higher sample rates waste bytes without improving transcription.
- **iPhone background execution limits:** long transcription jobs should use `BGProcessingTask` so they continue if the user locks the phone.
- **Keys in source = game over.** Use Keychain. Don't commit any `.env` files. Add them to `.gitignore` day one.

---

## 7. Alternatives considered (context for why we're not using them)

- **Otter.ai:** Free tier capped at 30-min sessions and 300 min/month. Paid is $17/mo. Good product, but $200+/year for something I can self-build is the SaaS tax I'm avoiding.
- **Notta:** More languages than Otter but 3-min free cap per session makes it a non-starter for meetings.
- **Apple Notes / Voice Memos built-in transcription:** No speaker diarization. Non-starter.
- **Google Pinpoint:** Free and does diarization well, but manual web upload for each file — no automation path from watch.
- **NotebookLM:** Not a transcriber; you feed it transcripts. Could be a downstream consumer of this app's output but not a replacement.
- **Running Pyannote on-device via CoreML:** Technically possible, a real project to get right. Skip for v1 — HF Space is $0 and fast enough.

---

## 8. Free-tier reference (as of early 2026 — verify before building)

| Service | Free allowance | Notes |
|---|---|---|
| Groq | High rate-limit free tier on Whisper-large-v3 | Fastest Whisper on the market |
| Deepgram | $200 in developer credits | Lowest latency, built-in diarization (could compete with Pyannote) |
| AssemblyAI | ~$50 credit | Has `speaker_labels=true` flag — easy fallback |
| Hugging Face Spaces | CPU Basic is free | Enough for Pyannote on short clips; upgrade if jobs time out |

> **Note to Claude Code:** verify current free-tier details by checking each provider's pricing page before hardcoding limits. These numbers shift.

---

## 9. Deliverables (final)

- Swift code: watchOS recorder + iOS controller (WhisperKit + API rotator + merge logic).
- Python code: Pyannote diarization service, deployable to HF Space.
- README at repo root with setup steps (Xcode, HF token, API keys).
- README in `diarization-service/` with HF Space deployment walkthrough.

---

## 10. Start here

1. Confirm the repo structure in §4 or propose a better one.
2. Scaffold the Xcode project (iOS + watchOS targets, shared code).
3. Begin Phase 1. Do not start Phase 2 until Phase 1 is verified.

Ask clarifying questions before writing code if anything in this brief is ambiguous.
