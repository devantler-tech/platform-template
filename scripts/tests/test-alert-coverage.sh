#!/usr/bin/env bash
# Proves scripts/validate-alert-coverage.sh fails when it should (platform-template#387).
# The production reconciliation Alert is the only notification for a failed
# HelmRelease, so a check that passes on a namespace nobody watches would be worse
# than no check. Each case edits a private copy of the manifests; the repository
# is never touched and no cluster is contacted.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
readonly repo_root
readonly alert="k8s/providers/hetzner/infrastructure/controllers/flux-notifications/alert.yaml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# A private copy of everything the validator reads.
fresh_copy() {
  rm -rf "${tmp_dir}/repo"
  mkdir -p "${tmp_dir}/repo/scripts"
  cp -R "${repo_root}/k8s" "${tmp_dir}/repo/k8s"
  cp "${repo_root}/scripts/validate-alert-coverage.sh" "${tmp_dir}/repo/scripts/"
}

# run_validator <output-file>: the validator's exit status, run from the copy's root.
run_validator() {
  (cd "${tmp_dir}/repo" && bash scripts/validate-alert-coverage.sh) >"$1" 2>&1
}

# expect_failure <name> <text the output must contain>
expect_failure() {
  local name="$1" want="$2" out="${tmp_dir}/out.txt"
  if run_validator "${out}"; then
    fail "${name}: the validator passed"
  fi
  grep -Fq -- "${want}" "${out}" || {
    cat "${out}" >&2
    fail "${name}: failed for another reason than '${want}'"
  }
  printf 'ok   %s\n' "${name}"
}

# --- the repository as committed passes ------------------------------------------------
fresh_copy
run_validator "${tmp_dir}/out.txt" || {
  cat "${tmp_dir}/out.txt" >&2
  fail "the committed manifests do not pass"
}
grep -Fq 'namespaces holding a HelmRelease' "${tmp_dir}/out.txt" ||
  fail "the validator passed without reporting HelmRelease coverage"
grep -Fq 'namespaces holding a Kustomization' "${tmp_dir}/out.txt" ||
  fail "the validator passed without reporting Kustomization coverage"
printf 'ok   %s\n' "the committed manifests pass and report both kinds"

# --- a namespace holding a HelmRelease is not watched ----------------------------------
fresh_copy
yq -i 'del(.spec.eventSources[] | select(.kind == "HelmRelease" and .namespace == "velero"))' \
  "${tmp_dir}/repo/${alert}"
expect_failure "an unwatched HelmRelease namespace fails" \
  'does not watch every namespace holding a HelmRelease'
grep -Fq 'namespace: velero' "${tmp_dir}/out.txt" ||
  fail "the failure did not name the unwatched namespace"

# --- the Kustomization source relies on the default namespace ---------------------------
fresh_copy
yq -i 'del(.spec.eventSources[] | select(.kind == "Kustomization") | .namespace)' \
  "${tmp_dir}/repo/${alert}"
expect_failure "a Kustomization source without a namespace fails" \
  'does not watch every namespace holding a Kustomization'

# --- a named source is not a whole-namespace watch --------------------------------------
fresh_copy
yq -i '(.spec.eventSources[] | select(.kind == "HelmRelease" and .namespace == "dex") | .name) = "dex"' \
  "${tmp_dir}/repo/${alert}"
expect_failure "a source that names one release does not cover its namespace" \
  'does not watch every namespace holding a HelmRelease'

# --- a layer that does not render is not a pass -----------------------------------------
fresh_copy
printf 'resources:\n  - does-not-exist.yaml\n' >"${tmp_dir}/repo/k8s/providers/hetzner/apps/kustomization.yaml"
expect_failure "a layer that fails to render fails closed" \
  'refusing to validate Alert coverage on a partial render'

printf 'alert-coverage: all cases passed\n'
