# Moving workload sizing to the shared catalog policy

Every Deployment, StatefulSet and DaemonSet gets a VerticalPodAutoscaler (VPA) from a Kyverno
policy, so workloads are right-sized without anyone writing a VPA by hand. Kyverno is removing the
classic `ClusterPolicy` generate rules that the template's `auto-vpa` policy uses, so sizing moves
to the shared [`devantler-tech/kyverno-policies`](https://github.com/devantler-tech/kyverno-policies)
catalog's `GeneratingPolicy` form. Tracking issue:
[platform-template#256](https://github.com/devantler-tech/platform-template/issues/256).

The two forms name their VPAs differently (`<name>` versus `<name>-<kind>`), so they cannot adopt
each other's VPAs. If both ran at once, one workload would get two VPAs fighting over its requests.
The move therefore comes in **two template changes that an instance takes as two separate
template-sync merges**.

## Step 1 — stop the classic policy (current template)

This step:

- unregisters `best-practices/auto-vpa.yaml` from
  `k8s/bases/infrastructure/cluster-policies/kustomization.yaml`. The policy uses
  `synchronize: true`, so Kyverno deletes the VPAs it generated. Workloads keep their current
  requests and limits; nothing resizes them until step 2.
- runs the VPA updater with `--min-replicas=1`. The catalog's VPAs set no `minReplicas`, and the
  updater's default of 2 would leave single-replica workloads, which most template workloads are,
  never resized.

The policy file stays in the repository as the rollback form.

**Before taking step 2**, merge the step 1 sync, let Flux reconcile `infrastructure`, and confirm no
classic VPA remains:

```bash
kubectl get vpa -A -l generate.kyverno.io/policy-name=auto-vpa
```

The command must return no resources.

## Step 2 — register the catalog form (later template change)

A later template change registers the catalog's `auto-vpa-generating-policy.yaml`: three
`GeneratingPolicy` objects, `auto-vpa-deployment`, `auto-vpa-statefulset` and `auto-vpa-daemonset`.
The template adopts the catalog's values: a 50m CPU floor, CPU-only sizing for DaemonSets, and
sizing in every namespace. Take it as its own template-sync merge, after the check above passes.
Afterwards, every matching workload should have exactly one VPA, labelled with the policy for its
kind.

If one template-sync pull request brings both steps at once, do not merge it as is. Apply step 1
first (merge a branch that carries only the step 1 changes), run the check, then merge the rest.
If both land in one reconcile, the classic policy's cleanup deletes VPAs the new policies skipped,
and they return only when Kyverno next re-scans its policies, by default up to an hour later.

## Rollback

Reverse the order:

1. Unregister the catalog form and wait until this returns no resources:

   ```bash
   kubectl get vpa -A -l 'generate.kyverno.io/policy-name in (auto-vpa-deployment,auto-vpa-statefulset,auto-vpa-daemonset)'
   ```

2. Register `best-practices/auto-vpa.yaml` again.

Keep `--min-replicas=1` in either direction; it only affects VPAs that set no `minReplicas`.
