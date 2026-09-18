import json
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from azure.core.exceptions import HttpResponseError, ResourceExistsError, ResourceNotFoundError
from fastapi.testclient import TestClient

from voiceprompt.app import create_app
from voiceprompt.azure_repository import AzureRepository, _partition
from voiceprompt.config import Settings
from voiceprompt.models import TranscriptionCheckpoint, TranscriptRecord


class Table:
    def __init__(self):
        self.entities = {}
        self.upsert_error = None
        self.delete_error = None

    async def create_entity(self, entity):
        key = (entity["PartitionKey"], entity["RowKey"])
        if key in self.entities:
            raise ResourceExistsError("Entity exists")
        await self.upsert_entity(entity, mode="replace")

    async def upsert_entity(self, entity, *, mode):
        if self.upsert_error:
            raise self.upsert_error
        assert mode == "replace"
        for value in entity.values():
            if isinstance(value, str) and len(value.encode("utf-16-le")) > 64 * 1024:
                raise HttpResponseError("PropertyValueTooLarge")
        self.entities[(entity["PartitionKey"], entity["RowKey"])] = entity.copy()

    async def get_entity(self, partition, row):
        if (partition, row) not in self.entities:
            raise ResourceNotFoundError("Entity not found")
        return self.entities[(partition, row)].copy()

    async def delete_entity(self, partition, row):
        if self.delete_error:
            raise self.delete_error
        if self.entities.pop((partition, row), None) is None:
            raise ResourceNotFoundError("Entity not found")

    async def query_entities(self, query, *, parameters):
        del query
        for (partition, row), entity in list(self.entities.items()):
            if partition != parameters["partition"]:
                continue
            if "since" in parameters and entity["created_at"] < parameters["since"]:
                continue
            if "cutoff" in parameters and row > parameters["cutoff"]:
                continue
            yield entity.copy()


class Container:
    def __init__(self):
        self.contents = {}
        self.downloads = []
        self.upload_error = None
        self.delete_error = None
        self.content_types = {}
        self.metadata = {}

    async def upload_blob(self, name, data, *, overwrite, content_settings, metadata=None):
        if self.upload_error:
            raise self.upload_error
        assert overwrite is True
        assert isinstance(data, bytes)
        self.contents[name] = data
        self.content_types[name] = content_settings.content_type
        self.metadata[name] = metadata or {}

    async def download_blob(self, name):
        self.downloads.append(name)
        if name not in self.contents:
            raise ResourceNotFoundError("Blob not found")
        return SimpleNamespace(readall=AsyncMock(return_value=self.contents[name]))

    async def delete_blob(self, name):
        if self.delete_error:
            raise self.delete_error
        if self.contents.pop(name, None) is None:
            raise ResourceNotFoundError("Blob not found")


@pytest.fixture
def repository(monkeypatch):
    tables = {name: Table() for name in ("sessions", "transcripts", "transcriptexpiry")}
    containers = {name: Container() for name in ("audio", "transcripts")}
    table_service = MagicMock()
    table_service.get_table_client.side_effect = tables.__getitem__
    blob_service = MagicMock()
    blob_service.get_container_client.side_effect = containers.__getitem__
    monkeypatch.setattr("voiceprompt.azure_repository.TableServiceClient", lambda *a, **kw: table_service)
    monkeypatch.setattr("voiceprompt.azure_repository.BlobServiceClient", lambda *a, **kw: blob_service)
    monkeypatch.setattr("voiceprompt.azure_repository.QueueServiceClient", MagicMock())
    return AzureRepository(Settings(environment="test", storage_account_name="testaccount"), AsyncMock())


def record(markdown="Small transcript.", **overrides):
    now = datetime.now(UTC)
    return TranscriptRecord(**{
        "id": uuid4(), "session_id": uuid4(), "owner": "owner-a",
        "markdown": markdown, "refined": True,
        "created_at": now, "expires_at": now + timedelta(hours=48),
        **overrides,
    })


