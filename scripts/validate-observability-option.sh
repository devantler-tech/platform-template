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
      '[.[] | select(type == "object" and .kind == $kind and (.metadata.namespace // "") == $namespace and .metadata.name == $name)] | length'
}

opencost_resource_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] | select(type == "object" and ((.kind == "Namespace" and .metadata.name == "opencost") or .metadata.namespace == "opencost"))] | length'
}

opencost_reference_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] | select(type == "object" and (tojson | test("opencost"; "i")))] | length'
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

flux_path() {
  local rendered_path="$1"
  local name="$2"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s -r \
      --arg name "${name}" \
      '[.[] | select(type == "object" and .kind == "Kustomization" and .metadata.namespace == "flux-system" and .metadata.name == $name)] |
       if length == 1 then .[0].spec.path else "invalid-count:\(length)" end'
}

assert_flux_path() {
  local rendered_path="$1"
  local name="$2"
  local expected="$3"
  local actual

  actual="$(flux_path "${rendered_path}" "${name}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "expected Flux Kustomization/${name} path ${expected} in ${rendered_path}, found ${actual}" >&2
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

assert_opencost_present() {
  local rendered_path="$1"

  assert_resource_count "${rendered_path}" Namespace "" opencost 1
  assert_resource_count "${rendered_path}" HelmRepository opencost opencost 1
  assert_resource_count "${rendered_path}" HelmRelease opencost opencost 1
  assert_resource_count "${rendered_path}" HTTPRoute opencost opencost 1
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy opencost allow-opencost 1
}

assert_opencost_resources_absent() {
  local rendered_path="$1"
  local actual

  actual="$(opencost_resource_count "${rendered_path}")"
  if [[ "${actual}" != "0" ]]; then
    echo "expected no OpenCost resources in ${rendered_path}, found ${actual}" >&2
    return 1
  fi
}

assert_opencost_reference_count() {
  local rendered_path="$1"
  local expected="$2"
  local actual

  actual="$(opencost_reference_count "${rendered_path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "expected ${expected} OpenCost-referencing resource(s) in ${rendered_path}, found ${actual}" >&2
    return 1
  fi
}

assert_opencost_absent() {
  local rendered_path="$1"
  local actual

  assert_opencost_resources_absent "${rendered_path}"
  actual="$(opencost_reference_count "${rendered_path}")"
  if [[ "${actual}" != "0" ]]; then
    echo "expected no OpenCost references in ${rendered_path}, found ${actual} resource(s)" >&2
    return 1
  fi
}

assert_auth_proxy_without_opencost() {
  local default_rendered_path="$1"
  local opt_in_rendered_path="$2"
  local expected
  local actual

  expected="$(
    yq eval-all -o=json 'select(.kind == "ConfigMap" and .metadata.namespace == "oauth2-proxy" and .metadata.name == "auth-proxy-config") | .data."dynamic.yaml" | from_yaml' "${default_rendered_path}" |
      jq -S -c 'del(.http.routers.opencost, .http.services.opencost)'
  )"
  actual="$(
    yq eval-all -o=json 'select(.kind == "ConfigMap" and .metadata.namespace == "oauth2-proxy" and .metadata.name == "auth-proxy-config") | .data."dynamic.yaml" | from_yaml' "${opt_in_rendered_path}" |
      jq -S -c '.'
  )"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "opt-in auth-proxy config must equal its provider default minus the OpenCost router and service" >&2
    return 1
  fi
}

policy_rules_without_namespace_exclusion() {
  local rendered_path="$1"
  local policy_name="$2"
  local namespace="$3"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s -r \
      --arg policy_name "${policy_name}" \
      --arg namespace "${namespace}" \
      '[.[] | select(type == "object" and .kind == "ClusterPolicy" and .metadata.name == $policy_name)] as $policies |
       if ($policies | length) != 1 then
         "invalid-policy-count:\($policies | length)"
       else
         [$policies[0].spec.rules[] |
          select(([.exclude.any[]?.resources.namespaces[]?] | index($namespace)) == null)] | length
       end'
}

