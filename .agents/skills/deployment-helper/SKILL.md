---
name: deployment-helper
description: Guided VoicePrompt deployment and installation. Use when the user invokes /deployment-helper, says "/deployment-helper go", or asks Copilot to deploy the Azure backend and install the macOS or iOS app.
license: MIT
metadata:
  author: VoicePrompt
  version: "1.0.0"
---

# VoicePrompt deployment helper

Deploy VoicePrompt from a fresh clone with as much work as possible performed by
the agent. Use the manual Azure CLI and Terraform flow; do not require or trigger
GitHub Actions.

The source of truth for values and troubleshooting is
`docs/configuration.md`. Inspect the current repository before acting because the
guide, Terraform, and scripts may have changed after this skill was written.

## Invocation

The expected invocation is:

```text
/deployment-helper go
```

When invoked, the first user-facing action must be one focused question:

> Do you want the recommended macOS app + backend setup, or should iOS be included?

Use these choices when structured questions are available:

1. `macOS app + backend (Recommended)`
2. `macOS + iOS apps + backend`
3. `iOS app + backend`

Do not run deployment commands before the user answers. Ask only one question at
a time throughout the workflow.

## Operating principles

- Act as an installer, not only as an advisor. Run preflight checks, query Azure,
  create local configuration, execute approved Terraform and Azure CLI commands,
  verify the backend, and build the selected app.
- Pause only for a decision, missing privilege, interactive authentication,
  Foundry model deployment, approval of cloud changes, or an Apple permission
  that only the user can grant.
- Detect and resume partial deployments. Never assume that a failed run left no
  resources.
- Never create duplicate Entra registrations or Azure resources. Search first
  and ask the user to choose if several plausible existing resources are found.
- Never overwrite an existing `infrastructure/terraform.tfvars`,
  `Apple/Configuration.xcconfig`, or Terraform state without inspecting it and
  receiving approval for conflicting changes.
- Never request or create client secrets for the Apple apps. They are public
  clients using Authorization Code with PKCE.
- Never print access tokens, credentials, Terraform state, or signed-in account
  tokens. IDs, resource names, and endpoints may be shown when useful.
- Do not commit, push, or start a GitHub Actions deployment unless the user
  explicitly asks.
- Keep temporary plans outside the repository and remove only the exact temporary
  files created by this run.
- Use immutable ACR image digests for the API and both jobs.
- Treat every `terraform apply` as a costed cloud change. Show the plan summary
  and obtain explicit approval immediately before applying it. Never use
  `-auto-approve`.
- If the working tree has tracked changes, explain that the ACR build uploads the
  current backend directory. Ask whether to continue with that exact content;
  never commit, stash, reset, or discard changes automatically.

## Responsibility split

The agent should perform:

- Tool and repository preflight checks.
- Azure account, subscription, Entra, and Foundry discovery.
- Entra app registration through Azure CLI/Microsoft Graph when the user approves
  and the signed-in account has permission.
- Creation or surgical update of ignored local configuration files.
- Terraform init, validate, plan, approved apply, and output inspection.
- ACR build, digest resolution, Container Apps deployment, and API verification.
- Xcode project generation and macOS build/install.
- iOS project generation and simulator build when selected.

The user must perform:

- Interactive Azure or Microsoft sign-in when no valid session exists.
- Tenant admin consent when the signed-in account cannot grant it.
- Deployment of unavailable Foundry models or acceptance of preview-model terms.
- Approval of Terraform plans and other resource-creating operations.
- Microsoft sign-in inside VoicePrompt.
- macOS Microphone and Accessibility permission grants.
- Apple signing/team selection for a physical iPhone.

## Workflow

Track progress through these checkpoints. Report the current checkpoint and the
next required user action without repeating the full plan.

### 1. Inspect and preflight

After the setup choice:

1. Confirm the current directory is the VoicePrompt repository by checking for
   `infrastructure/main.tf`, `backend/Dockerfile`, `Apple/project.yml`, and
   `scripts/install-macos.sh`.
2. Read `git status --short`. Do not alter existing changes.
3. Determine whether this is fresh or resumable by checking:
   - `infrastructure/terraform.tfvars`
   - `infrastructure/.terraform/`
   - Terraform state/backend initialization
   - `Apple/Configuration.xcconfig`
   - `~/Applications/VoicePromptMac.app`
