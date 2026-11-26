"""Voice transport validation and the transcription endpoint."""

import io
import wave

from fastapi.testclient import TestClient

from app.main import create_app
from app.voice import validate_wav


def wav_bytes(seconds: float = 0.5) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as sound:
        sound.setnchannels(1)
        sound.setsampwidth(2)
        sound.setframerate(16000)
        sound.writeframes(b"\0\0" * int(seconds * 16000))
    return buffer.getvalue()


def test_transcribe_returns_text_without_editing_scene(tmp_path, monkeypatch):
    monkeypatch.setattr("app.main.transcribe", lambda data: "Put a hill here" if validate_wav(data) is None else "")
    client = TestClient(create_app(tmp_path / "projects"))
    before = client.get("/api/scenes/demo").json()
    response = client.post("/api/transcribe", content=wav_bytes(), headers={"content-type": "audio/wav"})
    assert response.status_code == 200
    assert response.json() == {"text": "Put a hill here"}
    assert client.get("/api/scenes/demo").json() == before


def test_transcribe_rejects_bad_audio(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    assert client.post("/api/transcribe", content=b"not audio", headers={"content-type": "audio/wav"}).status_code == 422
    assert client.post("/api/transcribe", content=wav_bytes(), headers={"content-type": "text/plain"}).status_code == 415
    assert client.post("/api/transcribe", content=b"x" * 2_000_001,
                       headers={"content-type": "audio/wav"}).status_code == 413
