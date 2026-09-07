# Mission

Act as the principal engineer responsible for delivering this product end-to-end. Work autonomously in the current repository: investigate, design, implement, test, provision, deploy, and package the solution. Do not stop after planning or scaffolding, and do not ask me to choose routine technical details.

Use the existing product name if one exists; otherwise use **VoicePrompt** as a configurable working name.

# Product goal

Build a private voice-capture system for converting long spoken streams of thought into polished, copy-ready prompts:

1. A **native iOS app** records speech quickly and reliably.
2. A **Python cloud backend on Azure Container Apps** transcribes and lightly cleans the speech.
3. A **native macOS menu-bar app** automatically places the completed text in the clipboard and shows a notification.

Typical recordings last 10–20 minutes and are primarily in Czech, often containing English technical terminology. The final text will usually be pasted into GitHub Copilot or another AI agent.

# Required technology

- iOS: Swift, SwiftUI, AVFoundation, Swift Concurrency.
- macOS: native Swift/SwiftUI with AppKit where needed; use `MenuBarExtra` or an equivalent native menu-bar implementation.
- Do not use React Native, Flutter, Electron, Mac Catalyst, or a web wrapper.
- Share networking, authentication, persistence, and API models through a Swift package where practical.
- Backend: Python 3.12+, FastAPI, typed models, structured asynchronous processing.
- Infrastructure: follow existing repository conventions. If none exist, use Terraform.
- Azure access from workloads must use Managed Identity and least-privilege RBAC. Never use Azure service keys or connection strings.

# Autonomous working rules

Before changing code:

- Inspect repository instructions, current implementation, Git status, installed Xcode/toolchain, existing Azure configuration, and available Microsoft Foundry resources and model deployments.
- Reuse existing architecture and infrastructure conventions where sensible.
- If the repository is empty, create a coherent monorepo containing the Apple apps, shared Swift package, backend, infrastructure, tests, and documentation.
- Record important architecture decisions, but continue implementing without waiting for approval.
- Preserve unrelated user changes.

Continue through every unblocked task. Ask me only when a human-only external action is unavoidable, such as:

- Creating Google OAuth clients after bundle IDs and redirect values are known.
- Supplying an Apple Team ID, signing certificate, provisioning profile, device UDID, or APNs credential.
- Resolving an Azure authorization or policy blocker.
- Approving an infrastructure operation that would delete or replace existing resources or introduce unexpected fixed costs.

Complete all work that does not depend on the missing input before asking. When asking, provide the exact values and exact steps required in one concise request.

# User experience

## Native iOS app

The main screen must be extremely simple and fast, with two prominent recording controls:

1. **Hold to talk**: recording runs only while the control is held. Releasing or cancelling the gesture stops it.
2. **Start/Stop**: one tap starts continuous recording; another tap stops it.

Requirements:

- Recording must begin locally immediately and must never wait for Azure availability or authentication refresh.
- Continuous recording must remain active when the screen locks or the app moves to the background, using the supported iOS background-audio capability.
- Configure microphone permissions and all required entitlements correctly.
- Do not promise continued recording after the user force-quits the app or iOS terminates it.
- Support at least a 20-minute recording without loading the entire recording into memory.
- Show concise states such as ready, recording, uploading, processing, complete, offline, and error.
- On launch, warm the backend asynchronously and display its readiness, but never disable recording because the backend is cold or unreachable.
- Persist pending uploads and resume them after temporary network loss or app relaunch.
- Store credentials in Keychain and sensitive files using appropriate file protection.
- Provide accessible controls, Dynamic Type, VoiceOver labels, high contrast, and useful haptics.

## Native macOS app

Build a lightweight menu-bar application that normally runs without a Dock window.

Requirements:

- Monitor for completed transcriptions without keeping the Azure Container App continuously awake.
- When a new transcription completes:
  - Fetch it securely.
  - Copy it to `NSPasteboard` as plain-text Markdown.
  - Show a native notification without exposing the transcript contents.
  - Never copy the same transcription twice.
- If several transcriptions complete while the Mac is offline, synchronize all history but copy only the newest completion automatically.
- Provide an optional History/Settings window containing:
  - Transcriptions from the previous 48 hours.
  - Click-to-copy behavior.
  - Backend URL and connection status.
  - Google sign-in/sign-out.
  - Launch-at-login control using the supported macOS API.
- Prune local history automatically after 48 hours.
- Remain functional after sleep, wake, network changes, and backend cold starts.

For completion delivery, prefer **Azure Web PubSub in serverless mode**, with short-lived user-scoped client tokens issued by the authenticated API and Managed Identity used by the backend. This keeps macOS responsive without holding an Azure Container Apps connection open. If Web PubSub is prohibited by policy, use APNs. Do not replace event delivery with frequent polling; low-frequency reconciliation on launch, wake, and reconnect is acceptable.

## Visual design

Use a minimal native Apple design:

