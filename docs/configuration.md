# Configuration and registration

## Microsoft Entra ID

Use one single-tenant API registration and separate public-client registrations for
iOS and macOS. No client secret is used by either native application.

1. In **Microsoft Entra admin center > App registrations**, register
   `VoicePrompt API` for accounts in this organizational directory only.
2. Under **Expose an API**, accept the Application ID URI
   `api://<api-application-client-id>` and add delegated scope
   `VoicePrompt.Access`. In the app manifest, set `requestedAccessTokenVersion` to
   `2`. Admin consent is recommended for this private application.
3. Register `VoicePrompt iOS` as a public client. Add the mobile/desktop redirect
   URI `msauth.com.michalmar.voiceprompt.ios://auth`, enable public client flows,
   and grant delegated `VoicePrompt.Access` permission to `VoicePrompt API`.
4. Register `VoicePrompt macOS` as a public client. Add redirect URI
   `msauth.com.michalmar.voiceprompt.macos://auth`, enable public client flows,
   and grant the same delegated API permission.
5. Record the tenant ID, API application client ID, iOS client ID, macOS client ID,
   and the intended user's Entra **Object ID**. Grant tenant admin consent.
6. Configure Terraform:
   - `entra_tenant_id = "<tenant-id>"`
   - `entra_audience = "<api-application-client-id>"`
   - `entra_required_scope = "VoicePrompt.Access"`
   - `allowed_entra_object_ids = ["<user-object-id>"]`
7. Copy `Apple/Configuration.xcconfig.example` to an ignored local configuration,
   fill `ENTRA_TENANT_ID`,
   `ENTRA_API_SCOPE = api:/$()/<api-application-client-id>/VoicePrompt.Access`,
   `ENTRA_IOS_CLIENT_ID`, and `ENTRA_MAC_CLIENT_ID`, then apply those build settings
   to both generated Xcode targets. The checked-in `Apple/project.yml` already
   selects `Configuration.xcconfig` for Debug and Release in both targets.

In `.xcconfig` files, `//` starts a comment, even inside quoted values. The empty
`$()` expansion above preserves the full `api://...` scope. Use the same pattern
for HTTPS URLs. Do not add empty Entra settings to the targets in `project.yml`:
target settings override the values from the configuration file.

The clients use Authorization Code with PKCE in `ASWebAuthenticationSession`.
Refresh tokens are device-only Keychain items. The backend partitions ownership by
the validated `<tenant-id>:<object-id>` pair and requires the delegated scope.
When admitting another account, append its Object ID to `allowed_entra_object_ids`
without removing existing users, then deploy the updated allowlist. Successful
Microsoft sign-in alone does not grant API access. App users do not need Azure
Contributor, storage access, or directory administrator roles. Sign in with the
**same Microsoft account on iPhone and Mac** to synchronize that account's records;
allowing a second account does not share or merge either account's history.

## iOS transcripts

The Record tab displays the final cleaned-up Markdown after cloud processing.
Select text, use **Copy** for the entire transcript, or use **Share** to send it
to another app. The **History** tab lists the signed-in account's transcripts,
newest first; tap a record to open it. Pull to refresh or use the refresh button.
History also refreshes when the app returns to the foreground.
**Delete**, beside Share, immediately deletes the cloud transcript without a
confirmation dialog, matching the Mac app. Failed deletions display an error and
can be retried. This removes the record from both devices after syncing, but does
not remove text already copied or shared.

This uses the same authenticated transcript endpoints as the Mac app, with no
backend changes. Cloud history expires after 48 hours. The iOS app only keeps
downloaded text in memory and clears it on sign-out; copy or share anything you
want to retain. Records deleted on the Mac disappear from iOS after refreshing.

## Azure and Foundry

Authenticate Azure CLI and identify the existing Foundry resource. Transcription
uses **MAI-Transcribe-2** through the Speech fast transcription REST API. Markdown
cleanup remains on the existing `cleanup_deployment` (default `gpt-5.6-luna`).

The guide assumes those model deployments already exist; their names are not a
guarantee of availability in your subscription. If no Foundry resource exists,
select a supported region and available models before provisioning. A model
available in an editor or Copilot is not automatically an Azure deployment.

