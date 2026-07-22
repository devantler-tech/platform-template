#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# Renders a repository-relative profile so every assertion evaluates the effective
# Kustomize payload independently of the caller's working directory.
render() {
  local source_path="$1"
  local output_path="$2"

  if ! kubectl kustomize "${repo_root}/${source_path}" >"${output_path}"; then
    echo "failed to render ${source_path}" >&2
    return 1
  fi
}

# Counts one exact kind/namespace/name identity in a multi-document render.
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

loki_datasource_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] |
      select(type == "object" and .kind == "HelmRelease" and .metadata.namespace == "monitoring" and .metadata.name == "kube-prometheus-stack") |
      .spec.values.grafana.additionalDataSources[]? |
      select(.type == "loki" or ((.url // "") | test("loki\\.monitoring\\.svc")))] | length'
}

loki_service_reference_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] | select(type == "object" and (tojson | test("loki\\.monitoring\\.svc")))] | length'
}

# Fails closed when an exact rendered identity is missing or duplicated.
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

# Verifies that the default profiles render no Coroot-owned resources.
assert_default_off() {
  local rendered_path="$1"

  assert_resource_count "${rendered_path}" HelmRelease observability coroot-operator 0
  assert_resource_count "${rendered_path}" Coroot observability coroot 0
  assert_resource_count "${rendered_path}" HelmRelease observability audit-log-forwarder 0
  assert_resource_count "${rendered_path}" CronJob observability cluster-heartbeat 0
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-coroot 0
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-cluster-heartbeat 0
  assert_resource_count "${rendered_path}" HTTPRoute observability coroot 0
}

# Validates the singleton workload, isolation selector, and exact egress contract
# rendered by each explicit Coroot profile.
assert_coroot_heartbeat_contract() {
  local rendered_path="$1"
  local heartbeat_count
  local cronjob_contract
  local heartbeat_egress_contract
  local coroot_selector_contract
  local broad_external_egress

  heartbeat_count="$(resource_count "${rendered_path}" CronJob observability cluster-heartbeat)"
  cronjob_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "CronJob" and .metadata.namespace == "observability" and .metadata.name == "cluster-heartbeat") |
        select(.spec.schedule == "*/5 * * * *") |
        select(.spec.concurrencyPolicy == "Forbid") |
        select(.spec.startingDeadlineSeconds == 30) |
        select(.spec.successfulJobsHistoryLimit == 1 and .spec.failedJobsHistoryLimit == 1) |
        select(.spec.jobTemplate.spec.backoffLimit == 0 and .spec.jobTemplate.spec.activeDeadlineSeconds == 120) |
        .spec.jobTemplate.spec.template as $template |
        select($template.metadata.labels.app == "cluster-heartbeat") |
        select($template.metadata.labels["platform-heartbeat"] == "true") |
        $template.spec as $pod |
        select($pod.restartPolicy == "Never" and $pod.automountServiceAccountToken == false) |
        select($pod.priorityClassName == "platform-critical") |
        select($pod.securityContext.runAsNonRoot == true and $pod.securityContext.runAsUser == 65532) |
        select($pod.securityContext.seccompProfile.type == "RuntimeDefault") |
        select($pod.containers | length == 1) |
        $pod.containers[0] as $container |
        select($container.name == "heartbeat") |
        select($container.image == "docker.io/curlimages/curl:8.21.0@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13") |
        select($container.command == [
          "/bin/sh",
          "-c"
        ]) |
        select($container.args == [
          "curl -sf --max-time 10 --retry 3 --retry-delay 2 --retry-all-errors --retry-connrefused \"$1\" || true",
          "cluster-heartbeat",
          "${alertmanager_heartbeat_url:=https://example.invalid/no-heartbeat-configured}"
        ]) |
        select($container.securityContext.allowPrivilegeEscalation == false) |
        select($container.securityContext.readOnlyRootFilesystem == true) |
        select($container.securityContext.runAsNonRoot == true and $container.securityContext.runAsUser == 65532 and $container.securityContext.runAsGroup == 65532) |
        select($container.securityContext.capabilities.drop == ["ALL"]) |
        select($container.resources == {
          "requests":{"cpu":"5m","memory":"16Mi"},
          "limits":{"cpu":"50m","memory":"32Mi"}
        })] | length'
  )"
  heartbeat_egress_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-cluster-heartbeat") |
        select(.spec == {
          "endpointSelector":{"matchLabels":{"platform-heartbeat":"true"}},
          "enableDefaultDeny":{"ingress":true,"egress":true},
          "ingressDeny":[{}],
          "egress":[
            {
              "toFQDNs":[{"matchName":"hc-ping.com"}],
              "toPorts":[{"ports":[{"port":"443","protocol":"TCP"}]}]
            },
            {
              "toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s-app":"kube-dns"}}],
              "toPorts":[{
                "ports":[{"port":"53","protocol":"UDP"},{"port":"53","protocol":"TCP"}],
                "rules":{"dns":[{"matchName":"hc-ping.com"}]}
              }]
            }
          ]
        })] | length'
  )"
  coroot_selector_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-coroot") |
        select(.spec.endpointSelector.matchExpressions == [{"key":"platform-heartbeat","operator":"NotIn","values":["true"]}]) |
        select(all(.spec.egress[]?.toFQDNs[]?; .matchName != "hc-ping.com"))] | length'
  )"
  broad_external_egress="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-coroot") |
        .spec.egress[]? |
        select(any(.toEntities[]?; . == "world" or . == "all") or any(.toFQDNs[]?; has("matchPattern")))] | length'
  )"

  if [[ "${heartbeat_count}" != "1" || "${cronjob_contract}" != "1" ]]; then
    echo "Coroot profile must render one hardened five-minute cluster heartbeat in ${rendered_path}" >&2
    return 1
  fi
  if [[ "${heartbeat_egress_contract}" != "1" || "${coroot_selector_contract}" != "1" || "${broad_external_egress}" != "0" ]]; then
    echo "Coroot heartbeat must be excluded from broad policies and have one exact configured-host egress path without wildcard or world access in ${rendered_path}" >&2
    return 1
  fi
}

