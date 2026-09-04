from functools import lru_cache

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="VOICEPROMPT_", env_file=".env")

    environment: str = "production"
    storage_account_name: str = ""
    storage_endpoint_suffix: str = "core.windows.net"
    sessions_table: str = "sessions"
    transcripts_table: str = "transcripts"
    transcript_expiry_table: str = "transcriptexpiry"
    chunks_container: str = "audio"
    work_queue: str = "voice-work"
    poison_queue: str = "voice-work-poison"
    google_audiences: list[str] = Field(default_factory=list)
    allowed_google_subjects: set[str] = Field(default_factory=set)
    allowed_google_emails: set[str] = Field(default_factory=set)
    require_oidc_nonce: bool = True
    allow_development_auth: bool = False
    max_chunk_bytes: int = 8 * 1024 * 1024
    max_segments: int = 120
    transcript_ttl_hours: int = 48
    foundry_endpoint: str = ""
    speech_deployment: str = ""
    cleanup_deployment: str = "gpt-5.6-luna"
    foundry_api_version: str = "2025-04-01-preview"
    web_pubsub_endpoint: str = ""
    web_pubsub_hub: str = "voiceprompt"
    technical_glossary: list[str] = Field(
        default_factory=lambda: [
            "Microsoft", "Azure", "GitHub", "GitHub Copilot", "Swift", "SwiftUI",
            "Xcode", "SDK", "API", "AI", "LLM", "Python", "Terraform",
            "Container Apps", "Managed Identity", "Entra ID", "Microsoft Foundry",
            "iOS", "macOS",
        ]
    )

    @field_validator("google_audiences", mode="before")
    @classmethod
    def split_csv(cls, value: object) -> object:
        return value.split(",") if isinstance(value, str) else value

    @field_validator("allowed_google_subjects", "allowed_google_emails", mode="before")
    @classmethod
    def split_set(cls, value: object) -> object:
        return {part.strip() for part in value.split(",") if part.strip()} if isinstance(value, str) else value

    @property
    def use_memory_store(self) -> bool:
        return self.environment in {"test", "development"} and not self.storage_account_name

    @model_validator(mode="after")
    def development_auth_is_never_production(self) -> "Settings":
        if self.environment == "production" and self.allow_development_auth:
            raise ValueError("Development authentication cannot be enabled in production")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
