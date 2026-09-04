import hashlib
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from fastapi import HTTPException

from .config import Settings
from .models import (
    ChunkReceipt,
    SessionComplete,
    SessionCreate,
    SessionRecord,
    SessionStatus,
    TranscriptRecord,
)
from .repository import Repository


class SessionService:
    def __init__(self, repository: Repository, settings: Settings) -> None:
        self.repository = repository
        self.settings = settings

    async def create(self, owner: str, request: SessionCreate) -> SessionRecord:
        try:
            return await self.repository.create_session(
                SessionRecord(owner=owner, **request.model_dump())
            )
        except ValueError as exc:
            raise HTTPException(status_code=409, detail="Session ID already exists with different metadata") from exc

    async def get(self, owner: str, session_id: UUID) -> SessionRecord:
        session = await self.repository.get_session(owner, session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        return session

    async def upload(
        self,
        owner: str,
        session_id: UUID,
        sequence: int,
        data: bytes,
        checksum: str,
        started_ms: int,
        duration_ms: int,
        content_type: str,
    ) -> ChunkReceipt:
        session = await self.get(owner, session_id)
        if session.status in {SessionStatus.COMPLETED, SessionStatus.REFINING}:
            raise HTTPException(status_code=409, detail="Session no longer accepts segments")
        if sequence >= self.settings.max_segments:
            raise HTTPException(status_code=422, detail="Segment sequence exceeds limit")
        if not data or len(data) > self.settings.max_chunk_bytes:
            raise HTTPException(status_code=413, detail="Invalid segment size")
        actual = hashlib.sha256(data).hexdigest()
        if actual != checksum.lower():
            raise HTTPException(status_code=422, detail="Checksum mismatch")
        try:
            created = await self.repository.put_chunk(
                owner,
                session_id,
                sequence,
                data,
                actual,
                {
                    "content_type": content_type,
                    "started_ms": str(started_ms),
                    "duration_ms": str(duration_ms),
                },
            )
        except ValueError as exc:
            raise HTTPException(status_code=409, detail="Segment sequence has different content") from exc
        if sequence not in session.accepted_segments:
            session.accepted_segments.append(sequence)
            session.accepted_segments.sort()
        session.status = SessionStatus.UPLOADING
        session.error_code = None
        await self.repository.save_session(session)
        if created:
            await self.repository.enqueue(
                {"kind": "transcribe", "owner": owner, "session_id": str(session_id), "sequence": sequence}
            )
        return ChunkReceipt(sequence=sequence, checksum=actual, duplicate=not created)

    async def complete(self, owner: str, session_id: UUID, request: SessionComplete) -> SessionRecord:
        session = await self.get(owner, session_id)
        expected = list(range(request.expected_segment_count))
        if session.accepted_segments != expected:
            missing = sorted(set(expected) - set(session.accepted_segments))
            raise HTTPException(status_code=409, detail={"code": "segments_missing", "missing": missing})
        if session.expected_segment_count not in {None, request.expected_segment_count}:
            raise HTTPException(status_code=409, detail="Expected segment count cannot be changed")
        session.expected_segment_count = request.expected_segment_count
        if session.status != SessionStatus.COMPLETED:
            session.status = SessionStatus.TRANSCRIBING
            await self.repository.save_session(session)
            await self.repository.enqueue(
                {"kind": "finalize", "owner": owner, "session_id": str(session_id)}
            )
        return session

    async def create_transcript(self, session: SessionRecord, markdown: str) -> TranscriptRecord:
        now = datetime.now(UTC)
        transcript = TranscriptRecord(
            id=uuid4(),
            session_id=session.id,
            owner=session.owner,
            markdown=markdown,
            created_at=now,
            expires_at=now + timedelta(hours=self.settings.transcript_ttl_hours),
        )
        await self.repository.save_transcript(transcript)
        return transcript