- Monochrome black, white, and gray foundation.
- One restrained orange accent color.
- Support light and dark appearance.
- Create a microphone-with-cloud visual identity.
- Use proper Apple asset catalogs; generate all required app-icon sizes.
- Use a monochrome template icon for the macOS menu bar.
- Avoid decorative complexity and unnecessary navigation.

# Recording and upload protocol

Implement a resilient session-based protocol:

1. Generate a client-side session UUID so recording also works offline.
2. Divide audio into configurable segments of approximately 30 seconds.
3. Use a speech-compatible compressed mono format.
4. Assign every segment a sequence number, timing metadata, byte length, and SHA-256 checksum.
5. Upload segments idempotently with bounded retries and exponential backoff.
6. The server must safely handle duplicate and out-of-order uploads.
7. A finalization request must include the expected segment count.
8. Never finalize a session until every expected segment has been processed successfully.
9. Preserve a failed session in a recoverable state and expose an actionable error instead of silently returning partial text.

Use a small overlap between segments only if it can be implemented without audio corruption or duplicated text. Otherwise use boundary-safe segmentation and transcription context from the previous segment. Add deterministic de-duplication during transcript assembly.

Suggested versioned API surface:

- `POST /v1/sessions`
- `PUT /v1/sessions/{sessionId}/chunks/{sequence}`
- `POST /v1/sessions/{sessionId}/complete`
- `GET /v1/sessions/{sessionId}`
- `GET /v1/transcripts`
- `GET /v1/transcripts/{transcriptId}`
- `DELETE /v1/transcripts/{transcriptId}`
- `GET /health/live`
- `GET /health/ready`

Commit an OpenAPI specification and keep the Swift client contract synchronized with it.

# Azure backend

Use a small, scale-to-zero architecture:

- An externally reachable, authenticated API Container App.
- A queue-triggered worker Container App or Container Apps Job that scales to zero.
- Azure Blob Storage for temporary audio segments.
- Azure Queue Storage for processing work.
- Azure Table Storage for session state and the short-lived transcript history.
- A scheduled cleanup job.
- Application Insights/OpenTelemetry for operational telemetry.

Queue messages must contain identifiers, not transcript or audio content. Processing must be idempotent and safe under at-least-once delivery.

The client-facing API must use HTTPS, validate ownership of every resource, enforce upload limits, validate content types and checksums, and apply reasonable rate limiting. Do not expose Blob SAS URLs to clients.

# Authentication and authorization

Use Google OpenID Connect for both Apple applications:

- OAuth 2.0 Authorization Code flow with PKCE through the system browser.
- Separate native client registrations where required.
- No embedded client secret.
- Store refresh credentials only in Keychain; do not treat long-lived access tokens as a solution.
- Validate issuer, audience, signature, subject, expiry, and nonce server-side.
- Make an allowed Google subject/email list configurable because this is initially a single-user application.
- Partition all cloud data by the validated stable Google subject.
- Never log tokens, audio, raw transcripts, or cleaned transcripts.

Once bundle IDs, callback schemes, and redirect values are final, give me the exact Google registration instructions. Continue using mocked development authentication until I provide the resulting client IDs.

# Azure networking and identity

The Azure environment enforces policies that prohibit public access to data services, especially Storage Accounts.

Implement the required networking completely:

- Integrate the Azure Container Apps environment with a VNet.
- Disable public network access and shared-key authorization on the Storage Account where supported.
- Create private endpoints for Blob, Queue, and Table services.
- Create and link the corresponding private DNS zones:
  - `privatelink.blob.core.windows.net`
  - `privatelink.queue.core.windows.net`
  - `privatelink.table.core.windows.net`
- Use separate appropriately delegated subnets for Container Apps and private endpoints.
- Apply equivalent private-access controls to Key Vault, ACR, and Microsoft Foundry where required by existing policy.
- Keep only the authenticated client API and the selected client-notification endpoint externally reachable.
- Use Managed Identity for Storage, Microsoft Foundry, Web PubSub, Key Vault, and ACR access.
- Assign only the minimum required data-plane roles.

Do not work around policy by temporarily enabling public Storage access.

Use existing Microsoft Foundry resources and deployments where possible. Do not provision a new model deployment without first proving that no suitable deployment exists.

# Transcription and cleanup

Begin transcription as segments arrive so most work is already complete when recording stops.

## Speech-to-text

- Czech transcription quality is the highest model-selection priority.
- Discover the speech-capable models actually available in the existing Microsoft Foundry environment.
- Evaluate the strongest suitable current model using a representative Czech technical-language fixture.
- Keep the deployment name configurable rather than hardcoding it.
- Preserve punctuation, numbers, product names, and mixed Czech/English terminology.
- Retry transient model failures safely without producing duplicate transcript segments.

## Language cleanup

After all segment transcripts are assembled, send the complete raw transcript through a configurable cleanup model.

Evaluate **GPT-5.6 Luna first** for cost and latency, then use **GPT-5.6 Terra** if Luna does not meet the quality threshold.

The cleanup system prompt must:

