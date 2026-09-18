import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

from voiceprompt.config import Settings
from voiceprompt.models import SessionComplete, SessionCreate, SessionStatus, TranscriptionCheckpoint, TranscriptRecord
from voiceprompt.repository import MemoryRepository
from voiceprompt.service import SessionService


@pytest.fixture
def context():
    settings = Settings(environment="test", allow_development_auth=True, max_segments=4)
    repository = MemoryRepository()
    return repository, SessionService(repository, settings)


def test_development_auth_cannot_be_enabled_in_production():
    with pytest.raises(ValueError):
        Settings(environment="production", allow_development_auth=True)


@pytest.mark.asyncio
async def test_session_and_chunk_are_idempotent(context):
    repository, service = context
    session_id = uuid4()
    request = SessionCreate(id=session_id, audio_format="m4a")
    first = await service.create("owner-a", request)
    second = await service.create("owner-a", request)
    assert first.id == second.id

    audio = b"audio"
    checksum = hashlib.sha256(audio).hexdigest()
    receipt = await service.upload("owner-a", session_id, 0, audio, checksum, 0, 30_000, "audio/mp4")
    duplicate = await service.upload("owner-a", session_id, 0, audio, checksum, 0, 30_000, "audio/mp4")
    assert receipt.duplicate is False
    assert duplicate.duplicate is True
    assert repository.queue.qsize() == 1


@pytest.mark.asyncio
async def test_duplicate_sequence_with_different_content_is_rejected(context):
    _, service = context
    session_id = uuid4()
    await service.create("owner-a", SessionCreate(id=session_id, audio_format="m4a"))
    for data in (b"first", b"second"):
        checksum = hashlib.sha256(data).hexdigest()
        if data == b"first":
            await service.upload("owner-a", session_id, 0, data, checksum, 0, 1, "audio/mp4")
        else:
            with pytest.raises(HTTPException) as raised:
                await service.upload("owner-a", session_id, 0, data, checksum, 0, 1, "audio/mp4")
            assert raised.value.status_code == 409


@pytest.mark.asyncio
async def test_finalization_requires_every_segment(context):
    _, service = context
    session_id = uuid4()
    await service.create("owner-a", SessionCreate(id=session_id, audio_format="m4a"))
    audio = b"audio"
    await service.upload(
        "owner-a", session_id, 1, audio, hashlib.sha256(audio).hexdigest(), 30_000, 30_000, "audio/mp4"
    )
    with pytest.raises(HTTPException) as raised:
        await service.complete("owner-a", session_id, SessionComplete(expected_segment_count=2))
    assert raised.value.status_code == 409
    assert raised.value.detail["missing"] == [0]


@pytest.mark.asyncio
async def test_resource_ownership_isolated(context):
    _, service = context
    session_id = uuid4()
    await service.create("owner-a", SessionCreate(id=session_id, audio_format="m4a"))
    with pytest.raises(HTTPException) as raised:
        await service.get("owner-b", session_id)
    assert raised.value.status_code == 404


@pytest.mark.asyncio
async def test_retention_cleanup_is_idempotent(context):
    repository, _ = context
    now = datetime.now(UTC)
    record = TranscriptRecord(
        id=uuid4(),
        session_id=uuid4(),
        owner="owner-a",
        markdown="text",
        created_at=now - timedelta(hours=49),
        expires_at=now - timedelta(hours=1),
    )
    await repository.save_transcript(record)
    assert await repository.cleanup(now) == 1
    assert await repository.cleanup(now) == 0


