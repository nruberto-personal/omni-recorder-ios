---
title: Omni Recorder Diarization
colorFrom: blue
colorTo: purple
sdk: docker
app_port: 7860
pinned: false
---

# Omni Recorder Diarization Service

FastAPI wrapper around [pyannote.audio 3.1](https://github.com/pyannote/pyannote-audio) for the Omni Recorder project. Designed to deploy to a free Hugging Face Space (CPU basic tier).

## Endpoints

### `GET /health`
Returns model load status. Use to check the Space is warm.
```json
{ "status": "ok", "cuda": false }
```

### `POST /diarize`
Multipart form upload. Accepts an audio file; returns speaker-labeled time segments.

**Fields:**
- `audio` (required) — the audio file (wav, mp3, m4a, flac)
- `min_speakers` (optional int) — hint to the pipeline
- `max_speakers` (optional int) — hint to the pipeline

**Response:**
```json
{
  "segments": [
    { "start": 0.5, "end": 2.1, "speaker": "SPEAKER_00" },
    { "start": 2.3, "end": 5.4, "speaker": "SPEAKER_01" }
  ],
  "num_speakers": 2,
  "duration": 5.4
}
```

---

## Prerequisites

1. **Hugging Face account** with an access token that has "Read access to contents of all public gated repos you can access".
2. **Accept gated model terms** on both:
   - https://huggingface.co/pyannote/speaker-diarization-3.1
   - https://huggingface.co/pyannote/segmentation-3.0

---

## Deploy to a Hugging Face Space

1. Go to https://huggingface.co/new-space
   - **Space name:** `omni-recorder-diarization` (or whatever)
   - **License:** your choice
   - **SDK:** **Docker** → Blank template
   - **Hardware:** CPU basic (free)
   - **Visibility:** Public or Private (private requires HF Pro)
2. In the new Space's **Settings → Variables and secrets**, add a **secret** named `HF_TOKEN` with your token as the value. (Secret, not variable — never commit this anywhere.)
3. Clone the Space repo locally:
   ```sh
   git clone https://huggingface.co/spaces/<your-username>/omni-recorder-diarization
   cd omni-recorder-diarization
   ```
4. Copy these four files from `diarization-service/` in the Omni Recorder repo into the Space repo root:
   - `Dockerfile`
   - `app.py`
   - `requirements.txt`
   - `README.md` (this file — HF Spaces reads the YAML frontmatter for Space metadata)
5. Commit and push:
   ```sh
   git add Dockerfile app.py requirements.txt README.md
   git commit -m "Initial diarization service"
   git push
   ```
6. Watch the Space's **Logs** tab. First build installs torch + pyannote + deps — **expect 5–15 minutes**. After build, the container starts and downloads the Pyannote model weights (~500 MB) on first request or at startup.
7. Once the Space's status is **Running**, test from the repo root:
   ```sh
   python diarization-service/client.py <some_audio.m4a> \
     --url https://<your-username>-omni-recorder-diarization.hf.space
   ```

---

## Run locally (for development and testing)

```sh
cd diarization-service
python3.11 -m venv .venv
source .venv/bin/activate

pip install torch==2.3.1 torchaudio==2.3.1 --index-url https://download.pytorch.org/whl/cpu
pip install -r requirements.txt

# Load HF_TOKEN from the .env at the repo root (NEVER commit .env)
set -a; source ../.env; set +a

uvicorn app:app --reload --port 7860
```

In another terminal:
```sh
python client.py path/to/test.m4a
```

---

## Notes & limitations

- **CPU basic tier is slow.** Diarizing a 30-minute clip can take several minutes. For real 30–90 min meetings, upgrade the Space hardware (paid) or run the service elsewhere. Fine for Phase 3 end-to-end validation.
- **Single-request at a time.** The model instance is shared and Pyannote isn't thread-safe; concurrent requests will serialize.
- **Speaker labels are per-file only.** The same person in two different recordings will get different `SPEAKER_XX` labels — that's expected. Cross-recording speaker identity is out of scope for this project.
- **No auth on the endpoint.** The Space URL is the only barrier. If that concerns you, make the Space private (requires HF Pro).
