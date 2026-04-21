import os
import subprocess
import tempfile
import traceback
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from pyannote.audio import Pipeline

HF_TOKEN = os.environ.get("HF_TOKEN")
if not HF_TOKEN:
    raise RuntimeError("HF_TOKEN environment variable is required")

pipeline: Optional[Pipeline] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pipeline
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=HF_TOKEN,
    )
    if torch.cuda.is_available():
        pipeline.to(torch.device("cuda"))
    yield


app = FastAPI(title="Omni Recorder Diarization", lifespan=lifespan)


@app.get("/health")
def health():
    return {
        "status": "ok" if pipeline is not None else "loading",
        "cuda": torch.cuda.is_available(),
    }


@app.post("/diarize")
async def diarize(
    audio: UploadFile = File(...),
    min_speakers: Optional[int] = Form(None),
    max_speakers: Optional[int] = Form(None),
):
    if pipeline is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    suffix = Path(audio.filename or "audio").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await audio.read())
        upload_path = tmp.name

    # Transcode to 16 kHz mono WAV — libsndfile (via pyannote/torchaudio) can't read AAC/m4a.
    wav_path = tempfile.mktemp(suffix=".wav")

    try:
        try:
            subprocess.run(
                [
                    "ffmpeg", "-y", "-loglevel", "error",
                    "-i", upload_path,
                    "-ac", "1", "-ar", "16000", "-f", "wav",
                    wav_path,
                ],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as e:
            raise HTTPException(
                status_code=400,
                detail=f"ffmpeg failed: {e.stderr.decode('utf-8', errors='replace')}",
            )

        kwargs = {}
        if min_speakers is not None and min_speakers > 0:
            kwargs["min_speakers"] = min_speakers
        if max_speakers is not None and max_speakers > 0:
            kwargs["max_speakers"] = max_speakers

        try:
            diarization = pipeline(wav_path, **kwargs)
        except Exception as e:
            print(traceback.format_exc(), flush=True)
            raise HTTPException(
                status_code=500,
                detail=f"{type(e).__name__}: {e}",
            )

        segments = [
            {
                "start": round(float(turn.start), 3),
                "end": round(float(turn.end), 3),
                "speaker": speaker,
            }
            for turn, _, speaker in diarization.itertracks(yield_label=True)
        ]

        num_speakers = len({s["speaker"] for s in segments})
        duration = max((s["end"] for s in segments), default=0.0)

        return {
            "segments": segments,
            "num_speakers": num_speakers,
            "duration": round(duration, 3),
        }
    finally:
        for path in (upload_path, wav_path):
            try:
                os.unlink(path)
            except OSError:
                pass