# Validates the effective heartbeat after Flux post-build substitution.
assert_coroot_heartbeat_substitution() {
  local rendered_path="$1"
  local substituted_path
  local heartbeat_url="https://hc-ping.com/example-heartbeat"
  local heartbeat_host
  local heartbeat_token='$'
  local rendered_line
  local rendered_prefix
  local rendered_suffix
  local cronjob_matches
  local policy_matches

  substituted_path="${tmp_dir}/$(basename "${rendered_path}" .yaml)-heartbeat-substituted.yaml"
  heartbeat_token+='{alertmanager_heartbeat_url:=https://example.invalid/no-heartbeat-configured}'
  heartbeat_host="${heartbeat_url#https://}"
  heartbeat_host="${heartbeat_host%%/*}"
  while IFS= read -r rendered_line || [[ -n "${rendered_line}" ]]; do
    if [[ "${rendered_line}" == *"${heartbeat_token}"* ]]; then
      rendered_prefix="${rendered_line%%"${heartbeat_token}"*}"
      rendered_suffix="${rendered_line#*"${heartbeat_token}"}"
      rendered_line="${rendered_prefix}${heartbeat_url}${rendered_suffix}"
    fi
    printf '%s\n' "${rendered_line}"
  done <"${rendered_path}" >"${substituted_path}"

  cronjob_matches="$(
    yq eval-all -o=json '.' "${substituted_path}" |
      jq -s --arg heartbeat_url "${heartbeat_url}" '[.[] |
        select(.kind == "CronJob" and .metadata.namespace == "observability" and .metadata.name == "cluster-heartbeat") |
        .spec.jobTemplate.spec.template.spec.containers[0] as $container |
        select($container.command == ["/bin/sh", "-c"]) |
        select($container.args == [
          "curl -sf --max-time 10 --retry 3 --retry-delay 2 --retry-all-errors --retry-connrefused \"$1\" || true",
          "cluster-heartbeat",
          $heartbeat_url
        ])] | length'
  )"
  policy_matches="$(
    yq eval-all -o=json '.' "${substituted_path}" |
      jq -s --arg heartbeat_host "${heartbeat_host}" '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-cluster-heartbeat") |
        select(any(.spec.egress[]?.toFQDNs[]?; .matchName == $heartbeat_host)) |
        select(any(.spec.egress[]?.toPorts[]?.rules.dns[]?; .matchName == $heartbeat_host))] | length'
  )"

  if [[ "${cronjob_matches}" != "1" || "${policy_matches}" != "1" ]]; then
    echo "Flux-substituted heartbeat URL and exact policy host must agree in ${rendered_path}" >&2
    return 1
  fi
}

