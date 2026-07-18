#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render() {
  local source_path="$1"
  local output_path="$2"

  if ! kubectl kustomize "${repo_root}/${source_path}" >"${output_path}"; then
    echo "failed to render ${source_path}" >&2
    return 1
  fi
}

resource_count() {
  local rendered_path="$1"
  local kind="$2"
  local namespace="$3"
  local name="$4"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s \
      --arg kind "${kind}" \
      --arg namespace "${namespace}" \
      --arg name "${name}" \
      '[.[] | select(type == "object" and .kind == $kind and .metadata.namespace == $namespace and .metadata.name == $name)] | length'
}

assert_resource_count() {
  local rendered_path="$1"
  local kind="$2"
  local namespace="$3"
  local name="$4"
  local expected="$5"
  local actual

  actual="$(resource_count "${rendered_path}" "${kind}" "${namespace}" "${name}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "expected ${expected} ${kind}/${namespace}/${name} resource(s) in ${rendered_path}, found ${actual}" >&2
    return 1
  fi
}

assert_default_off() {
  local rendered_path="$1"

  assert_resource_count "${rendered_path}" HelmRelease observability coroot-operator 0
  assert_resource_count "${rendered_path}" Coroot observability coroot 0
  assert_resource_count "${rendered_path}" HelmRelease observability audit-log-forwarder 0
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-coroot 0
}

local_controllers_default="${tmp_dir}/local-controllers-default.yaml"
local_infrastructure_default="${tmp_dir}/local-infrastructure-default.yaml"
prod_controllers_default="${tmp_dir}/prod-controllers-default.yaml"
prod_infrastructure_default="${tmp_dir}/prod-infrastructure-default.yaml"
docker_controllers="${tmp_dir}/docker-controllers.yaml"
docker_infrastructure="${tmp_dir}/docker-infrastructure.yaml"
hetzner_controllers="${tmp_dir}/hetzner-controllers.yaml"
hetzner_infrastructure="${tmp_dir}/hetzner-infrastructure.yaml"
coroot_api_expression="\${env:COROOT_API_KEY}"
node_name_expression="\${env:K8S_NODE_NAME}"

# Cluster renders contain Flux pointers, so inspect the provider payloads those
# pointers reconcile. This catches accidental activation in either layer.
render k8s/providers/docker/infrastructure/controllers/ "${local_controllers_default}"
render k8s/providers/docker/infrastructure/ "${local_infrastructure_default}"
render k8s/providers/hetzner/infrastructure/controllers/ "${prod_controllers_default}"
render k8s/providers/hetzner/infrastructure/ "${prod_infrastructure_default}"
for rendered_path in \
  "${local_controllers_default}" \
  "${local_infrastructure_default}" \
  "${prod_controllers_default}" \
  "${prod_infrastructure_default}"; do
  assert_default_off "${rendered_path}"
done

# The default provider payloads still use the legacy kube-prometheus-backed
# OpenCost release. This staged slice must not activate or relocate it outside
# the explicit opt-in fixtures.
for rendered_path in "${local_controllers_default}" "${prod_controllers_default}"; do
  assert_resource_count "${rendered_path}" HelmRelease opencost opencost 1
done
for rendered_path in "${local_infrastructure_default}" "${prod_infrastructure_default}"; do
  assert_resource_count "${rendered_path}" HelmRelease opencost opencost 0
done

render k8s/testdata/observability-option/docker/controllers/ "${docker_controllers}"
render k8s/testdata/observability-option/docker/infrastructure/ "${docker_infrastructure}"
render k8s/testdata/observability-option/hetzner/controllers/ "${hetzner_controllers}"
render k8s/testdata/observability-option/hetzner/infrastructure/ "${hetzner_infrastructure}"

for rendered_path in "${docker_controllers}" "${hetzner_controllers}"; do
  assert_resource_count "${rendered_path}" HelmRelease observability coroot-operator 1
  assert_resource_count "${rendered_path}" Coroot observability coroot 0
  assert_resource_count "${rendered_path}" HelmRelease observability audit-log-forwarder 0
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-coroot 1
  assert_resource_count "${rendered_path}" HelmRelease opencost opencost 0
done

assert_resource_count "${docker_infrastructure}" HelmRelease observability coroot-operator 0
assert_resource_count "${docker_infrastructure}" Coroot observability coroot 1
assert_resource_count "${docker_infrastructure}" HelmRelease observability audit-log-forwarder 0
assert_resource_count "${docker_infrastructure}" HelmRelease opencost opencost 1

assert_resource_count "${hetzner_infrastructure}" HelmRelease observability coroot-operator 0
assert_resource_count "${hetzner_infrastructure}" Coroot observability coroot 1
assert_resource_count "${hetzner_infrastructure}" HelmRelease observability audit-log-forwarder 1
assert_resource_count "${hetzner_infrastructure}" HelmRelease opencost opencost 1

