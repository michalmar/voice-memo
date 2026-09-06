# VoicePrompt

VoicePrompt privately converts long Czech/mixed-English voice notes into polished,
copy-ready Markdown. The monorepo contains native iOS and macOS apps, a shared
Swift package, a FastAPI backend, and private Azure infrastructure.

## Layout

- `Apple/VoicePromptIOS` — immediate local recording, 30-second AAC/M4A segments,
  resilient upload queue, background-audio capability, hold-to-talk and start/stop UI.
- `Apple/VoicePromptMac` — Dockless menu-bar app, Web PubSub completion listener,
  exactly-once clipboard delivery, native notification, and 48-hour history.
- `Packages/VoicePromptKit` — versioned models, API client, Keychain storage, retries,
  and durable upload metadata.
- `backend` — authenticated FastAPI API, idempotent worker, retention job, Foundry
  speech/refinement client, and Managed Identity Azure adapters.
- `infrastructure` — Terraform for VNet-integrated Container Apps, private Storage,
  private DNS, Managed Identity/RBAC, Web PubSub, and telemetry.
- `api/openapi.json` — committed API contract.

## Local validation

```bash
python3 -m venv .venv
.venv/bin/pip install -e 'backend[test]'
.venv/bin/pytest backend/tests
.venv/bin/python scripts/export-openapi.py
(cd Packages/VoicePromptKit && swift test)
docker build -t voiceprompt:local backend
```

On macOS, install XcodeGen, run `make apple-project`, then build the iOS simulator
and macOS schemes in `Apple/VoicePrompt.xcodeproj`.

Development authentication is disabled by default. For local-only API work, copy
`backend/.env.example`, leave Azure resource fields empty, and explicitly set
`VOICEPROMPT_ALLOW_DEVELOPMENT_AUTH=true`; a development credential prefixed with
`dev:` is then accepted. Never enable this setting in a deployed environment.

See `docs/architecture.md`, `docs/configuration.md`, and `docs/validation.md`.
