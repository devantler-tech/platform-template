# GitHub Copilot review instructions — platform-template

`devantler-tech/platform-template` is a **GitHub template for a complete GitOps
Kubernetes platform** (Talos + KSail + Flux). It is **not a code repo** — all
"code" is Kubernetes YAML, managed with Kustomize overlays and reconciled by Flux
CD from OCI artifacts. Enforce the rules below when reviewing. They complement
`AGENTS.md` (the canonical, cross-tool instructions) — keep both in sync; if a PR
changes a convention here, it updates `AGENTS.md` too.

## Scope & altitude
- Review manifests **statically** (Kustomize build, schema/policy) — never assume
  a PR is applied to a live cluster as part of review.
- Stack: **Flux CD** (OCI artifacts), **Kustomize** (base → provider → cluster
  overlays), **KSail** (cluster + workload lifecycle), **Talos Linux**, **Cilium**
  (CNI + Gateway API), **Kyverno** (policy), **SOPS + Age** (secrets). Flag
  additions that diverge from this stack without justification.

## Secrets — SOPS-encrypted only
- Secrets are encrypted at rest with **SOPS + Age** (per-environment keys). **Flag
  any plaintext secret, credential, token, private key, or unencrypted `Secret`
  data** committed to the repo — secret material must be SOPS-encrypted and match
  the `.sops.yaml` rules. The Age key itself is generated per-instance by Bootstrap
  and must never be committed.

## Template-owned vs instance-owned
- **Template-owned (changed only here, never in an instance):** `k8s/clusters/base/`
  (Flux wiring), `k8s/bases/` (shared infrastructure), `k8s/providers/` overlays,
  and the workflows `cd.yaml`, `release.yaml`, `template-sync.yaml`,
  `validate-scaffold.yaml`, `bootstrap.yaml`, plus `CLAUDE.md` and `zizmor.yml`.
- **Instance-owned** files (`AGENTS.md`, `README.md`, KSail configs, `.sops.yaml`,
  Talos config, bootstrap variables, encrypted secrets) are listed in
  `.templatesyncignore`. Flag a PR that edits shared plumbing in a way an instance
  would lose on the next template-sync, or that removes an entry from
  `.templatesyncignore` without reason.

## Kustomize & Flux structure
- Respect the overlay chain (base → provider → cluster) and the Flux Kustomization
  ordering (bootstrap → infrastructure-controllers → infrastructure → apps). Keep
  resources in the right layer; flag a base resource added from an overlay or a
  reference that breaks `kubectl kustomize`.

## Commits, CI & security
- **PR titles must be Conventional Commits** (`feat:`/`fix:`/`chore:`/`docs:`/
  `ci:`/`refactor:`/`test:`) — semantic-release squash-merges the title into the
  release, so a non-conventional or bracket-prefixed title corrupts it. Flag
  violations.
- Workflow changes must pass `actionlint`. Pin third-party actions to a
  full-length commit SHA and set least-privilege `permissions:`. Flag unpinned
  actions and over-broad token scopes.
- Never weaken or skip a check to make CI pass (no disabled steps, `--no-verify`,
  or "flaky"-dismissals) — fix the underlying cause.

Keep this file concise (≤ 4000 chars — Copilot review truncates beyond that) and
in sync with `AGENTS.md`.