- Preserve the speaker’s complete intent, requirements, decisions, caveats, uncertainty, and technical details.
- Correct obvious transcription mistakes using context.
- Remove filler words, stuttering, accidental repetition, and abandoned formulations.
- Prefer the speaker’s later explicit correction when they revise an earlier statement.
- Never invent facts or silently resolve genuine ambiguity.
- Never turn the content into a short summary.
- Retain explicit negations, values, identifiers, code, URLs, and commands.
- Return only polished, copy-ready Markdown in the original spoken language.

Maintain a configurable technical glossary including terms such as Microsoft, Azure, GitHub, GitHub Copilot, Swift, SwiftUI, Xcode, SDK, API, AI, LLM, Python, Terraform, Container Apps, Managed Identity, Entra ID, Microsoft Foundry, iOS, and macOS.

# Retention and privacy

- Delete acknowledged iOS audio chunks as soon as they are durably accepted and no longer needed for retry.
- Delete cloud audio immediately after successful transcription and finalization.
- Delete intermediate raw transcript data after the cleaned result is produced.
- Retain cleaned transcripts in Azure and macOS for exactly 48 hours.
- Add a short Blob lifecycle policy as a safety net for abandoned temporary audio.
- Ensure cleanup is idempotent and covered by tests.
- Encrypt all traffic and rely on Azure encryption at rest.
- Do not include sensitive payloads in logs, traces, notifications, queue messages, or exception telemetry.

# Reliability and observability

Model the workflow explicitly with states such as:

`created -> recording -> uploading -> transcribing -> refining -> completed`

Include recoverable failure states and transitions.

Add:

- Correlation IDs and structured logs.
- Metrics for upload failures, queue delay, transcription latency, refinement latency, cleanup, and end-to-end completion.
- Health and readiness endpoints.
- Timeouts, cancellation, bounded retries, and poison-message handling.
- User-facing retry behavior with no silent data loss.
- Graceful handling of cold starts and network transitions.

# Testing

Design components for automated testing without requiring live microphone interaction.

Implement:

- Python unit tests for authentication, session state, idempotency, finalization, stitching, retention, and cleanup.
- Backend integration tests using Azurite and mocked Microsoft Foundry responses.
- API contract tests.
- A local end-to-end test that uploads segmented audio, processes it, and verifies the completed cleaned transcript.
- Swift unit tests for the recording state machine, segmentation metadata, upload queue, retries, persistence, authentication abstraction, event handling, history pruning, and duplicate prevention.
- iOS UI tests using an injected audio source rather than a physical microphone.
- macOS tests using injectable clipboard and notification abstractions.
- Build validation for both iOS Simulator and native macOS.
- Cloud smoke tests after deployment.
- CI workflows where the repository supports them.

Use the installed Xcode toolchain and iOS Simulator. Install only genuinely required tooling. Do not claim that simulator tests prove lock-screen/background microphone behavior; reserve that final validation for a real iPhone.

# Infrastructure and deployment

Infrastructure must be reproducible and non-destructive:

- Use the smallest practical consumption/serverless SKUs.
- Reuse suitable existing Azure resources.
- Run and inspect an infrastructure plan before applying it.
- You are authorized to apply app-specific, non-destructive, low-cost resources.
- Stop before deleting/replacing existing resources or creating unexpected fixed-cost services.
- Automate image build, deployment, RBAC, configuration, migrations, and smoke tests.
- Keep secrets out of source control and generated artifacts.
- Provide example configuration files containing placeholders only.

# Packaging

This product will not be distributed through the App Store or Mac App Store.

For iOS:

- Produce an Xcode archive and development/ad-hoc `.ipa` when signing assets allow it.
- Support direct installation through Xcode or Apple-supported ad-hoc provisioning.
- Explain any device-registration, certificate, expiration, or provisioning constraints accurately.
- Do not suggest that an unsigned IPA can simply be installed.

For macOS:

- Produce a local `.app` and a `.dmg` or `.pkg`.
- Sign and notarize when the required Developer ID credentials are available.
- Keep local development builds usable when those credentials have not yet been supplied.

# Definition of done

Do not declare completion until all of the following are true:

- iOS recording begins without waiting for the network.
- Start/Stop recording continues while the device is locked during a real-device test.
- A 20-minute segmented session can upload and finalize without missing or duplicated content.
- Backend cold starts do not cause recording loss.
- Czech transcription and cleanup preserve technical meaning and detailed requirements.
- The macOS menu-bar app receives completion, copies it exactly once, and shows a notification without opening a window.
- Offline recovery works on both clients.
- Audio is deleted after processing and text expires after 48 hours.
- Storage has no public access and all Azure service access uses Managed Identity.
- Automated tests and builds pass.
- Azure deployment and smoke tests succeed.
- Installable Apple artifacts or the maximum artifacts possible before signing are produced.
- Remaining user actions are limited to unavoidable Google/Apple registration or final physical-device validation.

At the end, report only the implemented outcome, important architecture decisions, deployed resource names and endpoints without secrets, artifact locations, and any exact remaining human-only steps.
