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

### Local Mac installation

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
**History & Settings** to open the app window. Installation and launch work without
backend configuration, but the app remains **Offline**: sign-in, transcript sync,
and automatic clipboard delivery require the backend and Entra setup above.
The Mac app receives transcripts; recording is handled by the iOS app.

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
