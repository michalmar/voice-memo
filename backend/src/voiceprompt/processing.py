import asyncio
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import Protocol
from uuid import UUID

import httpx
from azure.core.credentials_async import AsyncTokenCredential

from .config import Settings
from .models import SessionStatus
from .repository import Repository
from .service import SessionService
from .stitching import stitch_segments


class SpeechClient(Protocol):
    async def transcribe(self, audio: bytes, locale: str, context: str | None) -> str: ...


class RefinementClient(Protocol):
    async def refine(self, transcript: str) -> str: ...


class FoundryClient:
    def __init__(self, settings: Settings, credential: AsyncTokenCredential) -> None:
        self.settings = settings
        self.credential = credential

    async def _headers(self) -> dict[str, str]:
        token = await self.credential.get_token("https://cognitiveservices.azure.com/.default")
        return {"Authorization": "Bearer " + token.token}

    async def transcribe(self, audio: bytes, locale: str, context: str | None) -> str:
        prompt = ", ".join(self.settings.technical_glossary)
        if context:
            prompt += f". Previous context: {context[-800:]}"
        url = (
            f"{self.settings.foundry_endpoint.rstrip('/')}/openai/deployments/"
            f"{self.settings.speech_deployment}/audio/transcriptions"
        )
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.post(
                url,
                params={"api-version": self.settings.foundry_api_version},
                headers=await self._headers(),
                files={"file": ("segment.m4a", audio, "audio/mp4")},
                data={"language": locale.split("-")[0], "prompt": prompt},
            )
            response.raise_for_status()
            return response.json()["text"].strip()

    async def refine(self, transcript: str) -> str:
        system = (
            "Polish the transcript into copy-ready Markdown in its original language. Preserve every intent, "
            "requirement, decision, caveat, uncertainty, explicit negation, value, identifier, code fragment, "
            "URL, command, product name, and technical detail. Correct obvious transcription errors from context. "
            "Remove filler words, stuttering, accidental repetition, and abandoned formulations; prefer a later "
            "explicit correction. Never invent facts, resolve genuine ambiguity, or summarize. Return only Markdown. "
            f"Technical glossary: {', '.join(self.settings.technical_glossary)}."
        )
        url = (
            f"{self.settings.foundry_endpoint.rstrip('/')}/openai/deployments/"
            f"{self.settings.cleanup_deployment}/chat/completions"
        )
        async with httpx.AsyncClient(timeout=180) as client:
            response = await client.post(
                url,
                params={"api-version": self.settings.foundry_api_version},
                headers={**await self._headers(), "Content-Type": "application/json"},
                json={
                    "messages": [{"role": "system", "content": system}, {"role": "user", "content": transcript}],
                    "temperature": 0,
                },
            )
            response.raise_for_status()
            return response.json()["choices"][0]["message"]["content"].strip()


class Processor:
    def __init__(
        self,
        repository: Repository,
        settings: Settings,
        speech: SpeechClient,
        refinement: RefinementClient,
        notify: Callable[[str, UUID], Awaitable[None]] | None = None,
    ) -> None:
        self.repository = repository
        self.settings = settings
        self.speech = speech
        self.refinement = refinement
        self.notify = notify

    async def process(self, message: dict[str, object]) -> None:
        owner = str(message["owner"])
        session_id = UUID(str(message["session_id"]))
        session = await self.repository.get_session(owner, session_id)
        if not session or session.status == SessionStatus.COMPLETED:
            return
        if message["kind"] == "transcribe":
            sequence = int(message["sequence"])
            existing = await self.repository.get_segment_texts(owner, session_id, sequence + 1)
            if existing[sequence] is not None:
                await self.repository.delete_chunk(owner, session_id, sequence)
                return
            audio = await self.repository.get_chunk(owner, session_id, sequence)
            if audio is None:
                return
            context = existing[sequence - 1] if sequence > 0 else None
            text = await self.speech.transcribe(audio, session.locale, context)
            await self.repository.save_segment_text(owner, session_id, sequence, text)
            await self.repository.delete_chunk(owner, session_id, sequence)
            return
        if message["kind"] == "finalize":
            if session.expected_segment_count is None:
                return
            segments = await self.repository.get_segment_texts(owner, session_id, session.expected_segment_count)
            if any(segment is None for segment in segments):
                wait_count = int(message.get("wait_count", 0))
                if wait_count >= 20:
                    session.status = SessionStatus.FAILED
                    session.error_code = "segment_transcription_missing"
                    await self.repository.save_session(session)
                    return
                await asyncio.sleep(1)
                await self.repository.enqueue({**message, "wait_count": wait_count + 1})
                return
            session.status = SessionStatus.REFINING
            await self.repository.save_session(session)
            markdown = await self.refinement.refine(stitch_segments([part or "" for part in segments]))
            transcript = await SessionService(self.repository, self.settings).create_transcript(session, markdown)
            await self.repository.delete_segment_texts(owner, session_id)
            session.status = SessionStatus.COMPLETED
            await self.repository.save_session(session)
            if self.notify:
                await self.notify(owner, transcript.id)

    async def process_safely(self, message: dict[str, object]) -> None:
        try:
            await self.process(message)
        except Exception:
            owner = str(message.get("owner", ""))
            session_id = UUID(str(message["session_id"]))
            session = await self.repository.get_session(owner, session_id)
            if session:
                session.status = SessionStatus.FAILED
                session.error_code = "processing_failed"
                await self.repository.save_session(session)
            raise
