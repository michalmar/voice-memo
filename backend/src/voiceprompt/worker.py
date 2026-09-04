import asyncio
import base64
import json

from azure.identity.aio import DefaultAzureCredential
from azure.storage.queue.aio import QueueServiceClient

from .config import get_settings
from .processing import FoundryClient, Processor
from .runtime import create_notifier, create_repository


async def run() -> None:
    settings = get_settings()
    credential = DefaultAzureCredential()
    repository = create_repository(settings)
    foundry = FoundryClient(settings, credential)
    processor = Processor(repository, settings, foundry, foundry, create_notifier(settings))
    queue_service = QueueServiceClient(
        f"https://{settings.storage_account_name}.queue.{settings.storage_endpoint_suffix}",
        credential=credential,
    )
    queue = queue_service.get_queue_client(settings.work_queue)
    poison = queue_service.get_queue_client(settings.poison_queue)
    while True:
        found = False
        async for message in queue.receive_messages(messages_per_page=8, visibility_timeout=300):
            found = True
            payload = json.loads(base64.b64decode(message.content))
            try:
                await processor.process_safely(payload)
                await queue.delete_message(message.id, message.pop_receipt)
            except Exception:
                if message.dequeue_count >= 5:
                    await poison.send_message(message.content)
                    await queue.delete_message(message.id, message.pop_receipt)
        if not found:
            await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(run())
