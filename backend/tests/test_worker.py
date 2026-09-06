import asyncio
import base64
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest
from azure.storage.queue.aio import QueueClient

from voiceprompt.processing import Processor
from voiceprompt.worker import drain_queue


@pytest.mark.asyncio
@pytest.mark.parametrize("attempt,fails", [(None, False), (1, False), (1, True), (5, True)])
async def test_worker_drains_queue_and_exits(attempt, fails):
    queue = MagicMock(spec=QueueClient)
    poison = MagicMock(spec=QueueClient)
    processor = AsyncMock(spec=Processor)
    if fails:
        processor.process_safely.side_effect = RuntimeError("synthetic failure")
    payload = {"kind": "transcribe", "owner": "test-owner"}
    message = SimpleNamespace(
        id="test-message",
        pop_receipt="receipt",
        content=base64.b64encode(json.dumps(payload).encode()).decode(),
        dequeue_count=attempt,
    )
    receives = 0

    async def receive(**kwargs):
        nonlocal receives
        receives += 1
        if receives == 1 and attempt is not None:
            yield message

    queue.receive_messages.side_effect = receive
    await asyncio.wait_for(drain_queue(queue, poison, processor), timeout=1)

    assert receives == (1 if attempt is None else 2)
    if attempt is None:
        processor.process_safely.assert_not_awaited()
    else:
        processor.process_safely.assert_awaited_once_with(payload)
    if attempt is not None and (not fails or attempt >= 5):
        queue.delete_message.assert_awaited_once_with("test-message", "receipt")
    else:
        queue.delete_message.assert_not_awaited()
    if fails and attempt >= 5:
        poison.send_message.assert_awaited_once_with(message.content)
    else:
        poison.send_message.assert_not_awaited()
