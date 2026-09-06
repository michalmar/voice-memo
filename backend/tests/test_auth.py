from datetime import UTC, datetime, timedelta

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import HTTPException

from voiceprompt.auth import EntraTokenValidator
from voiceprompt.config import Settings


@pytest.mark.asyncio
async def test_entra_token_checks_tenant_scope_and_allow_list(monkeypatch):
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    validator = EntraTokenValidator()

    async def key(_, __):
        return private.public_key()

    monkeypatch.setattr(validator, "_key", key)
    now = datetime.now(UTC)
    token = jwt.encode(
        {
            "iss": "https://login.microsoftonline.com/tenant-id/v2.0",
            "aud": "api://voiceprompt",
            "sub": "pairwise-subject",
            "tid": "tenant-id",
            "oid": "allowed-object-id",
            "scp": "VoicePrompt.Access",
            "iat": now,
            "exp": now + timedelta(minutes=5),
        },
        private,
        algorithm="RS256",
        headers={"kid": "test"},
    )
    settings = Settings(
        environment="test",
        entra_tenant_id="tenant-id",
        entra_audience="api://voiceprompt",
        allowed_entra_object_ids={"allowed-object-id"},
    )
    principal = await validator.validate(token, settings)
    assert principal.subject == "tenant-id:allowed-object-id"
    settings.entra_required_scope = "Missing.Scope"
    with pytest.raises(HTTPException):
        await validator.validate(token, settings)


@pytest.mark.asyncio
async def test_entra_token_rejects_hmac_algorithm():
    token = jwt.encode(
        {"sub": "forged"},
        "attacker-controlled-secret-32-bytes!",
        algorithm="HS256",
        headers={"kid": "test"},
    )
    with pytest.raises(HTTPException):
        await EntraTokenValidator().validate(
            token,
            Settings(
                environment="test",
                entra_tenant_id="tenant-id",
                entra_audience="api-client-id",
            ),
        )
