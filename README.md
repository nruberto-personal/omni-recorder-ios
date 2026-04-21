# Omni-Recorder

Personal meeting recorder + transcriber. iPhone captures audio, iPhone transcribes locally (WhisperKit) with cloud fallback (Groq / Deepgram / AssemblyAI), diarization runs on a Pyannote microservice hosted on a Hugging Face Space. See `omni-recorder-claude-code-brief.md` for the full design brief.

## Status

**Phase 5 — Deepgram primary (cloud STT + diarization in one call).** Apple Watch target is deferred. AI-assisted speaker-name auto-fill scheduled for Phase 5.5 (Groq integration). WhisperKit + Pyannote Space retained in the codebase but not called in the primary path — available for a future offline mode.

## Setup

### Prerequisites
- macOS with Xcode 15+
- iOS 17+ device (simulator works for basic recording, but background recording with the screen locked can only be verified on a real device)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

### Generate and open the project
```sh
cd /path/to/omni-recorder
xcodegen generate
open OmniRecorder.xcodeproj
```

In Xcode, set your signing team under `OmniRecorder` target → Signing & Capabilities. The bundle ID is `com.nruberto.OmniRecorder` — change it in `project.yml` if you want a different prefix, then re-run `xcodegen generate`.

### Run
Select an iPhone (real device recommended) as the destination and run. The app will prompt for microphone permission on first record.

## Phase 1 — Definition of done ✅

- [x] Big mic button records mono 16 kHz AAC to `Documents/recording_<timestamp>.m4a`
- [x] Recording continues when the screen locks (background audio mode)
- [x] Recordings appear in a list below the recorder, sorted newest first
- [x] Swipe-to-delete

## Phase 2 — Definition of done

- [x] Tapping a recording opens a detail view
- [x] Play / pause control for the audio
- [x] "Transcribe" button runs WhisperKit `openai_whisper-small.en` on-device
- [x] First-run model download (~250 MB) shows a loading state
- [x] Transcript is saved as JSON alongside the `.m4a` and reloaded on reopen
- [x] Transcript renders with per-segment timecodes
- [ ] **Verify on a real device:** record a short clip → transcribe → see plausible text. Then transcribe a 10-min clip to sanity-check speed and accuracy.

## Phase 3 — Definition of done ✅

- [x] FastAPI service in `diarization-service/` with `POST /diarize` and `GET /health`
- [x] Dockerfile targeted at HF Spaces (non-root user, port 7860)
- [x] Python test client (`client.py`)
- [x] Deployment walkthrough in `diarization-service/README.md`
- [x] Deployed to HF Space; verified JSON response with `segments`, `num_speakers`, `duration`

## Phase 4 — Definition of done ✅

- [x] `OmniRecorder/Diarization/DiarizationClient.swift` — multipart upload to the Space
- [x] `OmniRecorder/Pipeline/TranscriptMerger.swift` — max-overlap merge, first-appearance label ordering
- [x] `OmniRecorder/App/Constants.swift` — Space URL (edit here to point at a different Space)
- [x] Transcribe flow runs WhisperKit + diarization **in parallel**
- [x] Graceful degradation: if diarization fails, transcript still renders with an orange warning banner, no speaker labels
- [x] Turn-level rendering: consecutive same-speaker Whisper segments merged into one paragraph
- [x] Inline speaker rename: tap a speaker label → text field → return to save
- [x] Speaker-name overrides persisted in the transcript JSON (`speakerNames` field)
- [x] "Re-transcribe" button on completed transcripts; preserves existing speaker names where raw IDs survive
- [ ] **Verify on a real device:** record a 2-minute clip with yourself speaking in two distinct tones (or with another person) → tap Transcribe → expect two speaker turns with readable labels that you can rename by tapping.

## Phase 5 — Definition of done

- [x] `TranscriptionProvider` protocol with `DeepgramProvider` as the first implementation
- [x] `KeychainStore` for API-key persistence; keys never hit disk or logs
- [x] `SettingsView` with a gear icon in the main navigation bar
- [x] `RecordingDetailView` uses the provider — no more parallel Whisper + Pyannote + merge
- [x] Single Deepgram API call returns transcript + speaker labels (paragraphs mapped directly to turns)
- [x] `beginBackgroundTask` + `isIdleTimerDisabled` so the flow survives brief app backgrounding and the screen stays on
- [x] Deepgram model id baked into the stored JSON (`deepgram-nova-3`)
- [x] Speaker-name overrides carry over on re-transcribe where raw IDs survive
- [ ] **Verify on a real device:** add Deepgram key in Settings → re-transcribe the Toronto/Fernando recording → expect rapid turnaround (seconds, not minutes) and markedly better speaker attribution than the WhisperKit+Pyannote path.

## Phase 5.5 — Definition of done

- [x] `tools/embed-dev-secrets.py` also reads `GROQ_KEY` from `.env`
- [x] `OmniRecorder/Pipeline/SpeakerInference.swift` — wraps Groq's chat-completions API (`llama-3.3-70b-versatile`), prompts the LLM to split a word-indexed transcript into speaker turns with inferred names
- [x] SettingsView has separate Save/Clear for Deepgram and Groq keys
- [x] Transcribe flow: after Deepgram returns, if `rawSpeakers.count <= 1`, the transcript is passed through `SpeakerInference.inferIfNeeded(from:)`. If Groq succeeds, speakers are rewritten with LLM-inferred boundaries and names; if anything goes wrong, the Deepgram output is kept as-is.
- [x] Generic labels (`Speaker 1`, `Speaker 2`) stay as-is in the default-label scheme; real names (`Nathan`, `Fernando`) are written into `speakerNames` so they render directly without user rename.
- [x] Model id gets `+groq` suffix when inference fired, so it's clear in the UI which path ran.
- [ ] **Verify:** Re-transcribe the Nathan/Fernando clip with both keys present. Expect Xcode console to log `[Deepgram] N words, 1 unique speakers: [0]` followed by `[Groq] inferred M turns, K speakers: ...`. Transcript UI should now show "Nathan" / "Fernando" (or similar names inferred from context) instead of Speaker A.

Once verified, Phase 5.5 is done. Phase 6 (UX polish: rename, tag, search, export, manual turn split for audio the LLM can't reason about) comes next.

After any change to `project.yml` (e.g. adding WhisperKit here), run `xcodegen generate` again before opening Xcode.

## Project layout

```
omni-recorder/
├── project.yml                  # XcodeGen config (source of truth)
├── OmniRecorder/                # iOS app target
│   ├── App/                     # @main entry, root view
│   ├── Recording/               # AVAudioRecorder + AVAudioSession
│   ├── Storage/                 # Recording persistence
│   ├── Views/                   # Recorder UI, recordings list
│   ├── Models/                  # Transcript + Recording types
│   └── Assets.xcassets/
├── diarization-service/         # (later) Pyannote HF Space service
└── omni-recorder-claude-code-brief.md
```

## Regenerating the project

Anytime `project.yml` changes (new source dirs, Info.plist keys, build settings), run:
```sh
xcodegen generate
```
The `.xcodeproj` is gitignored — it's regenerated from `project.yml`.
# omni-recorder-ios