async def save_legacy(repository, transcript):
    await repository.transcripts.upsert_entity({
        "PartitionKey": _partition(transcript.owner),
        "RowKey": str(transcript.id),
        "owner": transcript.owner,
        "payload": transcript.model_dump_json(),
        "created_at": transcript.created_at,
        "expires_at": transcript.expires_at,
    }, mode="replace")
    await repository.transcript_expiry.upsert_entity({
        "PartitionKey": "expiry",
        "RowKey": f"{transcript.expires_at.isoformat()}:{transcript.id}",
        "owner_partition": _partition(transcript.owner),
        "transcript_id": str(transcript.id),
    }, mode="replace")


@pytest.mark.asyncio
@pytest.mark.parametrize("length", [32_767, 32_768, 32_769, 600_000])
async def test_transcripts_cross_table_property_and_entity_limits_without_truncation(repository, length):
    transcript = record("x" * length + "\n\u017dlu\u0165ou\u010dk\u00fd \U0001f399\ufe0f\n")
    await repository.save_transcript(transcript)
    entity = await repository.transcripts.get_entity(_partition(transcript.owner), str(transcript.id))

    assert "markdown" not in json.loads(entity["payload"])
    assert len(entity["payload"].encode("utf-16-le")) < 1024
    assert repository.transcript_blobs.contents[entity["blob_name"]] == transcript.markdown.encode("utf-8")
    assert repository.transcript_blobs.content_types[entity["blob_name"]] == "text/markdown; charset=utf-8"
    assert repository.transcript_blobs.metadata[entity["blob_name"]]["session_id"] == str(transcript.session_id)
    assert await repository.get_transcript(transcript.owner, transcript.id) == transcript
    assert repository.blobs.contents == {}


@pytest.mark.asyncio
async def test_history_lists_old_and_new_metadata_without_downloading_bodies(repository):
    old = record("Legacy", created_at=datetime.now(UTC) - timedelta(hours=1), refined=None)
    new = record("New" * 30_000)
    await save_legacy(repository, old)
    await repository.save_transcript(new)
    await repository.save_transcript(record("Private", owner="owner-b"))

    history = await repository.list_transcripts("owner-a", old.created_at)
    assert [item.id for item in history] == [new.id, old.id]
    assert all("markdown" not in item.model_dump() for item in history)
    assert repository.transcript_blobs.downloads == []
    assert [item.id for item in await repository.list_transcripts("owner-a", new.created_at)] == [new.id]
    assert await repository.get_transcript("owner-a", old.id) == old
    assert repository.transcript_blobs.downloads == []


@pytest.mark.asyncio
async def test_read_and_delete_are_scoped_to_owner(repository):
    transcript = record()
    await repository.save_transcript(transcript)
    assert await repository.get_transcript("owner-b", transcript.id) is None
    assert await repository.delete_transcript("owner-b", transcript.id) is False
    assert await repository.get_transcript("owner-a", transcript.id) == transcript
    assert await repository.delete_transcript("owner-a", transcript.id) is True
    assert await repository.delete_transcript("owner-a", transcript.id) is False
    assert await repository.get_transcript("owner-a", transcript.id) is None
    assert repository.transcript_blobs.contents == {}


@pytest.mark.asyncio
async def test_missing_body_is_an_explicit_storage_error_not_missing_history(repository):
    transcript = record()
    await repository.save_transcript(transcript)
    repository.transcript_blobs.contents.clear()
    with pytest.raises(ResourceNotFoundError, match="Blob"):
        await repository.get_transcript("owner-a", transcript.id)
    assert len(await repository.list_transcripts("owner-a", transcript.created_at)) == 1


@pytest.mark.asyncio
async def test_legacy_deletion_and_expiry_remain_supported(repository):
    now = datetime.now(UTC)
    deleted = record()
    expired = record(expires_at=now - timedelta(seconds=1))
    await save_legacy(repository, deleted)
    await save_legacy(repository, expired)
    assert await repository.delete_transcript("owner-a", deleted.id) is True
    assert await repository.cleanup(now) == 1
    assert await repository.cleanup(now) == 0
    assert repository.transcripts.entities == {}


