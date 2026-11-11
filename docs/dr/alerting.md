# Observability

**Coroot** is the observability stack: service health, logs, traces, profiles
and incidents, collected by an eBPF node agent with no application changes.
Self-hosted, no SaaS metrics tier. There is no kube-prometheus-stack: no
Prometheus operator, Alertmanager, node-exporter or kube-state-metrics, and no
`monitoring` namespace. Alerting has four parts:

1. **Coroot incidents go to Slack.** Coroot inspects every workload and node
   and posts incident and resolution notifications in production.
2. **Flux reports its own failures.** Flux notification-controller posts
   reconciliation errors for every `Kustomization` and every `HelmRelease`.
3. **One off-cluster dead-man check.** The `cluster-heartbeat` CronJob pings an
   external monitor, so a cluster that is down still gets noticed.
4. **A health check for backups, databases and certificates.** The
   `platform-health-alert` CronJob posts what Coroot and Flux do not see: a
   failed or stale backup, a degraded CloudNativePG cluster and a certificate
   close to expiry. See [Backup, database and certificate check](#backup-database-and-certificate-check).

There is one UI, behind SSO: Coroot at `https://observability.${domain}`,
reached only through oauth2-proxy.

The earlier stacks (Loki, Alloy, OpenCost, Grafana and kube-prometheus-stack)
are gone. There is no cost allocation today.
[`TEMPLATING.md`](../TEMPLATING.md#observability-coroot-is-the-default)
says how an instance that ran them migrates.

## Components

| Component             | Role                                               | Persistence (prod) |
| --------------------- | -------------------------------------------------- | ------------------ |
| Coroot                | UI, incidents, service map, alert inspections      | PVC, 2 Gi          |
| Coroot Prometheus     | Coroot's own metric store                          | PVC, 10 Gi         |
| Coroot ClickHouse     | Logs, traces and profiles, 3 d retention           | PVC, 10 Gi         |
| Coroot node agent     | eBPF telemetry from every node (DaemonSet)         | n/a                |
| Audit log forwarder   | Ships Talos host audit logs to Coroot (prod only)  | n/a                |
| Flux notifications    | `Provider` and two `Alert` objects (prod only)     | n/a                |
| cluster-heartbeat     | Dead-man ping every five minutes (CronJob)         | n/a                |
| platform-health-alert | Backup, database and certificate check (prod only) | n/a                |

Local/CI runs the same stack without the audit log forwarder, the health check and
the Flux notification path. Coroot's bundled Prometheus is its own metric store; it
is not a Prometheus operator and installs no `monitoring.coreos.com` resources.

## Alert routing → Slack

In production, Coroot posts its incident and resolution notifications to a
Slack incoming webhook. The URL is per-cluster and SOPS-encrypted. Coroot's
per-alert notifications stay in the Coroot UI, so a noisy alert does not flood
the channel. Local / Docker renders no webhook and stays quiet by design.

Flux notification-controller now owns reconciliation errors in
production. Two event-driven `Alert` objects post through the same webhook:

- `platform-reconciliation` forwards `error` events for failed builds, applies
  and health checks. It watches every `Kustomization` and every `HelmRelease`.
- `platform-dependency-wait` forwards only the `info` events of a
  `Kustomization` whose prerequisite is not ready.

The controller layer applies them before it waits for every controller, so the
notification path already exists if that layer cannot become ready.
Local / Docker renders no Slack `Provider`, `Alert`, or webhook `Secret`.

### Why HelmRelease is watched directly

A failing `HelmRelease` can be invisible to its parent `Kustomization`. With
Helm remediation on, a failed upgrade is rolled back to the last good release.
The release is then Ready again, the parent stays healthy, and the release
silently stops advancing. The Prometheus rule `FluxHelmReleaseNotReady` used to
report that; the `Alert` reports the failed upgrade itself.

notification-controller has no namespace wildcard, so the `Alert` lists every
namespace that holds a `HelmRelease`. `scripts/validate-alert-coverage.sh`
fails CI when a release appears in a namespace that is not listed. **An
instance that adds a release in a new namespace adds that namespace to
`k8s/providers/hetzner/infrastructure/controllers/flux-notifications/alert.yaml`.**

## Dead-man's-switch (off-cluster heartbeat)

Nothing inside the cluster can tell you the cluster is down. The
`cluster-heartbeat` CronJob pings an **external** monitor every five minutes.
If the cluster dies, the monitor stops receiving pings and notifies Slack
out-of-band. It is the platform's one dead-man signal, so a production
bootstrap refuses to start without it.

`cluster_heartbeat_url` accepts only a canonical
`https://hc-ping.com/<lowercase-uuid>` URL; the CronJob's network policy allows
only `hc-ping.com:443` plus that hostname's exact DNS query. Bootstrap rejects
any other spelling, because a URL the cluster cannot reach is a monitor that
is silently dead. The infrastructure layer narrows the namespace deny and DNS
policies around this purpose-labelled workload, and the dependent apps layer
stages the CronJob only after that exclusion is ready. An invalid fallback
keeps an unconfigured CronJob quiet in local/CI.

The bearer URL reaches the CronJob through a Secret-backed environment variable.
The shell feeds it to curl as stdin configuration, so the credential is absent
from both the PodSpec and curl's runtime argument vector.

Recommended monitor: [healthchecks.io](https://healthchecks.io) (free,
open-source, native Slack integration). Create one check with a ~5 min period
and ~10 min grace and connect it to Slack. The CronJob deliberately accepts only
`hc-ping.com` because its egress policy is fail closed.

## What is alerted, and what is not

| Signal                                       | Where it shows                                |
| -------------------------------------------- | --------------------------------------------- |
| A workload misses its objectives             | Coroot incident → Slack                       |
| Node, pod, memory, disk and restart health   | Coroot inspections, in the Coroot UI          |
| A `Kustomization` fails to build or apply    | Flux `Alert` → Slack                          |
| A `HelmRelease` fails to install or upgrade  | Flux `Alert` → Slack                          |
| A prerequisite layer is not ready            | Flux `Alert` → Slack (dependency wait)        |
| The cluster stops answering                  | External monitor → Slack                      |
| A Velero backup failed or is stale           | Health check → Slack                          |
| A CloudNativePG cluster is degraded or stale | Health check → Slack                          |
| A certificate expires within 14 days         | Health check → Slack                          |
| Cluster Autoscaler cannot add a node         | Coroot incident for the workload left Pending |

**Cluster Autoscaler failures are left to Coroot.** KSail deploys and owns the
autoscaler, not this repository's manifests, so a check here would have to
guess its namespace and its event format. What matters to an operator is the
effect: pods that stay Pending, which Coroot reports as the workload missing
its objectives. Read the autoscaler's own state from its
`cluster-autoscaler-status` ConfigMap.

## Backup, database and certificate check

The `platform-health-alert` CronJob replaces the Prometheus rules that left
with kube-prometheus-stack. It runs every six hours in production, in the
`observability` namespace, and posts one Slack message listing every problem
it finds:

- a Velero schedule whose latest backup failed, or that has no completed
  backup in the last 26 hours;
- a CloudNativePG cluster with no completed `Backup` in the last 26 hours,
  fewer ready instances than it asks for, or a configured WAL archive that is
  not working, each for longer than 15 minutes;
- a cert-manager `Certificate` that expires within 14 days, which means
  cert-manager has not renewed it.

It posts to the same webhook as Coroot and Flux, so there is nothing new to
provision. Its network path is the `observability` namespace's `allow-coroot`
policy, which already lets every pod but the heartbeat reach the API server, DNS
and, in production, `hooks.slack.com:443`; the validator fails if that changes. A problem is reported again on every run until it is fixed. Its
identity can only list Velero schedules and backups, CloudNativePG clusters
and backups, and certificates. A kind whose API is not installed is skipped;
any other read or delivery failure fails the Job, so check
`kubectl -n observability get jobs` after a quiet week if you doubt it.
`scripts/tests/test-platform-health-alert.sh` runs the check against recorded
API responses in CI.

Every CloudNativePG cluster is expected to have a recent backup. A database you
add without a `ScheduledBackup` is reported until it has one.

## Off-cluster backup

There is no remote-write or SaaS mirror. Coroot's stores live in the
`observability` namespace, which Velero's `daily-full` schedule backs up to R2
every day (`includedNamespaces: ["*"]`, Kopia fs-backup). Restore is the
standard Velero flow in [runbook.md](./runbook.md). Backups are
filesystem-level and crash-consistent; fine for a 24 h RPO.

## Per-environment setup (manual SOPS steps)

The two secret inputs — `alertmanager_webhook_url` and
`cluster_heartbeat_url` — live in the per-cluster
`variables-cluster-secret.enc.yaml` (under `bootstrap/`). Both are read from
the `Secret` `variables-cluster`, which is a Flux `substituteFrom` source. The
Bootstrap workflow writes them from the `ALERTMANAGER_WEBHOOK_URL` and
`CLUSTER_HEARTBEAT_URL` repository secrets; to change one later:

```bash
# 1. Slack incoming webhook for Coroot and Flux notifications.
sops --set '["stringData"]["alertmanager_webhook_url"] "https://hooks.slack.com/services/XXX/YYY/ZZZ"' \
  k8s/clusters/prod/bootstrap/variables-cluster-secret.enc.yaml

# 2. The cluster heartbeat's external check (hc-ping.com only).
sops --set '["stringData"]["cluster_heartbeat_url"] "https://hc-ping.com/<uuid>"' \
  k8s/clusters/prod/bootstrap/variables-cluster-secret.enc.yaml
```

The webhook variable keeps its earlier name so an existing instance needs no
secret change. Slack side: create an incoming webhook for your alerts channel
(e.g. `#platform-alerts`). On healthchecks.io, create one check, connect its
Slack integration, and copy its ping URL into `cluster_heartbeat_url`.

| Env   | `alertmanager_webhook_url`      | `cluster_heartbeat_url`  |
| ----- | ------------------------------- | ------------------------ |
| local | invalid URL (alerts stay local) | unset → invalid          |
| prod  | Slack alerts-channel webhook    | cluster-monitor ping URL |

## On-call: inspect

- **Investigate** in Coroot at `https://observability.${domain}`: service health, logs,
  traces and incidents. It is behind GitHub SSO (oauth2-proxy, restricted to the operator).
- **A Flux alert** names the failing object. Read it with
  `kubectl -n <namespace> describe helmrelease <name>` or
  `kubectl -n flux-system describe kustomization <name>`.
- **There is nothing to silence.** Flux notifications are deduplicated and
  rate-limited by notification-controller, and Coroot resolves an incident
  itself when the workload recovers.

## Related

- [DR runbook](./runbook.md) — what to do when an alert fires, and restore
- [Velero + CNPG](./velero-cnpg.md) — the systems whose health is checked
- [restore-drill.md](./restore-drill.md) — CI validation of the stack
- [HA primitives](../ARCHITECTURE.md#clusters) — cluster environments and topology
