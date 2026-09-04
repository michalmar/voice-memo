# Validation record

Validated in the repository's Linux cloud environment:

- Python 3.12 backend unit, authentication, ownership, finalization, idempotency,
  stitching, retention, contract, and mocked local end-to-end tests.
- Swift 6.3 shared package build and tests.
- Terraform provider initialization, formatting, and static validation.
- OpenAPI generation and container image build.

Not executable in this environment:

- Xcode, iOS Simulator, native macOS build, archive, `.ipa`, `.app`, and `.dmg`
  because the runner is Linux and has no Xcode.
- Azure discovery, plan/apply, smoke tests, or model evaluation because Azure CLI
  has no authenticated account.
- Google sign-in because native client registrations do not exist.
- Signing/notarization because Apple credentials are unavailable.
- Lock-screen/background recording and a 20-minute physical-device recording,
  which must be verified on a real registered iPhone and must not be inferred from
  simulator tests.

Never expect recording to continue after force-quit or operating-system termination.