# Validates that kube-prometheus-stack still produces the Watchdog rule.
assert_watchdog_rendered() {
  local rendered_path="$1"
  local matches

  matches="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "HelmRelease" and .metadata.namespace == "monitoring" and .metadata.name == "kube-prometheus-stack") |
        select(.spec.values.defaultRules.create == true) |
        select((.spec.values.defaultRules.rules.general // true) == true) |
        select((.spec.values.defaultRules.disabled.Watchdog // false) == false)] | length'
  )"
  if [[ "${matches}" != "1" ]]; then
    echo "kube-prometheus-stack must render its enabled general/Watchdog rule in ${rendered_path}" >&2
    return 1
  fi
}

# Validates that only the observability namespace's generated policies defer
# the dedicated heartbeat label to its narrower workload policy.
assert_heartbeat_policy_exclusion() {
  local rendered_path="$1"
  local rule_name
  local scoped_rule_name
  local expected_spec
  local matches

  for rule_name in generate-default-deny generate-allow-dns; do
    matches="$(
      yq eval-all -o=json '.' "${rendered_path}" |
        jq -s --arg rule_name "${rule_name}" '[.[] |
          select(.kind == "ClusterPolicy" and .metadata.name == "add-default-deny") |
          .spec.rules[] |
          select(.name == $rule_name) |
          select(.exclude.any[0].resources.names | index("observability")) |
          select(.generate.data.spec.endpointSelector == {})] | length'
    )"
    if [[ "${matches}" != "1" ]]; then
      echo "add-default-deny/${rule_name} must retain the global guardrail and exclude observability for its scoped replacement in ${rendered_path}" >&2
      return 1
    fi

    scoped_rule_name="${rule_name}-observability"
    if [[ "${rule_name}" == "generate-default-deny" ]]; then
      expected_spec='{
        "endpointSelector":{"matchExpressions":[{"key":"platform-heartbeat","operator":"NotIn","values":["true"]}]},
        "enableDefaultDeny":{"ingress":true,"egress":true},
        "ingressDeny":[{}],
        "egressDeny":[{}]
      }'
    else
      expected_spec='{
        "endpointSelector":{"matchExpressions":[{"key":"platform-heartbeat","operator":"NotIn","values":["true"]}]},
        "egress":[{
          "toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s-app":"kube-dns"}}],
          "toPorts":[{"ports":[{"port":"53","protocol":"UDP"},{"port":"53","protocol":"TCP"}]}]
        }]
      }'
    fi
    matches="$(
      yq eval-all -o=json '.' "${rendered_path}" |
        jq -s --arg rule_name "${scoped_rule_name}" --argjson expected_spec "${expected_spec}" '[.[] |
          select(.kind == "ClusterPolicy" and .metadata.name == "add-default-deny") |
          .spec.rules[] |
          select(.name == $rule_name) |
          select(.match.any[0].resources.kinds == ["Namespace"]) |
          select(.match.any[0].resources.names == ["observability"]) |
          select(.generate.data.spec == $expected_spec)] | length'
    )"
    if [[ "${matches}" != "1" ]]; then
      echo "add-default-deny/${scoped_rule_name} must retain its complete scoped policy body in ${rendered_path}" >&2
      return 1
    fi
  done
}

# Verifies that default profiles retain the global deny and DNS selectors.
assert_heartbeat_policy_exclusion_absent() {
  local rendered_path="$1"
  local rule_name
  local matches

  for rule_name in generate-default-deny generate-allow-dns; do
    matches="$(
      yq eval-all -o=json '.' "${rendered_path}" |
        jq -s --arg rule_name "${rule_name}" '[.[] |
          select(.kind == "ClusterPolicy" and .metadata.name == "add-default-deny") |
          .spec.rules[] |
          select(.name == $rule_name) |
          select(((.exclude.any[0].resources.names // []) | index("observability")) == null) |
          select(.generate.data.spec.endpointSelector == {})] | length'
    )"
    if [[ "${matches}" != "1" ]]; then
      echo "default add-default-deny/${rule_name} must keep its global selector in ${rendered_path}" >&2
      return 1
    fi
  done

  matches="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "ClusterPolicy" and .metadata.name == "add-default-deny") |
        .spec.rules[] |
        select(.name == "generate-default-deny-observability" or .name == "generate-allow-dns-observability")] | length'
  )"
  if [[ "${matches}" != "0" ]]; then
    echo "default add-default-deny must not contain Coroot heartbeat exceptions in ${rendered_path}" >&2
    return 1
  fi
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

