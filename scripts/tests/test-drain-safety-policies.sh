#!/usr/bin/env bash
# Pins the scaffolded drain-safety posture to the reference platform's baseline
# (platform-template#67): the shared catalog's validate-pdb-drain-safe at an
# immutable revision with its consumer exclusion, the replica floor and ceiling,
# all Audit-only, and no template-owned PodDisruptionBudget that sets
# minAvailable. Renders both provider payloads; never contacts a cluster.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
readonly repo_root

readonly kustomization="${repo_root}/k8s/bases/infrastructure/cluster-policies/kustomization.yaml"
readonly catalog_source='^  - https://raw\.githubusercontent\.com/devantler-tech/kyverno-policies/[0-9a-f]{40}/policies/best-practices/validate-pdb-drain-safe\.yaml$'
# The only chart PDB values allowed to set minAvailable, as
# "<HelmRelease>:<values path>": the PDBs KSail installs with chart defaults
# before Flux (cert-manager, metrics-server, the Kyverno admission controller,
# the Hetzner CSI controller), which the consumer PolicyException exempts, and
# the kube-prometheus-stack Alertmanager that platform-template#65 retires.
readonly allowed_min_available='[
  "cert-manager:podDisruptionBudget",
  "cert-manager:cainjector.podDisruptionBudget",
  "cert-manager:webhook.podDisruptionBudget",
  "metrics-server:podDisruptionBudget",
  "kyverno:admissionController.podDisruptionBudget",
  "hcloud-csi:controller.podDisruptionBudget",
  "kube-prometheus-stack:alertmanager.alertmanagerSpec.podDisruptionBudget"
]'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# True when the rendered infrastructure payload carries each policy exactly
# once, Audit-only, plus the consumer exception naming the catalog policy.
policies_ok() {
  yq eval-all -o=json '.' "$1" | jq -s -e '
    . as $docs
    | def one($kind; $name):
      [$docs[] | select(type == "object" and .apiVersion == "policies.kyverno.io/v1"
        and .kind == $kind and .metadata.name == $name)];
    (["validate-pdb-drain-safe", "validate-replica-floor", "validate-replica-ceiling"]
      | all(. as $n | (one("ValidatingPolicy"; $n) as $p
        | ($p | length) == 1 and $p[0].spec.validationActions == ["Audit"])))
    and (one("PolicyException"; "validate-pdb-drain-safe-operator-managed") as $e
      | ($e | length) == 1
        and $e[0].spec.policyRefs == [{name: "validate-pdb-drain-safe", kind: "ValidatingPolicy"}])
  ' >/dev/null
}

# True when no rendered PodDisruptionBudget sets minAvailable and no HelmRelease
# value sets a non-null minAvailable outside the allow-list.
pdbs_drain_safe() {
  yq eval-all -o=json '.' "$1" | jq -s -e --argjson allowed "${allowed_min_available}" '
    ([.[] | select(type == "object" and .kind == "PodDisruptionBudget"
      and .spec.minAvailable != null)] | length) == 0
    and ([.[] | select(type == "object" and .kind == "HelmRelease")
      | .metadata.name as $n | (.spec.values // {}) as $v
      | $v | paths(objects) as $p
      | select($v | getpath($p) | .minAvailable? != null)
      | $n + ":" + ($p | map(tostring) | join("."))
      | select(. as $k | $allowed | index($k) | not)] | length) == 0
  ' >/dev/null
}

source_count="$(grep -E -c -- "${catalog_source}" "${kustomization}" || true)"
[[ "${source_count}" == "1" ]] ||
  fail "expected exactly one immutable validate-pdb-drain-safe catalog source, found ${source_count}"

for provider in docker hetzner; do
  infrastructure="${tmp_dir}/${provider}-infrastructure.yaml"
  controllers="${tmp_dir}/${provider}-controllers.yaml"
  kubectl kustomize "${repo_root}/k8s/providers/${provider}/infrastructure/" >"${infrastructure}"
  kubectl kustomize "${repo_root}/k8s/providers/${provider}/infrastructure/controllers/" >"${controllers}"

  policies_ok "${infrastructure}" ||
    fail "${provider}: drain-safety policies missing, duplicated or not Audit-only"
  pdbs_drain_safe "${controllers}" ||
    fail "${provider}: a template-owned PodDisruptionBudget sets minAvailable"

  if [[ "${provider}" == "docker" ]]; then
    mutated="${tmp_dir}/${provider}-deny.yaml"
    yq eval-all '(select(.kind == "ValidatingPolicy" and .metadata.name == "validate-replica-floor").spec.validationActions) = ["Deny"]' \
      "${infrastructure}" >"${mutated}"
    ! policies_ok "${mutated}" || fail "negative control passed with the replica floor set to Deny"

    mutated="${tmp_dir}/${provider}-no-exception.yaml"
    yq eval-all 'select(.kind != "PolicyException")' "${infrastructure}" >"${mutated}"
    ! policies_ok "${mutated}" || fail "negative control passed without the consumer PolicyException"

    mutated="${tmp_dir}/${provider}-min-available.yaml"
    yq eval-all '(select(.kind == "PodDisruptionBudget") | .spec.minAvailable) = 1' \
      "${controllers}" >"${mutated}"
    ! pdbs_drain_safe "${mutated}" || fail "negative control passed with a minAvailable PodDisruptionBudget"

    mutated="${tmp_dir}/${provider}-helm-min-available.yaml"
    yq eval-all '(select(.kind == "HelmRelease" and .metadata.name == "reloader") | .spec.values.reloader.deployment.pdb.minAvailable) = 1' \
      "${controllers}" >"${mutated}"
    ! pdbs_drain_safe "${mutated}" || fail "negative control passed with a minAvailable HelmRelease value"
  fi
done

echo "✓ Drain-safety policies and PodDisruptionBudgets match the platform baseline."