policy_rules_with_namespace_exclusion() {
  local rendered_path="$1"
  local policy_name="$2"
  local namespace="$3"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s -r \
      --arg policy_name "${policy_name}" \
      --arg namespace "${namespace}" \
      '[.[] | select(type == "object" and .kind == "ClusterPolicy" and .metadata.name == $policy_name)] as $policies |
       if ($policies | length) != 1 then
         "invalid-policy-count:\($policies | length)"
       else
         [$policies[0].spec.rules[] |
          select(([.exclude.any[]?.resources.namespaces[]?] | index($namespace)) != null)] | length
       end'
}

assert_namespace_excluded_from_all_policy_rules() {
  local rendered_path="$1"
  local policy_name="$2"
  local namespace="$3"
  local actual

  actual="$(policy_rules_without_namespace_exclusion "${rendered_path}" "${policy_name}" "${namespace}")"
  if [[ "${actual}" != "0" ]]; then
    echo "expected ClusterPolicy/${policy_name} to exclude namespace ${namespace} from every rule in ${rendered_path}, found ${actual} unprotected rule(s)" >&2
    return 1
  fi
}

assert_namespace_not_excluded_from_policy() {
  local rendered_path="$1"
  local policy_name="$2"
  local namespace="$3"
  local actual

  actual="$(policy_rules_with_namespace_exclusion "${rendered_path}" "${policy_name}" "${namespace}")"
  if [[ "${actual}" != "0" ]]; then
    echo "expected ClusterPolicy/${policy_name} to keep namespace ${namespace} enforced in ${rendered_path}, found ${actual} excluded rule(s)" >&2
    return 1
  fi
}

assert_security_exception_namespace_count() {
  local rendered_path="$1"
  local exception_name="$2"
  local namespace="$3"
  local expected="$4"
  local actual

  assert_resource_count "${rendered_path}" ClusterSecurityException "" "${exception_name}" 1
  actual="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s -r \
        --arg exception_name "${exception_name}" \
        --arg namespace "${namespace}" \
        '[.[] |
          select(type == "object" and .kind == "ClusterSecurityException" and .metadata.name == $exception_name) |
          .spec.match.namespaceSelector.matchExpressions[]? |
          select(.key == "kubernetes.io/metadata.name" and .operator == "In") |
          .values[]? |
          select(. == $namespace)] | length'
  )"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "expected ${expected} ${exception_name} Kubescape exception(s) for namespace ${namespace} in ${rendered_path}, found ${actual}" >&2
    return 1
  fi
}

local_controllers_default="${tmp_dir}/local-controllers-default.yaml"
local_infrastructure_default="${tmp_dir}/local-infrastructure-default.yaml"
local_apps_default="${tmp_dir}/local-apps-default.yaml"
prod_controllers_default="${tmp_dir}/prod-controllers-default.yaml"
prod_infrastructure_default="${tmp_dir}/prod-infrastructure-default.yaml"
prod_apps_default="${tmp_dir}/prod-apps-default.yaml"
local_cluster_default="${tmp_dir}/local-cluster-default.yaml"
prod_cluster_default="${tmp_dir}/prod-cluster-default.yaml"
local_cluster_coroot="${tmp_dir}/local-cluster-coroot.yaml"
prod_cluster_coroot="${tmp_dir}/prod-cluster-coroot.yaml"
docker_controllers="${tmp_dir}/docker-controllers.yaml"
docker_infrastructure="${tmp_dir}/docker-infrastructure.yaml"
docker_apps="${tmp_dir}/docker-apps.yaml"
hetzner_controllers="${tmp_dir}/hetzner-controllers.yaml"
hetzner_infrastructure="${tmp_dir}/hetzner-infrastructure.yaml"
hetzner_apps="${tmp_dir}/hetzner-apps.yaml"
coroot_api_expression="\${env:COROOT_API_KEY}"
node_name_expression="\${env:K8S_NODE_NAME}"

