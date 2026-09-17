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


class FakeRefinement:
    def __init__(self, expected_instructions: str | None = None) -> None:
        self.expected_instructions = expected_instructions

    async def refine(self, transcript: str, custom_instructions: str | None = None) -> str:
        assert transcript == "Fast raw transcript."
        assert custom_instructions == self.expected_instructions
        return "# Refined transcript"


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
        FakeRefinement(),
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
    assert response.json()["refined"] is False

    session = client.get(
        f"/v1/sessions/{session_id}",
        headers={"Authorization": "Bearer dev:test-owner"},
    )
    assert session.json()["status"] == "completed"


def test_immediate_transcription_can_refine_result():
    repository = MemoryRepository()
    app = create_app(
        repository,
        Settings(environment="test", allow_development_auth=True),
        FakeSpeech(),
        FakeRefinement(),
    )
    client = TestClient(app)
    session_id = uuid4()
    response = client.post(
        "/v1/transcriptions",
        headers={
            "Authorization": "Bearer " + "dev:test-owner",
            "Content-Type": "audio/mp4",
            "X-Session-ID": str(session_id),
            "X-Duration-Ms": "1200",
            "X-Locale": "en-US",
            "X-Refine": "true",
        },
        content=b"recording",
    )
    assert response.status_code == 201
    assert response.json()["markdown"] == "# Refined transcript"
    assert response.json()["refined"] is True

    session = client.get(
        f"/v1/sessions/{session_id}",
        headers={"Authorization": "Bearer " + "dev:test-owner"},
    )
    assert session.json()["status"] == "completed"


def test_immediate_transcription_adds_custom_refinement_instructions():
    repository = MemoryRepository()
    instructions = "Use concise bullet points."
    app = create_app(
        repository,
        Settings(environment="test", allow_development_auth=True),
        FakeSpeech(),
        FakeRefinement(instructions),
    )
    client = TestClient(app)
    session_id = uuid4()
    response = client.post(
        "/v1/transcriptions",
        headers={
            "Authorization": "Bearer " + "dev:test-owner",
            "X-Session-ID": str(session_id),
            "X-Duration-Ms": "1200",
            "X-Locale": "en-US",
            "X-Refine": "true",
        },
        files={"audio": ("recording.m4a", b"recording", "audio/mp4")},
        data={"refinement_instructions": instructions},
    )

    assert response.status_code == 201
    assert response.json()["markdown"] == "# Refined transcript"
    assert response.json()["refined"] is True


def test_immediate_transcription_rejects_refinement_instructions_over_limit():
    app = create_app(
        MemoryRepository(),
        Settings(environment="test", allow_development_auth=True),
        FakeSpeech(),
        FakeRefinement(),
    )
    client = TestClient(app)
    response = client.post(
        "/v1/transcriptions",
        headers={
            "Authorization": "Bearer " + "dev:test-owner",
            "X-Session-ID": str(uuid4()),
            "X-Duration-Ms": "1200",
            "X-Locale": "en-US",
            "X-Refine": "true",
        },
        files={"audio": ("recording.m4a", b"recording", "audio/mp4")},
        data={"refinement_instructions": "a" * 4_001},
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "Refinement instructions exceed 4,000 characters"
