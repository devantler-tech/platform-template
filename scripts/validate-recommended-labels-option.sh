#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_name="add-recommended-labels"
policy_revision="752a288171a6a26331e0a33ac18132ead0718cd3"
policy_url="https://raw.githubusercontent.com/devantler-tech/kyverno-policies/${policy_revision}/policies/best-practices/${policy_name}.yaml"
component="${repo_root}/k8s/components/cluster-policies/recommended-labels/kustomization.yaml"
templating_doc="${repo_root}/docs/TEMPLATING.md"

die() {
  echo "$1" >&2
  exit 1
}

assert_component_source() {
  local source_file="$1"

  yq -o=json '.' "${source_file}" |
    jq -e --arg url "${policy_url}" '
      .apiVersion == "kustomize.config.k8s.io/v1alpha1"
      and .kind == "Component"
      and ((keys | sort) == ["apiVersion", "kind", "resources"])
      and .resources == [$url]
    ' >/dev/null
}

assert_policy_absent() {
  local rendered_file="$1"

  yq eval-all -o=json '.' "${rendered_file}" |
    jq -s -e --arg name "${policy_name}" '
      [.[] | select(
        type == "object"
        and .apiVersion == "kyverno.io/v1"
        and .kind == "ClusterPolicy"
        and .metadata.name == $name
      )] | length == 0
    ' >/dev/null
}

assert_policy_contract() {
  local rendered_file="$1"

  yq eval-all -o=json '.' "${rendered_file}" |
    jq -s -e --arg name "${policy_name}" '
      [.[] | select(
        type == "object"
        and .apiVersion == "kyverno.io/v1"
        and .kind == "ClusterPolicy"
        and .metadata.name == $name
      )] as $policies
      | ($policies | length) == 1
        and (($policies[0].spec | keys | sort) == ["background", "rules"])
        and ($policies[0].spec.background == false)
        and ($policies[0].spec.rules == [{
          name: "add-workload-labels",
          match: {any: [{resources: {kinds: [
            "apps/v1/Deployment",
            "apps/v1/StatefulSet",
            "apps/v1/DaemonSet"
          ]}}]},
          exclude: {any: [{resources: {namespaces: [
            "kube-system",
            "kube-public",
            "kube-node-lease"
          ]}}]},
          preconditions: {all: [
            {
              key: "{{ request.object.metadata.name || \u0027\u0027 }}",
              operator: "NotEquals",
              value: ""
            },
            {
              key: "{{ length(request.object.metadata.name || \u0027\u0027) }}",
              operator: "LessThanOrEquals",
              value: 63
            }
          ]},
          mutate: {patchStrategicMerge: {
            metadata: {labels: {
              "+(app)": "{{ request.object.metadata.name || \u0027\u0027 }}",
              "+(app.kubernetes.io/name)": "{{ request.object.metadata.name || \u0027\u0027 }}"
            }},
            spec: {template: {metadata: {labels: {
              "+(app.kubernetes.io/name)": "{{ request.object.metadata.name || \u0027\u0027 }}"
            }}}}
          }}
        }])
    ' >/dev/null
}

assert_profile_contract() {
  local profile_file="$1"
  local cluster="$2"
  local base_path="$3"
  local opt_in_path="$4"
  local match_count
  local patch_body

  yq -o=json '.' "${profile_file}" |
    jq -e --arg resource "../${cluster}/" '
      .apiVersion == "kustomize.config.k8s.io/v1beta1"
      and .kind == "Kustomization"
      and ((keys | sort) == ["apiVersion", "kind", "patches", "resources"])
      and .resources == [$resource]
    ' >/dev/null

  match_count="$(
    yq '
      [.patches[] | select(
        .target.group == "kustomize.toolkit.fluxcd.io"
        and .target.version == "v1"
        and .target.kind == "Kustomization"
        and .target.name == "infrastructure"
        and .target.namespace == "flux-system"
      )] | length
    ' "${profile_file}"
  )"
  [[ "${match_count}" == "1" ]] || return 1

  patch_body="$(
    yq -r '
      .patches[] | select(
        .target.group == "kustomize.toolkit.fluxcd.io"
        and .target.version == "v1"
        and .target.kind == "Kustomization"
        and .target.name == "infrastructure"
        and .target.namespace == "flux-system"
      ) | .patch
    ' "${profile_file}"
  )"

  [[ -n "${patch_body}" ]] || return 1
  yq -o=json '.' <<<"${patch_body}" |
    jq -e --arg base "${base_path}" --arg opt_in "${opt_in_path}" '
      . == [
        {op: "test", path: "/spec/path", value: $base},
        {op: "replace", path: "/spec/path", value: $opt_in}
      ]
    ' >/dev/null
}

assert_provider_profile_contract() {
  local profile_file="$1"

  yq -o=json '.' "${profile_file}" |
    jq -e '
      .apiVersion == "kustomize.config.k8s.io/v1beta1"
      and .kind == "Kustomization"
      and ((keys | sort) == ["apiVersion", "components", "kind", "resources"])
      and .resources == ["../infrastructure/"]
      and .components == ["../../../components/cluster-policies/recommended-labels/"]
    ' >/dev/null
}

