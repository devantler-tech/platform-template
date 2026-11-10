# Observability

**Coroot** is the observability stack: service health, logs, traces, profiles
and incidents, collected by an eBPF node agent with no application changes.
`kube-prometheus-stack` (Prometheus + Alertmanager + node-exporter +
kube-state-metrics) still runs beside it for the metric-backed alert rules and
the `Watchdog` dead-man signal; its Grafana, Prometheus and Alertmanager web UIs
are not published. Self-hosted, no SaaS metrics tier. The stack is
production-hardened along four axes:

1. **Alerts go to Slack** via Alertmanager's native `slack_configs`, Coroot's
   incident notifications and Flux's own reconciliation alerts.
2. **Two independent dead-man checks** separate the Prometheus → Alertmanager
   pipeline from direct cluster liveness, so one sender cannot hide the other
   path's failure.
3. **State is persistent** — Prometheus and Alertmanager use Hetzner
   Cloud block volumes in prod, and Velero ships the `monitoring`
   namespace to R2 daily (24 h RPO).
4. **One UI, behind SSO**: Coroot at `https://observability.${domain}`, reached
   only through oauth2-proxy.

The earlier stack (Loki, Alloy, OpenCost and the Grafana UI) is gone. There is
no cost allocation today. [`TEMPLATING.md`](../TEMPLATING.md#observability-coroot-is-the-default)
says how an instance that ran the earlier stack migrates.

## Components

| Component          | Role                                                | Persistence (prod)        |
| ------------------ | --------------------------------------------------- | ------------------------- |
| Coroot             | UI, incidents, service map, alert inspections       | PVC, 2 Gi                 |
| Coroot Prometheus  | Coroot's own metric store                           | PVC, 10 Gi                |
| Coroot ClickHouse  | Logs, traces and profiles, 3 d retention            | PVC, 10 Gi                |
| Coroot node agent  | eBPF telemetry from every node (DaemonSet)          | n/a                       |
| Audit log forwarder | Ships Talos host audit logs to Coroot (prod only)  | n/a                       |
| Prometheus         | Metrics + alert evaluation, 14 d / 5 GiB retention  | `hcloud` PVC, 20 Gi       |
| Alertmanager       | Routing, grouping, silences (2 replicas, gossiped)  | `hcloud` PVC, 2 Gi        |
| node-exporter      | Node metrics (DaemonSet)                            | n/a                       |
| kube-state-metrics | Kubernetes object metrics                           | n/a                       |
| cluster-heartbeat  | Direct dead-man ping every five minutes (CronJob)   | n/a                       |

Local/CI runs the same stack without the audit log forwarder, with Prometheus
and Alertmanager on emptyDir — losing those on a restart is fine there. The
`hcloud` PVC overrides for Prometheus and Alertmanager live in the hetzner
overlay (`k8s/providers/hetzner/.../*/patches/`), the same way OpenBao gets
block storage.

## Alert routing → Slack

Alertmanager sends to a Slack incoming webhook (`slack_configs` with
`api_url_file`). The URL is per-cluster and SOPS-encrypted, so local
clusters get an invalid URL and stay quiet by design.

- `critical` → Slack immediately, repeat every 12 h.
- `warning`  → Slack, repeat every 24 h.
- `critical` inhibits matching `warning` (same alertname/cluster/namespace).

In production, Coroot posts its incident and resolution notifications to the
same webhook. Its per-alert notifications stay in the Coroot UI, so a noisy
alert does not flood the channel.

## Dead-man's-switch (off-cluster heartbeat)

In-cluster Alertmanager cannot tell you the cluster is down — it's down
too. The `Watchdog` alert is routed to a
dedicated `heartbeat` receiver that POSTs to an **external** monitor on a
tight cadence (`repeat_interval: 50s`). If the cluster — or the Prometheus →
Alertmanager pipeline — dies, the monitor stops receiving pings and notifies
Slack out-of-band.

A dedicated `cluster-heartbeat` CronJob pings a
**second external check** every five minutes independently of Coroot. It never
reuses `alertmanager_heartbeat_url`: doing so would let the CronJob keep that
monitor green while the Prometheus-to-Alertmanager pipeline was down.
Watchdog stays enabled on its existing check.
The CronJob's separate `cluster_heartbeat_url` accepts only a canonical
`https://hc-ping.com/<lowercase-uuid>` URL; its network policy allows only
`hc-ping.com:443` plus that hostname's exact DNS query. Bootstrap compares
canonical check identities, so URL fragments, query strings, and trailing slashes
cannot disguise reuse of the Alertmanager check. The infrastructure layer
narrows the namespace deny and DNS policies around this purpose-labelled
workload. The dependent apps layer
stages the CronJob only after that exclusion is ready, while Watchdog preserves the
original dead-man path until the apps reconciliation completes. An invalid fallback
keeps an unconfigured CronJob quiet.

The bearer URL reaches the CronJob through a Secret-backed environment variable.
The shell feeds it to curl as stdin configuration, so the credential is absent
from both the PodSpec and curl's runtime argument vector.
Flux notification-controller now owns reconciliation errors in
production. Two event-driven `Alert` objects watch every `Kustomization`:
one forwards `error` events for failed builds, applies, and health checks; the
other forwards only `info` dependency waits whose prerequisite is not ready.
The controller layer applies them before it waits for every controller, so the
notification path already exists if that layer cannot become ready. Both post
through the existing `alertmanager_webhook_url`.
Local / Docker renders no Slack `Provider`, `Alert`, or
webhook `Secret`.
`kube-prometheus-stack` remains transitional for Watchdog and the remaining
metric-backed alert rules until those paths are migrated separately.
Its Grafana, Prometheus and Alertmanager web UIs are
not published; the alerts themselves still run.

Recommended monitor: [healthchecks.io](https://healthchecks.io) (free,
open-source, native Slack integration). Keep two distinct checks: the existing
tight-cadence Watchdog URL in `alertmanager_heartbeat_url`, and a ~5 min period /
~10 min grace direct-cluster check in `cluster_heartbeat_url`. Connect both to
Slack, but never give them the same ping URL. A self-hosted alternative for the
Alertmanager check is supported; the CronJob deliberately accepts only
`hc-ping.com` because its egress policy is fail closed. Another alternative is a
scheduled GitHub Actions workflow that probes the public Gateway and posts
to Slack — fully under your control, no third-party monitor.

Both URLs are injected by Flux substitution. An unset `cluster_heartbeat_url`
defaults to an invalid URL, so local/CI and instances without the optional
second check stay inert while Watchdog continues unchanged.

## Off-cluster metric backup

There is no remote-write or SaaS mirror. Instead, the persistent
Prometheus and Alertmanager volumes live in the `monitoring`
namespace, which Velero's `daily-full` schedule backs up to R2 every day
(`includedNamespaces: ["*"]`, Kopia fs-backup). Restore is the standard
Velero flow in [runbook.md](./runbook.md). Backups are filesystem-level
and crash-consistent (Prometheus recovers via its WAL on restore);
fine for a 24 h RPO. Coroot's stores live in the `observability` namespace and are
covered by the same schedule.

## What gets alerted

Two sources:

1. **Curated chart default rules** (`defaultRules.create: true`). We keep
   the well-tested groups — `general` (incl. `Watchdog`), `alertmanager`,
   `prometheus`, `prometheusOperator`, `kubernetesApps`
   (CrashLooping/ReplicasMismatch/…), `kubernetesStorage`, `node`,
   `kubeStateMetrics` — and disable the groups for control-plane
   components we don't scrape (etcd, kube-apiserver/-scheduler/-controller-
   manager, kube-proxy, windows). `KubeCPUOvercommit` / `KubeMemoryOvercommit`
   are disabled — guaranteed noise on a cluster that runs hot on purpose.