# The supported selection surface is an alternate cluster path. Existing
# instance-owned KSail configs keep the default cluster paths until an operator
# explicitly opts in.
render k8s/clusters/local/ "${local_cluster_default}"
render k8s/clusters/prod/ "${prod_cluster_default}"
render k8s/clusters/local-coroot/ "${local_cluster_coroot}"
render k8s/clusters/prod-coroot/ "${prod_cluster_coroot}"

assert_flux_path "${local_cluster_default}" bootstrap clusters/local/bootstrap
assert_flux_path "${local_cluster_default}" infrastructure-controllers providers/docker/infrastructure/controllers
assert_flux_path "${local_cluster_default}" infrastructure providers/docker/infrastructure
assert_flux_path "${local_cluster_default}" apps providers/docker/apps
assert_flux_path "${prod_cluster_default}" bootstrap clusters/prod/bootstrap
assert_flux_path "${prod_cluster_default}" infrastructure-controllers providers/hetzner/infrastructure/controllers
assert_flux_path "${prod_cluster_default}" infrastructure providers/hetzner/infrastructure
assert_flux_path "${prod_cluster_default}" apps providers/hetzner/apps

assert_flux_path "${local_cluster_coroot}" bootstrap clusters/local/bootstrap
assert_flux_path "${local_cluster_coroot}" infrastructure-controllers providers/docker/infrastructure-controllers-coroot
assert_flux_path "${local_cluster_coroot}" infrastructure providers/docker/infrastructure-coroot
assert_flux_path "${local_cluster_coroot}" apps providers/docker/apps-coroot
assert_flux_path "${prod_cluster_coroot}" bootstrap clusters/prod/bootstrap
assert_flux_path "${prod_cluster_coroot}" infrastructure-controllers providers/hetzner/infrastructure-controllers-coroot
assert_flux_path "${prod_cluster_coroot}" infrastructure providers/hetzner/infrastructure-coroot
assert_flux_path "${prod_cluster_coroot}" apps providers/hetzner/apps-coroot

# Cluster renders contain Flux pointers, so inspect the provider payloads those
# pointers reconcile. This catches accidental activation in either layer.
render k8s/providers/docker/infrastructure/controllers/ "${local_controllers_default}"
render k8s/providers/docker/infrastructure/ "${local_infrastructure_default}"
render k8s/providers/docker/apps/ "${local_apps_default}"
render k8s/providers/hetzner/infrastructure/controllers/ "${prod_controllers_default}"
render k8s/providers/hetzner/infrastructure/ "${prod_infrastructure_default}"
render k8s/providers/hetzner/apps/ "${prod_apps_default}"
for rendered_path in \
  "${local_controllers_default}" \
  "${local_infrastructure_default}" \
  "${prod_controllers_default}" \
  "${prod_infrastructure_default}"; do
  assert_default_off "${rendered_path}"
done

# The default provider payloads retain the complete legacy OpenCost surface.
# Only the explicit Coroot profiles retire it.
for rendered_path in "${local_controllers_default}" "${prod_controllers_default}"; do
  assert_opencost_present "${rendered_path}"
done
for rendered_path in "${local_infrastructure_default}" "${prod_infrastructure_default}"; do
  assert_opencost_resources_absent "${rendered_path}"
  assert_namespace_not_excluded_from_policy "${rendered_path}" add-security-context observability
  assert_namespace_not_excluded_from_policy "${rendered_path}" validate-host-restrictions observability
  assert_namespace_not_excluded_from_policy "${rendered_path}" validate-pod-security observability
  assert_security_exception_namespace_count "${rendered_path}" infrastructure-privileged observability 0
  assert_security_exception_namespace_count "${rendered_path}" controller-rbac observability 0
  assert_security_exception_namespace_count "${rendered_path}" service-account-tokens observability 0
done
assert_opencost_reference_count "${local_apps_default}" 1
assert_opencost_reference_count "${prod_apps_default}" 1

render k8s/providers/docker/infrastructure-controllers-coroot/ "${docker_controllers}"
render k8s/providers/docker/infrastructure-coroot/ "${docker_infrastructure}"
render k8s/providers/docker/apps-coroot/ "${docker_apps}"
render k8s/providers/hetzner/infrastructure-controllers-coroot/ "${hetzner_controllers}"
render k8s/providers/hetzner/infrastructure-coroot/ "${hetzner_infrastructure}"
render k8s/providers/hetzner/apps-coroot/ "${hetzner_apps}"