assert_auth_proxy_with_coroot() {
  local default_rendered_path="$1"
  local opt_in_rendered_path="$2"
  local expected
  local actual

  expected="$(
    yq eval-all -o=json 'select(.kind == "ConfigMap" and .metadata.namespace == "oauth2-proxy" and .metadata.name == "auth-proxy-config") | .data."dynamic.yaml" | from_yaml' "${default_rendered_path}" |
      jq -S -c '
        del(.http.routers.opencost, .http.services.opencost) |
        .http.routers.coroot = {
          rule: "Host(`observability.${domain}`)",
          entryPoints: ["web"],
          service: "coroot"
        } |
        .http.services.coroot = {
          loadBalancer: {
            servers: [
              {url: "http://coroot-coroot.observability.svc.cluster.local:8080"}
            ]
          }
        }'
  )"
  actual="$(
    yq eval-all -o=json 'select(.kind == "ConfigMap" and .metadata.namespace == "oauth2-proxy" and .metadata.name == "auth-proxy-config") | .data."dynamic.yaml" | from_yaml' "${opt_in_rendered_path}" |
      jq -S -c '.'
  )"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "opt-in auth-proxy config must replace OpenCost with the authenticated Coroot UI" >&2
    return 1
  fi
}

assert_coroot_sso_controller_contract() {
  local rendered_path="$1"
  local route_contract
  local grant_contract
  local proxy_egress_contract
  local coroot_ingress_contract

  route_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "HTTPRoute" and .metadata.namespace == "observability" and .metadata.name == "coroot") |
        select(.spec.hostnames == ["observability.${domain}"]) |
        select(.spec.rules | length == 1) |
        select(.spec.rules[0].backendRefs == [{"name":"oauth2-proxy","namespace":"oauth2-proxy","port":80}]) |
        select(any(.spec.rules[0].filters[]?;
          .type == "RequestHeaderModifier" and
          any(.requestHeaderModifier.set[]?;
            .name == "X-Auth-Request-Redirect" and .value == "https://observability.${domain}/"))) |
        select(any(.spec.rules[0].filters[]?;
          .type == "ResponseHeaderModifier" and
          any(.responseHeaderModifier.set[]?;
            .name == "Strict-Transport-Security" and
            .value == "max-age=63072000; includeSubDomains; preload")))] | length'
  )"
  grant_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "ReferenceGrant" and .metadata.namespace == "oauth2-proxy" and .metadata.name == "allow-oauth2-proxy-backends") |
        select([.spec.from[]? | select(.namespace == "observability")] ==
          [{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","namespace":"observability"}]) |
        select(.spec.to == [{"group":"","kind":"Service","name":"oauth2-proxy"}])] | length'
  )"
  proxy_egress_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "oauth2-proxy" and .metadata.name == "allow-auth-proxy") |
        .spec.egress[]? |
        select(.toEndpoints == [{"matchLabels":{
          "app.kubernetes.io/component":"coroot",
          "app.kubernetes.io/part-of":"coroot",
          "k8s:io.kubernetes.pod.namespace":"observability"}}]) |
        select(.toPorts == [{"ports":[{"port":"8080","protocol":"TCP"}]}])] | length'
  )"
  coroot_ingress_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-coroot") |
        .spec.ingress[]? |
        select(.fromEndpoints == [{"matchLabels":{
          "app":"auth-proxy",
          "k8s:io.kubernetes.pod.namespace":"oauth2-proxy"}}]) |
        select(.toPorts == [{"ports":[{"port":"8080","protocol":"TCP"}]}])] | length'
  )"

  if [[ "${route_contract}" != "1" ]]; then
    echo "Coroot option must expose exactly one HSTS route through oauth2-proxy" >&2
    return 1
  fi
  if [[ "${grant_contract}" != "1" ]]; then
    echo "Coroot option must grant only the observability HTTPRoute access to oauth2-proxy" >&2
    return 1
  fi
  if [[ "${proxy_egress_contract}" != "1" ]]; then
    echo "auth-proxy must have one Coroot-specific TCP/8080 egress path" >&2
    return 1
  fi
  if [[ "${coroot_ingress_contract}" != "1" ]]; then
    echo "Coroot must admit one auth-proxy-specific TCP/8080 ingress path" >&2
    return 1
  fi
}

