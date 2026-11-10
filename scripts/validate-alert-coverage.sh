#!/usr/bin/env bash
# Fail if a Flux HelmRelease or Kustomization lives in a namespace the production
# reconciliation Alert does not watch.
#
# notification-controller has NO namespace wildcard: it defaults an omitted
# eventSources[].namespace to the Alert's own namespace and then matches on strict
# equality. `name: "*"` wildcards the NAME only. So every namespace holding a watched
# resource has to be listed explicitly in the Alert, and that list drifts the moment
# someone adds a release in a new namespace.
#
# An uncovered namespace is invisible. With Helm remediation on, a failed upgrade is
# rolled back to the last good release; the HelmRelease reports Ready again, its parent
# Kustomization stays healthy, and no alert ever fires while the release silently stops
# advancing. The Alert is the only production signal for that, so drift is a CI
# failure, not a comment.
#
# Run from the repository root. Renders the production layers; never contacts a cluster.

set -euo pipefail

readonly ALERT_FILE="k8s/providers/hetzner/infrastructure/controllers/flux-notifications/alert.yaml"
readonly LAYERS=(
  # The cluster overlay declares the Flux Kustomizations that drive every other layer,
  # so leaving it out would make flux-system look like it holds no Kustomization.
  "k8s/clusters/prod"
  "k8s/providers/hetzner/bootstrap"
  "k8s/providers/hetzner/infrastructure/controllers"
  "k8s/providers/hetzner/infrastructure"
  "k8s/providers/hetzner/apps"
)

for tool in kubectl yq; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "::error::${tool} is required to validate Alert coverage."
    exit 64
  }
done
[[ -f "${ALERT_FILE}" ]] || {
  echo "::error::${ALERT_FILE} not found (run from the repository root)."
  exit 64
}

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
rendered="${work_dir}/rendered.yaml"

# Render every layer once; both kinds are then read from the same output.
#
# Fail CLOSED on a render error. Swallowing a `kubectl kustomize` failure would drop
# every namespace declared only in that layer, so an uncovered namespace would never
# be compared against the Alert. A partial render is not a pass.
for layer in "${LAYERS[@]}"; do
  if ! kubectl kustomize "${layer}"; then
    echo "::error::kubectl kustomize failed to render ${layer}; refusing to validate Alert coverage on a partial render." >&2
    exit 1
  fi
  echo '---'
done >"${rendered}"

for kind in HelmRelease Kustomization; do
  declared="${work_dir}/declared-${kind}.txt"
  missing_namespace="${work_dir}/missing-namespace-${kind}.txt"
  watched="${work_dir}/watched-${kind}.txt"

  # Only the Flux kinds count. A `kind: Kustomization` in the kustomize.config.k8s.io
  # API group is a build input, not a Flux resource.
  case "${kind}" in
    HelmRelease) group="helm.toolkit.fluxcd.io" ;;
    Kustomization) group="kustomize.toolkit.fluxcd.io" ;;
    *)
      echo "::error::Unknown watched kind ${kind}."
      exit 64
      ;;
  esac

  # These Flux APIs are namespaced and this render path has no targetNamespace
  # fallback. Dropping a resource without a namespace would make the coverage set
  # look complete although the resource itself is malformed.
  yq ea -r "
    select(.kind == \"${kind}\" and (.apiVersion | test(\"^${group}/\")))
    | select((.metadata.namespace // \"\") == \"\")
    | (.kind + \"/\" + (.metadata.name // \"<unnamed>\"))
  " "${rendered}" | awk 'NF && $0 != "---"' >"${missing_namespace}"
  if [[ -s "${missing_namespace}" ]]; then
    echo "::error::Rendered ${kind} resources are missing metadata.namespace; Alert coverage cannot be proven."
    while read -r resource; do
      [[ -n "${resource}" ]] && echo "  ${resource}"
    done <"${missing_namespace}"
    exit 1
  fi

  yq ea -r "
    select(.kind == \"${kind}\" and (.apiVersion | test(\"^${group}/\")))
    | .metadata.namespace
    | select(. != null and . != \"\")
  " "${rendered}" | awk 'NF && $0 != "---"' | LC_ALL=C sort -u >"${declared}"

  if [[ ! -s "${declared}" ]]; then
    echo "::error::Rendered no ${kind}s at all, so coverage cannot be proven. Failing closed."
    exit 1
  fi

  # yq treats `== "*"` as a wildcard comparison, so anchor a regex to require the
  # literal whole-resource wildcard instead of accepting any named source.
  yq e ".spec.eventSources[] | select(.kind == \"${kind}\" and (.name | test(\"^\\\\*$\"))) | .namespace | select(. != null and . != \"\")" "${ALERT_FILE}" |
    LC_ALL=C sort -u >"${watched}"

  uncovered="$(comm -23 "${declared}" "${watched}")"
  if [[ -n "${uncovered}" ]]; then
    echo "::error::The reconciliation Alert does not watch every namespace holding a ${kind}."
    echo "A ${kind} in an unwatched namespace can fail, roll back and report Ready, with no alert."
    echo "Add a ${kind} eventSource for each namespace below to ${ALERT_FILE}:"
    while read -r ns; do
      [[ -n "${ns}" ]] && printf '    - kind: %s\n      name: "*"\n      namespace: %s\n' "${kind}" "${ns}"
    done <<<"${uncovered}"
    exit 1
  fi

  # A listed namespace that holds nothing never matches anything: harmless, but it is
  # dead configuration, so say so without failing the build.
  stale="$(comm -13 "${declared}" "${watched}" || true)"
  if [[ -n "${stale}" ]]; then
    echo "::warning::The Alert watches namespaces that hold no ${kind} (dead entries): $(echo "${stale}" | tr '\n' ' ')"
  fi

  echo "✅ Alert covers all $(wc -l <"${declared}" | tr -d ' ') namespaces holding a ${kind}."
done
