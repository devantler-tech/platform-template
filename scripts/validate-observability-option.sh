#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# Renders a repository-relative profile independently of the caller's working directory.
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

# Counts rendered resources owned by the OpenCost namespace.
opencost_resource_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] | select(type == "object" and ((.kind == "Namespace" and .metadata.name == "opencost") or .metadata.namespace == "opencost"))] | length'
}

# Counts rendered resources whose serialized content still references OpenCost.
opencost_reference_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] | select(type == "object" and (tojson | test("opencost"; "i")))] | length'
}

# Counts what would bring the retired kube-prometheus-stack back into a render:
# a resource of a Prometheus-operator kind, anything in (or the) `monitoring`
# namespace, a rule or grant that names that namespace, the chart's release or
# repository, and a chart value that switches a ServiceMonitor, PodMonitor or
# PrometheusRule on. Vendored operators keep RBAC rules that merely name the
# `monitoring.coreos.com` API group; those grant nothing here and are not counted.
prometheus_stack_trace_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] | select(type == "object") |
      select(
        ((.apiVersion // "") | startswith("monitoring.coreos.com/")) or
        (.kind == "Namespace" and .metadata.name == "monitoring") or
        ((.metadata.namespace // "") == "monitoring") or
        (.kind == "HelmRelease" and .metadata.name == "kube-prometheus-stack") or
        (.kind == "HelmRepository" and .metadata.name == "prometheus-community") or
        (.kind == "CiliumNetworkPolicy" and
          ([.. | objects | .["k8s:io.kubernetes.pod.namespace"]? | select(. == "monitoring")] | length > 0)) or
        (.kind == "ReferenceGrant" and any(.spec.from[]?; .namespace == "monitoring")) or
        (.kind == "HelmRelease" and
          ([.spec.values | .. | objects | to_entries[] |
            select(.key | test("^(serviceMonitor|podMonitor|prometheusRule)$"; "i")) |
            select((.value | type) == "object" and .value.enabled == true)] | length > 0))
      )] | length'
}

# Counts HelmReleases in a render, to prove a zero above came from real input.
helm_release_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] | select(type == "object" and .kind == "HelmRelease")] | length'
}

# Counts rendered resources whose serialized content still references Loki.
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

# Returns the source path for one uniquely rendered Flux Kustomization.
flux_path() {
  local rendered_path="$1"
  local name="$2"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s -r \
      --arg name "${name}" \
      '[.[] | select(type == "object" and .kind == "Kustomization" and .metadata.namespace == "flux-system" and .metadata.name == $name)] |
       if length == 1 then .[0].spec.path else "invalid-count:\(length)" end'
}

# Fails when a Flux Kustomization does not point at the expected profile path.
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

# Verifies the reconciliation edge and wait boundary that keep a later Flux
# payload from starting before its prerequisite reports ready.
assert_flux_dependency() {
  local rendered_path="$1"
  local name="$2"
  local dependency="$3"
  local matches

  matches="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s --arg name "${name}" --arg dependency "${dependency}" '[.[] |
        select(.kind == "Kustomization" and .metadata.namespace == "flux-system" and .metadata.name == $name) |
        select(.spec.dependsOn == [{"name":$dependency}]) |
        select(.spec.wait == true)] | length'
  )"
  if [[ "${matches}" != "1" ]]; then
    echo "Flux Kustomization/${name} must wait for ${dependency} in ${rendered_path}" >&2
    return 1
  fi
}

# Verifies that the heartbeat workload reconciles only in the apps layer,
# after infrastructure has replaced the observability namespace's generated
# deny policies with the scoped selectors.
assert_heartbeat_staged_after_policy_exclusion() {
  local controllers_rendered_path="$1"
  local apps_rendered_path="$2"

  assert_resource_count "${controllers_rendered_path}" CronJob observability cluster-heartbeat 0
  assert_resource_count "${controllers_rendered_path}" Secret observability cluster-heartbeat 0
  assert_resource_count "${controllers_rendered_path}" CiliumNetworkPolicy observability allow-cluster-heartbeat 0
  assert_resource_count "${apps_rendered_path}" CronJob observability cluster-heartbeat 1
  assert_resource_count "${apps_rendered_path}" Secret observability cluster-heartbeat 1
  assert_resource_count "${apps_rendered_path}" CiliumNetworkPolicy observability allow-cluster-heartbeat 1
}

# Executes the workflow's real heartbeat preflight with one bounded fixture URL.
run_bootstrap_heartbeat_preflight() {
  local bootstrap_workflow="$1"
  local cluster_heartbeat_url="$2"
  local validation_script

  validation_script="$(
    sed -n '/# The cluster heartbeat is the one off-cluster dead-man signal and has/,/# End of the heartbeat preflight\./p' "${bootstrap_workflow}"
  )"
  # The extraction must be exactly the preflight. An empty one would run nothing
  # and "accept" every URL. One without its end marker ran on to the end of the
  # workflow, and executing that would run the secret writes against this checkout.
  if [[ "${validation_script}" != *'CLUSTER_HEARTBEAT_URL'* ||
    "${validation_script}" != *'# End of the heartbeat preflight.'* ]] ||
    grep -Eq '(^|[^[:alnum:]_.-])(yq|sops)([^[:alnum:]_.-]|$)' <<<"${validation_script}"; then
    echo "could not extract exactly the heartbeat preflight from ${bootstrap_workflow}" >&2
    return 2
  fi
  env \
    CLUSTER_HEARTBEAT_URL="${cluster_heartbeat_url}" \
    bash -c "set -euo pipefail
