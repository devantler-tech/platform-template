# Secrets architecture & rotation design

This document describes how the platform manages secrets — the **SOPS → OpenBao →
External Secrets** architecture — and the **design for automated rotation**,
preferring **OpenBao-native** mechanisms. Treat the rotation section as a reference
design you adopt per stateful workload; each phase ships as its own reviewed PR.

> The examples below use a generic **database-backed application** (a workload that
> reads a DB credential from a `Secret` at startup, with the database run by the
> CloudNativePG operator or a Helm-installed engine). Substitute your own app.

## Secrets architecture

The platform uses a **hybrid SOPS + OpenBao** model:

- **SOPS + Age** encrypts externally-sourced secrets in Git (API tokens, service
  credentials). These are consumed by `infrastructure-controllers` via Flux
  `postBuild` substitution for bootstrap-critical controllers (e.g. the Hetzner CSI),
  and seeded into OpenBao via PushSecrets for all other consumers.
- **ESO password generators** create randomly-generatable secrets (database
  passwords, OIDC client secrets). PushSecrets seed these into OpenBao at first
  reconciliation.
- **OpenBao** (a self-hosted Vault fork) is the single source of truth for all
  non-bootstrap secrets. It runs in the `openbao` namespace with standalone file
  storage.
- **External Secrets Operator** syncs secrets from OpenBao into native Kubernetes
  `Secret` objects via `ExternalSecret` and `ClusterSecretStore` CRs.
- **PushSecret** CRs in [`k8s/bases/infrastructure/vault-seed/`](../k8s/bases/infrastructure/vault-seed)
  seed OpenBao from both generators and SOPS-decrypted Flux variable Secrets.

### Secret categories

| Category | Source | Example | Mechanism |
|----------|--------|---------|-----------|
| Randomly-generatable | ESO password generator | DB passwords, OIDC client secrets | Generator → PushSecret → OpenBao → ExternalSecret |
| Externally-sourced | SOPS-encrypted Git | API tokens, service credentials | SOPS → PushSecret → OpenBao → ExternalSecret |
| Bootstrap-critical | SOPS + Flux substitution | Hetzner Cloud token | SOPS → Flux `postBuild` → inline K8s Secret |

### First-time vault setup (after cluster creation)

1. Create the cluster: `ksail cluster create && ksail workload push && ksail workload reconcile`.
2. Flux deploys `infrastructure-controllers` → OpenBao starts (sealed, uninitialized).
   Controllers with placeholder Secrets (Dex, oauth2-proxy) start with dummy values.
3. Flux deploys `infrastructure` → the `vault-config` Job auto-initializes:
   - the `vault-init` container runs `bao operator init`, capturing the unseal key +
     root token;
   - the `store-keys` container persists them in the `openbao-unseal` K8s Secret;
   - the `vault-config` container configures policies, auth roles, and the KV engine.
4. OpenBao’s `postStart` hook auto-unseals on subsequent restarts using the
   `openbao-unseal` Secret (volume-mounted with `optional: true`).
5. ESO password generators create random secrets; PushSecrets seed all values (both
   generated and SOPS-sourced) into OpenBao.
6. ExternalSecrets sync secrets to consumer namespaces, overwriting the placeholders.
7. Reloader restarts the affected controllers (Dex, oauth2-proxy) with the real
   secrets.

> The Docker provider’s platform CA key pair is **not** stored in OpenBao —
> cert-manager auto-generates it via a self-signed CA `Certificate`
> ([`k8s/providers/docker/infrastructure/cluster-issuers/`](../k8s/providers/docker/infrastructure/cluster-issuers)).
> The Hetzner provider uses Let’s Encrypt and does not need a local CA.

No manual steps are required — cluster creation is fully automated.

---

## Rotation design

Status: **reference design.** Goal: automated rotation of platform secrets,
preferring OpenBao-native mechanisms.

### Current state

- **OpenBao = KV v2 + Kubernetes auth only** (configured by the `vault-config` Job).
  No Database secrets engine is enabled by default.
- **Two sourcing paths coexist (mid-migration):**
  - **OpenBao → ESO**: generators
    ([`k8s/bases/infrastructure/vault-seed/generators.yaml`](../k8s/bases/infrastructure/vault-seed))
    seed OpenBao KV once; `ExternalSecret`s sync to consumer namespaces (1 h refresh).
    Used by app DB/cache credentials, OIDC client secrets for the demo apps, the
    Cloudflare token, the R2 credentials, and the Alertmanager URLs.
  - **SOPS → Flux postBuild substitution**: `${dex_client_secret}`,
    `${flux_web_client_secret}`, `${oauth2_proxy_cookie_secret}` etc. are still read
    from `k8s/clusters/*/bootstrap/variables-cluster-secret.enc.yaml`. **Dex (the OIDC
    provider) and oauth2-proxy read from here, not OpenBao.**

### Why a non-zero `refreshInterval` does **not** rotate generators

The vault-seed PushSecrets use `refreshInterval: "0"`. A non-zero value would **not**
rotate the generated values: the ESO PushSecret reconciler persists a `GeneratorState`
and reuses the prior state, keeping generator output **stable** across reconciles.
**Conclusion: rotation needs an explicit mechanism, not a config flip.**

### Feasibility by secret class