4. Check required tools:

   ```bash
   az version
   terraform version
   jq --version
   git --version
   curl --version
   xcodebuild -version
   xcodegen --version
   ```

5. Require Xcode and XcodeGen only when an Apple app is selected. Require a
   full Xcode installation, not only Command Line Tools.
6. If tools are missing, ask permission before installing them. On macOS with
   Homebrew, the normal command is:

   ```bash
   brew install azure-cli terraform jq xcodegen
   ```

   Do not install tools that are already available.
7. Check whether the Container Apps extension is available:

   ```bash
   az extension show --name containerapp
   ```

   If it is missing or incompatible, ask permission before running
   `az extension add --name containerapp --upgrade`.

### 2. Confirm Azure identity and target subscription

The user is expected to be logged in. Check without exposing tokens:

```bash
az account show --output json
az account list --query "[?state=='Enabled'].{name:name,id:id,isDefault:isDefault}" --output table
az ad signed-in-user show --query "{id:id,userPrincipalName:userPrincipalName}" --output json
```

If authentication is missing or expired, ask the user to complete `az login`,
then re-run the checks. Do not attempt to type credentials or bypass conditional
access.

If more than one enabled subscription exists, ask which subscription to use.
Then set and verify it:

```bash
az account set --subscription "<subscription-id>"
az account show --query "{name:name,id:id,tenantId:tenantId}" --output json
```

Record the subscription ID, tenant ID, and signed-in user's Entra object ID for
the current run.

The account normally needs:

- Contributor on the target subscription or resource group.
- Owner or User Access Administrator where Terraform creates role assignments.
- Permission to create app registrations.
- A tenant role capable of granting admin consent, or help from an administrator.

Do not claim these rights are present merely because sign-in succeeded. Handle
authorization errors explicitly.

### 3. Configure Microsoft Entra ID

Use one API registration and one public-client registration for each selected
Apple platform.

First search exact and similar display names:

```bash
az ad app list --display-name "VoicePrompt API" --query "[].{displayName:displayName,appId:appId,id:id}" --output table
az ad app list --display-name "VoicePrompt macOS" --query "[].{displayName:displayName,appId:appId,id:id}" --output table
az ad app list --display-name "VoicePrompt iOS" --query "[].{displayName:displayName,appId:appId,id:id}" --output table
```

Inspect candidates rather than identifying them only by display name. Reuse a
registration only after verifying its URI, scope, redirect, and public-client
configuration.

For a fresh setup, explain the registrations that will be created and ask for
approval before creating them. Prefer Azure CLI plus Microsoft Graph through
`az rest`. Fall back to the portal steps in `docs/configuration.md` if Graph
permissions are unavailable.

Required API contract:

- Display name: `VoicePrompt API`
- Tenant-only sign-in audience.
- Application ID URI: `api://<api-client-id>`
- Enabled delegated scope: `VoicePrompt.Access`
- Access token version: 2

Required macOS public client:

- Display name: `VoicePrompt macOS`
- Redirect URI:
  `msauth.com.michalmar.voiceprompt.macos://auth`
- Public client flows enabled.
- Delegated `VoicePrompt.Access` permission on the API registration.

Required iOS public client:

- Display name: `VoicePrompt iOS`
- Redirect URI:
  `msauth.com.michalmar.voiceprompt.ios://auth`
- Public client flows enabled.
- Delegated `VoicePrompt.Access` permission on the API registration.

Generate a new UUID for the delegated scope only when creating a new API scope.
Create service principals where required for permission grant/admin consent.
After configuration, query Microsoft Graph again and verify every property.
Grant tenant admin consent when authorized. If that fails, give the user the
exact registration and permission that an administrator must approve, then wait
for confirmation before continuing.

Ask whether additional users need backend access. If not, use the signed-in
user's object ID. If yes, resolve each requested user to a stable Entra object ID
and confirm the final allowlist.

### 4. Discover and verify Microsoft Foundry

VoicePrompt requires an existing Foundry/Azure AI Services account that supports:

- Speech fast transcription with `MAI-Transcribe-2`.
- An Azure OpenAI deployment for Luna refinement, normally named
  `gpt-5.6-luna`.