assert_coroot_admin_role() {
  local rendered_path="$1"
  local expected="$2"
  local actual
  local any_role

  actual="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") |
        select(.spec.authAnonymousRole == "Admin")] | length'
  )"
  any_role="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") |
        select(.spec | has("authAnonymousRole"))] | length'
  )"
  if [[ "${actual}" != "${expected}" || "${any_role}" != "${expected}" ]]; then
    echo "expected ${expected} Coroot Admin-only role(s) behind the SSO profile in ${rendered_path}, found Admin=${actual} any=${any_role}" >&2
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
coroot_base="${tmp_dir}/coroot-base.yaml"
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
  assert_watchdog_rendered "${rendered_path}"
done
for rendered_path in "${local_infrastructure_default}" "${prod_infrastructure_default}"; do
  assert_opencost_resources_absent "${rendered_path}"
  assert_namespace_not_excluded_from_policy "${rendered_path}" add-security-context observability
  assert_namespace_not_excluded_from_policy "${rendered_path}" validate-host-restrictions observability
  assert_namespace_not_excluded_from_policy "${rendered_path}" validate-pod-security observability
  assert_security_exception_namespace_count "${rendered_path}" infrastructure-privileged observability 0
  assert_security_exception_namespace_count "${rendered_path}" controller-rbac observability 0
  assert_security_exception_namespace_count "${rendered_path}" service-account-tokens observability 0
  assert_heartbeat_policy_exclusion_absent "${rendered_path}"
done
assert_opencost_reference_count "${local_apps_default}" 1
assert_opencost_reference_count "${prod_apps_default}" 1

render k8s/providers/docker/infrastructure-controllers-coroot/ "${docker_controllers}"
render k8s/providers/docker/infrastructure-coroot/ "${docker_infrastructure}"
render k8s/providers/docker/apps-coroot/ "${docker_apps}"
render k8s/providers/hetzner/infrastructure-controllers-coroot/ "${hetzner_controllers}"
render k8s/providers/hetzner/infrastructure-coroot/ "${hetzner_infrastructure}"
render k8s/providers/hetzner/apps-coroot/ "${hetzner_apps}"
render k8s/bases/infrastructure/coroot/ "${coroot_base}"

# The default profiles retain the complete legacy Loki + Alloy logging path.
# Coroot profiles retire that coupled stack: Coroot handles workload logs, and
# the production profile's audit-log-forwarder handles Talos audit logs.
for rendered_path in "${local_controllers_default}" "${prod_controllers_default}"; do
  assert_resource_count "${rendered_path}" HelmRelease monitoring alloy-audit 1
  assert_resource_count "${rendered_path}" HelmRelease monitoring alloy 1
  assert_resource_count "${rendered_path}" HelmRelease monitoring loki 1
  assert_resource_count "${rendered_path}" HelmRepository monitoring grafana 1
  if [[ "$(loki_datasource_count "${rendered_path}")" != "1" ]]; then
    echo "default profile must retain the Grafana Loki datasource" >&2
    exit 1
  fi
done
for rendered_path in "${docker_controllers}" "${hetzner_controllers}"; do
  assert_resource_count "${rendered_path}" HelmRelease monitoring alloy-audit 0
  assert_resource_count "${rendered_path}" HelmRelease monitoring alloy 0
  assert_resource_count "${rendered_path}" HelmRelease monitoring loki 0
  assert_resource_count "${rendered_path}" HelmRepository monitoring grafana 0
  if [[ "$(loki_datasource_count "${rendered_path}")" != "0" ]]; then
    echo "Coroot profile must remove the dead Grafana Loki datasource" >&2
    exit 1
  fi
  if [[ "$(loki_service_reference_count "${rendered_path}")" != "0" ]]; then
    echo "Coroot profile must not retain a reference to the retired Loki service" >&2
    exit 1
  fi
done

assert_auth_proxy_with_coroot "${local_controllers_default}" "${docker_controllers}"
assert_auth_proxy_with_coroot "${prod_controllers_default}" "${hetzner_controllers}"

