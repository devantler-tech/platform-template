#!/usr/bin/env bash
# Pins both scaffolded default-deny Cilium policies to the valid, composable
# shape proven by the matching reference-platform fix (platform#3501).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
readonly repo_root

readonly generated_policy="${repo_root}/k8s/bases/infrastructure/cluster-policies/best-practices/add-default-deny.yaml"
readonly direct_policy="${repo_root}/k8s/bases/infrastructure/controllers/oauth2-proxy/cilium-network-policy-default-deny.yaml"
readonly expected='{"egress":[{}],"enableDefaultDeny":{"egress":true,"ingress":true},"endpointSelector":{},"ingress":[{}]}'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

matches_expected() {
  local actual
  actual="$(printf '%s' "$1" | yq -p=json -o=json -I=0 'sort_keys(..)')" || return 1
  [[ "${actual}" == "${expected}" ]]
}

check_spec() {
  local description="$1"
  local spec="$2"
  [[ -n "${spec}" && "${spec}" != 'null' ]] || fail "${description}: no policy spec found"
  matches_expected "${spec}" || fail "${description}: expected ${expected}, got $(printf '%s' "${spec}" | yq -p=json -o=json -I=0 'sort_keys(..)')"
}

# Negative controls prove the matcher rejects both broken shapes currently in
# the template, as well as an empty peer selector that would allow all traffic.
for invalid in \
  '{"endpointSelector":{},"ingress":[],"egress":[],"enableDefaultDeny":{"ingress":true,"egress":true}}' \
  '{"endpointSelector":{},"ingressDeny":[{}],"egressDeny":[{}],"enableDefaultDeny":{"ingress":true,"egress":true}}' \
  '{"endpointSelector":{},"ingress":[{"fromEndpoints":[{}]}],"egress":[{}],"enableDefaultDeny":{"ingress":true,"egress":true}}'; do
  if matches_expected "${invalid}"; then
    fail "the exact-shape matcher accepted an unsafe policy: ${invalid}"
  fi
done

generated_spec="$(yq -o=json -I=0 \
  '.spec.rules[] | select(.name == "generate-default-deny") | .generate.data.spec' \
  "${generated_policy}")"
direct_spec="$(yq -o=json -I=0 '.spec' "${direct_policy}")"

check_spec 'namespace-wide generated default-deny' "${generated_spec}"
check_spec 'oauth2-proxy direct default-deny' "${direct_spec}"

printf 'PASS: both scaffolded Cilium default-deny policies use one empty allow rule per direction\n'
