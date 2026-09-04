from uuid import uuid4

from fastapi.testclient import TestClient

from voiceprompt.app import create_app
from voiceprompt.config import Settings
from voiceprompt.repository import MemoryRepository


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
