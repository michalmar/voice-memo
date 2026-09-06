import hashlib
import json
from unittest.mock import AsyncMock
from uuid import uuid4

import httpx
import pytest
from azure.core.credentials import AccessToken
from azure.core.credentials_async import AsyncTokenCredential
from pydantic import ValidationError

from voiceprompt.config import Settings
from voiceprompt.models import SessionComplete, SessionCreate, SessionStatus
from voiceprompt.processing import FoundryClient, Processor
from voiceprompt.repository import MemoryRepository
from voiceprompt.service import SessionService
from voiceprompt.stitching import stitch_segments


class FakeModels:
    async def transcribe(self, audio: bytes, locale: str, context: str | None) -> str:
        del locale, context
        return audio.decode()

    async def refine(self, transcript: str) -> str:
        return f"# Prompt\n\n{transcript}"


@pytest.mark.asyncio
@pytest.mark.parametrize("temperature", [None, 0, 0.5, 2])
async def test_foundry_cleanup_temperature_is_opt_in(monkeypatch, temperature):
    settings = Settings(
        environment="test",
        foundry_endpoint="https://example.openai.azure.com/",
        cleanup_temperature=temperature,
    )
    credential = AsyncMock(spec=AsyncTokenCredential)
    credential.get_token.return_value = AccessToken("test-token", 9999999999)

    def respond(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/openai/deployments/gpt-5.6-luna/chat/completions"
        assert request.url.params["api-version"] == settings.foundry_api_version
        assert request.headers["Authorization"] == "Bearer test-token"
        payload = json.loads(request.content)
        assert payload["messages"][0]["role"] == "system"
        assert payload["messages"][1] == {"role": "user", "content": "Keep this detail."}
        if temperature is None:
            assert "temperature" not in payload
        else:
            assert payload["temperature"] == temperature
        return httpx.Response(200, json={"choices": [{"message": {"content": "  Keep this detail.\n"}}]})

    http_client = httpx.AsyncClient(transport=httpx.MockTransport(respond))
    monkeypatch.setattr("voiceprompt.processing.httpx.AsyncClient", lambda **kwargs: http_client)
    assert await FoundryClient(settings, credential).refine("Keep this detail.") == "Keep this detail."
    credential.get_token.assert_awaited_once_with("https://cognitiveservices.azure.com/.default")


def test_cleanup_temperature_defaults_to_model_default():
    assert Settings(environment="test").cleanup_temperature is None


@pytest.mark.parametrize("temperature", [-0.1, 2.1, float("nan"), float("inf")])
def test_cleanup_temperature_rejects_invalid_values(temperature):
    with pytest.raises(ValidationError):
        Settings(environment="test", cleanup_temperature=temperature)


def test_stitching_removes_boundary_overlap():
    assert stitch_segments(["Použij Azure Container Apps", "Azure Container Apps s Managed Identity"]) == (
        "Použij Azure Container Apps s Managed Identity"
    )


@pytest.mark.asyncio
async def test_local_end_to_end_deletes_intermediate_data():
    settings = Settings(environment="test", allow_development_auth=True)
    repository = MemoryRepository()
    service = SessionService(repository, settings)
    session_id = uuid4()
    await service.create("owner", SessionCreate(id=session_id, audio_format="m4a"))
    chunks = [b"Vytvor API pomoci", b"API pomoci FastAPI"]
    for sequence, audio in enumerate(chunks):
        await service.upload(
            "owner", session_id, sequence, audio, hashlib.sha256(audio).hexdigest(),
            sequence * 30_000, 30_000, "audio/mp4",
        )
    await service.complete("owner", session_id, SessionComplete(expected_segment_count=2))

    processor = Processor(repository, settings, FakeModels(), FakeModels())
    while not repository.queue.empty():
        await processor.process(await repository.queue.get())

    session = await service.get("owner", session_id)
    assert session.status == SessionStatus.COMPLETED
    transcripts = await repository.list_transcripts("owner", session.created_at)
    assert transcripts[0].markdown == "# Prompt\n\nVytvor API pomoci FastAPI"
    assert repository.chunks == {}
    assert repository.segment_texts == {}


@pytest.mark.asyncio
async def test_finalization_fails_after_bounded_waits():
    settings = Settings(environment="test", allow_development_auth=True)
    repository = MemoryRepository()
    service = SessionService(repository, settings)
    session_id = uuid4()
    await service.create("owner", SessionCreate(id=session_id, audio_format="m4a"))
    session = await service.get("owner", session_id)
    session.expected_segment_count = 1
    session.status = SessionStatus.TRANSCRIBING
    await repository.save_session(session)

    processor = Processor(repository, settings, FakeModels(), FakeModels())
    await processor.process({
        "kind": "finalize", "owner": "owner", "session_id": str(session_id), "wait_count": 20
    })
    failed = await service.get("owner", session_id)
    assert failed.status == SessionStatus.FAILED
    assert failed.error_code == "segment_transcription_missing"
    assert repository.queue.empty()