Set `foundry_endpoint` to the account's Azure OpenAI endpoint, such as
`https://<account>.openai.azure.com`, not the Foundry project URL ending in
`/api/projects/<project>`. Set `foundry_resource_id` to the parent account's Azure
resource ID, not the project ID. This endpoint is used only for Markdown cleanup.

Set `speech_endpoint` to the **same resource's custom Speech subdomain**, such as
`https://<account>.cognitiveservices.azure.com`, and `speech_model` to
`MAI-Transcribe-2`. This is a Speech model identifier, not an OpenAI deployment
name. The worker posts multipart `audio` and JSON `definition` fields to
`/speechtotext/transcriptions:transcribe?api-version=2025-10-15`, with
`enhancedMode.enabled=true` and `enhancedMode.model=MAI-Transcribe-2`.
`speech_api_version` controls this version separately from cleanup's OpenAI API.

The worker's user-assigned managed identity (selected by `AZURE_CLIENT_ID`) needs
**Cognitive Services Speech User** at `foundry_resource_id`. Terraform grants this
in addition to **Cognitive Services OpenAI User**, which remains necessary for
cleanup but does not authorize Speech transcription. Requests use a raw
`Authorization: Bearer <token>` header with the token scope
`https://cognitiveservices.azure.com/.default`. No Speech keys, client secrets,
or `aad#resource-id#token` SDK wrapper are used.

iOS continues uploading AAC/M4A. The worker converts each segment to 16 kHz mono
PCM WAV using FFmpeg because the MAI-specific documentation lists WAV, MP3, and
FLAC inputs. Conversion uses temporary files that are removed afterward and a
30-second deadline. The backend image includes FFmpeg; install it locally when
running the worker or audio tests outside Docker. Transcription uses **automatic
language identification**: the Speech request omits `locales`, even when an older
Apple app sends the default `cs-CZ` session metadata. The technical glossary becomes
`phraseList.phrases`. MAI uses verbatim output so the unchanged Markdown cleanup
step preserves intent. The old OpenAI previous-segment prompt has no equivalent
in this Speech request and is not sent. Full text comes from
`combinedPhrases[].text`, not the duplicated per-segment `phrases` array.

**Migration:** replace `speech_deployment` / `VOICEPROMPT_SPEECH_DEPLOYMENT` with
`speech_endpoint` / `VOICEPROMPT_SPEECH_ENDPOINT`, and optionally set
`speech_model` / `VOICEPROMPT_SPEECH_MODEL` and
`speech_api_version` / `VOICEPROMPT_SPEECH_API_VERSION` to override their defaults.
Rebuild and deploy the worker image. `worker_container_image` can pin a worker-only
immutable image without restarting the API or retention-cleanup job; when null it
uses the shared `container_image`. Apple apps do not need rebuilding.

