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

### Observability: Coroot is the default

Both default cluster paths run Coroot. A new instance selects nothing:

| Cluster | Path | Earlier opt-in path |
|---|---|---|
| local / Docker | `clusters/local` | `clusters/local-coroot` |
| prod / Hetzner | `clusters/prod` | `clusters/prod-coroot` |

Coroot used to be an opt-in profile selected through
`spec.workload.kustomizationFile` in the KSail config. The two `-coroot` paths
remain as aliases that render exactly what the default paths render, so an
instance that opted in keeps working after a template sync. The KSail configs
belong to the instance and are excluded from template sync, so nothing moves
such an instance; point it back at `clusters/local` or `clusters/prod` when
convenient. After changing the path, publish the payload, update the
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

**An instance on an earlier stack migrates with its next template sync.**
An earlier instance ran Loki, Alloy and OpenCost, and every instance ran
kube-prometheus-stack. When the sync merges and Flux reconciles it, Flux removes
the Loki, Alloy and OpenCost releases, the kube-prometheus-stack release and the
`opencost` and `monitoring` namespaces, and installs Coroot. No KSail config
changes. Four things need your attention:

- Nothing is migrated, and the old data is deleted. Flux removes the
  `monitoring` namespace with everything in it: the Prometheus and Alertmanager
  volumes, their silences and metric history, and a Loki volume an earlier
  uninstall left behind. Take what you need from them before the sync merges.
- Helm does not delete CustomResourceDefinitions. The Prometheus operator's
  `monitoring.coreos.com` definitions stay until you delete them, and a chart
  that creates a ServiceMonitor when they exist keeps doing so until then.
- Set the `CLUSTER_HEARTBEAT_URL` secret (and `cluster_heartbeat_url` in the
  production cluster secret) before syncing. It is now the only off-cluster
  dead-man signal, and `ALERTMANAGER_HEARTBEAT_URL` is no longer read. You can
  reuse the old check: nothing else pings it once Alertmanager is gone. Give it
  a five-minute period and a ten-minute grace.
- `talos/` belongs to the instance, so the sync does not touch it. Delete
  `talos/control-planes/allow-node-exporter-ingress.yaml` and
  `talos/workers/allow-node-exporter-ingress.yaml`: nothing listens on that
  port now.

The stack runs Coroot and nothing beside it. It has no OpenCost,
has no Loki or Alloy log path, and has no kube-prometheus-stack: no Prometheus
operator, Alertmanager, node-exporter or kube-state-metrics, and no
`monitoring.coreos.com` resource in any payload. Cost allocation is therefore unavailable.
Coroot is the only observability UI. Docker runs Coroot
without the audit log forwarder, while Hetzner includes the forwarder for host
audit logs. Because Coroot's eBPF agent and the production audit collector need
host access, the `observability` namespace is exempt from the
Kyverno host and restricted-pod policies.

Production / Hetzner reuses the existing encrypted webhook
variable for Coroot incident and resolution notifications. Its matching provider
policy permits only `hooks.slack.com:443`, so keep this value a Slack incoming-webhook URL.
Flux notification-controller reuses the same `alertmanager_webhook_url` in
production to report failed reconciliations; the variable keeps its earlier
name so an existing instance needs no secret change. The
controller layer applies both Flux alerts before it waits for every controller
to become ready: one forwards the error events of every `Kustomization` and
every `HelmRelease`, while a
narrow info-severity path for dependency waits covers a prerequisite that is
not ready. There is no polling workload to configure.
notification-controller has no namespace wildcard, so the error alert lists
every namespace that holds a `HelmRelease`, and `scripts/validate-alert-coverage.sh`
fails CI when one is missing. An instance that adds a release in a new namespace
adds that namespace to the alert.
Per-alert notifications remain visible only in the Coroot UI; this avoids sending
every noisy alert to the shared webhook. Local / Docker Coroot stays notification-free.
The apps layer also stages one hardened `cluster-heartbeat` CronJob for the cluster
dead-man signal. It is the only one, so a production bootstrap requires the
`CLUSTER_HEARTBEAT_URL` secret. The CronJob runs at
platform-critical priority, and its dedicated policy permits only `hc-ping.com:443`
plus that hostname's exact DNS query. Bootstrap accepts only a canonical
`https://hc-ping.com/<lowercase-uuid>` URL, so
fragments, query strings, or trailing slashes cannot encrypt a monitor the
cluster cannot reach.
The substituted bearer URL lives in a Kubernetes Secret and reaches the container
through a Secret-backed environment variable. A shell builtin feeds it to curl as
stdin configuration, so neither the PodSpec nor curl's runtime argument vector
contains the credential.
The infrastructure layer narrows the generated namespace policies
around the CronJob's purpose-specific label. The dependent apps layer stages the heartbeat only after that
infrastructure reconciliation is ready, preventing an existing namespace-wide
deny policy from blocking the new workload during an upgrade. The invalid URL
fallback keeps local and unconfigured instances inert.
Flux notification-controller now owns reconciliation errors in
production, including dependency waits.
Some Prometheus alert rules have no replacement: certificate expiry, backup
freshness and autoscaler failures are not alerted today.
[`docs/dr/alerting.md`](dr/alerting.md) lists what is and is not alerted.

Open the Coroot UI at `https://observability.<your-domain>`. Community Edition
does not provide native OIDC, so every UI request goes through the
existing Dex-backed oauth2-proxy before the in-cluster auth proxy forwards it to
Coroot. Coroot grants its anonymous user the Admin role only behind that complete
SSO path; there is no direct Gateway route to the Coroot service.

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
recommended-label profiles build on the default paths, so they run Coroot too.

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
- `variables-cluster-secret.enc.yaml` — SOPS-encrypted secrets (the alert webhook and heartbeat URLs,
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
  `HETZNER_LOCATION`, `SSO_GITHUB_APP_CLIENT_ID`, `R2_BUCKET` (optional), `APP_ID`,
  `APP_CLIENT_ID`.
- **Secrets you set:** `HCLOUD_TOKEN`, `GHCR_TOKEN`, `CLOUDFLARE_API_TOKEN`,
  `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `ALERTMANAGER_WEBHOOK_URL`,
  `CLUSTER_HEARTBEAT_URL`, `SSO_GITHUB_APP_CLIENT_SECRET`, `APP_PRIVATE_KEY`.
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
- [`k8s/bases/apps/`](../k8s/bases/apps) — the demo applications (homepage, whoami).
- [`k8s/components/`](../k8s/components) — shared transformations: the HelmRelease
  retry defaults and drift detection every HelmRelease-owning kustomization lists, and the
  shared policy set the opt-in profiles add.
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