for rendered_path in "${docker_controllers}" "${hetzner_controllers}"; do
  assert_resource_count "${rendered_path}" HelmRelease observability coroot-operator 1
  assert_resource_count "${rendered_path}" Coroot observability coroot 0
  assert_resource_count "${rendered_path}" HelmRelease observability audit-log-forwarder 0
  assert_resource_count "${rendered_path}" HelmRelease monitoring kube-prometheus-stack 1
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-coroot 1
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-cluster-heartbeat 1
  assert_opencost_absent "${rendered_path}"
  assert_coroot_sso_controller_contract "${rendered_path}"
  assert_coroot_heartbeat_contract "${rendered_path}"
  assert_coroot_heartbeat_substitution "${rendered_path}"
  assert_watchdog_rendered "${rendered_path}"
done

for rendered_path in "${docker_infrastructure}" "${hetzner_infrastructure}"; do
  assert_namespace_excluded_from_all_policy_rules "${rendered_path}" add-security-context observability
  assert_namespace_excluded_from_all_policy_rules "${rendered_path}" validate-host-restrictions observability
  assert_namespace_excluded_from_all_policy_rules "${rendered_path}" validate-pod-security observability
  assert_security_exception_namespace_count "${rendered_path}" infrastructure-privileged observability 1
  assert_security_exception_namespace_count "${rendered_path}" controller-rbac observability 1
  assert_security_exception_namespace_count "${rendered_path}" service-account-tokens observability 1
  assert_security_exception_namespace_count "${rendered_path}" health-probes observability 0
  assert_heartbeat_policy_exclusion "${rendered_path}"
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
assert_coroot_admin_role "${coroot_base}" 0
assert_coroot_admin_role "${docker_infrastructure}" 1
assert_coroot_admin_role "${hetzner_infrastructure}" 1

docker_notification_integrations="$(
  yq eval-all -o=json '.' "${docker_infrastructure}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | .spec.projects[]?.notificationIntegrations? | select(. != null)] | length'
)"
base_notification_integrations="$(
  yq eval-all -o=json '.' "${coroot_base}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | .spec.projects[]?.notificationIntegrations? | select(. != null)] | length'
)"
hetzner_notification_integrations="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | .spec.projects[]? | select(.name == "${cluster_name}") | .notificationIntegrations? | select(. != null)] | length'
)"
hetzner_webhook_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] |
      select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") |
      .spec.projects[]? |
      select(.name == "${cluster_name}") |
      .notificationIntegrations? |
      select(.baseURL == "https://observability.${domain}") |
      .webhook? |
      select(.url == "${alertmanager_webhook_url:=https://example.invalid/no-slack-configured}") |
      select(.incidents == true and .alerts == false) |
      select((.incidentTemplate | split("{{ json (printf") | length) == 3) |
      select(.incidentTemplate | contains("incident resolved")) |
      select(.incidentTemplate | contains(".RCASummary")) |
      select((.alertTemplate | split("{{ json (printf") | length) == 3) |
      select(.alertTemplate | contains(".RuleName"))] | length'
)"

if [[ "${docker_notification_integrations}" != "0" || "${base_notification_integrations}" != "0" ]]; then
  echo "Coroot webhook notifications must remain absent from the reusable and local profiles" >&2
  exit 1
fi
if [[ "${hetzner_notification_integrations}" != "1" || "${hetzner_webhook_contract}" != "1" ]]; then
  echo "production Coroot must reuse the cluster webhook for JSON-safe incident notifications while keeping alerts UI-only" >&2
  exit 1
fi

