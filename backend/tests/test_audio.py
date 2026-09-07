import asyncio
import io
import subprocess
import wave
from unittest.mock import AsyncMock, Mock

import pytest

from voiceprompt.audio import to_speech_wav


@pytest.mark.asyncio
async def test_ios_m4a_is_converted_to_seekable_mono_pcm_wav(tmp_path):
    source = tmp_path / "source.wav"
    with wave.open(str(source), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(b"\x00\x00" * 16000)
    m4a = tmp_path / "chunk.m4a"
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(source), "-c:a", "aac", str(m4a)],
        check=True,
    )
    result = await to_speech_wav(m4a.read_bytes())
    with wave.open(io.BytesIO(result), "rb") as decoded:
        assert decoded.getnchannels() == 1
        assert decoded.getsampwidth() == 2
        assert decoded.getframerate() == 16000
        assert 16000 <= decoded.getnframes() < 17000
        assert decoded.getcomptype() == "NONE"


@pytest.mark.asyncio
async def test_invalid_audio_is_reported_instead_of_uploaded():
    with pytest.raises(ValueError, match="Audio conversion to WAV failed"):
        await to_speech_wav(b"not audio")


@pytest.mark.asyncio
@pytest.mark.parametrize("error", [asyncio.CancelledError, TimeoutError])
async def test_conversion_stops_child_process_on_cancellation_or_timeout(monkeypatch, error):
    process = Mock(returncode=None)
    process.communicate = AsyncMock(side_effect=error)
    process.wait = AsyncMock()
    spawn = AsyncMock(return_value=process)
    monkeypatch.setattr("voiceprompt.audio.asyncio.create_subprocess_exec", spawn)
    with pytest.raises(error):
        await to_speech_wav(b"audio")
    process.kill.assert_called_once_with()
    process.wait.assert_awaited_once_with()
