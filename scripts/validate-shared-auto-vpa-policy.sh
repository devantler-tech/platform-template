#!/usr/bin/env bash
# Hold workload sizing to the shared catalog's GeneratingPolicy form of auto-vpa.
#
# Every rendered provider must register the pinned catalog source exactly once, render
# exactly one of each of its three GeneratingPolicies, and render no classic `auto-vpa`
# ClusterPolicy: the two forms must never size one workload at once
# (docs/auto-vpa-migration.md). Negative controls prove the check rejects a render that
# registers both forms or drops one policy.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_revision="af8d7711e8f7337b647e686c21816134976084f7"
policy_url="https://raw.githubusercontent.com/devantler-tech/kyverno-policies/${policy_revision}/policies/best-practices/auto-vpa-generating-policy.yaml"
kustomization="${repo_root}/k8s/bases/infrastructure/cluster-policies/kustomization.yaml"
rollback_policy="${repo_root}/k8s/bases/infrastructure/cluster-policies/best-practices/auto-vpa.yaml"

source_count="$(grep -F -c -- "  - ${policy_url}" "${kustomization}" || true)"
if [[ "${source_count}" != "1" ]]; then
  echo "expected exactly one immutable auto-vpa GeneratingPolicy source, found ${source_count}" >&2
  exit 1
fi

if grep -E -q -- '^[[:space:]]*-[[:space:]]+best-practices/auto-vpa\.yaml[[:space:]]*$' "${kustomization}"; then
  echo "the classic auto-vpa ClusterPolicy is registered next to the catalog form" >&2
  exit 1
fi

if [[ ! -f "${rollback_policy}" ]]; then
  echo "the classic auto-vpa rollback form is missing" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

assert_policy_contract() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s -e '
      [.[] | select(type == "object")] as $docs
      | [$docs[] | select(.apiVersion == "policies.kyverno.io/v1" and .kind == "GeneratingPolicy")
          | .metadata.name | select(startswith("auto-vpa-"))] as $generating
      | [$docs[] | select(.apiVersion == "kyverno.io/v1" and .kind == "ClusterPolicy"
          and .metadata.name == "auto-vpa")] as $classic
      | ($generating | sort) == ["auto-vpa-daemonset", "auto-vpa-deployment", "auto-vpa-statefulset"]
        and ($classic | length) == 0
    ' >/dev/null
}

for provider in docker hetzner; do
  rendered="${tmp_dir}/${provider}.yaml"
  kubectl kustomize "${repo_root}/k8s/providers/${provider}/infrastructure/" >"${rendered}"

  if ! assert_policy_contract "${rendered}"; then
    echo "${provider} render does not register exactly the catalog auto-vpa GeneratingPolicies" >&2
    exit 1
  fi

  if [[ "${provider}" == "docker" ]]; then
    mutated="${tmp_dir}/${provider}-both-forms.yaml"
    cat "${rendered}" >"${mutated}"
    printf -- '---\n' >>"${mutated}"
    cat "${rollback_policy}" >>"${mutated}"
    if assert_policy_contract "${mutated}"; then
      echo "negative control passed with the classic and catalog forms both rendered" >&2
      exit 1
    fi

    mutated="${tmp_dir}/${provider}-missing-daemonset.yaml"
    yq eval-all \
      'select((.kind == "GeneratingPolicy" and .metadata.name == "auto-vpa-daemonset") | not)' \
      "${rendered}" >"${mutated}"
    if assert_policy_contract "${mutated}"; then
      echo "negative control passed with the DaemonSet GeneratingPolicy removed" >&2
      exit 1
    fi
  fi
done

echo "✓ Shared auto-vpa GeneratingPolicy contract satisfied."
