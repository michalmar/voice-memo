from datetime import UTC, datetime, timedelta

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import HTTPException

from voiceprompt.auth import GoogleTokenValidator
from voiceprompt.config import Settings


@pytest.mark.asyncio
async def test_google_token_checks_nonce_and_allow_list(monkeypatch):
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    validator = GoogleTokenValidator()

    async def key(_):
        return private.public_key()

    monkeypatch.setattr(validator, "_key", key)
    now = datetime.now(UTC)
    token = jwt.encode(
        {
            "iss": "https://accounts.google.com",
            "aud": "client-id",
            "sub": "allowed-user",
            "email": "me@example.com",
            "nonce": "nonce-value",
            "iat": now,
            "exp": now + timedelta(minutes=5),
        },
        private,
        algorithm="RS256",
        headers={"kid": "test"},
    )
    settings = Settings(
        environment="test",
        google_audiences=["client-id"],
        allowed_google_subjects={"allowed-user"},
    )
    assert (await validator.validate(token, "nonce-value", settings)).subject == "allowed-user"
    with pytest.raises(HTTPException):
        await validator.validate(token, "wrong", settings)