${validation_script}" >/dev/null 2>&1
}

# Proves that bootstrap accepts one canonical check and an unset one, while
# rejecting every other spelling: a URL the cluster's egress policy cannot reach
# would encrypt a monitor that is silently dead.
assert_bootstrap_heartbeat_identity_contract() {
  local bootstrap_workflow="$1"
  local cluster_url='https://hc-ping.com/11111111-1111-4111-8111-111111111111'
  local cluster_alias
  local status
  local -a cluster_aliases=(
    "${cluster_url}#cluster"
    "${cluster_url}?source=cluster"
    "${cluster_url}/"
    "${cluster_url}/start"
    "${cluster_url}/fail"
    "${cluster_url}/log"
    "${cluster_url}/1"
    'https://HC-PING.com/11111111-1111-4111-8111-111111111111'
    'https://hc-ping.com:443/11111111-1111-4111-8111-111111111111'
    'https://user@hc-ping.com/11111111-1111-4111-8111-111111111111'
    'http://hc-ping.com/11111111-1111-4111-8111-111111111111'
    'https://hc-ping.com/project-slug/check-slug'
    'https://hc-ping.com/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
    'https://example.com/11111111-1111-4111-8111-111111111111'
  )

  if ! run_bootstrap_heartbeat_preflight "${bootstrap_workflow}" "${cluster_url}"; then
    echo "bootstrap must accept a canonical healthchecks.io check" >&2
    return 1
  fi
  if ! run_bootstrap_heartbeat_preflight "${bootstrap_workflow}" ""; then
    echo "bootstrap must keep an unset cluster check valid for a local bootstrap" >&2
    return 1
  fi
  for cluster_alias in "${cluster_aliases[@]}"; do
    status=0
    run_bootstrap_heartbeat_preflight "${bootstrap_workflow}" "${cluster_alias}" || status=$?
    if [[ "${status}" != "1" ]]; then
      echo "bootstrap must reject every noncanonical cluster check URL (${cluster_alias}: status ${status})" >&2
      return 1
    fi
  done
}

assert_bootstrap_heartbeat_identity_contract "${repo_root}/.github/workflows/bootstrap.yaml"