MAI-Transcribe-2 is **public preview**, without a production SLA. Check the current
[MAI instructions](https://learn.microsoft.com/azure/ai-services/speech-service/mai-transcribe?pivots=programming-language-rest),
[Speech RBAC guidance](https://learn.microsoft.com/azure/ai-services/speech-service/role-based-access-control),
and [region table](https://learn.microsoft.com/azure/ai-services/speech-service/regions?tabs=llmspeech).
As of September 7, 2026, the table did not list Sweden Central for MAI, but a live
managed-identity request explicitly selecting MAI-Transcribe-2 succeeded on this
deployment's existing `demo-swe` account. Validate availability on the actual
resource before switching a worker; do not infer it from ordinary Fast
Transcription region support.

### Managed-identity sample call

Run this on an Azure host with the workload identity attached, using a sample
WAV file. `AZURE_CLIENT_ID` selects the user-assigned identity and
`VOICEPROMPT_SPEECH_ENDPOINT` must contain the resource's custom Speech endpoint.
Managed identity is not available directly on a local Mac.

```python
import asyncio
import json
import os
from pathlib import Path

import httpx
from azure.identity.aio import ManagedIdentityCredential

async def main():
    async with ManagedIdentityCredential(client_id=os.environ["AZURE_CLIENT_ID"]) as credential:
        token = await credential.get_token("https://cognitiveservices.azure.com/.default")
        endpoint = os.environ["VOICEPROMPT_SPEECH_ENDPOINT"].rstrip("/")
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.post(
                f"{endpoint}/speechtotext/transcriptions:transcribe",
                params={"api-version": "2025-10-15"},
                headers={"Authorization": "Bearer " + token.token},
                files={
                    "audio": ("sample.wav", Path("sample.wav").read_bytes(), "audio/wav"),
                    "definition": (None, json.dumps({
                        "enhancedMode": {"enabled": True, "model": "MAI-Transcribe-2"},
                    }), "application/json"),
                },
            )
            response.raise_for_status()
            print(" ".join(item["text"] for item in response.json()["combinedPhrases"]))

asyncio.run(main())
```

Cleanup requests omit `temperature` by default because GPT-5.6 Luna rejects a
zero-temperature override. For a model supporting sampling controls, optionally
set Terraform's `cleanup_temperature` (or `VOICEPROMPT_CLEANUP_TEMPERATURE` when
running locally) to a value from 0 to 2. Leave it unset for Luna.

Copy `infrastructure/terraform.tfvars.example` to the ignored
`infrastructure/terraform.tfvars` and fill the subscription, region, identity, and
Foundry values. The deploying account needs Azure resource/RBAC permissions;
Entra Global Administrator alone does not grant subscription access.

The configuration includes a Basic private container registry with its admin
account disabled. For the first deployment, bootstrap only the registry and its
pull identity before publishing the backend image:

```bash
terraform -chdir=infrastructure init
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan \
  -var='container_image=bootstrap-only-not-used' \
  -target=azurerm_role_assignment.registry \
  -out=/tmp/voiceprompt-registry.tfplan
terraform -chdir=infrastructure show /tmp/voiceprompt-registry.tfplan
terraform -chdir=infrastructure apply /tmp/voiceprompt-registry.tfplan
```

This targeted bootstrap is a one-time exception: it creates only the registry,
workload identity, pull role, and their resource-group/naming dependencies. The
temporary image value must never be used for a full deployment.

Build and publish an AMD64 image, then use its immutable digest as
`container_image` in `terraform.tfvars`:

```bash
ACR_LOGIN_SERVER=$(terraform -chdir=infrastructure output -raw registry_login_server)
ACR_NAME=${ACR_LOGIN_SERVER%%.*}
az acr login --name "$ACR_NAME" --resource-group rg-voiceprompt-prod
docker build --platform linux/amd64 -t "$ACR_LOGIN_SERVER/voiceprompt:setup" backend
docker push "$ACR_LOGIN_SERVER/voiceprompt:setup"
az acr repository show --name "$ACR_NAME" --resource-group rg-voiceprompt-prod \
  --image voiceprompt:setup --query digest -o tsv
```

Use `<registry-login-server>/voiceprompt@sha256:<digest>`, not a mutable tag. If the
build needs an organization package mirror, pass a pip configuration file as a
BuildKit secret: `--secret id=pip_config,src=/path/to/pip.conf`. A custom CA can be
passed with `--secret id=custom_ca,src=/path/to/ca.crt`; do not disable TLS checks.
Use your configured resource group in these commands if it differs from
`rg-voiceprompt-prod`; explicit selection avoids unrelated Azure CLI defaults.

Confirm the workload identity's `AcrPull` assignment has propagated, then review
and apply the full plan:

```bash
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan -out=/tmp/voiceprompt.tfplan
terraform -chdir=infrastructure show /tmp/voiceprompt.tfplan
terraform -chdir=infrastructure apply /tmp/voiceprompt.tfplan
```

Do not apply if the plan replaces/deletes existing resources or introduces
unapproved SKUs. Compute uses the Consumption profile and Web PubSub uses Free_F1;
the Basic registry and three private endpoints have ongoing charges even while
compute is idle. Obtain approval for those charges. Existing Foundry resources
are referenced, not recreated.

Storage accounts use the AzureRM `storage.data_plane_available = false` feature,
and queues and containers use their storage account ID for ARM provisioning.
Tables use AzAPI ARM resources because AzureRM 4.x still performs data-plane
table/ACL operations even when configured with `storage_account_id`.
This avoids key-based availability polling and does not require
opening the private data plane. Runtime workloads select their user-assigned
identity with `AZURE_CLIENT_ID`.
The worker drains available queue messages and exits; new messages trigger new
job executions rather than leaving an idle worker running until its timeout.

Terraform state and plans can contain sensitive values. Keep them out of source
control and preserve a secure state backup before removing or replacing a local
checkout.

### Point the Apple apps at the backend

After deployment, obtain the API endpoint with
`terraform -chdir=infrastructure output -raw api_url`. In the ignored
`Apple/Configuration.xcconfig`, set:

```text
BACKEND_URL = https:/$()/<your-api-hostname>/
```

Rebuild and reinstall the apps after changing configuration. Both apps read this
URL from their built Info.plist; an existing `backendURL` UserDefaults value or
Xcode launch argument takes precedence. The example's `voiceprompt.invalid` URL
is deliberately unusable: Entra sign-in can be configured independently, but
upload and transcription require a deployed backend.
Restart the macOS app after editing its Backend URL in Settings.
The Mac app automatically removes a saved `voiceprompt.invalid` placeholder so it
cannot override a newly configured build. Deliberately configured custom URLs are
preserved.

### Where recordings and transcripts live

The API's `VOICEPROMPT_STORAGE_ACCOUNT_NAME` identifies the private Azure Storage
account. Audio uploads go to the **audio** blob container, partitioned by owner and
recording/session ID. Session state and intermediate segment text live in the
**sessions** table. Completed transcripts are rows in the **transcripts** table:
the row's JSON `payload` contains `markdown`, `session_id`, `created_at`, and
`expires_at`. The transcript UUID is the row key. The **transcriptexpiry** table
indexes cleanup; completed transcripts are retained for **48 hours**.

Storage public access is disabled. There is no public Markdown download URL.
Signed-in apps retrieve records using `GET /v1/transcripts` and
`GET /v1/transcripts/{transcript_id}` on the configured backend.

## Apple signing

The shared Swift package requires Swift 6.3 or newer. CI uses Xcode 26.5 on macOS
26 with an explicitly selected toolchain rather than the runner's default Xcode.

### Local Mac installation

For updates with an existing `Apple/Configuration.xcconfig`, quit VoicePrompt from
its menu-bar menu and run `./scripts/install-macos.sh` from the repository root.
The script regenerates the Xcode project, builds with local ad-hoc signing, replaces
`~/Applications/VoicePromptMac.app`, and launches it without deleting preferences or
Keychain credentials. Build products stay in `~/Library/Developer/Xcode/DerivedData/VoicePrompt`.

Use macOS 14 or later, Xcode with Swift 6.3 or later, and XcodeGen
(`brew install xcodegen` if it is missing). A local, ad-hoc-signed build does not
require a paid Apple Developer account or notarization.

From the repository root, preserve any existing local configuration, generate the
project, and build only the Mac app:

```bash
if [ ! -f Apple/Configuration.xcconfig ]; then
  cp Apple/Configuration.xcconfig.example Apple/Configuration.xcconfig
fi
make apple-project
xcodebuild -project Apple/VoicePrompt.xcodeproj \
  -scheme VoicePromptMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath Apple/build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

Quit any existing VoicePrompt instance before installing or updating it:

```bash
mkdir -p "$HOME/Applications"
ditto Apple/build/Build/Products/Debug/VoicePromptMac.app \
  "$HOME/Applications/VoicePromptMac.app"
open "$HOME/Applications/VoicePromptMac.app"
```

VoicePrompt runs in the **menu bar**, not the Dock. Click its icon and choose
**Settings...** to open the separate settings window in front of other windows.
The scrollable panel under the icon lists all loaded transcripts from the last
48 hours, newest first.
Installation and launch work without
backend configuration, but the app remains **Offline**: sign-in, transcript sync,
and automatic clipboard delivery require the backend and Entra setup above.
The Mac app receives transcripts; recording is handled by the iOS app.

Sign in with Microsoft **on the Mac as well as on iOS**; each app uses its own
client registration and Keychain. Settings shows the Microsoft login,
API connection, live-update connection, and any actionable errors separately.
The app refreshes history after sign-in and WebSocket reconnects, and polls every
minute to recover missed completion events. A WebSocket outage does not prevent
API history refresh. **Sync Now** refreshes immediately.

Click a transcript row to copy that record's **full Markdown** to the clipboard,
including text beyond its shortened preview. Each entry includes its creation
date and time and briefly shows **Copied**. Older records and repeated clicks can
be copied again; automatic delivery deduplication does not disable manual copying.

The separate **trash button** on each row immediately starts cloud deletion without
a confirmation dialog. This action cannot be undone.
This calls the existing authenticated `DELETE /v1/transcripts/{transcript_id}`
endpoint: it permanently removes the signed-in user's cloud transcript, not just
the local row. Other Macs using the same account remove it on their next sync.
The row remains visible while deletion is pending; failures show an error and allow
retry. A record that was already deleted or expired is removed locally as well.
Deletion does not clear text already copied to the clipboard or copies saved
elsewhere. It removes the transcript, not the recording session's operational
metadata; normal processing already deletes uploaded audio and intermediate text.
No backend deployment or new permissions are needed for this client feature.

After changing app configuration or updating source, rebuild and replace the
installed app as above: launching an older copy does not pick up new Info.plist
settings. Mac regression tests can be run without a paid developer account:

```bash
make apple-project
xcodebuild -project Apple/VoicePrompt.xcodeproj -scheme VoicePromptMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/VoicePrompt" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

### Local iOS Simulator testing

Select the **VoicePromptIOS** scheme and a named **iOS Simulator** destination
(for example, **iPhone 17**) in Xcode's toolbar, then choose **Product > Run**
(`Cmd+R`). Simulator runs do not require a Personal Team or a development
certificate. A connected physical iPhone is a different destination: if Xcode
reports that a development team is required, check that the selected destination
is actually a simulator.

After authentication, the app shows **Signed in with Microsoft** and **Sign Out**;
it restores this status from Keychain on launch. Canceled or failed sign-ins show
their reason. **Cloud ready** means the API is reachable, not that the account is
authorized.

Recording works before sign-in and while offline. Stopped recordings remain saved
on the device until the server acknowledges the complete upload. Use **Retry saved
uploads** after signing in or reconnecting. Rebuilding/reinstalling over the existing
simulator app preserves its recordings; the queue resolves audio paths against the
current sandbox rather than keeping obsolete container paths. Do not uninstall the
app to troubleshoot uploads, since uninstalling deletes its local recordings.

Uploads display segment progress and actionable failures. Successfully uploaded
recordings move through transcription to **Complete**; cloud failures are shown
instead of leaving an indefinite spinner. If processing takes longer than about
three minutes, use **Check processing status**. Starting another recording does not
cancel processing in the cloud.

Run the iOS lifecycle regression tests with:

```bash
make apple-project
xcodebuild -project Apple/VoicePrompt.xcodeproj -scheme VoicePromptIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/VoicePrompt" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

Keep test build products outside macOS-protected folders such as Documents:
the simulator test loader needs access to the injected test libraries. Keep code
signing enabled when running the simulator app; unsigned builds cannot access its
sign-in Keychain. Local ad-hoc signing (`CODE_SIGN_IDENTITY=-`) needs no paid
developer membership or certificate.

### Local iPhone testing with a free Personal Team

Running on your own iPhone from Xcode uses **development signing**, not App Store
or ad-hoc distribution. A free Apple Account (shown as a **Personal Team** in Xcode)
is sufficient. You do not need paid Apple Developer Program membership, an App Store
Connect app, TestFlight, an exported IPA, or notarization. Developer Mode allows
development-signed apps to run; it does not remove the signing requirement.

The iOS app uses its own sandbox and Keychain, not a shared App Group. Its
entitlements file is intentionally empty: App Groups are unavailable to free
Personal Teams and are unnecessary here. Microphone permission and Background
Modes > Audio are already declared in `Apple/VoicePromptIOS/Info.plist`.

1. Open Xcode and add your Apple Account under **Xcode > Settings > Accounts**
   (called **Apple Accounts** in some versions). Accept any developer agreements
   Xcode requests.
2. Install XcodeGen if needed with `brew install xcodegen`. From the repository
   root, create the ignored local configuration and generate/open the project:

   ```bash
   cp -n Apple/Configuration.xcconfig.example Apple/Configuration.xcconfig
   make apple-project
   open Apple/VoicePrompt.xcodeproj
   ```

   `cp -n` preserves an existing configuration. Fill the Entra values as described
   above when configuring sign-in; placeholder values are not working credentials.
3. Connect an unlocked iPhone running **iOS 17 or later** to the Mac using a cable.
   Tap **Trust This Computer** if prompted, and let Xcode pair with the phone in its
   device manager. On the iPhone, enable **Settings > Privacy & Security > Developer
   Mode**, restart, and confirm enabling it after restart. If the setting is
   missing, initiate pairing in Xcode first.
4. In Xcode's project navigator, select the **VoicePrompt** project, then
   **TARGETS > VoicePromptIOS > Signing & Capabilities**. Keep **Automatically
   manage signing** enabled and select your **Personal Team**. Leave
   `com.michalmar.voiceprompt.ios` as the bundle identifier unless Xcode says it is
   unavailable. Xcode manages the development certificate, device registration,
   and provisioning profile; allow network access to Apple's services. You do
   not need to configure the macOS target to run the iOS app.
5. Select the **VoicePromptIOS** scheme and your connected iPhone as the run
   destination, then choose **Product > Run** (`Cmd+R`). Use the normal Debug/Run
   workflow, not Archive/Distribute App. If iOS reports an untrusted developer,
   trust your developer entry under **Settings > General > VPN & Device
   Management**, then run again. Allow microphone access when the app asks.

With a free Personal Team, provisioning profiles expire after **7 days**. Rebuild
and reinstall from Xcode to renew them; there is no need to delete the app first.
Once installed and trusted, the app can run without the cable until its profile
expires. Sign-in, upload, and transcription still require the separate Entra and
backend configuration; successful signing alone does not configure those services.

Microphone capture uses the `.record` audio-session category with `.default` mode
and Bluetooth HFP input support. The playback-oriented `.spokenAudio` mode is not
appropriate for recording: an incompatible category/mode combination can fail with
`OSStatus -50` on a physical iPhone even when the simulator works. Rebuild and
reinstall the corrected app over the existing copy; changing Microsoft permissions
does not fix an audio-session configuration error.

XcodeGen recreates the project, so a Team selected only in Xcode may be lost after
`make apple-project`. To persist that choice locally, add
`DEVELOPMENT_TEAM = <your-team-id>` to the ignored `Apple/Configuration.xcconfig`
using the Team ID shown in Xcode. Do not commit account-specific signing settings
or certificates.

If the bundle identifier is unavailable, set a unique
`PRODUCT_BUNDLE_IDENTIFIER` for `VoicePromptIOS` in `Apple/project.yml` and regenerate
the project; changing only `bundleIdPrefix` does not override that explicit value.
If you also rename the `msauth` callback scheme, update the URL scheme in
`Apple/VoicePromptIOS/Info.plist` and the scheme portion of `redirectURI` in
`Apple/VoicePromptIOS/Sources/VoicePromptIOSApp.swift`, then register that complete
redirect URI in the Entra iOS app registration.

Apple references: [Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account)
and [enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

### Distribution later (not needed for the steps above)

Ad-hoc iOS distribution requires paid Apple Developer Program membership and
registered destination devices, but does not require an App Store release.
Development/ad-hoc apps expire with their provisioning profiles and cannot be
installed unsigned. macOS Developer ID signing and notarization are separate from
iPhone development; they require the team's Developer ID Application certificate
and notarization credentials when distributing the Mac app outside the App Store.