Discover candidate Cognitive Services accounts:

```bash
az resource list \
  --resource-type Microsoft.CognitiveServices/accounts \
  --query "[].{name:name,resourceGroup:resourceGroup,location:location,kind:kind,id:id}" \
  --output table
```

If several accounts are plausible, ask the user to choose. For the selected
account, inspect its properties and model deployments:

```bash
az cognitiveservices account show \
  --resource-group "<resource-group>" \
  --name "<account-name>" \
  --output json

az cognitiveservices account deployment list \
  --resource-group "<resource-group>" \
  --name "<account-name>" \
  --output table
```

Record:

- Full Azure resource ID.
- `https://<resource>.openai.azure.com`
- `https://<resource>.cognitiveservices.azure.com`
- Luna deployment name.

Do not use a Foundry project URL ending in `/api/projects/<project>`. If Luna is
missing or MAI-Transcribe-2 is unavailable, guide the user through deploying or
selecting them in Foundry. Preview availability and terms may require user action
and cannot be inferred from the resource name.

### 5. Create the local Terraform configuration

Verify that `infrastructure/terraform.tfvars` is ignored by Git before writing
tenant-specific values. Create it from the example when absent. Preserve
intentional existing values when resuming.

Populate:

```hcl
subscription_id          = "<subscription-id>"
location                 = "<selected-region>"
resource_group_name      = "<approved-resource-group-name>"
container_image          = "bootstrap-only-not-used"
entra_tenant_id          = "<tenant-id>"
entra_audience           = "<api-client-id>"
entra_required_scope     = "VoicePrompt.Access"
allowed_entra_object_ids = ["<allowed-user-object-id>"]
foundry_endpoint         = "https://<resource>.openai.azure.com"
foundry_resource_id      = "<full-foundry-resource-id>"
speech_endpoint          = "https://<resource>.cognitiveservices.azure.com"
speech_model             = "MAI-Transcribe-2"
cleanup_deployment       = "<luna-deployment-name>"
```

Ask for the Azure region and resource-group name only if they cannot be safely
inferred from existing configuration. Explain that the backend creates billable
Azure resources, including Container Apps, ACR, Storage, networking, Web PubSub,
and Application Insights.

Leave `cleanup_temperature` unset for Luna.

### 6. Bootstrap ACR and the pull identity

For a fresh deployment:

```bash
terraform -chdir=infrastructure init
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan \
  -var='container_image=bootstrap-only-not-used' \
  -target=azurerm_role_assignment.registry \
  -out=/tmp/voiceprompt-registry.tfplan
terraform -chdir=infrastructure show /tmp/voiceprompt-registry.tfplan
```

Summarize additions, changes, replacements, and deletions. Stop if the plan
deletes or replaces unrelated resources. Ask for explicit approval, then run:

```bash
terraform -chdir=infrastructure apply /tmp/voiceprompt-registry.tfplan
```

For an existing deployment, skip this checkpoint when the ACR, workload identity,
and `AcrPull` assignment are already present in state and Azure.

### 7. Build the backend image and finish infrastructure

Build the exact local backend in Azure:

```bash
REGISTRY_SERVER=$(terraform -chdir=infrastructure output -raw registry_login_server)
ACR_NAME="${REGISTRY_SERVER%%.*}"
RESOURCE_GROUP=$(az acr show --name "$ACR_NAME" --query resourceGroup --output tsv)
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
```

Require `IMAGE` to contain `@sha256:`. Update only `container_image` in the local
Terraform variables, preserving all other values. Then choose the fresh or
existing deployment path below.

For a fresh deployment whose complete stack does not exist yet:

```bash
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan -out=/tmp/voiceprompt.tfplan
terraform -chdir=infrastructure show /tmp/voiceprompt.tfplan
```

Summarize the plan and obtain explicit approval immediately before:

```bash
terraform -chdir=infrastructure apply /tmp/voiceprompt.tfplan
```

For an existing complete deployment, Terraform intentionally ignores later image
changes. Do not claim that another Terraform apply will roll out the image.
Resolve the deployed resource names:

```bash
NAMES=$(terraform -chdir=infrastructure output -json resource_names)
RESOURCE_GROUP=$(jq -r .resource_group <<<"$NAMES")
API_APP=$(jq -r .api <<<"$NAMES")
WORKER_JOB=$(jq -r .worker <<<"$NAMES")
CLEANUP_JOB=$(jq -r .cleanup <<<"$NAMES")
```