# Validates the singleton workload, isolation selector, and exact egress contract
# rendered by each explicit Coroot profile.
assert_coroot_heartbeat_contract() {
  local rendered_path="$1"
  local controllers_rendered_path="$2"
  local heartbeat_count
  local cronjob_contract
  local secret_contract
  local heartbeat_egress_contract
  local coroot_selector_contract
  local heartbeat_selecting_policy_count
  local source_image

  # The reviewed manifest owns the dependency pin; enforce its immutable shape
  # and compare the render to it so Renovate updates need only one version edit.
  source_image="$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "heartbeat") | .image' "${repo_root}/k8s/bases/apps/cluster-heartbeat/cron-job.yaml")"
  if [[ ! "${source_image}" =~ ^docker\.io/curlimages/curl:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "heartbeat source must pin the curlimages/curl release and its SHA-256 digest" >&2
    return 1
  fi

  heartbeat_count="$(resource_count "${rendered_path}" CronJob observability cluster-heartbeat)"
  cronjob_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s --arg source_image "${source_image}" '[.[] |
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
        select($container.image == $source_image) |
        select($container.command == [
          "/bin/sh",
          "-c"
        ]) |
        select($container.args == [
          "printf '\''url = \"%s\"\\n'\'' \"$HEARTBEAT_URL\" | curl --config - -sf --max-time 10 --retry 3 --retry-delay 2 --retry-all-errors --retry-connrefused || true"
        ]) |
        select($container.env == [{
          "name":"HEARTBEAT_URL",
          "valueFrom":{"secretKeyRef":{"name":"cluster-heartbeat","key":"url"}}
        }]) |
        select($container.securityContext.allowPrivilegeEscalation == false) |
        select($container.securityContext.readOnlyRootFilesystem == true) |
        select($container.securityContext.runAsNonRoot == true and $container.securityContext.runAsUser == 65532 and $container.securityContext.runAsGroup == 65532) |
        select($container.securityContext.capabilities.drop == ["ALL"]) |
        select($container.resources == {
          "requests":{"cpu":"5m","memory":"16Mi"},
          "limits":{"cpu":"50m","memory":"32Mi"}
        })] | length'
  )"
  secret_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.kind == "Secret" and .metadata.namespace == "observability" and .metadata.name == "cluster-heartbeat") |
        select(.type == "Opaque") |
        select(.stringData == {"url":"${cluster_heartbeat_url:=https://example.invalid/no-cluster-heartbeat-configured}"})] | length'
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
    yq eval-all -o=json '.' "${controllers_rendered_path}" |
      jq -s '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-coroot") |
        select(.spec.endpointSelector.matchExpressions == [{"key":"platform-heartbeat","operator":"NotIn","values":["true"]}]) |
        select(all(.spec.egress[]?.toFQDNs[]?; .matchName != "hc-ping.com"))] | length'
  )"
  heartbeat_selecting_policy_count="$(
    yq eval-all -o=json '.' "${rendered_path}" "${controllers_rendered_path}" |
      jq -s '
        def selector_matches($labels):
          (.spec.endpointSelector // {}) as $selector |
          all(($selector.matchLabels // {} | to_entries[]); $labels[.key] == .value) and
          all(($selector.matchExpressions // [])[];
            .key as $key |
            ($labels[$key] // null) as $value |
            if .operator == "In" then
              $value != null and ((.values // []) | index($value) != null)
            elif .operator == "NotIn" then
              $value == null or ((.values // []) | index($value) == null)
            elif .operator == "Exists" then
              $value != null
            elif .operator == "DoesNotExist" then
              $value == null
            else
              false
            end);
        {"app":"cluster-heartbeat","platform-heartbeat":"true"} as $heartbeat_labels |
        [.[] |
          select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability") |
          select(selector_matches($heartbeat_labels))] | length'
  )"

  if [[ "${heartbeat_count}" != "1" || "${cronjob_contract}" != "1" || "${secret_contract}" != "1" ]]; then
    echo "Coroot profile must render one hardened five-minute heartbeat with one Secret reference in ${rendered_path}" >&2
    return 1
  fi
  if [[ "${heartbeat_egress_contract}" != "1" || "${coroot_selector_contract}" != "1" || "${heartbeat_selecting_policy_count}" != "1" ]]; then
    echo "Coroot heartbeat must match only its one exact configured-host egress policy in ${rendered_path}" >&2
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
  local secret_matches
  local policy_matches

  substituted_path="${tmp_dir}/$(basename "${rendered_path}" .yaml)-heartbeat-substituted.yaml"
  heartbeat_token+='{cluster_heartbeat_url:=https://example.invalid/no-cluster-heartbeat-configured}'
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
          "printf '\''url = \"%s\"\\n'\'' \"$HEARTBEAT_URL\" | curl --config - -sf --max-time 10 --retry 3 --retry-delay 2 --retry-all-errors --retry-connrefused || true"
        ]) |
        select($container.env == [{
          "name":"HEARTBEAT_URL",
          "valueFrom":{"secretKeyRef":{"name":"cluster-heartbeat","key":"url"}}
        }])] | length'
  )"
  secret_matches="$(
    yq eval-all -o=json '.' "${substituted_path}" |
      jq -s --arg heartbeat_url "${heartbeat_url}" '[.[] |
        select(.kind == "Secret" and .metadata.namespace == "observability" and .metadata.name == "cluster-heartbeat") |
        select(.stringData.url == $heartbeat_url)] | length'
  )"
  policy_matches="$(
    yq eval-all -o=json '.' "${substituted_path}" |
      jq -s --arg heartbeat_host "${heartbeat_host}" '[.[] |
        select(.kind == "CiliumNetworkPolicy" and .metadata.namespace == "observability" and .metadata.name == "allow-cluster-heartbeat") |
        select(any(.spec.egress[]?.toFQDNs[]?; .matchName == $heartbeat_host)) |
        select(any(.spec.egress[]?.toPorts[]?.rules.dns[]?; .matchName == $heartbeat_host))] | length'
  )"

  if [[ "${cronjob_matches}" != "1" || "${secret_matches}" != "1" || "${policy_matches}" != "1" ]]; then
    echo "Flux-substituted heartbeat URL and exact policy host must agree in ${rendered_path}" >&2
    return 1
  fi
}

# Counts the Dex public-client redirect that existed only for Grafana's native OIDC login.
grafana_dex_redirect_count() {
  local rendered_path="$1"

  yq eval-all -o=json '.' "${rendered_path}" |
    jq -s '[.[] |
      select(type == "object" and .kind == "HelmRelease" and .metadata.namespace == "dex" and .metadata.name == "dex") |
      .spec.values.config.staticClients[]?.redirectURIs[]? |
      select(. == "https://grafana.${domain}/login/generic_oauth")] | length'
}

# Verifies that a rendered payload carries nothing of the retired
# kube-prometheus-stack. Controller payloads must also hold releases at all, so
# an empty or truncated render cannot pass as a clean one.
assert_prometheus_stack_absent() {
  local rendered_path="$1"
  local traces

  traces="$(prometheus_stack_trace_count "${rendered_path}")"
  if [[ "${traces}" != "0" ]]; then
    echo "expected no kube-prometheus-stack resource, monitoring namespace reference or enabled Prometheus-operator monitor in ${rendered_path}, found ${traces}" >&2
    return 1
  fi
  if [[ "$(grafana_dex_redirect_count "${rendered_path}")" != "0" ]]; then
    echo "expected no Dex redirect for Grafana in ${rendered_path}" >&2
    return 1
  fi
}

