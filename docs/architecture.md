# Architecture decisions

## Capture and delivery

Recording is a local-first operation. The iOS app creates a UUID and starts
`AVAudioRecorder` before it performs any API call. AAC-LC mono audio at 16 kHz and
48 kbit/s is rotated into boundary-safe 30-second M4A files. Each file is hashed
and persisted independently, so a 20-minute note never needs to reside in memory.
The queue deletes a local file only after the API acknowledges its idempotent PUT.

Completion uses Azure Web PubSub serverless delivery. The API issues ten-minute,
user-scoped WebSocket URLs; the worker sends only the transcript identifier to the
validated Entra tenant/object identity. The Mac performs low-frequency reconciliation on launch,
wake, and reconnect. It fetches every missed item but automatically copies only
the newest unseen completion.

## State and processing

The explicit state path is `created -> uploading -> transcribing -> refining ->
completed`, with `failed` preserving an actionable error code. Blob names and
Table partitions contain a one-way subject hash. Queue messages contain only owner,
session, sequence, and work kind identifiers.

Transcription starts as each segment arrives. Segment text is idempotently stored,
the audio Blob is then deleted, and finalization waits for every sequence. Assembly
removes deterministic boundary overlap. The full raw text is refined once and
deleted immediately after the cleaned transcript is durable. Transcript expiry is
enforced by hourly cleanup at 48 hours; a one-day Blob lifecycle rule is a safety
net for abandoned audio.

## Identity and network

Clients use Microsoft Entra ID Authorization Code with PKCE through the system
browser. They request a delegated API scope and keep refresh credentials in
Keychain. The backend accepts Entra access tokens only after signature, exact
tenant, issuer, audience, expiry, object ID, delegated scope, and allow-list
validation. Resource ownership is checked on every operation.

Azure workloads use a user-assigned Managed Identity. Storage shared-key access and
public networking are disabled. Blob, Queue, and Table use private endpoints and
linked private DNS zones inside the Container Apps VNet. Web PubSub remains public
only as the selected authenticated client-notification endpoint and has local auth
disabled. RBAC grants only Storage Blob/Queue/Table Data Contributor, Web PubSub
Service Owner, and Cognitive Services User.

Microsoft Foundry deployments are external inputs so Terraform cannot accidentally
create a model deployment. The speech deployment must be selected after evaluating
available speech-capable models against the Czech fixture. Cleanup defaults to the
existing `gpt-5.6-luna` deployment and should be changed to Terra only if the
quality gate fails.
