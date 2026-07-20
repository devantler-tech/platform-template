# Templating guide

This repository **is** the template. The shared platform scaffolding (bases,
providers, cluster Flux Kustomizations) stays untouched across every instance;
everything that genuinely varies per instance is a small set of **inputs**.

You normally don’t edit those inputs by hand. The
[**Bootstrap workflow**](../.github/workflows/bootstrap.yaml) renders them for you
from GitHub **Variables** and **Secrets** when you first stand up an instance — see
[`docs/BOOTSTRAP.md`](BOOTSTRAP.md). This document explains **what each input is, how
the bootstrap fills it, and how to change it** afterwards (or to add a new
environment). Anything not listed here is template *body* — leave it alone unless
you’re upstreaming a platform change.

> **Mental model.** GitHub Variable/Secret → bootstrap step → a rendered value in a
> file in this repo. To change an input after bootstrap, you edit the rendered file
> (and re-encrypt, for secrets) and let Flux reconcile — exactly what the bootstrap
> wrote the first time.

## Template inputs

### 1. ksail configs — one per environment

Files: [`ksail.yaml`](../ksail.yaml) (local), [`ksail.prod.yaml`](../ksail.prod.yaml).

Only these fields genuinely vary per instance:

| Field | local | prod | Filled by bootstrap from |
|---|---|---|---|
| `metadata.name` | cluster short name (`local`) | `prod` | — (fixed) |
| `spec.cluster.connection.context` | kubeconfig context | kubeconfig context | — (fixed) |
| `spec.cluster.localRegistry.registry` | n/a | OCI registry URL for the manifest artifact | repo owner/name (`REPLACE_OWNER`/`REPLACE_REPO`) + `GHCR_TOKEN` |
| `spec.provider.hetzner.location` | n/a | primary Hetzner location (`fsn1`, `nbg1`, `hel1`, …) | `HETZNER_LOCATION` Variable |
| `spec.provider.hetzner.{controlPlane,worker}ServerType` | n/a | Hetzner server types (default `cx33`) | — (edit to resize) |
| `spec.provider.hetzner.networkCidr` | n/a | private network CIDR | — (edit if it clashes) |
| `spec.cluster.autoscaler.node.pools` | n/a | node pool definitions (name, serverType, location, min, max) | — (edit to tune autoscaling) |
| `spec.cluster.autoscaler.node.maxNodesTotal` | n/a | hard ceiling on total cluster nodes | — (edit to cap cost) |
| `spec.workload.kustomizationFile` | `clusters/local` | `clusters/prod` | — (choose a default or opt-in profile) |

Everything else (distribution, provider, CNI, GitOps engine, timeouts,
`certManager`/`metricsServer`/`policyEngine`, Talos/Kubernetes version pins,
`sourceDirectory`, tag) should match across all Hetzner-backed instances. The
autoscaler is documented in [`node-autoscaling.md`](node-autoscaling.md).

### Select the transitional Coroot profile

The default paths keep the existing observability stack. To evaluate Coroot,
change only `spec.workload.kustomizationFile` in the KSail config for the cluster:

| Cluster | Default | Coroot profile |
|---|---|---|
| local / Docker | `clusters/local` | `clusters/local-coroot` |
| prod / Hetzner | `clusters/prod` | `clusters/prod-coroot` |

The KSail configs belong to the instance and are excluded from template sync, so
the choice persists when shared platform files update. To return to the default,
restore `clusters/local` or `clusters/prod`.

After selecting or reverting the profile, publish the payload, update the
FluxInstance sync path, and then ask Flux to reconcile it. Neither `cluster
update` alone nor `workload push` plus `workload reconcile` alone completes all
three steps:

```bash
# local / Docker
ksail --config ksail.yaml workload push
ksail --config ksail.yaml cluster update
ksail --config ksail.yaml workload reconcile

# prod / Hetzner
ksail --config ksail.prod.yaml workload push
ksail --config ksail.prod.yaml cluster update
ksail --config ksail.prod.yaml workload reconcile
```

This profile is transitional. It enables Coroot, removes OpenCost and its Headlamp
plugin, retires the legacy Loki and Alloy log path, and keeps kube-prometheus-stack
until the metrics and alerting migration is proven separately. Cost allocation is therefore unavailable in this
profile; it does not connect OpenCost to Coroot Prometheus. Docker runs Coroot
without the audit log forwarder, while Hetzner includes the forwarder for host
audit logs. Because Coroot's eBPF agent and the production audit collector need
host access, the profile also exempts the `observability` namespace from the
Kyverno host and restricted-pod policies; the default paths keep those policies
enforced for that namespace.

The production / Hetzner Coroot profile reuses the existing encrypted webhook
variable for Coroot incident and resolution notifications. Its matching provider
policy permits only `hooks.slack.com:443`, so keep this value a Slack incoming-webhook URL.
Per-alert notifications remain visible only in the Coroot UI; this avoids sending
every noisy alert to the shared webhook. Local / Docker Coroot stays notification-free.
Kube-prometheus-stack keeps owning its alert rules until that remaining metrics
and alerting migration is delivered separately.

