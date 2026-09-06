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

## Azure and Foundry

Authenticate Azure CLI, identify an existing Foundry resource, and list its
deployments. Evaluate speech-capable deployments with a representative Czech
technical recording; set `speech_deployment` to the winner. Evaluate the existing
GPT-5.6 Luna deployment first for detailed intent preservation and change
`cleanup_deployment` to GPT-5.6 Terra only if it fails.

The guide assumes those model deployments already exist; their names are not a
guarantee of availability in your subscription. If no Foundry resource exists,
select a supported region and available models before provisioning. A model
available in an editor or Copilot is not automatically an Azure deployment.

Set `foundry_endpoint` to the account's Azure OpenAI endpoint, such as
`https://<account>.openai.azure.com`, not the Foundry project URL ending in
`/api/projects/<project>`. Set `foundry_resource_id` to the parent account's Azure
resource ID, not the project ID. The current backend uses this one endpoint for
both deployments. A Realtime-only deployment cannot replace the file-transcription
deployment used for recorded M4A segments.

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
Restart the macOS app after editing its Backend URL in History & Settings.

## Apple signing

### Local iOS Simulator testing

Select the **VoicePromptIOS** scheme and a named **iOS Simulator** destination
(for example, **iPhone 17**) in Xcode's toolbar, then choose **Product > Run**
(`Cmd+R`). Simulator runs do not require a Personal Team or a development
certificate. A connected physical iPhone is a different destination: if Xcode
reports that a development team is required, check that the selected destination
is actually a simulator.

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
