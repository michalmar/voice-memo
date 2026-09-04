# Configuration and registration

## Google OAuth

Configure the Google consent screen, then add the account under **Test users** if
the app remains in testing.

1. Create an **iOS** OAuth client with bundle ID
   `com.michalmar.voiceprompt.ios`.
2. Create a **Desktop app** OAuth client named `VoicePrompt macOS`.
3. Put both resulting client IDs in Terraform `google_audiences`.
4. Configure each Apple target with its client ID and callback values after adding
   the production PKCE credential provider. Do not add a client secret to either app.
5. Obtain the stable Google `sub` claim from one validated sign-in and set it in
   `allowed_google_subjects`; email allow-listing is supported only as a bootstrap.

The checked-in Apple targets intentionally use an authentication abstraction and no
mock credential in release behavior. Client IDs are not secrets, but they are left
unconfigured until the registrations exist.

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
