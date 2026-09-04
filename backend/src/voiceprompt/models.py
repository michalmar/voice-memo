from datetime import UTC, datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, Field


class SessionStatus(StrEnum):
    CREATED = "created"
    RECORDING = "recording"
    UPLOADING = "uploading"
    TRANSCRIBING = "transcribing"
    REFINING = "refining"
    COMPLETED = "completed"
    FAILED = "failed"


class SessionCreate(BaseModel):
    id: UUID
    audio_format: str = Field(pattern=r"^(m4a|aac)$")
    locale: str = Field(default="cs-CZ", max_length=32)


class SessionComplete(BaseModel):
    expected_segment_count: int = Field(ge=1, le=120)


class SessionView(BaseModel):
    id: UUID
    status: SessionStatus
    accepted_segments: list[int]
    expected_segment_count: int | None = None
    error_code: str | None = None
    created_at: datetime
    updated_at: datetime


class ChunkReceipt(BaseModel):
    sequence: int
    checksum: str
    accepted: bool = True
    duplicate: bool = False


class TranscriptSummary(BaseModel):
    id: UUID
    session_id: UUID
    created_at: datetime
    expires_at: datetime


class Transcript(TranscriptSummary):
    markdown: str


class TranscriptList(BaseModel):
    items: list[TranscriptSummary]


class PubSubToken(BaseModel):
    url: str
    expires_at: datetime


class SessionRecord(BaseModel):
    id: UUID
    owner: str
    audio_format: str
    locale: str
    status: SessionStatus = SessionStatus.CREATED
    accepted_segments: list[int] = Field(default_factory=list)
    expected_segment_count: int | None = None
    error_code: str | None = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(UTC))


class TranscriptRecord(Transcript):
    owner: str

