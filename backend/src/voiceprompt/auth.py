import asyncio
from dataclasses import dataclass
from time import monotonic

import httpx
import jwt
from fastapi import Depends, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import Settings, get_settings

GOOGLE_ISSUERS = {"https://accounts.google.com", "accounts.google.com"}
GOOGLE_JWKS = "https://www.googleapis.com/oauth2/v3/certs"


@dataclass(frozen=True)
class Principal:
    subject: str
    email: str | None = None


class GoogleTokenValidator:
    def __init__(self) -> None:
        self._keys: dict[str, object] = {}
        self._expires = 0.0
        self._lock = asyncio.Lock()

    async def _key(self, key_id: str) -> object:
        if monotonic() >= self._expires or key_id not in self._keys:
            async with self._lock:
                if monotonic() >= self._expires or key_id not in self._keys:
                    async with httpx.AsyncClient(timeout=5) as client:
                        response = await client.get(GOOGLE_JWKS)
                        response.raise_for_status()
                    self._keys = {
                        item["kid"]: jwt.PyJWK.from_dict(item).key
                        for item in response.json()["keys"]
                    }
                    self._expires = monotonic() + 3600
        if key_id not in self._keys:
            raise ValueError("Unknown signing key")
        return self._keys[key_id]

    async def validate(self, token: str, nonce: str | None, settings: Settings) -> Principal:
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str):
                raise ValueError("Invalid signing algorithm")
            claims = jwt.decode(
                token,
                await self._key(header["kid"]),
                algorithms=["RS256"],
                audience=settings.google_audiences,
                issuer=list(GOOGLE_ISSUERS),
                options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            )
            if settings.require_oidc_nonce and (
                not nonce or claims.get("nonce") != nonce
            ):
                raise ValueError("Invalid nonce")
            subject = claims["sub"]
            email = claims.get("email")
            if settings.allowed_google_subjects or settings.allowed_google_emails:
                if subject not in settings.allowed_google_subjects and email not in settings.allowed_google_emails:
                    raise ValueError("User is not allowed")
            return Principal(subject=subject, email=email)
        except (jwt.PyJWTError, httpx.HTTPError, KeyError, ValueError) as exc:
            raise HTTPException(status_code=401, detail="Invalid identity token") from exc


_bearer = HTTPBearer(auto_error=False)
_validator = GoogleTokenValidator()


async def current_principal(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    nonce: str | None = Header(default=None, alias="X-OIDC-Nonce"),
    settings: Settings = Depends(get_settings),
) -> Principal:
    if settings.allow_development_auth and credentials and credentials.credentials.startswith("dev:"):
        return Principal(subject=credentials.credentials.removeprefix("dev:"))
    if not credentials or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="Authentication required")
    if not settings.google_audiences:
        raise HTTPException(status_code=503, detail="Authentication is not configured")
    return await _validator.validate(credentials.credentials, nonce, settings)