@pytest.mark.asyncio
async def test_expiry_removes_only_due_transcript_bodies_and_metadata(repository):
    now = datetime.now(UTC)
    expired = record(created_at=now - timedelta(hours=48), expires_at=now)
    current = record(created_at=now, expires_at=now + timedelta(hours=48))
    await repository.save_transcript(expired)
    await repository.save_transcript(current)
    assert await repository.cleanup(now - timedelta(microseconds=1)) == 0
    assert await repository.cleanup(now) == 1
    assert await repository.get_transcript(expired.owner, expired.id) is None
    assert await repository.get_transcript(current.owner, current.id) == current
    assert len(repository.transcript_blobs.contents) == 1
    assert await repository.cleanup(now) == 0
    assert await repository.cleanup(current.expires_at) == 1
    assert repository.transcript_blobs.contents == {}
    assert repository.transcript_expiry.entities == {}


@pytest.mark.asyncio
async def test_failed_metadata_save_preserves_body_for_recovery_and_expiry(repository):
    transcript = record("Long" * 30_000, expires_at=datetime.now(UTC))
    repository.transcripts.upsert_error = HttpResponseError("Table unavailable")
    with pytest.raises(HttpResponseError):
        await repository.save_transcript(transcript)
    assert repository.transcripts.entities == {}
    assert list(repository.transcript_blobs.contents.values()) == [transcript.markdown.encode()]
    assert len(repository.transcript_expiry.entities) == 1
    await repository.cleanup(datetime.now(UTC))
    assert repository.transcript_blobs.contents == {}
    assert repository.transcript_expiry.entities == {}


@pytest.mark.asyncio
async def test_failed_expiry_save_does_not_publish_untracked_history(repository):
    transcript = record()
    repository.transcript_expiry.upsert_error = HttpResponseError("Index unavailable")
    with pytest.raises(HttpResponseError):
        await repository.save_transcript(transcript)
    assert repository.transcripts.entities == {}
    assert list(repository.transcript_blobs.contents.values()) == [transcript.markdown.encode()]


@pytest.mark.asyncio
async def test_failed_body_save_does_not_publish_metadata(repository):
    repository.transcript_blobs.upload_error = HttpResponseError("Blob unavailable")
    with pytest.raises(HttpResponseError):
        await repository.save_transcript(record())
    assert repository.transcripts.entities == {}
    assert repository.transcript_expiry.entities == {}


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", ["blob", "table", "expiry"])
async def test_cleanup_retains_expiry_entry_when_deletion_fails_and_retries(repository, failure):
    transcript = record(expires_at=datetime.now(UTC))
    await repository.save_transcript(transcript)
    target = {
        "blob": repository.transcript_blobs,
        "table": repository.transcripts,
        "expiry": repository.transcript_expiry,
    }[failure]
    target.delete_error = HttpResponseError("Temporarily unavailable")
    with pytest.raises(HttpResponseError):
        await repository.cleanup(datetime.now(UTC))
    assert len(repository.transcript_expiry.entities) == 1
    target.delete_error = None
    await repository.cleanup(datetime.now(UTC))
    assert repository.transcripts.entities == {}
    assert repository.transcript_blobs.contents == {}
    assert repository.transcript_expiry.entities == {}


@pytest.mark.asyncio
async def test_delete_failure_preserves_metadata_and_can_be_retried(repository):
    transcript = record()
    await repository.save_transcript(transcript)
    repository.transcript_blobs.delete_error = HttpResponseError("Temporarily unavailable")
    with pytest.raises(HttpResponseError):
        await repository.delete_transcript(transcript.owner, transcript.id)
    assert await repository.get_transcript(transcript.owner, transcript.id) == transcript
    repository.transcript_blobs.delete_error = None
    assert await repository.delete_transcript(transcript.owner, transcript.id) is True