Open the Coroot UI at `https://observability.<your-domain>`. Community Edition
does not provide native OIDC, so this profile sends every UI request through the
existing Dex-backed oauth2-proxy before the in-cluster auth proxy forwards it to
Coroot. The profile grants Coroot's anonymous Admin role only behind that complete
SSO path; there is no direct Gateway route to the Coroot service. Returning to the
default cluster path removes the route and the profile-only Admin role together.

### Add recommended workload labels at admission

The default paths do not load this shared policy, so existing instances remain
unchanged until they select it. To fill missing identity labels at admission,
change only `spec.workload.kustomizationFile` in the KSail config for the cluster:

| Cluster | Default | Recommended-label profile |
|---|---|---|
| local / Docker | `clusters/local` | `clusters/local-recommended-labels` |
| prod / Hetzner | `clusters/prod` | `clusters/prod-recommended-labels` |

The profile adds the SHA-pinned shared `add-recommended-labels` Kyverno policy.
It fills missing `app` and `app.kubernetes.io/name` labels on Deployments,
StatefulSets, and DaemonSets without overwriting labels the workload author set.
System namespaces, generated names, and names that cannot be valid Kubernetes
label values are left unchanged.

The KSail configs belong to the instance and are excluded from template sync, so
the selection persists across shared updates. To disable the policy, restore
`clusters/local` or `clusters/prod`. After selecting or reverting the
recommended-label profile, run the same three-step sequence shown above:
`workload push` → `cluster update` → `workload reconcile`. It publishes the
payload, updates the FluxInstance sync path, and reconciles it. The
recommended-label profiles use the default observability paths; they do not also
select the transitional Coroot profile.

### 2. Talos machine-config directories

- [`talos-local/`](../talos-local) — Docker-provider patches (local).
- [`talos/`](../talos) — Hetzner-provider patches (prod). Split into `cluster/`,
  `control-planes/`, and `workers/` as ksail expects.

Bootstrap rewrites the placeholder domain (`platform.example.com`) here to your
`DOMAIN` (the Talos OIDC issuer references it). Edit the YAML patches inside if your
DNS, OIDC issuer, networking, or storage layout differs. When changing the Talos
version or extensions, keep them in lockstep with the `ksail.prod.yaml` pins — see
[`rwx-storage.md`](rwx-storage.md) for the Image Factory schematic workflow.

### 3. Per-cluster overlay

Each [`k8s/clusters/<env>/kustomization.yaml`](../k8s/clusters) carries two inputs in
a local-config `cluster-meta` ConfigMap:

```yaml
data:
  cluster_name: <env>          # drives spec.path: clusters/<env>/bootstrap
  provider: <docker|hetzner>   # drives spec.path: providers/<provider>/...
```

