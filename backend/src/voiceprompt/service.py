import hashlib
import logging
from typing import Protocol
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
    TranscriptionCheckpoint,
    TranscriptRecord,
)
from .repository import Repository


logger = logging.getLogger(__name__)


class SpeechTranscriber(Protocol):
    async def transcribe(self, audio: bytes, locale: str, context: str | None) -> str: ...


class TranscriptRefiner(Protocol):
    async def refine(self, transcript: str, custom_instructions: str | None = None) -> str: ...


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
        session.accepted_segments = await self.repository.list_accepted_segments(owner, session_id)
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
        session.accepted_segments = await self.repository.list_accepted_segments(owner, session_id)
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

    async def create_transcript(
        self,
        session: SessionRecord,
        markdown: str,
        refined: bool | None = None,
    ) -> TranscriptRecord:
        now = datetime.now(UTC)
        transcript = TranscriptRecord(
            id=uuid4(),
            session_id=session.id,
            owner=session.owner,
            markdown=markdown,
            refined=refined,
            created_at=now,
            expires_at=now + timedelta(hours=self.settings.transcript_ttl_hours),
        )
        await self.repository.save_transcript(transcript)
        return transcript

    async def transcribe_immediately(
        self,
        owner: str,
        session_id: UUID,
        audio: bytes,
        locale: str,
        audio_format: str,
        refine: bool,
        refinement_instructions: str | None,
        speech: SpeechTranscriber,
        refinement: TranscriptRefiner,
    ) -> TranscriptRecord:
        session = await self.create(
            owner,
            SessionCreate(id=session_id, audio_format=audio_format, locale=locale),
        )
        session.status = SessionStatus.TRANSCRIBING
        session.error_code = None
        await self.repository.save_session(session)
        failure_code = "speech_failed"
        checkpoint: TranscriptionCheckpoint | None = None
        try:
            markdown = await speech.transcribe(audio, locale, None)
            if refine:
                failure_code = "checkpoint_persistence_failed"
                now = datetime.now(UTC)
                checkpoint = TranscriptionCheckpoint(
                    session_id=session.id,
                    owner=session.owner,
                    markdown=markdown,
                    created_at=now,
                    expires_at=now + timedelta(hours=self.settings.transcript_ttl_hours),
                )
                await self.repository.save_transcription_checkpoint(checkpoint)
                session.status = SessionStatus.REFINING
                await self.repository.save_session(session)
                failure_code = "refinement_failed"
                markdown = await refinement.refine(markdown, refinement_instructions)
            failure_code = "transcript_persistence_failed"
            transcript = await self.create_transcript(session, markdown, refined=refine)
            if checkpoint is not None:
                await self.repository.delete_transcription_checkpoint(checkpoint)
            session.status = SessionStatus.COMPLETED
            await self.repository.save_session(session)
            return transcript
        except Exception:
            logger.exception("Immediate transcription %s failed: %s", session_id, failure_code)
            session.status = SessionStatus.FAILED
            session.error_code = failure_code
            await self.repository.save_session(session)
            raise
