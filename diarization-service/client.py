"""Simple client for local or remote testing of the diarization service.

Usage:
    python client.py <audio_file> [--url URL] [--min-speakers N] [--max-speakers N]

Examples:
    python client.py sample.m4a
    python client.py sample.m4a --url https://you-omni-recorder-diarization.hf.space
    python client.py sample.m4a --min-speakers 2 --max-speakers 4
"""
import argparse
import json
import sys
from pathlib import Path

import requests


def main() -> int:
    parser = argparse.ArgumentParser(description="Diarize an audio file.")
    parser.add_argument("audio", type=Path, help="Path to audio file (.wav/.m4a/.mp3/.flac)")
    parser.add_argument("--url", default="http://localhost:7860", help="Service base URL")
    parser.add_argument("--min-speakers", type=int, default=None)
    parser.add_argument("--max-speakers", type=int, default=None)
    args = parser.parse_args()

    if not args.audio.exists():
        print(f"File not found: {args.audio}", file=sys.stderr)
        return 1

    data = {}
    if args.min_speakers is not None:
        data["min_speakers"] = args.min_speakers
    if args.max_speakers is not None:
        data["max_speakers"] = args.max_speakers

    with args.audio.open("rb") as f:
        response = requests.post(
            f"{args.url.rstrip('/')}/diarize",
            files={"audio": (args.audio.name, f, "application/octet-stream")},
            data=data,
            timeout=600,
        )

    if response.status_code != 200:
        print(f"HTTP {response.status_code}: {response.text}", file=sys.stderr)
        return 1

    print(json.dumps(response.json(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
