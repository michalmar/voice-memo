import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory


async def to_speech_wav(audio: bytes) -> bytes:
    """Convert iOS AAC/M4A chunks to the PCM WAV input supported by MAI Speech."""
    with TemporaryDirectory(prefix="voiceprompt-audio-") as directory:
        source = Path(directory) / "input.m4a"
        destination = Path(directory) / "output.wav"
        source.write_bytes(audio)
        process = await asyncio.create_subprocess_exec(
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-protocol_whitelist", "file,pipe", "-i", str(source),
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", str(destination),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            async with asyncio.timeout(30):
                await process.communicate()
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()
        if process.returncode != 0:
            raise ValueError(f"Audio conversion to WAV failed (ffmpeg exit {process.returncode})")
        return destination.read_bytes()
