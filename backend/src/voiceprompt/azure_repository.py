import base64
import json
from datetime import UTC, datetime
from hashlib import sha256
from uuid import UUID

from azure.core.exceptions import HttpResponseError, ResourceExistsError, ResourceNotFoundError
from azure.core.credentials_async import AsyncTokenCredential
from azure.data.tables.aio import TableServiceClient
from azure.storage.blob.aio import BlobServiceClient
from azure.storage.queue.aio import QueueServiceClient

from .config import Settings
from .models import SessionRecord, TranscriptRecord


def _partition(owner: str) -> str:
    return sha256(owner.encode()).hexdigest()


class AzureRepository:
    """Storage implementation using only Entra credentials and private service endpoints."""

    def __init__(self, settings: Settings, credential: AsyncTokenCredential) -> None:
        suffix = settings.storage_endpoint_suffix
        name = settings.storage_account_name
        self.sessions = TableServiceClient(
            f"https://{name}.table.{suffix}", credential=credential
        ).get_table_client(settings.sessions_table)
        self.transcripts = TableServiceClient(
            f"https://{name}.table.{suffix}", credential=credential
        ).get_table_client(settings.transcripts_table)
        self.blobs = BlobServiceClient(
            f"https://{name}.blob.{suffix}", credential=credential
        ).get_container_client(settings.chunks_container)
        self.queue = QueueServiceClient(
            f"https://{name}.queue.{suffix}", credential=credential
        ).get_queue_client(settings.work_queue)

    @staticmethod
    def _session_entity(session: SessionRecord) -> dict[str, object]:
        data = session.model_dump(mode="json")
        return {
            "PartitionKey": _partition(session.owner),
            "RowKey": f"session:{session.id}",
            "owner": session.owner,
            "payload": json.dumps(data, separators=(",", ":")),
        }

    async def create_session(self, session: SessionRecord) -> SessionRecord:
        try:
            await self.sessions.create_entity(self._session_entity(session))
            return session
        except ResourceExistsError:
            existing = await self.get_session(session.owner, session.id)
            if not existing or existing.audio_format != session.audio_format or existing.locale != session.locale:
                raise ValueError("session_conflict")
            return existing

    async def get_session(self, owner: str, session_id: UUID) -> SessionRecord | None:
        try:
            item = await self.sessions.get_entity(_partition(owner), f"session:{session_id}")
            if item["owner"] != owner:
                return None
            return SessionRecord.model_validate_json(item["payload"])
        except ResourceNotFoundError:
            return None

    async def save_session(self, session: SessionRecord) -> None:
        session.updated_at = datetime.now(UTC)
        await self.sessions.upsert_entity(self._session_entity(session), mode="replace")

    def _blob_name(self, owner: str, session_id: UUID, sequence: int) -> str:
        return f"{_partition(owner)}/{session_id}/{sequence:06d}.m4a"

    async def put_chunk(self, owner: str, session_id: UUID, sequence: int, data: bytes, checksum: str, metadata: dict[str, str]) -> bool:
        blob = self.blobs.get_blob_client(self._blob_name(owner, session_id, sequence))
        try:
            await blob.upload_blob(data, overwrite=False, metadata={**metadata, "sha256": checksum})
            return True
        except ResourceExistsError:
            properties = await blob.get_blob_properties()
            if properties.metadata.get("sha256") != checksum:
                raise ValueError("checksum_conflict")
            return False

    async def get_chunk(self, owner: str, session_id: UUID, sequence: int) -> bytes | None:
        try:
            return await (await self.blobs.download_blob(self._blob_name(owner, session_id, sequence))).readall()
        except ResourceNotFoundError:
            return None

    async def delete_chunk(self, owner: str, session_id: UUID, sequence: int) -> None:
        try:
            await self.blobs.delete_blob(self._blob_name(owner, session_id, sequence))
        except ResourceNotFoundError:
            pass

    async def save_segment_text(self, owner: str, session_id: UUID, sequence: int, text: str) -> None:
        await self.sessions.upsert_entity(
            {
                "PartitionKey": _partition(owner),
                "RowKey": f"segment:{session_id}:{sequence:06d}",
                "owner": owner,
                "text": text,
            },
            mode="replace",
        )

    async def get_segment_texts(self, owner: str, session_id: UUID, count: int) -> list[str | None]:
        values: list[str | None] = [None] * count
        query = "PartitionKey eq @partition and RowKey ge @start and RowKey lt @end"
        parameters = {
            "partition": _partition(owner),
            "start": f"segment:{session_id}:",
            "end": f"segment:{session_id};",
        }
        async for entity in self.sessions.query_entities(query, parameters=parameters):
            sequence = int(entity["RowKey"].rsplit(":", 1)[1])
            if sequence < count:
                values[sequence] = entity["text"]
        return values

    async def delete_segment_texts(self, owner: str, session_id: UUID) -> None:
        values = await self.get_segment_texts(owner, session_id, 10_000)
        for sequence, value in enumerate(values):
            if value is not None:
                try:
                    await self.sessions.delete_entity(_partition(owner), f"segment:{session_id}:{sequence:06d}")
                except ResourceNotFoundError:
                    pass

    async def enqueue(self, message: dict[str, object]) -> None:
        encoded = base64.b64encode(json.dumps(message, separators=(",", ":")).encode()).decode()
        await self.queue.send_message(encoded)

    async def save_transcript(self, transcript: TranscriptRecord) -> None:
        await self.transcripts.upsert_entity(
            {
                "PartitionKey": _partition(transcript.owner),
                "RowKey": str(transcript.id),
                "owner": transcript.owner,
                "payload": transcript.model_dump_json(),
                "expires_at": transcript.expires_at,
                "created_at": transcript.created_at,
            },
            mode="replace",
        )

    async def get_transcript(self, owner: str, transcript_id: UUID) -> TranscriptRecord | None:
        try:
            item = await self.transcripts.get_entity(_partition(owner), str(transcript_id))
            if item["owner"] != owner:
                return None
            return TranscriptRecord.model_validate_json(item["payload"])
        except ResourceNotFoundError:
            return None

    async def list_transcripts(self, owner: str, since: datetime) -> list[TranscriptRecord]:
        query = "PartitionKey eq @partition and created_at ge @since"
        parameters = {"partition": _partition(owner), "since": since}
        records = [
            TranscriptRecord.model_validate_json(entity["payload"])
            async for entity in self.transcripts.query_entities(query, parameters=parameters)
        ]
        return sorted(records, key=lambda item: item.created_at, reverse=True)

    async def delete_transcript(self, owner: str, transcript_id: UUID) -> bool:
        try:
            await self.transcripts.delete_entity(_partition(owner), str(transcript_id))
            return True
        except ResourceNotFoundError:
            return False

    async def cleanup(self, now: datetime) -> int:
        count = 0
        async for entity in self.transcripts.query_entities(
            "expires_at le @now", parameters={"now": now}
        ):
            try:
                await self.transcripts.delete_entity(entity["PartitionKey"], entity["RowKey"])
                count += 1
            except (ResourceNotFoundError, HttpResponseError):
                continue
        return count

