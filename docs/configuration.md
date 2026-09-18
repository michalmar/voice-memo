# VoicePrompt setup guide

This guide explains how to configure and run VoicePrompt for the first time. It
covers the backend, the macOS app, the iOS app, and manual Azure deployment
without GitHub Actions.

VoicePrompt is not a standalone offline speech recognizer. Every usable setup
needs the backend and at least one Apple app.

## Recommended Copilot-assisted setup

The easiest path from a fresh clone is the repository's `deployment-helper`
skill. Open the cloned repository with GitHub Copilot and enter:

```text
/deployment-helper go
```

The helper asks first whether you want:

1. The macOS app and backend only, which is the recommended default.
2. The macOS and iOS apps with one shared backend.
3. The iOS app and backend only.

Copilot then performs most of the repeatable work: prerequisite checks, Azure and
Foundry discovery, local configuration, Entra registration when authorized,
Terraform planning and deployment, backend image deployment and verification,
and the selected Apple build.

You remain in control of operations that require credentials, elevated consent,
cloud-cost approval, or operating-system permissions. In particular, be prepared
to:

- Be signed in with Azure CLI to the intended tenant and subscription.
- Approve the proposed Entra registrations and each Terraform apply.
- Ask a tenant administrator for consent if your account cannot grant it.
- Deploy or select the required Foundry models if they are not already available.
- Sign in inside VoicePrompt and grant Apple privacy permissions.

