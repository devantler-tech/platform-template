# Platform Template ☸️⛴️

A GitHub template for running your own Kubernetes platform on Hetzner Cloud, where every change is
made through Git. It is for homelab owners and small teams who want a production-grade cluster —
networking, certificates, secrets, single sign-on, security, storage, databases, observability and
backups already wired together — stood up by one unattended workflow run.

It is the reusable, automatically bootstrapped form of
[`devantler-tech/platform`](https://github.com/devantler-tech/platform).

## What you get

- **A cluster that follows Git** — [Flux](https://fluxcd.io) applies what is merged, so every
  change to the cluster is a reviewed pull request. This way of working is called GitOps.
- **One tool for every environment** — [KSail](https://github.com/devantler-tech/ksail) creates
  and updates the clusters. All of them run [Talos Linux](https://www.talos.dev), a minimal
  operating system built only to run Kubernetes: on Docker on your machine and in CI, on Hetzner
  Cloud in production.
- **The services an app needs, already running** — Cilium networking and Gateway API, cert-manager
  certificates, OpenBao secrets, Dex single sign-on, Kyverno policies, Longhorn storage,
  CloudNativePG databases, Prometheus, Grafana and Loki monitoring, and Velero backups.
- **Changes tested before they deploy** — CI validates every pull request and system-tests it on
  a throwaway cluster before the merge queue deploys it to production.
- **Your apps from their own repositories** — run an application as a *tenant* that deploys from
  its own repository; see [`docs/TENANTS.md`](docs/TENANTS.md).

The full component list, the cluster sizes and the repository layout are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Quick start

The [Bootstrap workflow](.github/workflows/bootstrap.yaml) takes a new repository to a running
Hetzner cluster with live DNS, unattended:

1. **Use this template** → **Create a new repository** on GitHub.
2. **Install a GitHub App** on the new repository and add its `APP_ID` as a Variable and its
   `APP_PRIVATE_KEY` as a Secret. The bootstrap writes the cluster's credentials back as secrets,
   which the default `GITHUB_TOKEN` is not allowed to do.
3. **Add your Variables and Secrets** — Variables such as `DOMAIN`, `CLOUDFLARE_ZONE`,
   `ADMIN_EMAIL` and `HETZNER_LOCATION`, and Secrets such as `HCLOUD_TOKEN` and
   `CLOUDFLARE_API_TOKEN`. The bootstrap generates `SOPS_AGE_KEY`, `KUBE_CONFIG` and
   `TALOS_CONFIG` itself.
4. **Run it** — Actions → **🌱 Bootstrap** → *Run workflow*, choose `prod`, and type `yes`.

From then on, merging a pull request deploys through the merge queue, and pushing a `v*` tag
deploys through the CD pipeline. [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md) is the full guide: the
App's permissions, every Variable and Secret, verification, teardown and troubleshooting.

## Local development

You need neither Hetzner nor the Bootstrap workflow to develop locally: the local cluster runs on
Docker. Install [Docker](https://docs.docker.com/get-docker/) and
[KSail](https://github.com/devantler-tech/ksail), then:

```bash
ksail cluster create
ksail workload push
ksail workload reconcile
```

KSail maps ports 80 and 443 to localhost (see [`ksail.yaml`](ksail.yaml)), so services open at
`https://platform.lan` and `https://<service>.platform.lan` once you add the entries from
[`hosts`](hosts) to your system's hosts file. Local certificates come from a self-signed CA that
cert-manager generates, so trust that CA to avoid browser warnings.

Validate manifests before you push, which is faster than a cluster test:

```bash
ksail workload validate                          # local cluster
ksail --config ksail.prod.yaml workload validate # production cluster
```

Tear the cluster down with `ksail cluster delete`.

> **Secrets locally.** A fresh copy carries placeholder `*.enc.yaml` files that are not encrypted
> to a real key yet. Generate your own Age key, add its public half to [`.sops.yaml`](.sops.yaml)
> and encrypt the seed secrets with `sops -e` — or run the Bootstrap workflow with the `local`
> environment. See [`docs/TEMPLATING.md`](docs/TEMPLATING.md) and
> [`docs/secret-rotation.md`](docs/secret-rotation.md).

## Documentation

- [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) — what runs on the cluster, the local and production clusters, and how the repository is laid out.
- [`BOOTSTRAP.md`](docs/BOOTSTRAP.md) — the end-to-end bootstrap guide: prerequisites, Variables and Secrets, run, verify, teardown, troubleshooting.
- [`TEMPLATING.md`](docs/TEMPLATING.md) — the inputs the bootstrap renders, and how to change them later or for a new environment.
- [`TENANTS.md`](docs/TENANTS.md) — adding a tenant: an app that runs on the platform from its own repository.
- [`secret-rotation.md`](docs/secret-rotation.md) — how secrets flow (SOPS → OpenBao → External Secrets) and how they rotate.
- [`node-autoscaling.md`](docs/node-autoscaling.md) — how the Cluster Autoscaler is configured on Hetzner.
- [`oidc-kubectl.md`](docs/oidc-kubectl.md) — signing `kubectl` in to the cluster with OIDC.
- [`runtime-security.md`](docs/runtime-security.md) — runtime threat detection (Kubescape) and enforcement (Tetragon).
- [`rwx-storage.md`](docs/rwx-storage.md) — Longhorn replicated and shared (RWX) storage.
- [`dr/`](docs/dr) — disaster-recovery runbooks: backup and restore drills, OpenBao key custody, Velero + CloudNativePG, alerting.

## Credits

Derived from [`devantler-tech/platform`](https://github.com/devantler-tech/platform),
built with [KSail](https://github.com/devantler-tech/ksail),
[Flux](https://fluxcd.io), [Talos Linux](https://www.talos.dev), and the open-source
projects listed in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## License

See [`LICENSE`](LICENSE). Security policy: [`SECURITY.md`](SECURITY.md).
