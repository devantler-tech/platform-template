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

assert_policy_contract() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s -e --arg name "${policy_name}" '
      [.[] | select(
        type == "object"
        and .apiVersion == "kyverno.io/v1"
        and .kind == "ClusterPolicy"
        and .metadata.name == $name
      )] as $policies
      | $policies[0].spec.rules as $rules
      | ($policies | length) == 1
        and (($policies[0].spec | keys) == ["background", "rules"])
        and ($policies[0].spec.background == false)
        and ([$rules[].name] == [
          "default-install-remediation",
          "default-upgrade-remediation"
        ])
        and ([$rules[] | keys] == [
          ["match", "mutate", "name", "preconditions"],
          ["match", "mutate", "name", "preconditions"]
        ])
        and ([$rules[].match | keys] == [["any"], ["any"]])
        and ([$rules[].mutate | keys] == [
          ["patchStrategicMerge"],
          ["patchStrategicMerge"]
        ])
        and ([$rules[].preconditions | keys] == [["all"], ["all"]])
        and ($rules[0].match.any == [{
          resources: {
            kinds: ["helm.toolkit.fluxcd.io/v2/HelmRelease"],
            operations: ["CREATE", "UPDATE"],
            selector: {matchLabels: {"helm.toolkit.fluxcd.io/remediation": "enabled"}}
          }
        }])
        and ($rules[1].match.any == $rules[0].match.any)
        and ([$rules[] | has("exclude")] | all(. == false))
        and ($rules[0].preconditions.all == [
          {
            key: "{{ request.object.spec.install.strategy.name || \u0027\u0027 }}",
            operator: "NotEquals",
            value: "RetryOnFailure"
          },
          {
            key: "{{ request.object.spec.install.remediation.retries || \u0027\u0027 }}",
            operator: "NotEquals",
            value: 0
          }
        ])
        and ($rules[1].preconditions.all == [
          {
            key: "{{ request.object.spec.upgrade.strategy.name || \u0027\u0027 }}",
            operator: "NotEquals",
            value: "RetryOnFailure"
          },
          {
            key: "{{ request.object.spec.upgrade.remediation.retries || \u0027\u0027 }}",
            operator: "NotEquals",
            value: 0
          }
        ])
        and ($rules[0].mutate.patchStrategicMerge == {
          spec: {install: {remediation: {
            "+(retries)": -1,
            "+(remediateLastFailure)": true
          }}}
        })
        and ($rules[1].mutate.patchStrategicMerge == {
          spec: {upgrade: {remediation: {
            "+(retries)": -1,
            "+(remediateLastFailure)": true
          }}}
        })
    ' >/dev/null
}

for provider in docker hetzner; do
  rendered="${tmp_dir}/${provider}.yaml"
  kubectl kustomize "${repo_root}/k8s/providers/${provider}/infrastructure/" >"${rendered}"

  if ! assert_policy_contract "${rendered}"; then
    echo "${provider} render does not preserve the shared ${policy_name} contract" >&2
    exit 1
  fi

  if [[ "${provider}" == "docker" ]]; then
    mutated="${tmp_dir}/${provider}-invalid-precondition.yaml"
    yq eval-all \
      '(select(.apiVersion == "kyverno.io/v1" and .kind == "ClusterPolicy" and .metadata.name == "helm-release-remediation-retries").spec.rules[0].preconditions.all[0].operator) = "Equals"' \
      "${rendered}" >"${mutated}"
    if assert_policy_contract "${mutated}"; then
      echo "negative control passed after inverting the install-strategy precondition" >&2
      exit 1
    fi

    mutated="${tmp_dir}/${provider}-disabled-admission.yaml"
    yq eval-all \
      '(select(.apiVersion == "kyverno.io/v1" and .kind == "ClusterPolicy" and .metadata.name == "helm-release-remediation-retries").spec.admission) = false' \
      "${rendered}" >"${mutated}"
    if assert_policy_contract "${mutated}"; then
      echo "negative control passed after disabling admission processing" >&2
      exit 1
    fi

    mutated="${tmp_dir}/${provider}-mutate-existing.yaml"
    yq eval-all \
      '(select(.apiVersion == "kyverno.io/v1" and .kind == "ClusterPolicy" and .metadata.name == "helm-release-remediation-retries").spec.rules[0].mutate.targets) = [{"apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease", "name": "sample", "namespace": "default"}]' \
      "${rendered}" >"${mutated}"
    if assert_policy_contract "${mutated}"; then
      echo "negative control passed after enabling mutate-existing targets" >&2
      exit 1
    fi

    mutated="${tmp_dir}/${provider}-broadened-match.yaml"
    yq eval-all \
      '(select(.apiVersion == "kyverno.io/v1" and .kind == "ClusterPolicy" and .metadata.name == "helm-release-remediation-retries").spec.rules[0].match.resources.kinds) = ["helm.toolkit.fluxcd.io/v2/HelmRelease"]' \
      "${rendered}" >"${mutated}"
    if assert_policy_contract "${mutated}"; then
      echo "negative control passed after adding a sibling match.resources selector" >&2
      exit 1
    fi
  fi
done

echo "✓ Shared Helm remediation policy contract satisfied."