coroot_key_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | .spec.projects[]?.apiKeys[]?.keySecret | select(.name == "coroot-api-key" and .key == "key")] | length'
)"
coroot_agent_key_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | .spec.apiKeySecret | select(.name == "coroot-api-key" and .key == "key")] | length'
)"
anonymous_role_contract="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | select(.spec | has("authAnonymousRole"))] | length'
)"
forwarder_key_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "observability" and .metadata.name == "audit-log-forwarder") | .spec.values.extraEnvs[]? | select(.name == "COROOT_API_KEY") | .valueFrom.secretKeyRef | select(.name == "coroot-api-key" and .key == "key")] | length'
)"
opencost_dependency_contract="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "opencost" and .metadata.name == "opencost") | select((.spec.dependsOn | length) == 1 and .spec.dependsOn[0].name == "coroot-operator" and .spec.dependsOn[0].namespace == "observability")] | length'
)"
opencost_prometheus_contract="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "opencost" and .metadata.name == "opencost") | select(.spec.values.opencost.prometheus.external.url == "http://coroot-prometheus.observability.svc.cluster.local:9090")] | length'
)"
opencost_service_monitor_disabled="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "opencost" and .metadata.name == "opencost") | select(.spec.values.opencost.metrics.serviceMonitor.enabled == false)] | length'
)"
opencost_legacy_backend_count="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "opencost" and .metadata.name == "opencost") | .spec.values.opencost.prometheus.external.url | select(type == "string" and contains("kube-prometheus-stack"))] | length'
)"
opencost_coroot_egress_contract="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "opencost" and .metadata.name == "allow-opencost") | select(any(.spec.egress[]?.toEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "observability"))] | length'
)"
opencost_legacy_egress_count="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "opencost" and .metadata.name == "allow-opencost") | select(any(.spec.egress[]?.toEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "monitoring"))] | length'
)"
opencost_legacy_ingress_count="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "opencost" and .metadata.name == "allow-opencost") | select(any(.spec.ingress[]?.fromEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "monitoring"))] | length'
)"
substitution_disabled="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -sr '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "observability" and .metadata.name == "audit-log-forwarder") | .metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"] == "disabled"] | all'
)"
audit_glob_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "observability" and .metadata.name == "audit-log-forwarder") | .spec.values.config.receivers.filelog.include[]? | select(. == "/var/log/audit/kube/audit*")] | length'
)"
network_policy_contract="$(
  yq eval-all -o=json '.' "${hetzner_controllers}" |
    jq -s '[.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-coroot") | select(any(.spec.ingress[]?.fromEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "observability")) | select(any(.spec.egress[]?.toEntities[]?; . == "kube-apiserver")) | select(any(.spec.egress[]?.toFQDNs[]?; .matchName == "ghcr.io"))] | length'
)"
renovate_coroot_manager="$(
  jq '[.customManagers[]? | select(.datasourceTemplate == "docker") | select(any(.fileMatch[]?; . == "^k8s/bases/infrastructure/coroot/coroot\\.ya?ml$")) | select(any(.matchStrings[]?; contains("ghcr\\.io/coroot")))] | length' \
    "${repo_root}/.github/renovate.json"
)"

if [[ "${coroot_key_contract}" != "1" || "${coroot_agent_key_contract}" != "1" || "${forwarder_key_contract}" != "1" ]]; then
  echo "Coroot projects, bundled agents, and audit-log-forwarder do not share the coroot-api-key/key Secret contract" >&2
  exit 1
fi
if [[ "${opencost_dependency_contract}" != "2" || "${opencost_prometheus_contract}" != "2" || "${opencost_service_monitor_disabled}" != "2" || "${opencost_legacy_backend_count}" != "0" || "${opencost_coroot_egress_contract}" != "2" || "${opencost_legacy_egress_count}" != "0" || "${opencost_legacy_ingress_count}" != "0" ]]; then
  echo "opt-in OpenCost must run in the infrastructure layer against Coroot Prometheus without a ServiceMonitor or obsolete monitoring access" >&2
  exit 1
fi
if [[ "${anonymous_role_contract}" != "0" ]]; then
  echo "generic Coroot option must not grant an anonymous role; instances may opt in behind their own authentication boundary" >&2
  exit 1
fi
if [[ "${substitution_disabled}" != "true" ]]; then
  echo "audit-log-forwarder must disable Flux substitution for OpenTelemetry env expressions" >&2
  exit 1
fi
if [[ "${audit_glob_contract}" != "1" ]]; then
  echo "audit-log-forwarder must discover the active and retained rotated audit logs" >&2
  exit 1
fi
if [[ "${network_policy_contract}" != "1" ]]; then
  echo "Coroot controller layer must retain its intra-namespace, Kubernetes API, and GHCR access" >&2
  exit 1
fi
if [[ "${renovate_coroot_manager}" != "1" ]]; then
  echo "Coroot's image.name pins must remain Renovate-trackable" >&2
  exit 1
fi
if ! grep -Fq "${coroot_api_expression}" "${hetzner_infrastructure}" || ! grep -Fq "${node_name_expression}" "${hetzner_infrastructure}"; then
  echo "audit-log-forwarder render lost its OpenTelemetry env expressions" >&2
  exit 1
fi

if grep -R -E -n '(devantler|homelab|hooks\.slack\.com|hcloud|alertmanager_webhook_url)' \
  "${repo_root}/k8s/bases/infrastructure/controllers/coroot" \
  "${repo_root}/k8s/bases/infrastructure/coroot" \
  "${repo_root}/k8s/bases/infrastructure/audit-log-forwarder"; then
  echo "staged observability manifests contain an instance-specific value" >&2
  exit 1
fi

echo "Observability option validation passed (default-off + staged provider renders)."