@pytest.mark.asyncio
async def test_raw_checkpoints_are_large_private_and_retained_independently_per_attempt(repository):
    now = datetime.now(UTC)
    expired = TranscriptionCheckpoint(
        session_id=uuid4(), owner="owner-a", markdown="\u010desk\u00fd text " * 20_000,
        created_at=now - timedelta(hours=48), expires_at=now,
    )
    retry = expired.model_copy(update={"id": uuid4(), "created_at": now, "expires_at": now + timedelta(hours=48)})
    await repository.save_transcription_checkpoint(expired)
    await repository.save_transcription_checkpoint(retry)
    assert len(repository.transcript_blobs.contents) == 2
    assert repository.transcripts.entities == {}
    assert await repository.list_transcripts("owner-a", expired.created_at) == []
    await repository.cleanup(now)
    assert len(repository.transcript_blobs.contents) == 1
    assert TranscriptionCheckpoint.model_validate_json(
        next(iter(repository.transcript_blobs.contents.values()))
    ) == retry
    await repository.delete_transcription_checkpoint(retry)
    await repository.delete_transcription_checkpoint(retry)
    await repository.cleanup(retry.expires_at)
    assert repository.transcript_blobs.contents == {}
    assert repository.transcript_expiry.entities == {}


def test_long_refined_api_result_round_trips_through_blob_storage(repository):
    raw = "Raw text with \u010desk\u00e9 znaky. " * 4000
    polished = "# Transcript\n\n" + raw
    speech = SimpleNamespace(transcribe=AsyncMock(return_value=raw))
    refinement = SimpleNamespace(refine=AsyncMock(return_value=polished))
    client = TestClient(create_app(
        repository, Settings(environment="test", allow_development_auth=True), speech, refinement
    ))
    session_id = uuid4()
    headers = {"Authorization": "Bearer " + "dev:owner-a"}
    response = client.post(
        "/v1/transcriptions",
        headers={**headers, "Content-Type": "audio/mp4", "X-Session-ID": str(session_id),
                 "X-Duration-Ms": "3000000", "X-Refine": "true"},
        content=b"recording",
    )
    assert response.status_code == 201
    assert response.json()["markdown"] == polished
    assert response.json()["refined"] is True
    transcript_id = response.json()["id"]
    assert client.get(f"/v1/transcripts/{transcript_id}", headers=headers).json() == response.json()
    history = client.get("/v1/transcripts", headers=headers).json()["items"]
    assert len(history) == 1
    assert "markdown" not in history[0]
    assert client.get(f"/v1/sessions/{session_id}", headers=headers).json()["status"] == "completed"
    assert all(name.startswith("completed/") for name in repository.transcript_blobs.contents)
    assert client.delete(f"/v1/transcripts/{transcript_id}", headers=headers).status_code == 204
    assert repository.transcript_blobs.contents == {}


def test_api_storage_failure_preserves_raw_and_refined_content_and_marks_session_failed(repository):
    raw = "Private long-session raw text. " * 4000
    polished = "# Polished\n" + raw
    speech = SimpleNamespace(transcribe=AsyncMock(return_value=raw))
    refinement = SimpleNamespace(refine=AsyncMock(return_value=polished))
    repository.transcripts.upsert_error = HttpResponseError("Table temporarily unavailable")
    client = TestClient(create_app(
        repository, Settings(environment="test", allow_development_auth=True), speech, refinement,
    ), raise_server_exceptions=False)
    session_id = uuid4()
    headers = {"Authorization": "Bearer " + "dev:owner-a"}
    response = client.post(
        "/v1/transcriptions",
        headers={**headers, "Content-Type": "audio/mp4", "X-Session-ID": str(session_id),
                 "X-Duration-Ms": "3000000", "X-Refine": "true"},
        content=b"recording",
    )
    assert response.status_code == 500
    session = client.get(f"/v1/sessions/{session_id}", headers=headers).json()
    assert session["status"] == "failed"
    assert session["error_code"] == "transcript_persistence_failed"
    assert client.get("/v1/transcripts", headers=headers).json()["items"] == []
    checkpoints = [
        TranscriptionCheckpoint.model_validate_json(body)
        for name, body in repository.transcript_blobs.contents.items()
        if name.startswith("checkpoints/")
    ]
    assert len(checkpoints) == 1
    assert checkpoints[0].session_id == session_id
    assert checkpoints[0].markdown == raw
    completed = [
        body for name, body in repository.transcript_blobs.contents.items() if name.startswith("completed/")
    ]
    assert completed == [polished.encode()]
