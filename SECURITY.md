# Security Policy

## Supported versions

This repository is a continuously-deployed GitOps platform; only the `main`
branch and the most recent `v*` tag deployed to production are supported.
Older tags are kept for history and disaster-recovery purposes only and do
not receive security backports.

## Reporting a vulnerability

**Do not open a public issue for security reports.** Please use one of the
following private channels:

1. **Preferred** — open a private security advisory via GitHub, using **this
   repository's** Security tab → *Advisories* → *Report a vulnerability* (an
   instance created from this template inherits its own advisory inbox). This
   keeps the report inside the repository's coordinated-disclosure workflow and
   gives the maintainer a private space to discuss and patch.
2. As a fallback, email <admin@example.com> with `[platform-security]` in the
   subject line. *(Instances created from this template should replace this
   address with their own security contact.)*

When you report, please include:

- A description of the issue and the impact you believe it has.
- Steps to reproduce, ideally with a minimal proof of concept.
- The commit SHA or release tag the report applies to.
- Any suggested remediation, if you have one.

## Response targets

We are a single-maintainer project; responses are best-effort but we aim for:

| Severity | First acknowledgement | Triage decision | Fix or mitigation |
| -------- | --------------------- | --------------- | ----------------- |
| Critical | 48 hours              | 5 days          | 14 days           |
| High     | 5 days                | 14 days         | 30 days           |
| Medium   | 14 days               | 30 days         | next minor        |
| Low      | 30 days               | next minor      | next minor        |

Severity follows the [CVSS v3.1] vector in the report; in case of
disagreement the maintainer's assessment is used and recorded in the
advisory.

## Coordinated disclosure

We follow a 90-day disclosure window by default, counting from the
acknowledgement date. We will publish a GitHub Security Advisory and credit
reporters who wish to be credited. If a fix is impractical within 90 days we
will request an extension before the window closes.

## Scope

In scope:

- Manifests under `k8s/` and Talos patches under `talos/` and `talos-local/`.
- Workflow definitions under `.github/workflows/` and supporting scripts.
- Documentation that, if wrong, would lead an operator to a weaker
  configuration (notably any disaster-recovery, secret-rotation, or
  authentication docs under `docs/`, if present).
- The KSail configuration files (`ksail.yaml`, `ksail.prod.yaml`). KSail's
  native Hetzner provider owns the Hetzner Cloud provisioning lifecycle;
  there is no in-repo provisioning script.

Out of scope:

- Vulnerabilities in upstream container images, Helm charts, or
  Talos/Kubernetes itself. Please report those to the respective upstream
  projects. We will of course update the affected component once an upstream
  fix is available; tracking issues for that are welcome as normal issues.
- Theoretical findings on encrypted SOPS payloads (`*.enc.yaml`). The
  ciphertext is intentionally checked into git; finding ciphertext is not a
  vulnerability. The corresponding private Age keys are not stored in this
  repository.
- Self-XSS, missing security headers on pages that do not handle authenticated
  state, and other findings without a realistic exploit path.

## Cryptographic material

- All in-repo secrets are SOPS-encrypted with Age (`.sops.yaml` lists the
  current recipients). Reporting that ciphertext is present in git is not a
  vulnerability.
- The platform OCI artifact published to GHCR should be signed via cosign
  keyless signing (Fulcio + Rekor) against the GitHub Actions OIDC identity of
  this repository's `cd.yaml` workflow, and the cluster's `OCIRepository`
  should set `spec.verify` (with a `matchOIDCIdentity` regex as the policy
  decision point) so only artifacts from that trusted workflow are reconciled.
  Until both the signing step and consumer-side verification are in place in a
  given instance, the deploy pipeline is the only enforcement of artifact
  integrity — operate accordingly.
- Talos PKI, OpenBao unseal material, and the Hetzner API token are the three
  pieces of cryptographic material whose loss would force a full cluster
  rebuild; document their custody in your instance's disaster-recovery runbook.

## Public-repository hardening

Because this repository is public, the following constraints apply to all
contributions:

- Plaintext secrets must never be committed. All Kubernetes Secrets and any
  other sensitive material must be SOPS-encrypted (`*.enc.yaml`) and gated
  by the `.sops.yaml` rules.
- Third-party GitHub Actions must be pinned by commit SHA (not by tag), per
  the pinning policy in `zizmor.yml`. Dependabot is configured to update these
  (`.github/dependabot.yml`); if Renovate is also enabled, keep GitHub Actions
  assigned to a single tool to avoid two tools racing on the same files.
- Where cosign keyless signing and consumer-side `OCIRepository.spec.verify`
  are in place, bypassing artifact verification in a PR is a security
  regression. Where they are not yet, the deploy pipeline
  (`.github/workflows/cd.yaml`) is the only enforcement of artifact integrity;
  review PRs that touch it with the same care as PRs that would touch
  verification config.

[CVSS v3.1]: https://www.first.org/cvss/v3.1/specification-document
