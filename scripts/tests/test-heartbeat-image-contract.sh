#!/usr/bin/env bash
# Exercise the production heartbeat assertion against real provider renders.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd "${script_dir}/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

# Load only the two assertions under test; do not run the complete validator.
sed -n '/^resource_count() {/,/^}/p' "${source_root}/scripts/validate-observability-option.sh" >"${test_dir}/assertions.sh"
sed -n '/^assert_coroot_heartbeat_contract() {/,/^}/p' "${source_root}/scripts/validate-observability-option.sh" >>"${test_dir}/assertions.sh"
# shellcheck source=/dev/null
source "${test_dir}/assertions.sh"

kubectl kustomize "${source_root}/k8s/providers/docker/apps-coroot" >"${test_dir}/apps.yaml"
kubectl kustomize "${source_root}/k8s/providers/docker/infrastructure-controllers-coroot" >"${test_dir}/controllers.yaml"
repo_root="${test_dir}/source"
mkdir -p "${repo_root}/k8s/bases/apps/cluster-heartbeat"
source_manifest="${repo_root}/k8s/bases/apps/cluster-heartbeat/cron-job.yaml"
cp "${source_root}/k8s/bases/apps/cluster-heartbeat/cron-job.yaml" "${source_manifest}"

# Current reviewed source must work without another version literal to update.
assert_coroot_heartbeat_contract "${test_dir}/apps.yaml" "${test_dir}/controllers.yaml"

set_images() {
  local source_image="$1"
  local rendered_image="$2"
  SOURCE_IMAGE="${source_image}" yq -i '.spec.jobTemplate.spec.template.spec.containers[0].image = strenv(SOURCE_IMAGE)' "${source_manifest}"
  RENDERED_IMAGE="${rendered_image}" yq '(. | select(.kind == "CronJob" and .metadata.name == "cluster-heartbeat") | .spec.jobTemplate.spec.template.spec.containers[0].image) = strenv(RENDERED_IMAGE)' "${test_dir}/apps.yaml" >"${test_dir}/mutated-apps.yaml"
}

expect_rejected() {
  local description="$1"
  if assert_coroot_heartbeat_contract "${test_dir}/mutated-apps.yaml" "${test_dir}/controllers.yaml" >"${test_dir}/rejection.log" 2>&1; then
    printf 'FAIL: accepted %s\n' "${description}" >&2
    exit 1
  fi
}

current_image="$(yq -r '.spec.jobTemplate.spec.template.spec.containers[0].image' "${source_manifest}")"
# A different reviewed source pin must also pass, proving updates need one edit.
previous_image='docker.io/curlimages/curl:8.21.0@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13'
set_images "${previous_image}" "${previous_image}"
assert_coroot_heartbeat_contract "${test_dir}/mutated-apps.yaml" "${test_dir}/controllers.yaml"

set_images "${current_image}" "${previous_image}"
expect_rejected 'a render that differs from its source'
for invalid_image in \
  'docker.io/curlimages/curl:8.23.0' \
  'docker.io/curlimages/curl:latest@sha256:11e64e28c5f58c8d93ee95fcf22ac055f48b0bc440e0ce7d8013bbb5ad6aa8ac' \
  'example.invalid/curl:8.23.0@sha256:11e64e28c5f58c8d93ee95fcf22ac055f48b0bc440e0ce7d8013bbb5ad6aa8ac' \
  'docker.io/curlimages/curl:8.23.0@sha256:bad'; do
  set_images "${invalid_image}" "${invalid_image}"
  expect_rejected 'an unapproved registry, floating tag or invalid digest'
done

printf 'PASS: heartbeat accepts reviewed pinned source updates and rejects five invalid image cases\n'
