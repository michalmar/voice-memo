import asyncio
from datetime import UTC, datetime

from .app import app


async def run() -> None:
    deleted = await app.state.repository.cleanup(datetime.now(UTC))
    print({"event": "retention_cleanup", "deleted_count": deleted})


if __name__ == "__main__":
    asyncio.run(run())