[[ -f "${component}" ]] || die "missing recommended-labels component"
assert_component_source "${component}" || die "recommended-labels component is not one exact immutable policy import"
component_source_count="$(grep -R -F -h -- "${policy_url}" "${repo_root}/k8s/components" | wc -l | tr -d ' ')"
[[ "${component_source_count}" == "1" ]] || die "expected one component import for ${policy_name}, found ${component_source_count}"

for profile in \
  "${repo_root}/k8s/providers/docker/infrastructure-recommended-labels/kustomization.yaml" \
  "${repo_root}/k8s/providers/hetzner/infrastructure-recommended-labels/kustomization.yaml"; do
  [[ -f "${profile}" ]] || die "missing provider opt-in profile: ${profile}"
  assert_provider_profile_contract "${profile}" || die "provider opt-in profile has unexpected resources or components: ${profile}"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

for provider in docker hetzner; do
  default_render="${tmp_dir}/${provider}-default.yaml"
  opt_in_render="${tmp_dir}/${provider}-recommended-labels.yaml"
  kubectl kustomize "${repo_root}/k8s/providers/${provider}/infrastructure" >"${default_render}"
  kubectl kustomize "${repo_root}/k8s/providers/${provider}/infrastructure-recommended-labels" >"${opt_in_render}"

  assert_policy_absent "${default_render}" || die "${provider} default unexpectedly enables ${policy_name}"
  assert_policy_contract "${opt_in_render}" || die "${provider} opt-in does not preserve the reviewed ${policy_name} contract"
done

for cluster in local prod; do
  if [[ "${cluster}" == "local" ]]; then
    provider="docker"
  else
    provider="hetzner"
  fi
  profile="${repo_root}/k8s/clusters/${cluster}-recommended-labels/kustomization.yaml"
  assert_profile_contract \
    "${profile}" \
    "${cluster}" \
    "providers/${provider}/infrastructure" \
    "providers/${provider}/infrastructure-recommended-labels" ||
    die "${cluster} profile does not fail closed while selecting the recommended-labels provider path"

  rendered_profile="${tmp_dir}/${cluster}-profile.yaml"
  kubectl kustomize "${repo_root}/k8s/clusters/${cluster}-recommended-labels" >"${rendered_profile}"
  selected_path="$(
    yq eval-all -o=json '.' "${rendered_profile}" |
      jq -rs --arg name infrastructure '
        [.[] | select(
          type == "object"
          and .apiVersion == "kustomize.toolkit.fluxcd.io/v1"
          and .kind == "Kustomization"
          and .metadata.name == $name
          and .metadata.namespace == "flux-system"
        ) | .spec.path] | if length == 1 then .[0] else "" end
      '
  )"
  [[ "${selected_path}" == "providers/${provider}/infrastructure-recommended-labels" ]] ||
    die "${cluster} profile selected unexpected infrastructure path: ${selected_path}"
done

for required_doc_token in \
  'clusters/local-recommended-labels' \
  'clusters/prod-recommended-labels' \
  'add-recommended-labels' \
  "restore \`clusters/local\` or \`clusters/prod\`"; do
  grep -F -q -- "${required_doc_token}" "${templating_doc}" ||
    die "templating guide is missing recommended-label opt-in guidance: ${required_doc_token}"
done

mutable_component="${tmp_dir}/mutable-component.yaml"
sed "s/${policy_revision}/main/" "${component}" >"${mutable_component}"
if assert_component_source "${mutable_component}"; then
  die "negative control passed with a mutable policy source"
fi

duplicate_component="${tmp_dir}/duplicate-component.yaml"
cp "${component}" "${duplicate_component}"
printf '  - %s\n' "${policy_url}" >>"${duplicate_component}"
if assert_component_source "${duplicate_component}"; then
  die "negative control passed with a duplicate policy source"
fi

baseline="${tmp_dir}/docker-recommended-labels.yaml"
for mutation in background broad-kind overwrite-label missing-exclusion missing-name-guard; do
  mutated="${tmp_dir}/mutated-${mutation}.yaml"
  case "${mutation}" in
    background)
      expression='(select(.kind == "ClusterPolicy" and .metadata.name == "add-recommended-labels").spec.background) = true'
      ;;
    broad-kind)
      expression='(select(.kind == "ClusterPolicy" and .metadata.name == "add-recommended-labels").spec.rules[0].match.any[0].resources.kinds[0]) = "Deployment"'
      ;;
    overwrite-label)
      expression='(select(.kind == "ClusterPolicy" and .metadata.name == "add-recommended-labels").spec.rules[0].mutate.patchStrategicMerge.metadata.labels) = {"app": "{{ request.object.metadata.name || \u0027\u0027 }}"}'
      ;;
    missing-exclusion)
      expression='del(select(.kind == "ClusterPolicy" and .metadata.name == "add-recommended-labels").spec.rules[0].exclude)'
      ;;
    missing-name-guard)
      expression='del(select(.kind == "ClusterPolicy" and .metadata.name == "add-recommended-labels").spec.rules[0].preconditions.all[1])'
      ;;
  esac
  yq eval-all "${expression}" "${baseline}" >"${mutated}"
  if assert_policy_contract "${mutated}"; then
    die "negative control passed after ${mutation} mutation"
  fi
done

echo "✓ Recommended workload labels stay default-off and preserve the reviewed policy contract."
