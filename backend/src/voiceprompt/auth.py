import asyncio
from dataclasses import dataclass
from time import monotonic

import httpx
import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import Settings, get_settings


@dataclass(frozen=True)
class Principal:
    subject: str
    tenant_id: str


class EntraTokenValidator:
    def __init__(self) -> None:
        self._keys: dict[str, object] = {}
        self._expires = 0.0
        self._lock = asyncio.Lock()

    async def _key(self, key_id: str, tenant_id: str) -> object:
        if monotonic() >= self._expires or key_id not in self._keys:
            async with self._lock:
                if monotonic() >= self._expires or key_id not in self._keys:
                    async with httpx.AsyncClient(timeout=5) as client:
                        response = await client.get(
                            f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"
                        )
                        response.raise_for_status()
                    self._keys = {
                        item["kid"]: jwt.PyJWK.from_dict(item).key
                        for item in response.json()["keys"]
                    }
                    self._expires = monotonic() + 3600
        if key_id not in self._keys:
            raise ValueError("Unknown signing key")
        return self._keys[key_id]

    async def validate(self, token: str, settings: Settings) -> Principal:
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str):
                raise ValueError("Invalid signing algorithm")
            issuer = f"https://login.microsoftonline.com/{settings.entra_tenant_id}/v2.0"
            claims = jwt.decode(
                token,
                await self._key(header["kid"], settings.entra_tenant_id),
                algorithms=["RS256"],
                audience=settings.entra_audience,
                issuer=issuer,
                options={"require": ["exp", "iat", "iss", "aud", "sub", "tid", "oid", "scp"]},
            )
            tenant_id = claims["tid"]
            object_id = claims["oid"]
            if tenant_id != settings.entra_tenant_id:
                raise ValueError("Invalid tenant")
            scopes = set(str(claims["scp"]).split())
            if settings.entra_required_scope not in scopes:
                raise ValueError("Required scope is missing")
            if settings.allowed_entra_object_ids and object_id not in settings.allowed_entra_object_ids:
                raise ValueError("User is not allowed")
            return Principal(subject=f"{tenant_id}:{object_id}", tenant_id=tenant_id)
        except (jwt.PyJWTError, httpx.HTTPError, KeyError, ValueError) as exc:
            raise HTTPException(status_code=401, detail="Invalid access token") from exc


_bearer = HTTPBearer(auto_error=False)
_validator = EntraTokenValidator()


async def current_principal(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    settings: Settings = Depends(get_settings),
) -> Principal:
    if settings.allow_development_auth and credentials and credentials.credentials.startswith("dev:"):
        return Principal(subject=credentials.credentials.removeprefix("dev:"), tenant_id="development")
    if not credentials or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="Authentication required")
    if not settings.entra_tenant_id or not settings.entra_audience:
        raise HTTPException(status_code=503, detail="Authentication is not configured")
    return await _validator.validate(credentials.credentials, settings)