| Class | Examples | OpenBao-native fit | Plan |
| --- | --- | --- | --- |
| **Database creds** | app DB user (MySQL/Postgres), cache user | ✅ **Database engine, static roles** | Phase 1–2 below |
| **Internal random** | oauth2-proxy cookie secret | ❌ no native engine | Migrate consumer to OpenBao, rotate via scheduled Job; no shared party → only forces re-login |
| **Shared OIDC** | `dex_client_secret`, `flux_web_client_secret` | ❌ no native engine | Unify Dex + clients on OpenBao first; coordinated rotation (short consumer refresh) to avoid auth-mismatch skew |
| **Provider tokens** | Cloudflare, Hetzner, GitHub, R2 | ❌ external system-of-record | Scheduled job calling the provider API → write OpenBao; mostly out of scope |
| **Roots** | SOPS Age key, OpenBao unseal/root | ❌ | Manual runbook + calendar reminder |

### OpenBao-native rotation (chosen mechanism)

OpenBao’s **Database secrets engine** supports **static roles** for MySQL/MariaDB,
PostgreSQL, and Redis-compatible stores: OpenBao stores and **automatically rotates
the password of an existing database user** on a `rotation_period`. This fits apps
that read a credential from a `Secret` at startup — unlike *dynamic* roles, which mint
ephemeral users the app would have to re-fetch.

### Phase 1 — a database-backed app’s DB user

1. **Enable + configure the engine** (in the `vault-config` Job, idempotent):
   - `bao secrets enable database` (mount `database/`).
   - Configure a connection plugin pointing at the app’s database Service,
     authenticating with the **root/admin** credential already in KV
     (`apps/<app>/db` → admin password). Restrict `allowed_roles` to the app role.
   - Create a static role for the app user: `username=<app-user>`,
     `rotation_period=720h` (30 d). **Target the app user, never the admin/root user**
     (OpenBao does not distinguish root when rotating).
2. **Consume the rotated credential** — *not* a plain `ExternalSecret`. ESO’s Vault
   provider supports **KV only**, so the database engine must be read via the
   **`VaultDynamicSecret` generator** (`generators.external-secrets.io`). The
   generator does a GET on `database/static-creds/<role>` and returns the `data` map;
   an `ExternalSecret` consumes it via `dataFrom.sourceRef.generatorRef` and maps the
   `password` field into the app’s Secret. Keep the admin/root password on KV (root
   rotation is out of scope; never put root under a static role).
3. **Propagation**: the ExternalSecret’s `refreshInterval` re-reads the current static
   cred; Reloader restarts the app pods when the password changes. Use a **short**
   refreshInterval (~1 m) so the post-rotation window (below) is small.

### Credential handover sequence

- **Fresh cluster** (Flux order `bootstrap → infrastructure-controllers → infrastructure → apps`):
  KV seeds → ESO writes the DB Secret → the database bootstraps the app user with that
  password → `vault-config` enables the DB engine and creates the static role →
  OpenBao performs the **initial rotation** → ESO updates the Secret → Reloader
  restarts the app with the new password.
- **Existing cluster**: same, but the static role’s first rotation changes the live
  password immediately. Ordering must ensure the DB-engine config runs **after** the
  database is reachable.

### Risks & rollback

- **Re-read behavior.** Unlike the PushSecret + password generator (which *caches* via
  `GeneratorState`), the **`VaultDynamicSecret` generator re-reads on every
  ExternalSecret refresh** — so rotation **does** propagate to the consumer Secret
  within one refresh cycle. No silent-rotation time-bomb.
- **Post-rotation window**: the app reads its password once at startup, so after every
  rotation there is a brief window (≈ ExternalSecret refreshInterval + pod restart)
  where existing/new DB connections use the stale password and fail until Reloader
  restarts the app. Inherent to a non-Vault-native app; bounded by a short
  refreshInterval + a long `rotation_period`.
- **Risk**: a misconfigured connection/role rotates the user to a value the `Secret`
  doesn’t reflect → the app loses DB access. **Mitigation**: validate the full chain on
  the local Talos+Docker cluster (the CI system test exercises DB engine + ESO + app
  bring-up) before any prod tag.
- **Rollback**: point the app’s DB ExternalSecret back at KV (`apps/<app>/db`), then
  manually reset the user’s password to the KV value (`ALTER USER`). The DB-engine
  mount can stay (unused) or be disabled.
- **Never** put root/admin under a static role.

### Validation

- `kubectl kustomize k8s/clusters/local/` and `kubectl kustomize k8s/clusters/prod/`
  both build; `ksail workload validate` and
  `ksail --config ksail.prod.yaml workload validate` pass.
- CI’s full local-cluster system test must bring the app up healthy with creds sourced
  from `database/static-creds/<role>`.

### Phase 2 — cache / Redis-compatible store

Same pattern using OpenBao’s Redis-compatible plugin and a static role for the cache
user, once Phase 1 is proven.

## Non-database secrets (not OpenBao-native)

- **oauth2-proxy cookie secret** — first migrate the consumer from the SOPS Flux var
  to an OpenBao `ExternalSecret`, then rotate on a cadence via a small scheduled Job
  that writes a fresh random value to the KV path. No shared party → the only effect
  is forced re-login. (Cleanest non-DB rotation; can ship independently of the DB
  work.)
- **OIDC client secrets** — require unifying Dex (the provider, currently SOPS) and
  all clients onto OpenBao, then rotating with a short consumer `refreshInterval` (or a
  coordinated job) so Dex and clients converge before the old secret is invalid;
  otherwise rotation causes an auth-mismatch outage.
- **Provider tokens / roots** — manual or provider-API driven; document a runbook and
  a calendar reminder for the SOPS Age key and the OpenBao unseal/root token. See
  [`dr/crypto-custody.md`](dr/crypto-custody.md) for the per-artifact threat model.

## Rollout order

1. Phase 1 — a database-backed app’s static-role rotation (the flagship pattern).
2. Phase 2 — cache / Redis-compatible static-role rotation.
3. oauth2-proxy cookie secret migration + scheduled rotation.
4. Later — OIDC coordination; provider-token jobs; root-secret runbook.
