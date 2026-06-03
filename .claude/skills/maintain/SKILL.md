---
name: maintain
description: Repository maintenance for the devantler-tech platform template — triage, dependency/security hygiene, CI health, manifest/Helm/Flux investigation, small confident fixes. Static validation only; never runs a cluster. Use when performing autonomous or on-request maintenance of this repo.
---
Perform maintenance per the **## Maintenance** section of this repo's [`AGENTS.md`](../../../AGENTS.md), within the shared devantler-tech maintenance conventions it references. Static validation only (`ksail --config ksail.yaml workload validate` / `ksail --config ksail.prod.yaml workload validate`, or `kubectl kustomize`) — never run a cluster. A draft PR is the checkpoint; never merge external PRs or self-merge your own unreviewed drafts.
