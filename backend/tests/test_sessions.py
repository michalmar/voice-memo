import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from fastapi import HTTPException

from voiceprompt.config import Settings
from voiceprompt.models import SessionComplete, SessionCreate, SessionStatus, TranscriptRecord
from voiceprompt.repository import MemoryRepository
from voiceprompt.service import SessionService


@pytest.fixture
def context():
    settings = Settings(environment="test", allow_development_auth=True, max_segments=4)
    repository = MemoryRepository()
    return repository, SessionService(repository, settings)


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