@pytest.mark.asyncio
async def test_immediate_refinement_checkpoints_raw_text_before_model_and_removes_it_on_success(context):
    repository, service = context
    session_id = uuid4()
    raw = "Long raw transcript. " * 10_000

    async def refine(text, instructions):
        assert text == raw
        checkpoint = next(iter(repository.transcription_checkpoints.values()))
        assert checkpoint.session_id == session_id
        assert checkpoint.markdown == raw
        assert checkpoint.expires_at - checkpoint.created_at == timedelta(hours=48)
        assert await repository.list_transcripts("owner-a", checkpoint.created_at) == []
        return "# Polished\n" + text

    speech = AsyncMock()
    speech.transcribe.return_value = raw
    refinement = AsyncMock()
    refinement.refine.side_effect = refine
    transcript = await service.transcribe_immediately(
        "owner-a", session_id, b"audio", "cs-CZ", "m4a", True, None, speech, refinement,
    )
    assert transcript.markdown == "# Polished\n" + raw
    assert repository.transcription_checkpoints == {}
    assert (await service.get("owner-a", session_id)).status == SessionStatus.COMPLETED


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "stage,error_code,raw_saved",
    [
        ("speech", "speech_failed", False),
        ("checkpoint", "checkpoint_persistence_failed", False),
        ("refinement", "refinement_failed", True),
        ("transcript", "transcript_persistence_failed", True),
    ],
)
async def test_immediate_failures_are_marked_and_preserve_available_raw_text(
    context, monkeypatch, stage, error_code, raw_saved, caplog
):
    repository, service = context
    session_id = uuid4()
    speech, refinement = AsyncMock(), AsyncMock()
    speech.transcribe.return_value = "Private raw transcript."
    refinement.refine.return_value = "# Polished transcript"
    failure = RuntimeError("Synthetic failure")
    if stage == "speech":
        speech.transcribe.side_effect = failure
    elif stage == "refinement":
        refinement.refine.side_effect = failure
    else:
        method = "save_transcription_checkpoint" if stage == "checkpoint" else "save_transcript"
        monkeypatch.setattr(repository, method, AsyncMock(side_effect=failure))

    with pytest.raises(RuntimeError, match="Synthetic failure"):
        await service.transcribe_immediately(
            "owner-a", session_id, b"audio", "cs-CZ", "m4a", True, None, speech, refinement,
        )
    session = await service.get("owner-a", session_id)
    assert session.status == SessionStatus.FAILED
    assert session.error_code == error_code
    assert bool(repository.transcription_checkpoints) is raw_saved
    assert error_code in caplog.text
    assert "Private raw transcript." not in caplog.text
    if raw_saved:
        assert next(iter(repository.transcription_checkpoints.values())).markdown == "Private raw transcript."
    if stage in {"speech", "checkpoint"}:
        refinement.refine.assert_not_awaited()


@pytest.mark.asyncio
async def test_unrefined_storage_failure_also_marks_session_failed(context, monkeypatch):
    repository, service = context
    speech, refinement = AsyncMock(), AsyncMock()
    speech.transcribe.return_value = "Raw transcript."
    monkeypatch.setattr(repository, "save_transcript", AsyncMock(side_effect=RuntimeError("Storage down")))
    session_id = uuid4()
    with pytest.raises(RuntimeError, match="Storage down"):
        await service.transcribe_immediately(
            "owner-a", session_id, b"audio", "cs-CZ", "m4a", False, None, speech, refinement,
        )
    session = await service.get("owner-a", session_id)
    assert session.status == SessionStatus.FAILED
    assert session.error_code == "transcript_persistence_failed"
    refinement.refine.assert_not_awaited()


@pytest.mark.asyncio
async def test_failed_session_checkpoints_expire_without_a_final_transcript(context):
    repository, _ = context
    now = datetime.now(UTC)
    expired = TranscriptionCheckpoint(
        session_id=uuid4(), owner="owner-a", markdown="Raw",
        created_at=now - timedelta(hours=48), expires_at=now,
    )
    current = expired.model_copy(update={"id": uuid4(), "expires_at": now + timedelta(hours=1)})
    await repository.save_transcription_checkpoint(expired)
    await repository.save_transcription_checkpoint(current)
    await repository.cleanup(now)
    assert list(repository.transcription_checkpoints.values()) == [current]
