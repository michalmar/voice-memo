from datetime import UTC, datetime, timedelta

from azure.identity.aio import DefaultAzureCredential
from azure.messaging.webpubsubservice.aio import WebPubSubServiceClient

from .azure_repository import AzureRepository
from .config import Settings
from .models import PubSubToken
from .repository import MemoryRepository, Repository


def create_repository(settings: Settings) -> Repository:
    if settings.use_memory_store:
        return MemoryRepository()
    if not settings.storage_account_name:
        raise RuntimeError("VOICEPROMPT_STORAGE_ACCOUNT_NAME is required")
    return AzureRepository(settings, DefaultAzureCredential())


def create_event_issuer(settings: Settings):
    if not settings.web_pubsub_endpoint:
        return None
    credential = DefaultAzureCredential()
    client = WebPubSubServiceClient(
        endpoint=settings.web_pubsub_endpoint,
        hub=settings.web_pubsub_hub,
        credential=credential,
    )

    async def issue(owner: str) -> PubSubToken:
        expires = datetime.now(UTC) + timedelta(minutes=10)
        token = await client.get_client_access_token(
            user_id=owner,
            roles=[f"webpubsub.joinLeaveGroup.{owner}", f"webpubsub.sendToGroup.{owner}"],
            minutes_to_expire=10,
        )
        return PubSubToken(url=token["url"], expires_at=expires)

    return issue


def create_notifier(settings: Settings):
    if not settings.web_pubsub_endpoint:
        return None
    client = WebPubSubServiceClient(
        endpoint=settings.web_pubsub_endpoint,
        hub=settings.web_pubsub_hub,
        credential=DefaultAzureCredential(),
    )

    async def notify(owner: str, transcript_id) -> None:
        await client.send_to_user(
            user_id=owner,
            message={"type": "transcript.completed", "transcript_id": str(transcript_id)},
            content_type="application/json",
        )

    return notify