coroot_key_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | .spec.projects[]?.apiKeys[]?.keySecret | select(.name == "coroot-api-key" and .key == "key")] | length'
)"
coroot_agent_key_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "Coroot" and .metadata.namespace == "observability" and .metadata.name == "coroot") | .spec.apiKeySecret | select(.name == "coroot-api-key" and .key == "key")] | length'
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
audit_pipeline_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "observability" and .metadata.name == "audit-log-forwarder") | .spec.values.config.service.pipelines.logs | select(any(.receivers[]?; . == "filelog")) | select(any(.exporters[]?; . == "otlphttp/coroot"))] | length'
)"
audit_exporter_contract="$(
  yq eval-all -o=json '.' "${hetzner_infrastructure}" |
    jq -s '[.[] | select(.kind == "HelmRelease" and .metadata.namespace == "observability" and .metadata.name == "audit-log-forwarder") | .spec.values.config.exporters."otlphttp/coroot" | select(.logs_endpoint == "http://coroot-coroot.observability.svc.cluster.local:8080/v1/logs") | select(.headers."x-api-key" == "${env:COROOT_API_KEY}")] | length'
)"
network_policy_contract="$(
  yq eval-all -o=json '.' "${hetzner_controllers}" |
    jq -s '[.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-coroot") | select(any(.spec.ingress[]?.fromEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "observability")) | select(any(.spec.egress[]?.toEntities[]?; . == "kube-apiserver")) | select(any(.spec.egress[]?.toFQDNs[]?; .matchName == "ghcr.io")) | select(any(.spec.egress[]?.toFQDNs[]?; .matchName == "hooks.slack.com"))] | length'
)"
docker_webhook_egress_contract="$(
  yq eval-all -o=json '.' "${docker_controllers}" |
    jq -s '[.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-coroot") | .spec.egress[]?.toFQDNs[]? | select(.matchName == "hooks.slack.com")] | length'
)"
renovate_coroot_manager="$(
  jq '[.customManagers[]? | select(.datasourceTemplate == "docker") | select(any(.fileMatch[]?; . == "^k8s/bases/infrastructure/coroot/coroot\\.ya?ml$")) | select(any(.matchStrings[]?; contains("ghcr\\.io/coroot")))] | length' \
    "${repo_root}/.github/renovate.json"
)"

if [[ "${coroot_key_contract}" != "1" || "${coroot_agent_key_contract}" != "1" || "${forwarder_key_contract}" != "1" ]]; then
  echo "Coroot projects, bundled agents, and audit-log-forwarder do not share the coroot-api-key/key Secret contract" >&2
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
if [[ "${audit_pipeline_contract}" != "1" ]]; then
  echo "audit-log-forwarder must route the filelog receiver through the logs pipeline to otlphttp/coroot" >&2
  exit 1
fi
if [[ "${audit_exporter_contract}" != "1" ]]; then
  echo "audit-log-forwarder must export logs to Coroot's in-cluster OTLP endpoint with its x-api-key" >&2
  exit 1
fi
if [[ "${network_policy_contract}" != "1" || "${docker_webhook_egress_contract}" != "0" ]]; then
  echo "production Coroot must allow its Slack webhook while local Coroot stays notification-free" >&2
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
  "retires the legacy Loki and Alloy log path" \
  "stages one hardened \`cluster-heartbeat\` CronJob" \
  "reuses the existing encrypted heartbeat URL" \
  "permits only \`hc-ping.com:443\`" \
  "runs at platform-critical priority" \
  "runs alongside Watchdog" \
  "custom-provider heartbeats" \
  "does not add a new secret" \
  "keeps kube-prometheus-stack" \
  "Cost allocation is therefore unavailable" \
  "reuses the existing encrypted webhook" \
  "incident and resolution notifications" \
  "permits only \`hooks.slack.com:443\`" \
  "Per-alert notifications remain visible only in the Coroot UI" \
  "Local / Docker Coroot stays notification-free" \
  "Kube-prometheus-stack keeps owning its alert rules" \
  "https://observability.<your-domain>" \
  "Dex-backed oauth2-proxy" \
  "no direct Gateway route to the Coroot service" \
  "removes the route and the profile-only Admin role together"; do
  if ! grep -Fq "${documented_boundary}" "${templating_guide}"; then
    echo "templating guide does not retain Coroot boundary: ${documented_boundary}" >&2
    exit 1
  fi
done

if grep -R -n 'alertmanager_heartbeat_host' \
  "${repo_root}/.github/workflows/bootstrap.yaml" \
  "${repo_root}/docs" \
  "${repo_root}/k8s"; then
  echo "Coroot heartbeat must not add an instance-owned host variable" >&2
  exit 1
fi

alerting_guide="${repo_root}/docs/dr/alerting.md"
for documented_heartbeat_boundary in \
  "The default profile keeps the \`Watchdog\` alert" \
  "The Coroot profile uses the dedicated \`cluster-heartbeat\` CronJob" \
  "only \`hc-ping.com:443\`" \
  "keeps Watchdog" \
  "custom-provider heartbeats" \
  "Flux reconciliation alerting still depends on kube-prometheus-stack"; do
  if ! grep -Fq "${documented_heartbeat_boundary}" "${alerting_guide}"; then
    echo "alerting guide does not retain heartbeat boundary: ${documented_heartbeat_boundary}" >&2
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
