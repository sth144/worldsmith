"""Local speech-to-text for short scene commands."""

from __future__ import annotations

import io
import os
import tempfile
import wave
from functools import lru_cache
from pathlib import Path

from fastapi import HTTPException

MAX_WAV_BYTES = 2_000_000
MAX_SECONDS = 15


def validate_wav(data: bytes) -> None:
    if not 44 <= len(data) <= MAX_WAV_BYTES:
        raise HTTPException(422, "Recording must be a short WAV file")
    try:
        with wave.open(io.BytesIO(data), "rb") as sound:
            rate = sound.getframerate()
            duration = sound.getnframes() / rate if rate else 0
            if sound.getcomptype() != "NONE" or sound.getsampwidth() != 2 or sound.getnchannels() != 1:
                raise HTTPException(422, "Recording must be mono 16-bit PCM WAV")
            if not 8000 <= rate <= 48000 or not 0.25 <= duration <= MAX_SECONDS:
                raise HTTPException(422, "Recording must be 0.25–15 seconds at 8–48 kHz")
    except (EOFError, wave.Error) as exc:
        raise HTTPException(422, "Recording is not a valid WAV file") from exc


@lru_cache(maxsize=1)
def _model():
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise HTTPException(503, "Voice transcription is unavailable; install the server voice extra") from exc
    # First use downloads the model into the Mac's model cache. Audio stays on the Mac.
    return WhisperModel(os.environ.get("WORLDSMITH_WHISPER_MODEL", "base.en"),
                        device="cpu", compute_type="int8")


def transcribe(data: bytes) -> str:
    validate_wav(data)
    with tempfile.TemporaryDirectory(prefix="worldsmith-voice-") as directory:
        audio = Path(directory) / "command.wav"
        audio.write_bytes(data)
        try:
            segments, _ = _model().transcribe(str(audio), language="en", beam_size=3,
                                               condition_on_previous_text=False, vad_filter=True)
            transcript = " ".join(segment.text.strip() for segment in segments).strip()
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(502, "Could not transcribe recording") from exc
    if not transcript:
        raise HTTPException(422, "No speech was detected; try again")
    return transcript[:1000]