assert_auth_proxy_without_opencost "${local_controllers_default}" "${docker_controllers}"
assert_auth_proxy_without_opencost "${prod_controllers_default}" "${hetzner_controllers}"

for rendered_path in "${docker_controllers}" "${hetzner_controllers}"; do
  assert_resource_count "${rendered_path}" HelmRelease observability coroot-operator 1
  assert_resource_count "${rendered_path}" Coroot observability coroot 0
  assert_resource_count "${rendered_path}" HelmRelease observability audit-log-forwarder 0
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-coroot 1
  assert_opencost_absent "${rendered_path}"
done

for rendered_path in "${docker_infrastructure}" "${hetzner_infrastructure}"; do
  assert_namespace_excluded_from_all_policy_rules "${rendered_path}" add-security-context observability
  assert_namespace_excluded_from_all_policy_rules "${rendered_path}" validate-host-restrictions observability
  assert_namespace_excluded_from_all_policy_rules "${rendered_path}" validate-pod-security observability
  assert_security_exception_namespace_count "${rendered_path}" infrastructure-privileged observability 1
  assert_security_exception_namespace_count "${rendered_path}" controller-rbac observability 1
  assert_security_exception_namespace_count "${rendered_path}" service-account-tokens observability 1
  assert_security_exception_namespace_count "${rendered_path}" health-probes observability 0
done

assert_resource_count "${docker_infrastructure}" HelmRelease observability coroot-operator 0
assert_resource_count "${docker_infrastructure}" Coroot observability coroot 1
assert_resource_count "${docker_infrastructure}" HelmRelease observability audit-log-forwarder 0
assert_opencost_absent "${docker_infrastructure}"

assert_resource_count "${hetzner_infrastructure}" HelmRelease observability coroot-operator 0
assert_resource_count "${hetzner_infrastructure}" Coroot observability coroot 1
assert_resource_count "${hetzner_infrastructure}" HelmRelease observability audit-log-forwarder 1
assert_opencost_absent "${hetzner_infrastructure}"
assert_opencost_absent "${docker_apps}"
assert_opencost_absent "${hetzner_apps}"

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

templating_guide="${repo_root}/docs/TEMPLATING.md"
for documented_value in \
  clusters/local-coroot \
  clusters/prod-coroot \
  spec.workload.kustomizationFile; do
  if ! grep -Fq "${documented_value}" "${templating_guide}"; then
    echo "templating guide does not document Coroot opt-in value ${documented_value}" >&2
    exit 1
  fi
done
templating_flat="$(tr '\n' '|' <"${templating_guide}")"
for config_path in ksail.yaml ksail.prod.yaml; do
  expected_sequence="ksail --config ${config_path} workload push|ksail --config ${config_path} cluster update|ksail --config ${config_path} workload reconcile"
  if [[ "${templating_flat}" != *"${expected_sequence}"* ]]; then
    echo "templating guide does not document publish, path update, and reconciliation in order for ${config_path}" >&2
    exit 1
  fi
done
for documented_boundary in \
  "This profile is transitional." \
  "removes OpenCost and its Headlamp" \
  "Cost allocation is therefore unavailable"; do
  if ! grep -Fq "${documented_boundary}" "${templating_guide}"; then
    echo "templating guide does not retain Coroot boundary: ${documented_boundary}" >&2
    exit 1
  fi
done

if grep -R -E -n '(devantler|homelab|hooks\.slack\.com|hcloud|alertmanager_webhook_url)' \
  "${repo_root}/k8s/bases/infrastructure/controllers/coroot" \
  "${repo_root}/k8s/bases/infrastructure/coroot" \
  "${repo_root}/k8s/bases/infrastructure/audit-log-forwarder"; then
  echo "Coroot profile manifests contain an instance-specific value" >&2
  exit 1
fi

echo "Observability option validation passed (default-off + selectable Coroot provider renders)."
