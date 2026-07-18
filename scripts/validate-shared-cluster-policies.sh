#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_name="helm-release-remediation-retries"
policy_revision="fd5fe3e8bb837ed6fecbd70dfdc59df1b94672c1"
policy_url="https://raw.githubusercontent.com/devantler-tech/kyverno-policies/${policy_revision}/policies/flux/${policy_name}.yaml"
kustomization="${repo_root}/k8s/bases/infrastructure/cluster-policies/kustomization.yaml"
legacy_policy="${repo_root}/k8s/bases/infrastructure/cluster-policies/flux/${policy_name}.yaml"

source_count="$(grep -F -c -- "  - ${policy_url}" "${kustomization}" || true)"
if [[ "${source_count}" != "1" ]]; then
  echo "expected exactly one immutable ${policy_name} source, found ${source_count}" >&2
  exit 1
fi

if [[ -e "${legacy_policy}" ]]; then
  echo "legacy local ${policy_name} policy still exists" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

for provider in docker hetzner; do
  rendered="${tmp_dir}/${provider}.yaml"
  kubectl kustomize "${repo_root}/k8s/providers/${provider}/infrastructure/" >"${rendered}"

  if ! yq eval-all -o=json '.' "${rendered}" |
    jq -s -e --arg name "${policy_name}" '
      [.[] | select(
        type == "object"
        and .apiVersion == "kyverno.io/v1"
        and .kind == "ClusterPolicy"
        and .metadata.name == $name
      )] as $policies
      | ($policies | length) == 1
        and ($policies[0].spec.background == false)
        and ([$policies[0].spec.rules[].name] == [
          "default-install-remediation",
          "default-upgrade-remediation"
        ])
        and ([$policies[0].spec.rules[].match.any[0].resources.kinds] | all(
          . == ["helm.toolkit.fluxcd.io/v2/HelmRelease"]
        ))
        and ([$policies[0].spec.rules[].match.any[0].resources.operations] | all(
          . == ["CREATE", "UPDATE"]
        ))
        and ([$policies[0].spec.rules[].match.any[0].resources.selector.matchLabels["helm.toolkit.fluxcd.io/remediation"]] | all(
          . == "enabled"
        ))
        and ([$policies[0].spec.rules[] | has("exclude")] | all(. == false))
        and ($policies[0].spec.rules[0].preconditions.all[0].value == "RetryOnFailure")
        and ($policies[0].spec.rules[0].preconditions.all[1].value == 0)
        and ($policies[0].spec.rules[0].mutate.patchStrategicMerge.spec.install.remediation["+(retries)"] == -1)
        and ($policies[0].spec.rules[0].mutate.patchStrategicMerge.spec.install.remediation["+(remediateLastFailure)"] == true)
        and ($policies[0].spec.rules[1].preconditions.all[0].value == "RetryOnFailure")
        and ($policies[0].spec.rules[1].preconditions.all[1].value == 0)
        and ($policies[0].spec.rules[1].mutate.patchStrategicMerge.spec.upgrade.remediation["+(retries)"] == -1)
        and ($policies[0].spec.rules[1].mutate.patchStrategicMerge.spec.upgrade.remediation["+(remediateLastFailure)"] == true)
    ' >/dev/null; then
    echo "${provider} render does not preserve the shared ${policy_name} contract" >&2
    exit 1
  fi
done

echo "✓ Shared cluster-policy contract satisfied."
