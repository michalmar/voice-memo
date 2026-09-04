import asyncio
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from typing import Protocol
from uuid import UUID

from .models import SessionRecord, TranscriptRecord


class Repository(Protocol):
    async def create_session(self, session: SessionRecord) -> SessionRecord: ...
    async def get_session(self, owner: str, session_id: UUID) -> SessionRecord | None: ...
    async def save_session(self, session: SessionRecord) -> None: ...
    async def put_chunk(self, owner: str, session_id: UUID, sequence: int, data: bytes, checksum: str, metadata: dict[str, str]) -> bool: ...
    async def get_chunk(self, owner: str, session_id: UUID, sequence: int) -> bytes | None: ...
    async def delete_chunk(self, owner: str, session_id: UUID, sequence: int) -> None: ...
    async def save_segment_text(self, owner: str, session_id: UUID, sequence: int, text: str) -> None: ...
    async def get_segment_texts(self, owner: str, session_id: UUID, count: int) -> list[str | None]: ...
    async def delete_segment_texts(self, owner: str, session_id: UUID) -> None: ...
    async def enqueue(self, message: dict[str, object]) -> None: ...
    async def save_transcript(self, transcript: TranscriptRecord) -> None: ...
    async def get_transcript(self, owner: str, transcript_id: UUID) -> TranscriptRecord | None: ...
    async def list_transcripts(self, owner: str, since: datetime) -> list[TranscriptRecord]: ...
    async def delete_transcript(self, owner: str, transcript_id: UUID) -> bool: ...
    async def cleanup(self, now: datetime) -> int: ...


class MemoryRepository:
    def __init__(self) -> None:
        self.sessions: dict[tuple[str, UUID], SessionRecord] = {}
        self.chunks: dict[tuple[str, UUID, int], tuple[bytes, str]] = {}
        self.segment_texts: dict[tuple[str, UUID, int], str] = {}
        self.transcripts: dict[tuple[str, UUID], TranscriptRecord] = {}
        self.queue: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self._lock = asyncio.Lock()

    async def create_session(self, session: SessionRecord) -> SessionRecord:
        async with self._lock:
            key = (session.owner, session.id)
            existing = self.sessions.get(key)
            if existing:
                if existing.audio_format != session.audio_format or existing.locale != session.locale:
                    raise ValueError("session_conflict")
                return existing
            self.sessions[key] = session.model_copy(deep=True)
            return session

    async def get_session(self, owner: str, session_id: UUID) -> SessionRecord | None:
        value = self.sessions.get((owner, session_id))
        return value.model_copy(deep=True) if value else None

    async def save_session(self, session: SessionRecord) -> None:
        session.updated_at = datetime.now(UTC)
        self.sessions[(session.owner, session.id)] = session.model_copy(deep=True)

    async def put_chunk(self, owner: str, session_id: UUID, sequence: int, data: bytes, checksum: str, metadata: dict[str, str]) -> bool:
        del metadata
        key = (owner, session_id, sequence)
        async with self._lock:
            existing = self.chunks.get(key)
            if existing:
                if existing[1] != checksum:
                    raise ValueError("checksum_conflict")
                return False
            self.chunks[key] = (data, checksum)
            return True

    async def get_chunk(self, owner: str, session_id: UUID, sequence: int) -> bytes | None:
        value = self.chunks.get((owner, session_id, sequence))
        return value[0] if value else None

    async def delete_chunk(self, owner: str, session_id: UUID, sequence: int) -> None:
        self.chunks.pop((owner, session_id, sequence), None)

    async def save_segment_text(self, owner: str, session_id: UUID, sequence: int, text: str) -> None:
        self.segment_texts[(owner, session_id, sequence)] = text

    async def get_segment_texts(self, owner: str, session_id: UUID, count: int) -> list[str | None]:
        return [self.segment_texts.get((owner, session_id, sequence)) for sequence in range(count)]

    async def delete_segment_texts(self, owner: str, session_id: UUID) -> None:
        keys = [key for key in self.segment_texts if key[:2] == (owner, session_id)]
        for key in keys:
            del self.segment_texts[key]

    async def enqueue(self, message: dict[str, object]) -> None:
        await self.queue.put(message)

    async def save_transcript(self, transcript: TranscriptRecord) -> None:
        self.transcripts[(transcript.owner, transcript.id)] = transcript

    async def get_transcript(self, owner: str, transcript_id: UUID) -> TranscriptRecord | None:
        return self.transcripts.get((owner, transcript_id))

    async def list_transcripts(self, owner: str, since: datetime) -> list[TranscriptRecord]:
        return sorted(
            [item for (subject, _), item in self.transcripts.items() if subject == owner and item.created_at >= since],
            key=lambda item: item.created_at,
            reverse=True,
        )

    async def delete_transcript(self, owner: str, transcript_id: UUID) -> bool:
        return self.transcripts.pop((owner, transcript_id), None) is not None

    async def cleanup(self, now: datetime) -> int:
        expired = [key for key, value in self.transcripts.items() if value.expires_at <= now]
        for key in expired:
            del self.transcripts[key]
        return len(expired)

    async def messages(self) -> AsyncIterator[dict[str, object]]:
        while True:
            yield await self.queue.get()