The skill is stored at
`.agents/skills/deployment-helper/SKILL.md`. It uses the manual process in this
guide and does not depend on GitHub Actions. If your Copilot environment does not
load repository skills, follow the same steps manually starting at
[Choose the setup you want](#1-choose-the-setup-you-want).

## Contents

1. [Choose the setup you want](#1-choose-the-setup-you-want)
2. [Prerequisites](#2-prerequisites)
3. [Record the values you will need](#3-record-the-values-you-will-need)
4. [Configure Microsoft Entra ID](#4-configure-microsoft-entra-id)
5. [Prepare Microsoft Foundry](#5-prepare-microsoft-foundry)
6. [Deploy the backend manually](#6-deploy-the-backend-manually)
7. [Configure the Apple apps](#7-configure-the-apple-apps)
8. [Install and configure the macOS app](#8-install-and-configure-the-macos-app)
9. [Run the iOS app](#9-run-the-ios-app)
10. [Using both apps](#10-using-both-apps)
11. [Optional local backend development](#11-optional-local-backend-development)
12. [Troubleshooting](#12-troubleshooting)
13. [Data, retention, and security](#13-data-retention-and-security)

## 1. Choose the setup you want

| Setup | Backend | API registration | macOS registration | iOS registration |
|-------|---------|------------------|--------------------|------------------|
| macOS only | Required | Required | Required | Not required |
| iOS only | Required | Required | Not required | Required |
| macOS and iOS | Required | Required | Required | Required |

### macOS only

Choose this if you want the menu-bar app and quick transcription on a Mac.

You need:

1. The Azure backend.
2. One Microsoft Entra API registration.
3. One Microsoft Entra public-client registration for macOS.
4. The macOS app built with those settings.

You do not need to register, build, or install the iOS app.

Mac quick transcription sends one recording directly to the API. It uses
MAI-Transcribe-2 and, when the **Refine** HUD switch is enabled, GPT-5.6 Luna.
The current Terraform configuration still provisions the complete backend stack,
including the worker used by iOS recordings.

### iOS only

Choose this if you want to record and read transcripts on an iPhone without using
the Mac app.

You need:

1. The complete Azure backend, including the transcription worker.
2. One Microsoft Entra API registration.
3. One Microsoft Entra public-client registration for iOS.
4. The iOS app built with those settings.

You do not need to register or install the macOS app. Completed transcripts remain
available in the iOS History tab.

### macOS and iOS

Choose this for the complete workflow. Register both native apps and sign in with
the same Microsoft account on both devices. Each app uses a separate Entra client
registration, but both request access to the same API.

## 2. Prerequisites

### Azure and Microsoft prerequisites

Have these ready before starting:

- An Azure subscription.
- Permission to create resource groups, Container Apps, Storage, networking,
  managed identities, role assignments, Web PubSub, and Container Registry.
  **Owner**, or **Contributor** plus **User Access Administrator**, is normally
  sufficient at the target scope.
- A Microsoft Entra tenant in which you can create app registrations and grant
  tenant-wide consent. Application Administrator or a similar directory role may
  be required.
- A Microsoft account in that tenant for each VoicePrompt user.
- An existing Microsoft Foundry/Cognitive Services account with:
  - MAI-Transcribe-2 available for Speech transcription.
  - A GPT-5.6 Luna deployment, named `gpt-5.6-luna` by default.
- A supported Azure region for the selected models and infrastructure.

The Terraform configuration references the Foundry account. It does not create
the Foundry account or deploy the models.

### Local tools

Install:

- Git
- Azure CLI
- Terraform 1.9 or later
- `jq`
- Xcode with Swift 6.3 or later
- XcodeGen

On macOS with Homebrew:

```bash
brew install azure-cli terraform jq xcodegen
```

ACR builds the backend image in Azure, so Docker is not required for deployment.
Docker is useful only for optional local image testing.

For local backend tests, install Python 3.12 or later and FFmpeg.

### Apple hardware and accounts

- The Mac app requires macOS 14 or later.
- The iOS app requires iOS 17 or later.
- The iOS Simulator does not require a paid Apple Developer account.
- Installing on your own iPhone requires an Apple Account configured as a
  Personal Team in Xcode. A free Personal Team works, but its provisioning
  profile expires after seven days.

## 3. Record the values you will need

Keep a private worksheet with these values:

| Value | Where it comes from |
|-------|---------------------|
| Azure subscription ID | Azure subscription |
| Azure region | Region selected for the backend |
| Entra tenant ID | Microsoft Entra tenant |
| API application client ID | VoicePrompt API app registration |
| Allowed user object ID | Entra user profile |
| macOS client ID | macOS public-client registration |
| iOS client ID | iOS public-client registration |
| Foundry resource ID | Azure resource JSON or resource overview |
| Foundry OpenAI endpoint | `https://<resource>.openai.azure.com` |
| Foundry Speech endpoint | `https://<resource>.cognitiveservices.azure.com` |
| Luna deployment name | Usually `gpt-5.6-luna` |

Do not commit tenant-specific IDs, Terraform state, access tokens, signing
certificates, or local Apple configuration.

## 4. Configure Microsoft Entra ID

VoicePrompt uses one API registration and a separate public-client registration
for each Apple platform you intend to use. Native apps use Authorization Code
with PKCE and do not have client secrets.

### 4.1 Register the API

1. Open **Microsoft Entra admin center > App registrations**.
2. Select **New registration**.
3. Name it `VoicePrompt API`.
4. Select **Accounts in this organizational directory only**.
5. Complete the registration.
6. Record its **Application (client) ID** and the tenant ID.
7. Open **Expose an API**.
8. Accept the default Application ID URI:

   ```text
   api://<api-application-client-id>
   ```

9. Add a delegated scope named:

   ```text
   VoicePrompt.Access
   ```

10. In the app manifest, set `requestedAccessTokenVersion` to `2`.

The backend validates the tenant, API audience, delegated scope, and an explicit
allowlist of user object IDs.

### 4.2 Register the macOS client

Skip this section for an iOS-only setup.

1. Create another app registration named `VoicePrompt macOS`.
2. Configure it as a public client.
3. Add this mobile/desktop redirect URI:

   ```text
   msauth.com.michalmar.voiceprompt.macos://auth
   ```

4. Enable public client flows.
5. Under **API permissions**, add delegated permission
   `VoicePrompt.Access` from `VoicePrompt API`.
6. Record the macOS registration's client ID.

### 4.3 Register the iOS client

Skip this section for a Mac-only setup.

1. Create another app registration named `VoicePrompt iOS`.
2. Configure it as a public client.
3. Add this mobile/desktop redirect URI:

   ```text
   msauth.com.michalmar.voiceprompt.ios://auth
   ```

4. Enable public client flows.
5. Under **API permissions**, add delegated permission
   `VoicePrompt.Access` from `VoicePrompt API`.
6. Record the iOS registration's client ID.

### 4.4 Grant consent and allow users

Grant tenant admin consent for the delegated API permission.

Record the **Object ID** of every user allowed to use the backend. These values go
into Terraform:

```hcl
allowed_entra_object_ids = [
  "<first-user-object-id>",
  "<second-user-object-id>",
]
```

Successful Microsoft sign-in does not automatically grant backend access. The
signed-in user's object ID must also be in this allowlist.

Users of the Apple apps do not need Azure Contributor, Storage, Foundry, or
directory administrator roles.

## 5. Prepare Microsoft Foundry

VoicePrompt uses two model surfaces on the same Foundry/Cognitive Services
account:

- Speech endpoint for MAI-Transcribe-2:

  ```text
  https://<resource>.cognitiveservices.azure.com
  ```

- Azure OpenAI endpoint for Luna:

  ```text
  https://<resource>.openai.azure.com
  ```

Do not use a Foundry project URL ending in `/api/projects/<project>`.

Record the parent Foundry account's full Azure resource ID. Terraform grants the
backend's managed identity:

- **Cognitive Services Speech User** for transcription.
- **Cognitive Services OpenAI User** for Luna refinement.

MAI-Transcribe-2 is a preview model and may not be available in every region.
Confirm model availability on the actual resource before deploying.

## 6. Deploy the backend manually

These steps do not use GitHub Actions. Run them from the repository root.

### 6.1 Sign in to Azure

```bash
az login
az account set --subscription "<subscription-id>"
az account show --output table
az extension add --name containerapp --upgrade
```

Use an account with both resource creation and role-assignment permissions.

### 6.2 Create the Terraform configuration

Copy the example:

```bash
cp infrastructure/terraform.tfvars.example infrastructure/terraform.tfvars
```

Edit `infrastructure/terraform.tfvars`:

```hcl
subscription_id          = "<subscription-id>"
location                 = "<azure-region>"
resource_group_name      = "rg-voiceprompt-prod"

# This is replaced after the first image build.
container_image          = "bootstrap-only-not-used"

entra_tenant_id          = "<tenant-id>"
entra_audience           = "<api-application-client-id>"
entra_required_scope     = "VoicePrompt.Access"
allowed_entra_object_ids = ["<allowed-user-object-id>"]

foundry_endpoint         = "https://<resource>.openai.azure.com"
foundry_resource_id      = "/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.CognitiveServices/accounts/<resource>"
speech_endpoint          = "https://<resource>.cognitiveservices.azure.com"
speech_model             = "MAI-Transcribe-2"
cleanup_deployment       = "gpt-5.6-luna"
```

Leave `cleanup_temperature` unset for Luna. The model rejects the zero-temperature
override used by some older deployments.

### 6.3 Bootstrap the registry and pull identity

The first backend image cannot be built until the registry exists. Initialize
Terraform and create only the registry, workload identity, pull role, and their
dependencies:

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

Review the plan before applying it. Do not continue if it deletes or replaces
unrelated resources.

### 6.4 Build the first backend image in ACR

Use a clean, committed working tree so the image tag identifies the code that was
actually uploaded:

```bash
git status --short
```

Commit or intentionally resolve any output before continuing.

Resolve the registry created by Terraform:

```bash
REGISTRY_SERVER=$(terraform -chdir=infrastructure output -raw registry_login_server)
ACR_NAME="${REGISTRY_SERVER%%.*}"
RESOURCE_GROUP=$(az acr show --name "$ACR_NAME" --query resourceGroup --output tsv)
TAG="manual-$(git rev-parse --short HEAD)-$(date -u +%Y%m%d%H%M%S)"
```

Build the image in Azure:

```bash
az acr build \
  --resource-group "$RESOURCE_GROUP" \
  --registry "$ACR_NAME" \
  --image "voiceprompt:$TAG" \
  backend
```

Resolve the immutable digest:

```bash
DIGEST=$(az acr repository show \
  --name "$ACR_NAME" \
  --image "voiceprompt:$TAG" \
  --query digest \
  --output tsv)

IMAGE="$REGISTRY_SERVER/voiceprompt@$DIGEST"
echo "$IMAGE"
```

The value must contain `@sha256:`. Use the immutable digest, not only the tag.

### 6.5 Create the complete backend

Replace `container_image` in `infrastructure/terraform.tfvars` with the value of
`$IMAGE`, then run:

```bash
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan -out=/tmp/voiceprompt.tfplan
terraform -chdir=infrastructure show /tmp/voiceprompt.tfplan
terraform -chdir=infrastructure apply /tmp/voiceprompt.tfplan
```

The full stack includes:

- Public Container Apps API with private access to backend resources.
- Container Apps transcription worker job.
- Retention cleanup job.
- Private Storage account, separate audio/transcript Blob containers, queues, and tables.
- Azure Container Registry.
- Managed identity and role assignments.
- Web PubSub for completion events.
- VNet, private endpoints, and private DNS.
- Application Insights.

This infrastructure has ongoing Azure charges. Review the selected SKUs and your
organization's approval requirements before applying.

### 6.6 Verify the first deployment

Read the API URL:

```bash
API_URL=$(terraform -chdir=infrastructure output -raw api_url)
echo "$API_URL"
```

Check readiness:

```bash
curl --fail --silent --show-error "$API_URL/health/ready"
```

Expected response:

```json
{"status":"ready"}
```

Check that the deployed API contains Mac refinement support:

```bash
curl --fail --silent --show-error "$API_URL/openapi.json" \
  | jq '{
      refine_header: (
        .paths["/v1/transcriptions"].post.parameters
        | any(.name == "X-Refine")
      ),
      refined_confirmation: (
        .components.schemas.Transcript.properties
        | has("refined")
      )
    }'
```

Both values must be `true`. If they are false, an older API revision is receiving
traffic.

### 6.7 Deploy later backend updates manually

Terraform intentionally ignores post-provision image changes for the API and two
jobs. For each later release:

1. Start from a clean, committed working tree.
2. Build a new image.
3. Resolve its digest.
4. Update the API, worker, and cleanup job to the same immutable image.
5. Verify the live contract.

```bash
NAMES=$(terraform -chdir=infrastructure output -json resource_names)
RESOURCE_GROUP=$(jq -r .resource_group <<<"$NAMES")
API_APP=$(jq -r .api <<<"$NAMES")
WORKER_JOB=$(jq -r .worker <<<"$NAMES")
CLEANUP_JOB=$(jq -r .cleanup <<<"$NAMES")
ACR_NAME=$(jq -r .registry <<<"$NAMES")
REGISTRY_SERVER=$(terraform -chdir=infrastructure output -raw registry_login_server)

TAG="manual-$(git rev-parse --short HEAD)-$(date -u +%Y%m%d%H%M%S)"

az acr build \
  --resource-group "$RESOURCE_GROUP" \
  --registry "$ACR_NAME" \
  --image "voiceprompt:$TAG" \
  backend

DIGEST=$(az acr repository show \
  --name "$ACR_NAME" \
  --image "voiceprompt:$TAG" \
  --query digest \
  --output tsv)

IMAGE="$REGISTRY_SERVER/voiceprompt@$DIGEST"

az containerapp update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$API_APP" \
  --image "$IMAGE" \
  --output none

az containerapp job update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WORKER_JOB" \
  --image "$IMAGE" \
  --output none

az containerapp job update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLEANUP_JOB" \
  --image "$IMAGE" \
  --output none
```

Wait for the new Container Apps revision to become ready, then repeat the
readiness and OpenAPI checks from the previous section.

## 7. Configure the Apple apps

Create the ignored local build configuration:

```bash
cp -n Apple/Configuration.xcconfig.example Apple/Configuration.xcconfig
```

Edit `Apple/Configuration.xcconfig`:

```text
ENTRA_TENANT_ID = <tenant-id>
ENTRA_IOS_CLIENT_ID = <ios-client-id>
ENTRA_MAC_CLIENT_ID = <macos-client-id>
ENTRA_API_SCOPE = api:/$()/<api-application-client-id>/VoicePrompt.Access
BACKEND_URL = https:/$()/<your-api-hostname>/
```

The empty `$()` is required because `//` starts a comment in an `.xcconfig` file.
It allows Xcode to produce the intended `api://` and `https://` values.

For a Mac-only build, `ENTRA_IOS_CLIENT_ID` can remain a placeholder because the
iOS target is not built. For an iOS-only build, the macOS client ID can remain a
placeholder. The tenant, API scope, backend URL, and client ID for the app being
built must be real.

The Apple apps read these values from their built `Info.plist`. Rebuild and
reinstall after changing the file.

<a id="local-mac-installation"></a>

## 8. Install and configure the macOS app

Skip this section for an iOS-only setup.

### 8.1 Build and install

The easiest local installation is:

```bash
./scripts/install-macos.sh
```

The script:

1. Regenerates the Xcode project.
2. Uses an available Apple Development or Developer ID identity so macOS can
   preserve Accessibility permission across rebuilds.
3. Installs it at `~/Applications/VoicePromptMac.app`.
4. Launches it as a menu-bar app.

Quit an existing VoicePrompt process from its menu before rerunning the installer.
A paid Apple Developer account is not required. If no stable signing identity is
available, the installer falls back to ad-hoc signing and resets the stale
VoicePrompt Accessibility entry whenever the app identity changes. In that mode,
grant Accessibility permission again after each rebuild.

To build manually:

```bash
make apple-project
xcodebuild -project Apple/VoicePrompt.xcodeproj \
  -scheme VoicePromptMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath Apple/build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  build
```

### 8.2 First launch

1. Find VoicePrompt in the menu bar, not the Dock.
2. Open **Settings**.
3. Confirm the backend URL.
4. Sign in with the allowed Microsoft account.
5. Configure or disable the global shortcut.
6. Leave **Paste text into the active app** enabled if you want automatic paste.
7. Optionally add custom Luna instructions in the **Luna Refinement** text area.

Custom instructions:

- Are limited to 4,000 characters.
- Are added to the built-in Luna prompt rather than replacing it.
- Apply only to Mac quick transcriptions when **Refine** is enabled in the HUD.
- Can be empty. Empty content uses the built-in refinement prompt unchanged.

### 8.3 Permissions

macOS asks for:

- **Microphone** permission to record.
- **Accessibility** permission when automatic paste is first used.

Accessibility permission is not required if you only want the transcript copied
to the clipboard.

The app's Settings show the actual macOS Accessibility status separately from the
**Paste text into the active app** preference. The preference enables the feature;
the macOS permission authorizes it.

### 8.4 Use quick transcription

1. Press the configured shortcut, Shift-Command-Space by default, or select
   **Start Quick Transcription** from the menu.
2. Confirm the compact **Refine** switch is in the desired state.
3. Speak.
4. Select **Stop** to transcribe, or **Cancel** to discard the local recording.

When refinement is enabled:

- The HUD displays a spinner with a sparkle.
- The title changes to **Refining with Luna** when the backend reports that phase.
- A completed, backend-confirmed refined transcript keeps a sparkle in history.

If the app says the backend did not confirm refinement, verify the OpenAPI contract
from section 6.6. That warning normally means an older backend revision is still
receiving traffic.

## 9. Run the iOS app

Skip this section for a Mac-only setup.

### 9.1 iOS Simulator

```bash
make apple-project
open Apple/VoicePrompt.xcodeproj
```

In Xcode:

1. Select the **VoicePromptIOS** scheme.
2. Select an iOS 17 or later simulator.
3. Choose **Product > Run**.
4. Allow microphone access.
5. Sign in with an allowed Microsoft account.

The simulator does not require a paid Apple Developer account.

### 9.2 Physical iPhone with a free Personal Team

1. Add your Apple Account under **Xcode > Settings > Accounts**.
2. Connect and unlock the iPhone.
3. Trust the Mac when prompted.
4. Enable **Settings > Privacy & Security > Developer Mode** on the iPhone.
5. In Xcode, select **VoicePromptIOS > Signing & Capabilities**.
6. Keep automatic signing enabled and select your Personal Team.
7. Select the connected iPhone and run the app.
8. Trust the development certificate on the iPhone if requested.

A free Personal Team profile expires after seven days. Rebuild over the installed
app to renew it. Do not uninstall the app when troubleshooting pending uploads,
because uninstalling deletes its locally queued recordings.

If the bundle identifier is unavailable, choose a unique bundle identifier and
update all matching iOS callback schemes in:

- `Apple/project.yml`
- `Apple/VoicePromptIOS/Info.plist`
- `Apple/VoicePromptIOS/Sources/VoicePromptIOSApp.swift`
- The Entra iOS redirect URI

## 10. Using both apps

Sign in with the same Microsoft account on iOS and macOS.

- iOS uploads resilient 30-second audio segments.
- The worker transcribes the segments and Luna refines the final Markdown.
- Both apps can display the resulting transcript.
- The Mac can receive completion events, copy the result, and show notifications.
- History is retained for 48 hours by default.
- Deleting a transcript from either app removes it from cloud history for both
  devices after synchronization.

Separate allowed accounts have separate histories. Adding another user to the
allowlist does not merge or share transcripts.

## 11. Optional local backend development

Production authentication is enabled by default. For local backend-only work:

```bash
python3 -m venv .venv
.venv/bin/pip install -e 'backend[test]'
cp backend/.env.example backend/.env
```

Set:

```text
VOICEPROMPT_ENVIRONMENT=development
VOICEPROMPT_ALLOW_DEVELOPMENT_AUTH=true
```

Development tokens use the `dev:` prefix. Never enable development authentication
in a deployed or production environment.

Run tests:

```bash
.venv/bin/python -m pytest backend/tests
(cd Packages/VoicePromptKit && swift test)
```

Run the API locally:

```bash
.venv/bin/uvicorn voiceprompt.app:app \
  --app-dir backend/src \
  --host 127.0.0.1 \
  --port 8000
```

The in-memory development configuration is useful for API development, but real
Speech and Luna calls still require correctly configured Azure endpoints and
credentials.

## 12. Troubleshooting

### The app is offline

- Check `BACKEND_URL`.
- Confirm `/health/ready` returns HTTP 200.
- Rebuild the Apple app after changing `Configuration.xcconfig`.
- On macOS, a URL saved in Settings overrides the bundled URL until changed.

### Direct paste says Accessibility access is required, but it looks enabled

The paste preference and macOS Accessibility permission are separate. In
VoicePrompt Settings, check **Accessibility access**:

- If it says **Granted**, direct paste is authorized.
- If it says **Required**, select **Request Access** or **Open System Settings**.
- If the macOS list already shows VoicePrompt enabled, remove that stale entry,
  add `~/Applications/VoicePromptMac.app` again, and enable it.

This usually happens when an older local installation was ad-hoc signed. Run
`./scripts/install-macos.sh` again: it now prefers a stable Apple Development or
Developer ID identity and resets an incompatible stale entry during the
transition.

### Microsoft sign-in succeeds but the API returns 403

- Confirm the native app has delegated `VoicePrompt.Access`.
- Grant admin consent.
- Confirm the user object ID is in `allowed_entra_object_ids`.
- Confirm the API audience matches the API application client ID.

### The Mac says refinement was not confirmed

The Mac sent a refinement request, but the response did not contain the
backend-confirmed `refined` field.

Check:

```bash
curl --silent "$API_URL/openapi.json" \
  | jq '.components.schemas.Transcript.properties.refined'
```

If the result is `null`, deploy the latest backend image and wait for Container
Apps traffic to move to the new revision.

### Long recordings fail while saving, or recovery is needed

Older backends store the full transcript in a Table Storage string property,
which has a fixed 64 KiB UTF-16 limit. The blob-backed backend removes that
transcript-size restriction without changing the client API. Audio upload size,
recording duration and model/request timeout limits are unchanged.

For an existing installation, apply the updated Terraform configuration to create
the private `transcripts` container and its separate retention rule before
deploying the new backend. Update the API, worker and cleanup job to the same
blob-aware image, and drain old worker executions before resuming recordings.
Do not run an old cleanup image against new checkpoint expiry records. Existing
table-only transcripts are read without migration; an old backend cannot read
new blob-backed records, so rolling back to it is not supported after new writes.
Rebuild/install the Mac app separately to enable local audio preservation.

`VOICEPROMPT_TRANSCRIPTS_CONTAINER` defaults to `transcripts`.
`transcript_ttl_hours` in Terraform defaults to 48 and configures both
`VOICEPROMPT_TRANSCRIPT_TTL_HOURS` for all backend workloads and the orphan-blob
lifecycle duration. Keep these aligned if configuring resources manually.
Storage data-plane tools used for recovery need access to the storage private
endpoint; do not enable public storage access to work around this.

On the updated Mac app, HTTP/network errors and missing refinement confirmation
retain the recording at:

```text
~/Library/Application Support/VoicePrompt/QuickRecordings/<session-id>.m4a
```

The error includes the exact path. Dismissing it or starting another recording
does not delete the saved file. Retained failures have no automatic local expiry;
remove them manually once they are no longer needed. There is not yet an in-app
retry/import workflow for these files.

Before Luna refinement, the backend saves raw text in a private checkpoint blob
under `transcripts/checkpoints/<owner-hash>/<session-id>/`. These JSON files contain
the raw Markdown and expiry time; authorized operators can retrieve them through
the existing private storage access path while the checkpoint is retained.
They are not automatically published in history. If the final table write fails,
the completed Markdown may also exist under `transcripts/completed/`; blob
metadata identifies the session and transcript. None of these protections can
restore recordings already discarded by older app/backend versions.

### Custom Luna instructions are ignored

- Confirm the HUD **Refine** switch is enabled.
- Confirm the text is 4,000 characters or fewer.
- Confirm the deployed backend includes `python-multipart`.
- Confirm the latest API image is serving traffic.
- Leave the field empty to verify that the built-in prompt still works.

### Transcription works but Luna fails

- Confirm the Luna deployment name.
- Confirm the Foundry OpenAI endpoint.
- Confirm **Cognitive Services OpenAI User** is assigned to the workload identity.
- Leave `cleanup_temperature` unset for GPT-5.6 Luna.
- Inspect API or worker logs in Azure.

### MAI transcription fails

- Confirm the custom Speech endpoint.
- Confirm MAI-Transcribe-2 is available on the resource.
- Confirm **Cognitive Services Speech User** is assigned to the workload identity.
- Confirm the backend image contains FFmpeg.

### Inspect Container Apps

```bash
NAMES=$(terraform -chdir=infrastructure output -json resource_names)
RESOURCE_GROUP=$(jq -r .resource_group <<<"$NAMES")
API_APP=$(jq -r .api <<<"$NAMES")

az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$API_APP" \
  --output table

az containerapp logs show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$API_APP" \
  --follow
```

## 13. Data, retention, and security

- Audio, session data, and transcripts are partitioned by the validated Entra
  tenant and user object ID.
- iOS audio segments are stored temporarily in the private Blob container.
- Mac quick-transcription audio is sent directly to the API and is not placed in
  Blob Storage.
- Completed transcript content is stored in the private `transcripts` Blob
  container; the `transcripts` table holds metadata and blob references. Legacy
  table-only transcripts remain readable until deleted or expired.
- Mac raw-text recovery checkpoints use the same transcript container and
  retention period, and are removed after successful final persistence.
- Failed Mac audio stays locally in Application Support until manually removed.
- Transcripts expire after 48 hours by default.
- Hourly cleanup deletes expired transcript metadata and content together.
  A separate Blob lifecycle rule cleans up orphaned content asynchronously.
  Blob soft-delete protection retains deleted blobs for one additional day.
- Storage public access is disabled.
- Runtime services use managed identity; Apple apps never receive Azure service
  credentials.
- Refresh tokens are stored in each device's Keychain.
- Terraform state and plan files can contain sensitive values. Store and back
  them up securely.

The backend image includes FFmpeg and uses managed identity for Speech, Luna,
Storage, Queue, Table, Web PubSub, and registry access. Do not add service keys or
client secrets to the repository.