# Verifies the production Coroot profile's exact event-driven Flux alert path.
assert_flux_notification_contract() {
  local rendered_path="$1"
  local provider_contract
  local error_alert_contract
  local dependency_alert_contract
  local secret_contract

  provider_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.apiVersion == "notification.toolkit.fluxcd.io/v1beta3") |
        select(.kind == "Provider" and .metadata.namespace == "flux-system" and .metadata.name == "slack") |
        select(.spec == {"type":"slack","secretRef":{"name":"slack-webhook"}})] | length'
  )"
  error_alert_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.apiVersion == "notification.toolkit.fluxcd.io/v1beta3") |
        select(.kind == "Alert" and .metadata.namespace == "flux-system" and .metadata.name == "platform-reconciliation") |
        select((.spec | del(.eventSources)) == {
          "providerRef":{"name":"slack"},
          "eventSeverity":"error",
          "eventMetadata":{"summary":"Flux reconciliation error — production platform"}
        }) |
        # The cluster Kustomizations first, then one whole-namespace HelmRelease
        # source per namespace. Which namespaces must be listed is proven against
        # the renders by scripts/validate-alert-coverage.sh.
        select(.spec.eventSources[0] == {"kind":"Kustomization","name":"*","namespace":"flux-system"}) |
        select((.spec.eventSources[1:] | length) > 0) |
        select(all(.spec.eventSources[1:][];
          (keys == ["kind","name","namespace"]) and .kind == "HelmRelease" and .name == "*" and
          (.namespace | type == "string" and length > 0))) |
        select(([.spec.eventSources[1:][].namespace] | unique | length) == (.spec.eventSources[1:] | length))] | length'
  )"
  dependency_alert_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.apiVersion == "notification.toolkit.fluxcd.io/v1beta3") |
        select(.kind == "Alert" and .metadata.namespace == "flux-system" and .metadata.name == "platform-dependency-wait") |
        select(.spec as $spec |
          $spec == {
            "providerRef":{"name":"slack"},
            "eventSeverity":"info",
            "eventSources":[{"kind":"Kustomization","name":"*"}],
            "inclusionList":[".*Dependencies do not meet ready condition.*"],
            "eventMetadata":{"summary":"Flux dependency wait — production platform"}
          } and
          ("Dependencies do not meet ready condition, retrying in 5s" | test($spec.inclusionList[0])) and
          ("Reconciliation finished in 250ms, next run in 10m0s" | test($spec.inclusionList[0]) | not))] | length'
  )"
  secret_contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '[.[] |
        select(.apiVersion == "v1") |
        select(.kind == "Secret" and .metadata.namespace == "flux-system" and .metadata.name == "slack-webhook") |
        select(.type == "Opaque") |
        select(.stringData == {"address":"${alertmanager_webhook_url:=https://example.invalid/no-slack-configured}"})] | length'
  )"

  if [[ "${provider_contract}" != "1" || "${error_alert_contract}" != "1" || "${dependency_alert_contract}" != "1" || "${secret_contract}" != "1" ]]; then
    echo "production Coroot controllers must render exact Flux error and dependency-wait paths through the existing Slack webhook" >&2
    return 1
  fi
}