Replacements in the same file rewrite the sentinel placeholders (`__CLUSTER__`,
`__PROVIDER__`) that come from [`k8s/clusters/base/`](../k8s/clusters/base). Adding a
new environment is “copy an existing overlay directory, change these two values,
point ksail at it” (see [Adding a new environment](#adding-a-new-environment)).

### 4. Per-cluster bootstrap variables

Each [`k8s/clusters/<env>/bootstrap/`](../k8s/clusters) directory holds the only
resources Flux reads that are genuinely per-cluster:

- `variables-cluster-config-map.yaml` — non-secret values (hostnames, URLs, issuer,
  replica counts, Hetzner LB location/type, Longhorn settings, etc.). Bootstrap fills
  `domain`, `domain_regex`, `github_app_client_id`, and `admin_email` from your
  Variables; the rest are sensible defaults you can tune.
- `variables-cluster-secret.enc.yaml` — SOPS-encrypted secrets (Alertmanager URLs,
  the OIDC/cookie secrets, the GitHub SSO client secret, the Hetzner/R2 tokens).
  Bootstrap fills these from your Secrets and `sops -e` encrypts them.

There is also a shared [`k8s/bases/bootstrap/`](../k8s/bases/bootstrap) layer
(`variables-base-config-map.yaml` + `variables-base-secret.enc.yaml`) for values
common to all clusters (Cloudflare account/zone, R2 endpoint/bucket and credentials).

**To change a non-secret value after bootstrap:** edit the ConfigMap and let Flux
reconcile. **To change a secret value:** edit it with `sops` (which decrypts, lets you
set, and re-encrypts), then commit:

```bash
sops --set '["stringData"]["alertmanager_webhook_url"] "https://hooks.slack.com/services/XXX/YYY/ZZZ"' \
  k8s/clusters/prod/bootstrap/variables-cluster-secret.enc.yaml
```

### 5. SOPS configuration

[`.sops.yaml`](../.sops.yaml) lists the Age public keys authorised to decrypt
secrets. In a fresh template it contains the `<INSTANCE_AGE_PUBLIC_KEY>` placeholder;
**bootstrap replaces it with the public half of the Age key it generates**, then
encrypts every `*.enc.yaml`. The matching private key is stored as the
`SOPS_AGE_KEY` secret (in the `prod` environment and repo-level).

To rotate the key or add recipients (e.g. a hardware-backed YubiKey identity for cold
backup), follow [`secret-rotation.md`](secret-rotation.md) and
[`dr/crypto-custody.md`](dr/crypto-custody.md).

### 6. CI/CD configuration (GitHub Variables & Secrets)

The GitHub Actions workflows are driven by the Variables and Secrets you set on the
repository. The **full, authoritative tables** — name → what it is → where to get it,
plus which values the bootstrap auto-generates — live in
[`docs/BOOTSTRAP.md` → Configuration](BOOTSTRAP.md#configuration). In short:

- **Variables:** `DOMAIN`, `CLOUDFLARE_ZONE`, `CLOUDFLARE_ACCOUNT_ID`, `ADMIN_EMAIL`,
  `HETZNER_LOCATION`, `GITHUB_APP_CLIENT_ID`, `R2_BUCKET` (optional), `APP_ID`.
- **Secrets you set:** `HCLOUD_TOKEN`, `GHCR_TOKEN`, `CLOUDFLARE_API_TOKEN`,
  `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `ALERTMANAGER_WEBHOOK_URL`,
  `ALERTMANAGER_HEARTBEAT_URL`, `GITHUB_APP_CLIENT_SECRET`, `APP_PRIVATE_KEY`.
- **Auto-generated by bootstrap:** `SOPS_AGE_KEY`, and the `prod`-environment
  `KUBE_CONFIG` / `TALOS_CONFIG`.

See [`.github/workflows/`](../.github/workflows) for the exact names in use.

## Template body (do not edit when instantiating)

- [`k8s/clusters/base/`](../k8s/clusters/base) — shared Flux Kustomizations with
  sentinel paths.
- [`k8s/bases/infrastructure/`](../k8s/bases/infrastructure) — Cilium, cert-manager,
  Kyverno, alerting configs, OpenBao vault, External Secrets Operator,
  ClusterSecretStore, vault-config Job, vault-seed PushSecrets, vault-backup CronJob,
  and the rest of the controller set.
- [`k8s/bases/apps/`](../k8s/bases/apps) — the demo applications (homepage, whoami,
  headlamp).
- [`k8s/components/`](../k8s/components) — shared opt-in transformations used by
  provider profiles, such as removing OpenCost across controller, infrastructure,
  and app layers.
- [`k8s/providers/{docker,hetzner}/`](../k8s/providers) — provider-specific assembly
  of the bases.

Changes here are **platform changes** — contribute them upstream to
[`devantler-tech/platform`](https://github.com/devantler-tech/platform) rather than
diverging your instance, so you keep inheriting fixes.

## Secrets architecture (summary)

The platform uses a **hybrid SOPS + OpenBao** model; the full design and rotation
plan is in [`secret-rotation.md`](secret-rotation.md). In brief:

- **SOPS + Age** encrypts externally-sourced seed secrets in Git (API tokens, service
  credentials). A few bootstrap-critical ones are consumed directly via Flux
  `postBuild` substitution; the rest are seeded into OpenBao.
- **ESO password generators** create randomly-generatable secrets (database
  passwords, OIDC client secrets) and seed them into OpenBao on first reconciliation.
- **OpenBao** (a self-hosted Vault fork) is the single source of truth for non-
  bootstrap secrets, running in the `openbao` namespace with file storage.
- **External Secrets Operator** syncs secrets from OpenBao into native Kubernetes
  `Secret`s via `ExternalSecret` + `ClusterSecretStore`.
- **PushSecret** CRs in `k8s/bases/infrastructure/vault-seed/` seed OpenBao from both
  generators and SOPS-decrypted Flux variable Secrets.

> The Docker provider’s platform CA key pair is **not** stored in OpenBao —
> cert-manager auto-generates it via a self-signed CA `Certificate`
> (`k8s/providers/docker/infrastructure/cluster-issuers/`). The Hetzner provider uses
> Let’s Encrypt and needs no local CA.

On a fresh cluster the whole chain bootstraps itself — no manual vault steps are
required.

## Adding a new environment

1. `cp -R talos talos-<env>` (or reuse `talos`).
2. `cp -R k8s/clusters/prod k8s/clusters/<env>` and update `cluster_name` +
   `provider` in the new overlay’s `cluster-meta` patch.
3. Edit `k8s/clusters/<env>/bootstrap/variables-cluster-{config-map,secret.enc}.yaml`
   (re-encrypt the secret file with your Age key).
4. `cp ksail.prod.yaml ksail.<env>.yaml` and update the per-cluster fields in
   [§1](#1-ksail-configs--one-per-environment).
5. Wire the new environment into [`.github/workflows/`](../.github/workflows) as
   needed.

That’s the complete set of edits — everything else is inherited from the shared
scaffold.