Show the target resources and immutable digest, obtain approval for the rollout,
then update all three workloads:

```bash
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

If role-assignment propagation causes an image-pull failure, verify that the
managed identity has `AcrPull`, wait briefly, and retry the failed operation once.
Do not hide the original error.

### 8. Verify the backend

Read the deployed URL:

```bash
API_URL=$(terraform -chdir=infrastructure output -raw api_url)
curl --fail --silent --show-error "$API_URL/health/ready"
```

Require `{"status":"ready"}`. Then verify the deployed refinement contract:

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

Both values must be `true`. Container Apps can temporarily route to an older
revision during rollout, so retry for a bounded period before diagnosing failure.

When verification fails, inspect current revisions and logs using the
`resource_names` Terraform output. Do not continue to app installation while the
backend contract is invalid.

### 9. Configure and install the macOS app

Skip for iOS-only setups.

Verify `Apple/Configuration.xcconfig` is ignored. Create it from the example when
absent and populate the real values:

```text
ENTRA_TENANT_ID = <tenant-id>
ENTRA_IOS_CLIENT_ID = <ios-client-id-or-placeholder>
ENTRA_MAC_CLIENT_ID = <macos-client-id>
ENTRA_API_SCOPE = api:/$()/<api-client-id>/VoicePrompt.Access
BACKEND_URL = https:/$()/<api-hostname>/
```

The empty `$()` is mandatory in `.xcconfig` values because `//` starts a comment.
Strip `https://` before inserting the API hostname into the escaped form.

Run:

```bash
./scripts/install-macos.sh
```

The installer prefers an available Apple Development or Developer ID identity so
macOS Accessibility permission survives rebuilds. If it falls back to ad-hoc
signing, explain that direct-paste permission must be granted again after each
rebuild. When the installed signing requirement changes, the installer resets
the stale VoicePrompt Accessibility entry before launch.

If VoicePrompt is already running, ask the user to quit it from the menu-bar app,
then rerun the installer. Verify:

- `~/Applications/VoicePromptMac.app` exists.
- The installed app launches as a menu-bar app.
- The built configuration contains the intended backend URL and Entra IDs,
  without printing tokens.

Guide the user through first launch:

1. Open VoicePrompt from the menu bar.
2. Sign in with an allowlisted Microsoft account.
3. Grant Microphone permission.
4. Grant Accessibility permission only if automatic paste is desired.
5. Record a short quick transcription with **Refine** enabled.
6. Confirm the refinement sparkle/status appears and no backend-confirmation
   warning is shown.

If the sign-in or transcription fails, diagnose it before declaring success.

### 10. Configure iOS when selected

Create and verify the iOS Entra registration in checkpoint 3 and use its client
ID in `Apple/Configuration.xcconfig`.

Ask whether the target is Simulator or a physical iPhone. For Simulator:

```bash
make apple-project
xcodebuild \
  -project Apple/VoicePrompt.xcodeproj \
  -scheme VoicePromptIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

If that simulator is unavailable, select an installed iOS 17-or-later simulator
from `xcrun simctl list devices available`.

For a physical iPhone, generate/open the project, then hand off Apple Account,
team selection, Developer Mode, device trust, and signing to the user as described
in `docs/configuration.md`. Do not alter bundle identifiers unless the current
identifier is unavailable and the user approves the coordinated change.

### 11. Finish and report

The deployment is complete only when:

- Terraform apply succeeded.
- The API readiness check succeeded.
- The OpenAPI refinement checks both returned `true`.
- The selected Apple app built successfully.
- The macOS app is installed when selected.
- The user can sign in with an allowlisted account.
- A short selected-platform transcription reaches the backend.

Report:

- Selected setup.
- Azure subscription name and resource group.
- Backend URL.
- Reused versus newly created Entra registrations.
- Foundry account and model/deployment names.
- Installed app path or iOS run target.
- Any user-only action still outstanding.

Do not report success if a required checkpoint remains unverified. A Mac-only
user can rerun `/deployment-helper go` later and choose an iOS setup; reuse the
existing backend and API registration rather than provisioning duplicates.
