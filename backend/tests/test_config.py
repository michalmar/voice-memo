import pytest
from pydantic import ValidationError

from voiceprompt.config import Settings


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("", set()),
        ("user-a", {"user-a"}),
        (" user-a, user-b, user-a, ", {"user-a", "user-b"}),
        ('["user-a", "user-b"]', {"user-a", "user-b"}),
        ("[]", set()),
    ],
)
def test_allowlist_environment_accepts_csv_and_json(monkeypatch, value, expected):
    monkeypatch.setenv("VOICEPROMPT_ALLOWED_ENTRA_OBJECT_IDS", value)
    assert Settings(_env_file=None).allowed_entra_object_ids == expected


def test_allowlist_accepts_explicit_set():
    assert Settings(allowed_entra_object_ids={"user-a"}).allowed_entra_object_ids == {"user-a"}


def test_allowlist_rejects_malformed_json(monkeypatch):
    monkeypatch.setenv("VOICEPROMPT_ALLOWED_ENTRA_OBJECT_IDS", '["user-a"')
    with pytest.raises(ValidationError):
        Settings(_env_file=None)


@pytest.mark.parametrize("hours", [0, -1, 1.5])
def test_transcript_retention_requires_positive_whole_hours(hours):
    with pytest.raises(ValidationError):
        Settings(transcript_ttl_hours=hours)


def test_transcript_storage_configuration(monkeypatch):
    monkeypatch.setenv("VOICEPROMPT_TRANSCRIPTS_CONTAINER", "private-transcripts")
    monkeypatch.setenv("VOICEPROMPT_TRANSCRIPT_TTL_HOURS", "72")
    settings = Settings(_env_file=None)
    assert settings.transcripts_container == "private-transcripts"
    assert settings.transcript_ttl_hours == 72
