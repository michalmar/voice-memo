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
   `ENTRA_API_SCOPE = "api://<api-application-client-id>/VoicePrompt.Access"`,
   `ENTRA_IOS_CLIENT_ID`, and `ENTRA_MAC_CLIENT_ID`, then apply those build settings
   to both generated Xcode targets.

The clients use Authorization Code with PKCE in `ASWebAuthenticationSession`.
Refresh tokens are device-only Keychain items. The backend partitions ownership by
the validated `<tenant-id>:<object-id>` pair and requires the delegated scope.

## Azure and Foundry

Authenticate Azure CLI, identify an existing Foundry resource, and list its
deployments. Evaluate speech-capable deployments with a representative Czech
technical recording; set `speech_deployment` to the winner. Evaluate the existing
GPT-5.6 Luna deployment first for detailed intent preservation and change
`cleanup_deployment` to GPT-5.6 Terra only if it fails.

Copy `infrastructure/terraform.tfvars.example` outside source control, fill its
placeholders, and run:

```bash
terraform -chdir=infrastructure init
terraform -chdir=infrastructure plan -out=/tmp/voiceprompt.tfplan
terraform -chdir=infrastructure show /tmp/voiceprompt.tfplan
terraform -chdir=infrastructure apply /tmp/voiceprompt.tfplan
```

Do not apply if the plan replaces/deletes existing resources or introduces a
non-consumption SKU. The current configuration creates only app-specific resources.

## Apple signing

Replace the bundle prefix only if it is unavailable in the supplied Apple team.
Select the Apple Team for both targets and enable automatic signing. The iOS target
requires Microphone and Background Modes > Audio. Register each physical device for
development/ad-hoc distribution. A development/ad-hoc IPA expires with its profile
and cannot be installed unsigned. macOS Developer ID signing and notarization require
the team's Developer ID Application certificate and App Store Connect credentials.
