import hashlib
from datetime import UTC, datetime, timedelta
from uuid import UUID

from azure.identity.aio import DefaultAzureCredential
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from starlette.datastructures import UploadFile

from .auth import Principal, current_principal
from .config import Settings, get_settings
from .models import (
    ChunkReceipt,
    PubSubToken,
    SessionComplete,
    SessionCreate,
    SessionView,
    Transcript,
    TranscriptList,
    TranscriptSummary,
)
from .repository import MemoryRepository, Repository
from .processing import FoundryClient, RefinementClient, SpeechClient
from .runtime import create_event_issuer, create_repository
from .service import SessionService


def create_app(
    repository: Repository | None = None,
    settings: Settings | None = None,
    speech_client: SpeechClient | None = None,
    refinement_client: RefinementClient | None = None,
) -> FastAPI:
    config = settings or get_settings()
    store = repository or create_repository(config)
    app = FastAPI(title="VoicePrompt API", version="1.0.0")
    app.state.repository = store
    app.state.settings = config
    app.state.event_token_issuer = create_event_issuer(config)
    foundry_client = (
        FoundryClient(config, DefaultAzureCredential())
        if speech_client is None or refinement_client is None
        else None
    )
    app.state.speech_client = speech_client or foundry_client
    app.state.refinement_client = refinement_client or foundry_client

    def service() -> SessionService:
        return SessionService(app.state.repository, app.state.settings)

    @app.middleware("http")
    async def correlation(request: Request, call_next):
        correlation_id = request.headers.get("X-Correlation-ID") or hashlib.sha256(
            f"{id(request)}:{datetime.now(UTC).isoformat()}".encode()
        ).hexdigest()[:24]
        response = await call_next(request)
        response.headers["X-Correlation-ID"] = correlation_id
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/health/live", include_in_schema=False)
    async def live() -> dict[str, str]:
        return {"status": "live"}

    @app.get("/health/ready", include_in_schema=False)
    async def ready() -> JSONResponse:
        return JSONResponse({"status": "ready"})

    @app.post("/v1/sessions", response_model=SessionView, status_code=status.HTTP_201_CREATED)
    async def create_session(
        body: SessionCreate,
        principal: Principal = Depends(current_principal),
        sessions: SessionService = Depends(service),
    ):
        return await sessions.create(principal.subject, body)

    @app.put("/v1/sessions/{session_id}/chunks/{sequence}", response_model=ChunkReceipt)
    async def upload_chunk(
        session_id: UUID,
        sequence: int,
        request: Request,
        checksum: str = Header(alias="X-Content-SHA256", pattern=r"^[0-9a-fA-F]{64}$"),
        started_ms: int = Header(alias="X-Started-Ms", ge=0),
        duration_ms: int = Header(alias="X-Duration-Ms", gt=0, le=60000),
        principal: Principal = Depends(current_principal),
        sessions: SessionService = Depends(service),
    ):
        content_type = request.headers.get("content-type", "").split(";")[0]
        if content_type not in {"audio/mp4", "audio/aac", "audio/x-m4a"}:
            raise HTTPException(status_code=415, detail="Unsupported audio type")
        data = await request.body()
        return await sessions.upload(
            principal.subject, session_id, sequence, data, checksum, started_ms, duration_ms, content_type
        )

    @app.post("/v1/sessions/{session_id}/complete", response_model=SessionView, status_code=202)
    async def complete_session(
        session_id: UUID,
        body: SessionComplete,
        principal: Principal = Depends(current_principal),
        sessions: SessionService = Depends(service),
    ):
        return await sessions.complete(principal.subject, session_id, body)

    @app.post("/v1/transcriptions", response_model=Transcript, status_code=status.HTTP_201_CREATED)
    async def transcribe_immediately(
        request: Request,
        session_id: UUID = Header(alias="X-Session-ID"),
        duration_ms: int = Header(alias="X-Duration-Ms", gt=0, le=7_200_000),
        locale: str = Header(default="cs-CZ", alias="X-Locale", max_length=32),
        refine: bool = Header(default=False, alias="X-Refine"),
        principal: Principal = Depends(current_principal),
        sessions: SessionService = Depends(service),
    ):
        del duration_ms
        request_content_type = request.headers.get("content-type", "").split(";")[0]
        refinement_instructions: str | None = None
        if request_content_type == "multipart/form-data":
            form = await request.form()
            audio = form.get("audio")
            if not isinstance(audio, UploadFile):
                raise HTTPException(status_code=422, detail="Multipart request must include an audio file")
            data = await audio.read()
            content_type = audio.content_type or ""
            supplied_instructions = form.get("refinement_instructions", "")
            if not isinstance(supplied_instructions, str):
                raise HTTPException(status_code=422, detail="Refinement instructions must be text")
            refinement_instructions = supplied_instructions.strip() or None
        else:
            data = await request.body()
            content_type = request_content_type
        formats = {
            "audio/mp4": "m4a",
            "audio/aac": "aac",
            "audio/x-m4a": "m4a",
        }
        if content_type not in formats:
            raise HTTPException(status_code=415, detail="Unsupported audio type")
        if refinement_instructions and len(refinement_instructions) > 4_000:
            raise HTTPException(status_code=422, detail="Refinement instructions exceed 4,000 characters")
        if not data or len(data) > app.state.settings.max_immediate_recording_bytes:
            raise HTTPException(status_code=413, detail="Invalid recording size")
        return await sessions.transcribe_immediately(
            principal.subject,
            session_id,
            data,
            locale,
            formats[content_type],
            refine,
            refinement_instructions,
            app.state.speech_client,
            app.state.refinement_client,
        )

    @app.get("/v1/sessions/{session_id}", response_model=SessionView)
    async def get_session(
        session_id: UUID,
        principal: Principal = Depends(current_principal),
        sessions: SessionService = Depends(service),
    ):
        return await sessions.get(principal.subject, session_id)

    @app.get("/v1/transcripts", response_model=TranscriptList)
    async def list_transcripts(principal: Principal = Depends(current_principal)):
        since = datetime.now(UTC) - timedelta(hours=app.state.settings.transcript_ttl_hours)
        records = await app.state.repository.list_transcripts(principal.subject, since)
        return TranscriptList(items=[TranscriptSummary(**item.model_dump()) for item in records])

    @app.get("/v1/transcripts/{transcript_id}", response_model=Transcript)
    async def get_transcript(transcript_id: UUID, principal: Principal = Depends(current_principal)):
        item = await app.state.repository.get_transcript(principal.subject, transcript_id)
        if not item:
            raise HTTPException(status_code=404, detail="Transcript not found")
        return item

    @app.delete("/v1/transcripts/{transcript_id}", status_code=204)
    async def delete_transcript(transcript_id: UUID, principal: Principal = Depends(current_principal)):
        if not await app.state.repository.delete_transcript(principal.subject, transcript_id):
            raise HTTPException(status_code=404, detail="Transcript not found")
        return Response(status_code=204)

    @app.post("/v1/events/token", response_model=PubSubToken)
    async def event_token(principal: Principal = Depends(current_principal)):
        issuer = getattr(app.state, "event_token_issuer", None)
        if issuer is None:
            raise HTTPException(status_code=503, detail="Completion events are not configured")
        return await issuer(principal.subject)

    return app


app = create_app()