# Validates the production backup, database and certificate check (#423): one
# read-only identity that can only list the kinds it judges, the shared
# webhook input, and a CronJob wired to both.
assert_platform_health_alert_contract() {
  local rendered_path="$1"
  local contract

  contract="$(
    yq eval-all -o=json '.' "${rendered_path}" |
      jq -s '
        def one($kind; $ns; $name): [.[] | select(type == "object" and .kind == $kind and (.metadata.namespace // "") == $ns and .metadata.name == $name)];
        (one("ServiceAccount"; "observability"; "platform-health-alert") | length == 1) and
        (one("ClusterRole"; ""; "platform-health-alert") | length == 1 and .[0].rules == [
          {"apiGroups":["velero.io"],"resources":["schedules","backups"],"verbs":["list"]},
          {"apiGroups":["postgresql.cnpg.io"],"resources":["clusters","backups"],"verbs":["list"]},
          {"apiGroups":["cert-manager.io"],"resources":["certificates"],"verbs":["list"]}]) and
        (one("ClusterRoleBinding"; ""; "platform-health-alert") | length == 1 and
          .[0].roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"platform-health-alert"} and
          .[0].subjects == [{"kind":"ServiceAccount","name":"platform-health-alert","namespace":"observability"}]) and
        (one("Secret"; "observability"; "platform-health-alert-webhook") | length == 1 and
          .[0].stringData == {"url":"${alertmanager_webhook_url:=https://example.invalid/no-slack-configured}"}) and
        (one("CronJob"; "observability"; "platform-health-alert") | length == 1 and
          .[0].metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"] == "disabled" and
          (.[0].spec.jobTemplate.spec.template.spec as $pod |
            $pod.serviceAccountName == "platform-health-alert" and
            $pod.securityContext.runAsNonRoot == true and
            ($pod.containers | length == 1) and
            $pod.containers[0].securityContext.readOnlyRootFilesystem == true and
            $pod.containers[0].securityContext.allowPrivilegeEscalation == false and
            ($pod.containers[0].image | test("@sha256:[0-9a-f]{64}$")) and
            ($pod.containers[0].env // [] | map(.valueFrom // empty) | length == 0) and
            ([$pod.volumes[] | select(.secret != null) | .secret] == [{"secretName":"platform-health-alert-webhook","defaultMode":288}]) and
            # The pod must stay outside the heartbeat carve-out, so the namespace-wide
            # allow-coroot policy below selects it.
            ((.[0].spec.jobTemplate.spec.template.metadata.labels // {}) | has("platform-heartbeat") | not))) and
        # allow-coroot is the only policy that lets this pod out of the namespace default-deny:
        # it must select every pod but the heartbeat and allow the API server, Slack on 443 and DNS.
        (one("CiliumNetworkPolicy"; "observability"; "allow-coroot") | length == 1 and
          .[0].spec.endpointSelector == {"matchExpressions":[{"key":"platform-heartbeat","operator":"NotIn","values":["true"]}]} and
          (.[0].spec.egress | any(.toEntities == ["kube-apiserver"] and (has("toPorts") | not))) and
          (.[0].spec.egress | any((.toFQDNs // [] | any(.matchName == "hooks.slack.com")) and
            .toPorts == [{"ports":[{"port":"443","protocol":"TCP"}]}])) and
          (.[0].spec.egress | any(.toEndpoints == [{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s-app":"kube-dns"}}] and
            (.toPorts[0].ports | map(.protocol) | sort) == ["TCP","UDP"] and
            .toPorts[0].rules.dns == [{"matchPattern":"*"}])))
      '
  )"
  if [[ "${contract}" != "true" ]]; then
    echo "production controllers must render the read-only platform-health-alert check wired to the existing Slack webhook" >&2
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
        "ingress":[{}],
        "egress":[{}]
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

# Verifies that a rendered profile contains no OpenCost-owned resources.
assert_opencost_resources_absent() {
  local rendered_path="$1"
  local actual

  actual="$(opencost_resource_count "${rendered_path}")"
  if [[ "${actual}" != "0" ]]; then
    echo "expected no OpenCost resources in ${rendered_path}, found ${actual}" >&2
    return 1
  fi
}

# Verifies that both OpenCost resources and serialized references are absent.
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

# Verifies that the hardened auth proxy fronts exactly the homepage, Hubble and Coroot UIs.
assert_auth_proxy_with_coroot() {
  local rendered_path="$1"
  local expected
  local actual

  expected="$(
    jq -n -S -c '{
      routers: {
        coroot: {rule: "Host(`observability.${domain}`)", entryPoints: ["web"], service: "coroot"},
        homepage: {rule: "Host(`${domain}`)", entryPoints: ["web"], service: "homepage"},
        hubble: {rule: "Host(`hubble.${domain}`)", entryPoints: ["web"], service: "hubble-ui"}
      },
      services: {
        coroot: {loadBalancer: {servers: [{url: "http://coroot-coroot.observability.svc.cluster.local:8080"}]}},
        homepage: {loadBalancer: {servers: [{url: "http://homepage.homepage.svc.cluster.local:80"}]}},
        "hubble-ui": {loadBalancer: {servers: [{url: "http://keda-add-ons-http-interceptor-proxy.keda.svc.cluster.local:8080"}]}}
      }
    }'
  )"
  actual="$(
    yq eval-all -o=json 'select(.kind == "ConfigMap" and .metadata.namespace == "oauth2-proxy" and .metadata.name == "auth-proxy-config") | .data."dynamic.yaml" | from_yaml' "${rendered_path}" |
      jq -S -c '.http'
  )"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "auth-proxy config must route exactly the homepage, Hubble and the authenticated Coroot UI in ${rendered_path}" >&2
    return 1
  fi
}

# Verifies the Coroot controller profile's SSO and access-control contract.
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
        # No fixed X-Auth-Request-Redirect: oauth2-proxy returns the user to the
        # page they asked for (scripts/tests/test-oauth2-proxy-sso-redirects.sh).
        select(all(.spec.rules[0].filters[]?;
          .type != "RequestHeaderModifier" or
          ([((.requestHeaderModifier.set // []) + (.requestHeaderModifier.add // []))[] |
            select(.name | ascii_downcase == "x-auth-request-redirect")] | length == 0))) |
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

# Verifies whether a rendered Coroot project grants the expected admin role.
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

# Counts policy rules that omit the required namespace exclusion.
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

# Verifies that every rule in a policy excludes the selected namespace.
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

# Verifies the exact namespace match count in one security exception.
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

local_cluster="${tmp_dir}/local-cluster.yaml"
prod_cluster="${tmp_dir}/prod-cluster.yaml"
local_cluster_alias="${tmp_dir}/local-cluster-alias.yaml"
prod_cluster_alias="${tmp_dir}/prod-cluster-alias.yaml"
docker_controllers="${tmp_dir}/docker-controllers.yaml"
docker_infrastructure="${tmp_dir}/docker-infrastructure.yaml"
docker_apps="${tmp_dir}/docker-apps.yaml"
hetzner_controllers="${tmp_dir}/hetzner-controllers.yaml"
hetzner_infrastructure="${tmp_dir}/hetzner-infrastructure.yaml"
hetzner_apps="${tmp_dir}/hetzner-apps.yaml"
coroot_base="${tmp_dir}/coroot-base.yaml"
coroot_api_expression="\${env:COROOT_API_KEY}"
node_name_expression="\${env:K8S_NODE_NAME}"

# Coroot is the default, so the default cluster paths point at the provider
# layers that carry it. The earlier opt-in paths stay as aliases for instances
# whose KSail config already selects them, and must render exactly the defaults.
render k8s/clusters/local/ "${local_cluster}"
render k8s/clusters/prod/ "${prod_cluster}"
render k8s/clusters/local-coroot/ "${local_cluster_alias}"
render k8s/clusters/prod-coroot/ "${prod_cluster_alias}"

for rendered_path in "${local_cluster}" "${local_cluster_alias}"; do
  assert_flux_path "${rendered_path}" bootstrap clusters/local/bootstrap
  assert_flux_path "${rendered_path}" infrastructure-controllers providers/docker/infrastructure/controllers
  assert_flux_path "${rendered_path}" infrastructure providers/docker/infrastructure
  assert_flux_path "${rendered_path}" apps providers/docker/apps
done
for rendered_path in "${prod_cluster}" "${prod_cluster_alias}"; do
  assert_flux_path "${rendered_path}" bootstrap clusters/prod/bootstrap
  assert_flux_path "${rendered_path}" infrastructure-controllers providers/hetzner/infrastructure/controllers
  assert_flux_path "${rendered_path}" infrastructure providers/hetzner/infrastructure
  assert_flux_path "${rendered_path}" apps providers/hetzner/apps
done
for rendered_path in "${local_cluster}" "${prod_cluster}" "${local_cluster_alias}" "${prod_cluster_alias}"; do
  assert_flux_dependency "${rendered_path}" infrastructure infrastructure-controllers
  assert_flux_dependency "${rendered_path}" apps infrastructure
done
if ! cmp -s "${local_cluster}" "${local_cluster_alias}" || ! cmp -s "${prod_cluster}" "${prod_cluster_alias}"; then
  echo "clusters/local-coroot and clusters/prod-coroot must render exactly what the default cluster paths render" >&2
  exit 1
fi

# The retired stacks and the opt-in layers that used to remove them must not
# come back as sources: a leftover directory is one include away from rendering.
for retired_path in \
  k8s/bases/infrastructure/controllers/loki \
  k8s/bases/infrastructure/controllers/alloy \
  k8s/bases/infrastructure/controllers/opencost \
  k8s/providers/hetzner/infrastructure/controllers/loki \
  k8s/components/observability-coroot \
  k8s/providers/docker/infrastructure-controllers-coroot \
  k8s/providers/docker/infrastructure-coroot \
  k8s/providers/docker/apps-coroot \
  k8s/providers/hetzner/infrastructure-controllers-coroot \
  k8s/providers/hetzner/infrastructure-coroot \
  k8s/providers/hetzner/apps-coroot \
  k8s/bases/infrastructure/controllers/kube-prometheus-stack \
  k8s/bases/infrastructure/alerts \
  k8s/bases/infrastructure/external-secrets/alertmanager-webhook.yaml \
  k8s/bases/infrastructure/vault-seed/push-secret-seed-alertmanager.yaml \
  k8s/providers/hetzner/infrastructure/controllers/kube-prometheus-stack \
  k8s/providers/hetzner/infrastructure/patches/retain-helm-release-alert.yaml; do
  if [[ -e "${repo_root}/${retired_path}" ]]; then
    echo "retired observability source must stay deleted: ${retired_path}" >&2
    exit 1
  fi
done

# Cluster renders contain Flux pointers, so inspect the provider payloads those
# pointers reconcile.
render k8s/providers/docker/infrastructure/controllers/ "${docker_controllers}"
render k8s/providers/docker/infrastructure/ "${docker_infrastructure}"
render k8s/providers/docker/apps/ "${docker_apps}"
render k8s/providers/hetzner/infrastructure/controllers/ "${hetzner_controllers}"
render k8s/providers/hetzner/infrastructure/ "${hetzner_infrastructure}"
render k8s/providers/hetzner/apps/ "${hetzner_apps}"
render k8s/bases/infrastructure/coroot/ "${coroot_base}"

# Coroot handles workload logs and the production audit-log-forwarder handles
# Talos audit logs, so the coupled Loki + Alloy path and OpenCost are gone.
for rendered_path in "${docker_controllers}" "${hetzner_controllers}"; do
  assert_resource_count "${rendered_path}" HelmRelease monitoring alloy-audit 0
  assert_resource_count "${rendered_path}" HelmRelease monitoring alloy 0
  assert_resource_count "${rendered_path}" HelmRelease monitoring loki 0
  assert_resource_count "${rendered_path}" HelmRepository monitoring grafana 0
done
# A leftover Loki address can sit in any payload (a Coroot, homepage or
# datasource setting), so every render is searched, not only the controllers.
for rendered_path in "${docker_controllers}" "${docker_infrastructure}" "${docker_apps}" \
  "${hetzner_controllers}" "${hetzner_infrastructure}" "${hetzner_apps}" "${coroot_base}"; do
  if [[ "$(loki_service_reference_count "${rendered_path}")" != "0" ]]; then
    echo "no render may retain a reference to the retired Loki service: ${rendered_path}" >&2
    exit 1
  fi
done

assert_resource_count "${docker_controllers}" Provider flux-system slack 0
assert_resource_count "${docker_controllers}" Alert flux-system platform-reconciliation 0
assert_resource_count "${docker_controllers}" Alert flux-system platform-dependency-wait 0
assert_resource_count "${docker_controllers}" Secret flux-system slack-webhook 0
assert_flux_notification_contract "${hetzner_controllers}"
assert_platform_health_alert_contract "${hetzner_controllers}"
for health_alert_kind in ServiceAccount CronJob; do
  assert_resource_count "${docker_controllers}" "${health_alert_kind}" observability platform-health-alert 0
done
assert_resource_count "${docker_controllers}" Secret observability platform-health-alert-webhook 0
assert_resource_count "${docker_controllers}" ClusterRole "" platform-health-alert 0

assert_heartbeat_staged_after_policy_exclusion "${docker_controllers}" "${docker_apps}"
assert_heartbeat_staged_after_policy_exclusion "${hetzner_controllers}" "${hetzner_apps}"

assert_auth_proxy_with_coroot "${docker_controllers}"
assert_auth_proxy_with_coroot "${hetzner_controllers}"

# kube-prometheus-stack is retired: no payload carries a Prometheus-operator
# resource, the monitoring namespace, a rule or grant that names it, or a chart
# value that would need the operator's definitions. The controller payloads must
# hold releases at all, so a truncated render cannot pass as a clean one.
for rendered_path in "${docker_controllers}" "${hetzner_controllers}"; do
  if [[ "$(helm_release_count "${rendered_path}")" -lt 10 ]]; then
    echo "expected the controller payload ${rendered_path} to hold its HelmReleases" >&2
    exit 1
  fi
done
for rendered_path in "${docker_controllers}" "${docker_infrastructure}" "${docker_apps}" \
  "${hetzner_controllers}" "${hetzner_infrastructure}" "${hetzner_apps}" "${coroot_base}"; do
  assert_prometheus_stack_absent "${rendered_path}"
done

for rendered_path in "${docker_controllers}" "${hetzner_controllers}"; do
  assert_resource_count "${rendered_path}" HelmRelease observability coroot-operator 1
  assert_resource_count "${rendered_path}" Coroot observability coroot 0
  assert_resource_count "${rendered_path}" HelmRelease observability audit-log-forwarder 0
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-coroot 1
  assert_resource_count "${rendered_path}" CronJob observability cluster-heartbeat 0
  assert_resource_count "${rendered_path}" Secret observability cluster-heartbeat 0
  assert_resource_count "${rendered_path}" CiliumNetworkPolicy observability allow-cluster-heartbeat 0
  assert_opencost_absent "${rendered_path}"
  assert_coroot_sso_controller_contract "${rendered_path}"
done

# The demo apps prove each apps check examined a real render rather than an
# empty one.
for rendered_path in "${docker_apps}" "${hetzner_apps}"; do
  assert_resource_count "${rendered_path}" HelmRelease homepage homepage 1
  assert_resource_count "${rendered_path}" HelmRelease whoami whoami 1
done
assert_coroot_heartbeat_contract "${docker_apps}" "${docker_controllers}"
assert_coroot_heartbeat_substitution "${docker_apps}"
assert_coroot_heartbeat_contract "${hetzner_apps}" "${hetzner_controllers}"
assert_coroot_heartbeat_substitution "${hetzner_apps}"

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
assert_resource_count "${docker_infrastructure}" Provider flux-system slack 0
assert_resource_count "${docker_infrastructure}" Alert flux-system platform-reconciliation 0
assert_resource_count "${docker_infrastructure}" Alert flux-system platform-dependency-wait 0
assert_resource_count "${docker_infrastructure}" Secret flux-system slack-webhook 0
assert_opencost_absent "${docker_infrastructure}"

assert_resource_count "${hetzner_infrastructure}" HelmRelease observability coroot-operator 0
assert_resource_count "${hetzner_infrastructure}" Coroot observability coroot 1
assert_resource_count "${hetzner_infrastructure}" HelmRelease observability audit-log-forwarder 1
assert_resource_count "${hetzner_infrastructure}" Provider flux-system slack 0
assert_resource_count "${hetzner_infrastructure}" Alert flux-system platform-reconciliation 0
assert_resource_count "${hetzner_infrastructure}" Alert flux-system platform-dependency-wait 0
assert_resource_count "${hetzner_infrastructure}" Secret flux-system slack-webhook 0
assert_opencost_absent "${hetzner_infrastructure}"
assert_opencost_absent "${docker_apps}"
assert_opencost_absent "${hetzner_apps}"
# The Admin role ships with the Coroot resource itself: the route, grant and
# network boundary that put oauth2-proxy in front of it are always rendered.
assert_coroot_admin_role "${coroot_base}" 1
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
  echo "Coroot webhook notifications must remain absent from the reusable base and the local layers" >&2
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
    echo "templating guide does not document the Coroot path value ${documented_value}" >&2
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
  "The stack runs Coroot and nothing beside it." \
  "It has no OpenCost," \
  "has no Loki or Alloy log path" \
  "has no kube-prometheus-stack" \
  "stages one hardened \`cluster-heartbeat\` CronJob" \
  "a production bootstrap requires the" \
  "permits only \`hc-ping.com:443\`" \
  "Bootstrap accepts only a canonical" \
  "dependent apps layer stages the heartbeat only after" \
  "Secret-backed environment variable" \
  "stdin configuration" \
  "platform-critical priority" \
  "Cost allocation is therefore unavailable" \
  "reuses the same \`alertmanager_webhook_url\`" \
  "production to report failed reconciliations" \
  "reuses the existing encrypted webhook" \
  "incident and resolution notifications" \
  "permits only \`hooks.slack.com:443\`" \
  "Per-alert notifications remain visible only in the Coroot UI" \
  "Local / Docker Coroot stays notification-free" \
  "Flux notification-controller now owns reconciliation errors" \
  "controller layer applies both Flux alerts" \
  "every \`HelmRelease\`" \
  "narrow info-severity path for dependency waits" \
  "scripts/validate-alert-coverage.sh" \
  "adds that namespace to the alert" \
  "a \`platform-health-alert\` CronJob reports failed or stale backups" \
  "Cluster Autoscaler failures are left to Coroot." \
  "https://observability.<your-domain>" \
  "Dex-backed oauth2-proxy" \
  "no direct Gateway route to the Coroot service" \
  "the Admin role only behind that complete" \
  "render exactly what the default paths render" \
  "migrates with its next template sync" \
  "Flux removes" \
  "the old data is deleted" \
  "Helm does not delete CustomResourceDefinitions" \
  "\`ALERTMANAGER_HEARTBEAT_URL\` is no longer read" \
  "allow-node-exporter-ingress.yaml"; do
  if ! grep -Fq "${documented_boundary}" "${templating_guide}"; then
    echo "templating guide does not retain Coroot boundary: ${documented_boundary}" >&2
    exit 1
  fi
done

alerting_guide="${repo_root}/docs/dr/alerting.md"
for documented_heartbeat_boundary in \
  "There is no kube-prometheus-stack" \
  "One off-cluster dead-man check" \
  "cluster_heartbeat_url" \
  "The two secret inputs" \
  "\`hc-ping.com:443\`" \
  "Bootstrap rejects" \
  "dependent apps layer" \
  "curl as stdin configuration" \
  "Flux notification-controller now owns reconciliation errors" \
  "Two event-driven \`Alert\` objects" \
  "The controller layer applies them before it waits" \
  "every \`Kustomization\` and every \`HelmRelease\`" \
  "Why HelmRelease is watched directly" \
  "scripts/validate-alert-coverage.sh" \
  "Local / Docker renders no Slack" \
  "Backup, database and certificate check" \
  "Cluster Autoscaler failures are left to Coroot." \
  "scripts/tests/test-platform-health-alert.sh" \
  "A certificate expires within 14 days"; do
  if ! grep -Fq "${documented_heartbeat_boundary}" "${alerting_guide}"; then
    echo "alerting guide does not retain alerting boundary: ${documented_heartbeat_boundary}" >&2
    exit 1
  fi
done

# Operator documentation must not send anyone to a service that no longer exists.
for stale_doc in "${templating_guide}" "${alerting_guide}" \
  "${repo_root}/docs/BOOTSTRAP.md" "${repo_root}/docs/ARCHITECTURE.md" "${repo_root}/README.md"; do
  if grep -n -E 'svc/kube-prometheus-stack|Watchdog|alertmanager_heartbeat_url|grafana\.\$\{domain\}' "${stale_doc}"; then
    echo "documentation still describes the retired kube-prometheus-stack: ${stale_doc}" >&2
    exit 1
  fi
done

bootstrap_workflow="${repo_root}/.github/workflows/bootstrap.yaml"
for bootstrap_boundary in \
  "CLUSTER_HEARTBEAT_URL: \${{ secrets.CLUSTER_HEARTBEAT_URL }}" \
  "heartbeat_url_pattern='^https://hc-ping\\.com/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'" \
  'CLUSTER_HEARTBEAT_URL must be a canonical https://hc-ping.com/<lowercase-uuid> URL or be unset' \
  'required+=(HCLOUD_TOKEN CLUSTER_HEARTBEAT_URL HETZNER_LOCATION)' \
  '.stringData.cluster_heartbeat_url = strenv(CLUSTER_HEARTBEAT_URL)'; do
  if ! grep -Fq "${bootstrap_boundary}" "${bootstrap_workflow}"; then
    echo "bootstrap workflow does not retain cluster-heartbeat boundary: ${bootstrap_boundary}" >&2
    exit 1
  fi
done

# The Alertmanager heartbeat is retired with its stack: nothing may read it again.
# The bootstrap workflow may only delete the old key, and the protected placeholder
# secrets (`*.enc.yaml`, which automation never edits) are the one place it may
# still be listed until the workflow drops it.
if grep -n 'ALERTMANAGER_HEARTBEAT_URL' "${bootstrap_workflow}" ||
  grep 'alertmanager_heartbeat' "${bootstrap_workflow}" |
  grep -v -x -E '[[:space:]]*del\(\.stringData\.alertmanager_heartbeat_url\) \|'; then
  echo "the bootstrap workflow must not read the retired Alertmanager heartbeat" >&2
  exit 1
fi
if ! grep -q -x -E '[[:space:]]*del\(\.stringData\.alertmanager_heartbeat_url\) \|' "${bootstrap_workflow}"; then
  echo "the bootstrap workflow must drop the retired Alertmanager heartbeat key from the prod secret" >&2
  exit 1
fi
if grep -R -n -i --exclude='*.enc.yaml' 'alertmanager_heartbeat' "${repo_root}/k8s"; then
  echo "no manifest may read the retired Alertmanager heartbeat" >&2
  exit 1
fi

if grep -R -E -n '(devantler|homelab|hooks\.slack\.com|hcloud|alertmanager_webhook_url)' \
  "${repo_root}/k8s/bases/infrastructure/controllers/coroot" \
  "${repo_root}/k8s/bases/infrastructure/coroot" \
  "${repo_root}/k8s/bases/apps/cluster-heartbeat" \
  "${repo_root}/k8s/bases/infrastructure/audit-log-forwarder"; then
  echo "Coroot manifests contain an instance-specific value" >&2
  exit 1
fi

echo "Observability validation passed (Coroot by default on both providers; the earlier opt-in paths alias the defaults)."
