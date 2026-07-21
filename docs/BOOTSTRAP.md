# Bootstrap guide

This is the authoritative, end-to-end guide for standing up a new instance of this
template — from **“Use this template”** to a **running Hetzner cluster with live
DNS**, unattended.

The whole thing is driven by one workflow,
[`.github/workflows/bootstrap.yaml`](../.github/workflows/bootstrap.yaml). You give
it some GitHub configuration and one GitHub App; it does the rest:

1. Generates an Age keypair and wires the public key into `.sops.yaml`.
2. Renders the per-instance configuration from GitHub **Variables**.
3. Encrypts the secret values from GitHub **Secrets** into the committed `*.enc.yaml` files.
4. Provisions the cluster with `ksail cluster create` (Talos on Hetzner).
5. Writes the cluster-derived credentials (kubeconfig, talosconfig, the generated Age key) back as `prod` **environment** secrets — this is what lets the steady-state CD pipeline take over.
6. Points Cloudflare DNS at the new load balancer (best-effort).
7. Publishes the manifests (OCI → GHCR) and reconciles Flux.
8. Commits the rendered + encrypted tree back so the instance is reproducible.

> **One run, once.** Bootstrap calls `ksail cluster create` — the genuine
> first-provisioning primitive. It is **not** the steady-state path. After it
> succeeds, the cluster is owned by the steady-state pipelines (`ci.yaml` /
> `cd.yaml`), which run `ksail cluster update`. See
> [Post-bootstrap: steady state](#post-bootstrap-steady-state).

---

## Prerequisites

### External accounts

| Account | Used for | Notes |
|---|---|---|
| **Hetzner Cloud** | The cluster’s infrastructure + a managed Cloud Load Balancer for ingress | Create a project; mint a read/write API token. |
| **Cloudflare** | DNS for your domain (apex + wildcard → the load balancer) and Origin CA | Your domain’s zone must be on Cloudflare; mint a scoped API token. |
| **Cloudflare R2** (or any S3-compatible object store) | Off-cluster backup target for Velero + CloudNativePG | An R2 bucket + an access key pair. Optional but strongly recommended. |
| **GitHub App for cluster SSO** | Dex’s GitHub OIDC connector — lets you log in to platform UIs and `kubectl` with GitHub | A *second*, separate App from the bootstrap App below (this one is the cluster’s identity provider). |
| **GitHub App for the bootstrap** | Lets the workflow write `prod` environment secrets back | See [Install the bootstrap GitHub App](#1-install-the-bootstrap-github-app). |
| **GHCR (GitHub Container Registry)** | Hosts the published OCI manifest artifact | A token with `packages: read/write`. |
| **An external heartbeat monitor** (e.g. [healthchecks.io](https://healthchecks.io)) | Dead-man’s-switch so you’re paged if the whole cluster goes dark | Optional; see [`docs/dr/alerting.md`](dr/alerting.md). |

> **You do not need to install SOPS, Age, KSail, or Talos locally to bootstrap.**
> The workflow installs its own tooling on the runner. You only need them for
> [local development](../README.md#local-development) or hands-on operations.

### 1. Install the bootstrap GitHub App

The bootstrap’s final, critical act is to write the cluster credentials it just
generated (`KUBE_CONFIG`, `TALOS_CONFIG`, `SOPS_AGE_KEY`) back as **`prod`
environment secrets**, so every later deploy is unattended. **The default
`GITHUB_TOKEN` cannot set repository or environment secrets.** That is the one and
only reason an elevated credential is required.

Provide it as a **GitHub App** (recommended) or a **fine-grained PAT**, granted these
repository permissions:

- **Contents: write** — commit the rendered + encrypted tree back.
- **Secrets: write** — write the `prod` environment secrets.
- **Environments: write** — create the `prod` environment.
- **Actions: write** — manage workflow-visible secrets.

**Using a GitHub App (recommended):**

1. Create a GitHub App (org or personal): *Settings → Developer settings → GitHub
   Apps → New GitHub App*. Grant the four repository permissions above.
2. Generate a **private key** for the App (downloads a `.pem`).
3. **Install** the App on your new instance repository.
4. Provide its credentials to the repo:
   - **Variable** `APP_ID` = the App’s numeric App ID.
   - **Secret** `APP_PRIVATE_KEY` = the full contents of the `.pem`.

The workflow mints a short-lived installation token from these via
`actions/create-github-app-token`, and uses *that* token (not `GITHUB_TOKEN`) for the
checkout, the commit-back, and the secret writes.

**Using a fine-grained PAT instead:** create a fine-grained PAT scoped to the repo
with the same four permissions, and adapt the `app-token` step to use it. The App is
preferred because its token is short-lived and scoped to the install.

> So, to be explicit and honest about the UX: this is **“GitHub config + one GitHub
> App install,”** not literally only secrets. Everything else the workflow needs it
> generates itself.

---

## Configuration

Set these in your **new instance repository** under *Settings → Secrets and variables
→ Actions*. Variables are non-secret; Secrets are encrypted.

### GitHub Variables (non-secret)

| Variable | What it is | Where to get it |
|---|---|---|
| `DOMAIN` | The platform’s base hostname; services are exposed at `<svc>.<DOMAIN>` (e.g. `platform.example.com`) | You choose it — a subdomain of your Cloudflare zone. |
| `CLOUDFLARE_ZONE` | The Cloudflare zone the domain lives in (e.g. `example.com`) | Cloudflare dashboard → your domain. |
| `CLOUDFLARE_ACCOUNT_ID` | Your Cloudflare account ID (used to build the R2 S3 endpoint) | Cloudflare dashboard → account home → **Account ID**. |
| `ADMIN_EMAIL` | Operator email; used for Let’s Encrypt registration and the cluster’s read-only OIDC RBAC subject (e.g. `admin@example.com`) | You choose it. |
| `HETZNER_LOCATION` | Primary Hetzner datacenter: `fsn1`, `nbg1`, or `hel1` | [Hetzner locations](https://docs.hetzner.com/cloud/general/locations/). |
| `GITHUB_APP_CLIENT_ID` | **Client ID** of the *cluster SSO* GitHub App (Dex’s GitHub connector) | The SSO App’s settings page. |
| `R2_BUCKET` | Backup bucket name (optional; defaults to `platform-backups`) | Cloudflare R2 → your bucket. |
| `APP_ID` | App ID of the **bootstrap** GitHub App (see prerequisites) | The bootstrap App’s settings page. |

### GitHub Secrets

| Secret | What it is | Where to get it |
|---|---|---|
| `HCLOUD_TOKEN` | Hetzner Cloud API token (read/write) — provisions nodes, LB, network | Hetzner console → project → **Security → API tokens**. |
| `GHCR_TOKEN` | GHCR token with `packages: read/write` — push/pull the OCI manifest | GitHub → *Settings → Developer settings → Tokens* (classic with `write:packages`, or a fine-grained PAT). |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token — DNS edit for the zone (+ Origin CA if used) | Cloudflare → **My Profile → API Tokens**. Scope to the zone’s DNS. |
| `R2_ACCESS_KEY_ID` | R2 (S3) access key ID for backups | Cloudflare R2 → **Manage R2 API Tokens**. |
| `R2_SECRET_ACCESS_KEY` | R2 (S3) secret access key for backups | Same place as the access key ID. |
| `ALERTMANAGER_WEBHOOK_URL` | Incoming webhook for alert notifications (e.g. Slack) | Your chat platform’s incoming-webhook setup. |
| `ALERTMANAGER_HEARTBEAT_URL` | Ping URL for the off-cluster dead-man’s-switch | healthchecks.io (or similar) check ping URL. |
| `GITHUB_APP_CLIENT_SECRET` | **Client secret** of the *cluster SSO* GitHub App (Dex’s GitHub connector) | The SSO App’s settings page (generate a client secret). |
| `APP_PRIVATE_KEY` | Private key (`.pem`) of the **bootstrap** GitHub App | Generated when you created the bootstrap App. |

### Auto-generated by the bootstrap — you never set these

| Secret | Scope | What it is |
|---|---|---|
| `SOPS_AGE_KEY` | `prod` environment **and** repo-level | The Age private key the workflow generates; the repo-level copy lets CI decrypt for validation/system-tests. |
| `KUBE_CONFIG` | `prod` environment | The kubeconfig produced by `ksail cluster create`. |
| `TALOS_CONFIG` | `prod` environment | The talosconfig produced by `ksail cluster create`. |
| Internal OIDC / cookie secrets | encrypted in-repo | `dex_client_secret`, `flux_web_client_secret`, `oauth2_proxy_cookie_secret` are random-generated and encrypted into the committed `*.enc.yaml`. |

---

## Run the bootstrap

1. Make sure the [bootstrap App is installed](#1-install-the-bootstrap-github-app)
   and all [Variables + Secrets](#configuration) are set.
2. Go to **Actions → 🌱 Bootstrap → Run workflow**.
3. Choose the **environment** (`prod` for the real cluster; `local` for a Docker
   dry-run that skips the credential write-back, DNS, and commit-back).
4. Type **`yes`** into the **confirm** box — this provisions real infrastructure.
5. Run it and watch the logs.

### What the workflow does internally

The steps, in order (read the workflow for the exact commands):

1. **Harden runner** and **confirm** — refuses to run unless `confirm == yes`.
2. **Mint App token** — short-lived installation token from `APP_ID` + `APP_PRIVATE_KEY`.
3. **Checkout** with that token (so the later commit-back can push).
4. **Refuse if already bootstrapped** — fails if a `prod` `KUBE_CONFIG` secret already
   exists (the re-bootstrap guard; see [Troubleshooting](#troubleshooting)).
5. **Install tooling** — `ksail`, `sops`, `age`, `yq` on the runner.
6. **Generate Age key + update `.sops.yaml`** — replaces the `<INSTANCE_AGE_PUBLIC_KEY>`
   placeholder with the freshly generated public key, and imports the key into ksail.
7. **Render configuration from Variables** — writes your `DOMAIN`, Cloudflare,
   admin-email, Hetzner-location and SSO values into the `variables-*` ConfigMaps and
   `ksail.prod.yaml`, and rewrites the domain/org placeholders in `talos/` and `k8s/`.
8. **Encrypt secrets into `*.enc.yaml`** — fills the secret values from GitHub Secrets,
   generates the internal random secrets, and `sops -e` encrypts each file with your
   new Age key.
9. **Validate rendered manifests** — `ksail … workload validate`.
10. **Create cluster** — `ksail … cluster create` (Talos on Hetzner). Errors if the
    cluster already exists, so it’s safe against double-runs.
11. **Write cluster creds back as `prod` environment secrets** (prod only) —
    `KUBE_CONFIG`, `TALOS_CONFIG`, `SOPS_AGE_KEY`.
12. **Point Cloudflare DNS at the load balancer** (prod only, best-effort) — polls for
    the LB IP, then creates `A` records for the apex and wildcard.
13. **Push manifests + reconcile** — `ksail … workload push` then `… workload reconcile`.
14. **Commit the rendered + encrypted tree** (prod only) — commits `.sops.yaml`,
    `ksail.prod.yaml`, `talos/`, and `k8s/` back to the branch.

---

## Verify

After the workflow goes green:

1. **`prod` environment secrets exist.** *Settings → Environments → prod* should now
   list `KUBE_CONFIG`, `TALOS_CONFIG`, and `SOPS_AGE_KEY`.
2. **The rendered tree was committed.** Your default branch should have a
   `chore: bootstrap rendered configuration` commit; `.sops.yaml` now contains a real
   `age1…` recipient (not the placeholder), and the `variables-*` ConfigMaps carry
   your real values.
3. **DNS resolves to the load balancer.** Check that `DOMAIN` and `*.DOMAIN` resolve
   to the Hetzner LB IP (the workflow log prints it). If the best-effort step warned,
   set the records manually — see [Troubleshooting](#troubleshooting).
4. **Flux is healthy.** With the `prod` kubeconfig (pull `KUBE_CONFIG` locally, or use
   your operator workstation), all Kustomizations should converge:

   ```bash
   flux get kustomizations -A
   kubectl get pods -A
   ```

5. **The platform answers.** Browse to `https://<DOMAIN>` (homepage) once
   cert-manager has issued certificates. Log in via the GitHub SSO App.

---

## Post-bootstrap: steady state

Bootstrap is a one-shot. From here, the cluster is owned by the steady-state
pipelines, all of which run the **idempotent** `ksail cluster update` (not
`cluster create`):

- **`ci.yaml`** — on every PR: validates manifests, runs an **ephemeral Docker
  system test** (a real local Talos+Docker cluster, exercised and torn down), and on
  merge-queue runs `ksail cluster update` to deploy.
- **`cd.yaml`** — on a `v*` tag: deploys the tagged release to prod with
  `ksail cluster update`.

Day-to-day, you simply open PRs and merge them, or cut a `v*` tag. The cluster
credentials persisted during bootstrap are what let these run unattended. If you ever
rebuild the cluster, those credentials go stale and must be refreshed — see
[`docs/dr/runbook.md`](dr/runbook.md) Scenario 9, and
[Troubleshooting](#troubleshooting) below.

To change inputs after bootstrap (domain, Hetzner sizing, autoscaler pools, add an
environment), see [`docs/TEMPLATING.md`](TEMPLATING.md).

---

## Teardown

To destroy the cluster and allow a fresh re-bootstrap later:

1. **Delete the cluster** (from a machine with the `prod` configs):

   ```bash
   ksail --config ksail.prod.yaml cluster delete
   ```

   This removes the Hetzner servers, load balancer, and network that ksail created.

2. **Clean up any orphaned autoscaler nodes** — `cluster delete` may leave behind
   servers the Cluster Autoscaler created:

   ```bash
   hcloud server list --selector cluster.autoscaler.nodeGroupLabel
   hcloud server delete <server-id>   # for each orphan
   ```

3. **Delete the `prod` environment secrets** so the re-bootstrap guard passes again:

   ```bash
   gh secret delete KUBE_CONFIG  --env prod
   gh secret delete TALOS_CONFIG --env prod
   gh secret delete SOPS_AGE_KEY --env prod
   ```

   (The workflow’s “Refuse if already bootstrapped” step keys off the `prod`
   `KUBE_CONFIG` secret. Until it is gone, bootstrap will refuse to run.)

You can then re-run the Bootstrap workflow to provision a fresh cluster. Backups in
R2 survive teardown; restore app/PV data per [`docs/dr/runbook.md`](dr/runbook.md).

---

## Troubleshooting

### DNS wasn’t set automatically

The DNS step is **best-effort** (`continue-on-error`): it polls up to ~10 minutes for
the load-balancer IP, and if it can’t resolve one (or the records already exist) it
warns instead of failing. Create the records by hand once the LB has an IP:

```bash
# Get the LB IP from the cluster:
kubectl -n kube-system get svc \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}'
```

Then add **`A`** (and optionally **`AAAA`**) records in Cloudflare for both `DOMAIN`
and `*.DOMAIN` pointing at that IP (unproxied / DNS-only).

### Re-running bootstrap is blocked

Symptom: the **“Refuse if already bootstrapped”** step fails with *“A ‘prod’
`KUBE_CONFIG` secret already exists.”* This is intentional — it stops a second
bootstrap from racing the existing cluster. If you genuinely want to re-bootstrap,
[tear down](#teardown) first (delete the cluster **and** the `prod` env secrets), then
run it again.

### The cluster is unreachable later (deploys fail)

After a **full cluster rebuild**, the API endpoint and Talos PKI change, so the
`prod` `KUBE_CONFIG` / `TALOS_CONFIG` secrets are stale. The deploy pipelines will
fail their reachability preflight (or `ksail cluster update` will report a bogus
“N configuration changes” plan, then `connection refused` /
`x509: certificate signed by unknown authority "talos"`). Refresh both from a machine
that can reach the rebuilt cluster:

```bash
# After `ksail cluster create` wrote fresh local configs:
kubectl --context admin@prod get --raw='/readyz'   # -> ok
talosctl --talosconfig ~/.talos/config version     # -> talks to the nodes

gh secret set KUBE_CONFIG  --env prod < ~/.kube/config
gh secret set TALOS_CONFIG --env prod < ~/.talos/config
```

Full procedure: [`docs/dr/runbook.md`](dr/runbook.md) Scenario 9.

### The workflow can’t write secrets / commit

Symptom: failures in the credential write-back or the commit-back step (`403`,
“resource not accessible”). The bootstrap App (or PAT) is missing a permission, isn’t
installed on this repo, or `APP_ID` / `APP_PRIVATE_KEY` are wrong. Re-check
[Install the bootstrap GitHub App](#1-install-the-bootstrap-github-app): you need
**Contents, Secrets, Environments, Actions = write**, and the App must be **installed
on the instance repo**.

### It refuses to run in the template repo

By design — the job is guarded with `if: github.repository != '…/platform-template'`.
Bootstrap only runs in **instances** created from the template, never the template
itself. Make sure you ran *“Use this template”* and are operating in your own copy.

### Validation / decrypt errors in CI

If CI can’t decrypt `*.enc.yaml`, the repo-level `SOPS_AGE_KEY` is missing or doesn’t
match the recipient in `.sops.yaml`. The bootstrap writes a repo-level copy of the Age
key for exactly this reason; if it was deleted, restore it from the `prod`
environment’s `SOPS_AGE_KEY` (or rotate per [`docs/secret-rotation.md`](secret-rotation.md)).

---

## Related documents

- [`TEMPLATING.md`](TEMPLATING.md) — the template inputs and how to change them.
- [`secret-rotation.md`](secret-rotation.md) — the secrets architecture and rotation.
- [`dr/runbook.md`](dr/runbook.md) — disaster recovery, including credential refresh.
- [`dr/alerting.md`](dr/alerting.md) — alert routing and the dead-man’s-switch.
- [`oidc-kubectl.md`](oidc-kubectl.md) — logging in to the cluster with GitHub via Dex.
