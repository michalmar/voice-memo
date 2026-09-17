# Azure Deployment Plan

> **Status:** Validated

Generated: 2026-09-15T15:40:00+02:00

## 1. Goal

Replace local backend image builds and manual Terraform image rollouts with a GitHub Actions production deployment workflow.

## 2. Confirmed Environment

| Attribute | Value |
|-----------|-------|
| Repository | `michalmar/voice-memo` |
| Branch | `main` |
| Subscription | `ME-MngEnvMCAP372348-mimarusa-1` (`7bc68c68-f434-49ad-ab3e-b883ec39da86`) |
| Location | Sweden Central |
| Resource group | `rg-voiceprompt-prod` |
| Registry | `crvoiceprompt18ifwf` |
| API | `ca-voiceprompt-api-18ifwf` |
| Worker job | `caj-voiceprompt-worker-18ifwf` |
| Cleanup job | `caj-voiceprompt-cleanup-18ifwf` |

## 3. Trigger

- Run automatically after the existing `CI` workflow succeeds on `main`.
- Also support manual dispatch from `main`.
- Use a production concurrency group to prevent overlapping rollouts.

## 4. Build and Deployment

1. Authenticate from GitHub Actions to Azure with OIDC; no client secret.
2. Check out the exact commit that passed CI.
3. Run `az acr build` in the existing ACR so no local/self-hosted Docker compute or package mirror is required.
4. Resolve the pushed tag to an immutable SHA-256 digest.
5. Update the existing API, worker job, and cleanup job to that digest.
6. Verify the healthy active API revision, readiness endpoint, OpenAPI contract, and all three live image references.

## 5. Infrastructure Ownership

- Reuse the existing `foundry-agents-lifecycle-github-oidc` application (`38e006e7-12fc-47c0-b325-0d17decb48b8`).
- Add only a federated credential restricted to `michalmar/voice-memo` branch `main`.
- Do not create an identity or add/change Azure RBAC.
- Keep Terraform responsible for initial image/bootstrap configuration, but ignore later container-image changes because GitHub Actions becomes the image deployment owner.

## 6. Repository Changes

| File | Change |
|------|--------|
| `.github/workflows/deploy-backend.yml` | New OIDC + ACR build + ACA rollout workflow |
| `backend/Dockerfile` | Remove BuildKit-only secret mounts so ACR Tasks can build it |
| `infrastructure/main.tf` | Make GitHub Actions the owner of post-provision image changes |
| `docs/configuration.md` | Replace local production build instructions with workflow setup and use |

## 7. Provisioning Limits

| Resource Type | New | Total | Limit | Status |
|---------------|-----|-------|-------|--------|
| User-assigned managed identity | 0 | Existing identities unchanged | No quota impact | ✅ |
| Federated identity credential | 1 | 5 on existing application | 20 per application | ✅ |
| Container Apps / ACR | 0 | Existing resources unchanged | No new service quota | ✅ |

## 8. Security

- OIDC only; no Azure password/client secret in GitHub.
- Federated subject restricted to `repo:michalmar/voice-memo:ref:refs/heads/main`.
- Workflow permissions limited to `contents: read` and `id-token: write`.
- Immutable image digest deployment.
- Existing deployment principal and permissions are reused without RBAC mutation.
- No Terraform state or production tfvars stored in GitHub.

## 9. Execution

- [x] Analyze existing repository, workflow, ACR, and Container Apps deployment.
- [x] Select workflow architecture.
- [x] User approves revised plan.
- [x] Generate workflow, Terraform image ownership, Dockerfile, and documentation changes.
- [x] Validate workflow YAML, backend image build compatibility, Terraform, and tests.
- [x] With explicit permission, add the repository-specific federated credential to the existing application.
- [x] Configure GitHub Actions repository variables.
- [ ] Run the workflow manually once and verify production.

## 10. Validation Proof

| Check | Result |
|-------|--------|
| Backend tests | 50 passed |
| Workflow YAML | Parsed successfully |
| Azure CLI rollout commands | API and job commands support `--image` |
| Terraform format and syntax | Passed |
| Terraform plan | No infrastructure changes |
| ACR cloud build | Succeeded as Linux AMD64, digest `sha256:f4ba73ca52df06d6f405e87be14376068699ac6aa81d0da11bb19d4145a868d7` |

**Validated by:** azure-validate

**Validation timestamp:** 2026-09-15T15:47+02:00

## 11. Configuration Proof

- Existing Azure application: `foundry-agents-lifecycle-github-oidc`
- Client ID: `38e006e7-12fc-47c0-b325-0d17decb48b8`
- Federated credential: `voice-memo-main`
- Subject: `repo:michalmar/voice-memo:ref:refs/heads/main`
- GitHub repository variables: all nine required values configured
- No Azure identity or RBAC changes made
- First workflow run remains pending until the workflow file is committed and pushed to `main`