2. **Platform-specific rules** in
   `k8s/bases/infrastructure/alerts/platform-critical.yaml` (not in the
   chart): Velero/CNPG backups, Flux reconciliation, cert-manager expiry,
   cluster-autoscaler and resource-pressure.

| Alert                       | Severity | Why                                       |
| --------------------------- | -------- | ----------------------------------------- |
| `Watchdog`                  | none     | Always firing → external heartbeat        |
| `NodeNotReady`              | critical | Single node loss                          |
| `PersistentVolumeFillingUp` | critical | >90% PVC                                  |
| `CertificateExpiringSoon`   | warning  | <14 d to expiry, cert-manager not renewing |
| `FluxKustomizationNotReady` | critical | Reconciliation broken >15 min             |
| `VeleroNoRecentBackup`      | critical | RPO breach — no successful backup in 30h  |
| `CNPGClusterDegraded`       | critical | Primary alone, no streaming replica       |

(plus the chart's workload/storage/self-monitoring alerts.)

In production, the event-driven Flux notifications replace
the Kustomization half of `FluxKustomizationNotReady`. A production patch renames
the remaining metric rule to `FluxHelmReleaseNotReady` and narrows it to
HelmRelease readiness, so the two paths do not send the same failure twice. The
other table entries still come from `kube-prometheus-stack` while it is
transitional.

## Per-environment setup (manual SOPS steps)

The three secret inputs — `alertmanager_webhook_url`,
`alertmanager_heartbeat_url`, and `cluster_heartbeat_url` — live in the
per-cluster `variables-cluster-secret.enc.yaml` (under `bootstrap/`) and must
be set by hand. All three are read from the `Secret` `variables-cluster`, which
is a Flux `substituteFrom` source.

```bash
# 1. Slack incoming webhook for Alertmanager, Coroot, and Flux notifications.
sops --set '["stringData"]["alertmanager_webhook_url"] "https://hooks.slack.com/services/XXX/YYY/ZZZ"' \
  k8s/clusters/prod/bootstrap/variables-cluster-secret.enc.yaml

# 2. Prometheus → Alertmanager pipeline check (healthchecks.io or similar).
sops --set '["stringData"]["alertmanager_heartbeat_url"] "https://hc-ping.com/<uuid>"' \
  k8s/clusters/prod/bootstrap/variables-cluster-secret.enc.yaml

# 3. Separate direct-cluster check for the cluster heartbeat (hc-ping.com only).
sops --set '["stringData"]["cluster_heartbeat_url"] "https://hc-ping.com/<different-uuid>"' \
  k8s/clusters/prod/bootstrap/variables-cluster-secret.enc.yaml
```

Slack side: create an incoming webhook for your alerts channel (e.g.
`#platform-alerts`) — the channel in the config is cosmetic, since an incoming
webhook posts to the channel it was created for. On healthchecks.io, create two
distinct checks, connect each check's Slack integration, and copy their different
ping URLs into `alertmanager_heartbeat_url` and `cluster_heartbeat_url` respectively.

| Env   | `alertmanager_webhook_url`      | `alertmanager_heartbeat_url`       | `cluster_heartbeat_url`                 |
| ----- | ------------------------------- | ---------------------------------- | --------------------------------------- |
| local | invalid URL (alerts stay local) | unset → invalid                    | unset → invalid                         |
| prod  | Slack alerts-channel webhook    | pipeline-monitor ping URL          | distinct cluster-monitor ping URL       |

## On-call: silence and inspect

- **Investigate** in Coroot at `https://observability.${domain}`: service health, logs,
  traces and incidents. It is behind GitHub SSO (oauth2-proxy, restricted to the operator).
- **Silence or inspect a firing alert**: Alertmanager still sends the metric-backed alerts,
  but its web UI is not published, so reach it through the cluster API with your own
  kubeconfig. Run
  `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093`, open
  `http://localhost:9093` and use Silences → New. For Prometheus, use
  `svc/kube-prometheus-stack-prometheus 9090` the same way.

## Resource footprint (prod)

| Component      | Requests          | Limits      |
| -------------- | ----------------- | ----------- |
| Prometheus     | 50m / 256 Mi      | — / 1.5 Gi  |
| Alertmanager   | 50m / 64 Mi (×2)  | — / 128 Mi  |
| Operator       | 50m / 128 Mi      | — / 256 Mi  |

VPA right-sizes the requests at runtime (RequestsOnly), so the limits are
the real ceilings. The always-on tier (Coroot and
persistent Prometheus + Alertmanager) is what motivates the planned bump to a 4th
static worker (`ksail.prod.yaml`); it's held at 3 today while prod is
right-sized, and the hetzner overlay opts out of kubevirt/cdi to free
~1.5 GiB so the tier still fits.

## Related

- [DR runbook](./runbook.md) — what to do when an alert fires, and restore
- [Velero + CNPG](./velero-cnpg.md) — the systems whose health is checked
- [restore-drill.md](./restore-drill.md) — CI validation of the stack
- [HA primitives](../ARCHITECTURE.md#clusters) — cluster environments and topology
