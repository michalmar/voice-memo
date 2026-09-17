from uuid import uuid4

from fastapi.testclient import TestClient

from voiceprompt.app import create_app
from voiceprompt.config import Settings
from voiceprompt.repository import MemoryRepository


class FakeSpeech:
    async def transcribe(self, audio: bytes, locale: str, context: str | None) -> str:
        assert audio == b"recording"
        assert locale == "en-US"
        assert context is None
        return "Fast raw transcript."


def test_health_and_openapi_contract():
    app = create_app(
        MemoryRepository(),
        Settings(environment="test", allow_development_auth=True),
    )
    client = TestClient(app)
    assert client.get("/health/live").status_code == 200
    schema = client.get("/openapi.json").json()
    assert "/v1/sessions" in schema["paths"]
    assert "/v1/sessions/{session_id}/chunks/{sequence}" in schema["paths"]
    assert "/v1/transcriptions" in schema["paths"]


def test_development_auth_is_explicit():
    app = create_app(MemoryRepository(), Settings(environment="test", allow_development_auth=True))
    client = TestClient(app)
    response = client.post(
        "/v1/sessions",
        headers={"Authorization": "Bearer " + "dev:test-owner"},
        json={"id": str(uuid4()), "audio_format": "m4a", "locale": "cs-CZ"},
    )
    assert response.status_code == 201
    assert response.json()["status"] == "created"


def test_immediate_transcription_stores_verbatim_result():
    repository = MemoryRepository()
    app = create_app(
        repository,
        Settings(environment="test", allow_development_auth=True),
        FakeSpeech(),
    )
    client = TestClient(app)
    session_id = uuid4()
    response = client.post(
        "/v1/transcriptions",
        headers={
            "Authorization": "Bearer dev:test-owner",
            "Content-Type": "audio/mp4",
            "X-Session-ID": str(session_id),
            "X-Duration-Ms": "1200",
            "X-Locale": "en-US",
        },
        content=b"recording",
    )
    assert response.status_code == 201
    assert response.json()["session_id"] == str(session_id)
    assert response.json()["markdown"] == "Fast raw transcript."

    session = client.get(
        f"/v1/sessions/{session_id}",
        headers={"Authorization": "Bearer dev:test-owner"},
    )
    assert session.json()["status"] == "completed"
