#!/usr/bin/env bash
# Runs the production platform-health-alert check, exactly as rendered, against
# recorded Kubernetes API responses. curl is stubbed: API reads are served from
# fixtures and the Slack delivery is captured instead of sent.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd "${script_dir}/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

kubectl kustomize "${source_root}/k8s/providers/hetzner/infrastructure/controllers" >"${test_dir}/controllers.yaml"
yq 'select(.kind == "CronJob" and .metadata.name == "platform-health-alert") | .spec.jobTemplate.spec.template.spec.containers[0].command[2]' \
  "${test_dir}/controllers.yaml" >"${test_dir}/check.sh"
[[ -s "${test_dir}/check.sh" ]] || fail "the production render has no platform-health-alert script"
container_env() {
  yq "select(.kind == \"CronJob\" and .metadata.name == \"platform-health-alert\") | .spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" \
    "${test_dir}/controllers.yaml"
}
BACKUP_MAX_AGE_SECONDS="$(container_env BACKUP_MAX_AGE_SECONDS)"
CERT_WARN_SECONDS="$(container_env CERT_WARN_SECONDS)"
GRACE_SECONDS="$(container_env GRACE_SECONDS)"
[[ "${BACKUP_MAX_AGE_SECONDS}" == 93600 && "${CERT_WARN_SECONDS}" == 1209600 && "${GRACE_SECONDS}" == 900 ]] ||
  fail "unexpected thresholds: ${BACKUP_MAX_AGE_SECONDS} ${CERT_WARN_SECONDS} ${GRACE_SECONDS}"
export BACKUP_MAX_AGE_SECONDS CERT_WARN_SECONDS GRACE_SECONDS

mkdir -p "${test_dir}/bin" "${test_dir}/sa"
printf 'token' >"${test_dir}/sa/token"
printf 'ca' >"${test_dir}/sa/ca.crt"
cat >"${test_dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out="" data="" config=0 url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --data) data="${2#@}"; shift ;;
    --config) config=1; shift ;;
    -w|--cacert|-H|--max-time|--retry|--retry-delay) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
if [[ "${config}" == 1 ]]; then
  cat >"${FIXTURES}/posted.config"
  cp "${data}" "${FIXTURES}/posted.json"
  [[ ! -e "${FIXTURES}/post-fails" ]] || exit 22
  exit 0
fi
path="${url#https://api.test}"
fixture="${FIXTURES}/$(printf '%s' "${path}" | tr '/' '_').json"
if [[ -e "${FIXTURES}/server-error" ]]; then printf '500'; exit 0; fi
if [[ -e "${fixture}" ]]; then cp "${fixture}" "${out}"; printf '200'; else printf '404'; fi
STUB
chmod +x "${test_dir}/bin/curl"

now=1794355200 # 2026-11-11T00:00:00Z
iso() { jq -n -r --argjson t "$1" '$t | todate'; }
hours_ago() { iso $((now - $1 * 3600)); }

new_case() {
  FIXTURES="${test_dir}/case"
  rm -rf "${FIXTURES}" "${test_dir}/work"
  mkdir -p "${FIXTURES}" "${test_dir}/work"
  printf 'https://hooks.slack.test/services/x' >"${test_dir}/webhook"
  export FIXTURES
}
fixture() { printf '%s' "$2" >"${FIXTURES}/$(printf '%s' "$1" | tr '/' '_').json"; }

run_check() {
  PATH="${test_dir}/bin:${PATH}" API=https://api.test SA_DIR="${test_dir}/sa" WORK_DIR="${test_dir}/work" \
    NOW="${now}" WEBHOOK_FILE="${test_dir}/webhook" sh "${test_dir}/check.sh" >"${test_dir}/out" 2>&1
}

healthy_fixtures() {
  fixture /apis/velero.io/v1/schedules "{\"items\":[{\"metadata\":{\"namespace\":\"velero\",\"name\":\"daily-full\",\"creationTimestamp\":\"$(hours_ago 500)\"}}]}"
  fixture /apis/velero.io/v1/backups "{\"items\":[
    {\"metadata\":{\"namespace\":\"velero\",\"name\":\"daily-full-1\",\"creationTimestamp\":\"$(hours_ago 30)\",\"labels\":{\"velero.io/schedule-name\":\"daily-full\"}},\"status\":{\"phase\":\"Completed\",\"completionTimestamp\":\"$(hours_ago 29)\"}},
    {\"metadata\":{\"namespace\":\"velero\",\"name\":\"daily-full-2\",\"creationTimestamp\":\"$(hours_ago 6)\",\"labels\":{\"velero.io/schedule-name\":\"daily-full\"}},\"status\":{\"phase\":\"Completed\",\"completionTimestamp\":\"$(hours_ago 5)\"}}]}"
  fixture /apis/postgresql.cnpg.io/v1/clusters "{\"items\":[{\"metadata\":{\"namespace\":\"app\",\"name\":\"db\",\"creationTimestamp\":\"$(hours_ago 500)\"},
    \"spec\":{\"instances\":3,\"backup\":{\"barmanObjectStore\":{}}},
    \"status\":{\"readyInstances\":3,\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastTransitionTime\":\"$(hours_ago 100)\"},{\"type\":\"ContinuousArchiving\",\"status\":\"True\",\"lastTransitionTime\":\"$(hours_ago 100)\"}]}}]}"
  fixture /apis/postgresql.cnpg.io/v1/backups "{\"items\":[{\"metadata\":{\"namespace\":\"app\",\"name\":\"db-1\"},\"spec\":{\"cluster\":{\"name\":\"db\"}},\"status\":{\"phase\":\"completed\",\"stoppedAt\":\"$(hours_ago 3)\"}}]}"
  fixture /apis/cert-manager.io/v1/certificates "{\"items\":[{\"metadata\":{\"namespace\":\"gateway\",\"name\":\"wildcard\"},\"status\":{\"notAfter\":\"$(hours_ago -1440)\"}}]}"
}

# 1. A healthy cluster posts nothing.
new_case
healthy_fixtures
run_check || fail "healthy run failed: $(cat "${test_dir}/out")"
grep -q 'No backup, database or certificate problem found.' "${test_dir}/out" || fail "healthy run did not report a clean check"
[[ ! -e "${FIXTURES}/posted.json" ]] || fail "healthy run posted to Slack"

# 2. Every problem shape is reported in one Slack post, and nothing within its grace.
new_case
fixture /apis/velero.io/v1/schedules "{\"items\":[
  {\"metadata\":{\"namespace\":\"velero\",\"name\":\"failing\",\"creationTimestamp\":\"$(hours_ago 500)\"}},
  {\"metadata\":{\"namespace\":\"velero\",\"name\":\"stale\",\"creationTimestamp\":\"$(hours_ago 500)\"}},
  {\"metadata\":{\"namespace\":\"velero\",\"name\":\"never\",\"creationTimestamp\":\"$(hours_ago 27)\"}},
  {\"metadata\":{\"namespace\":\"velero\",\"name\":\"new\",\"creationTimestamp\":\"$(hours_ago 2)\"}}]}"
fixture /apis/velero.io/v1/backups "{\"items\":[
  {\"metadata\":{\"namespace\":\"velero\",\"name\":\"failing-1\",\"creationTimestamp\":\"$(hours_ago 10)\",\"labels\":{\"velero.io/schedule-name\":\"failing\"}},\"status\":{\"phase\":\"Completed\",\"completionTimestamp\":\"$(hours_ago 9)\"}},
  {\"metadata\":{\"namespace\":\"velero\",\"name\":\"failing-2\",\"creationTimestamp\":\"$(hours_ago 1)\",\"labels\":{\"velero.io/schedule-name\":\"failing\"}},\"status\":{\"phase\":\"PartiallyFailed\"}},
  {\"metadata\":{\"namespace\":\"velero\",\"name\":\"stale-1\",\"creationTimestamp\":\"$(hours_ago 40)\",\"labels\":{\"velero.io/schedule-name\":\"stale\"}},\"status\":{\"phase\":\"Completed\",\"completionTimestamp\":\"2026-11-09T09:00:00.123Z\"}}]}"
fixture /apis/postgresql.cnpg.io/v1/clusters "{\"items\":[
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"unbacked\",\"creationTimestamp\":\"$(hours_ago 500)\"},\"spec\":{\"instances\":1},\"status\":{\"readyInstances\":1,\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastTransitionTime\":\"$(hours_ago 100)\"}]}},
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"short\",\"creationTimestamp\":\"$(hours_ago 500)\"},\"spec\":{\"instances\":3},\"status\":{\"readyInstances\":2,\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\",\"lastTransitionTime\":\"$(hours_ago 1)\"}]}},
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"settling\",\"creationTimestamp\":\"$(hours_ago 500)\"},\"spec\":{\"instances\":3},\"status\":{\"readyInstances\":2,\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\",\"lastTransitionTime\":\"$(iso $((now - 300)))\"}]}},
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"archive\",\"creationTimestamp\":\"$(hours_ago 500)\"},\"spec\":{\"instances\":1,\"plugins\":[{\"name\":\"barman-cloud.cloudnative-pg.io\",\"isWALArchiver\":true}]},\"status\":{\"readyInstances\":1,\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastTransitionTime\":\"$(hours_ago 100)\"},{\"type\":\"ContinuousArchiving\",\"status\":\"False\",\"lastTransitionTime\":\"$(hours_ago 2)\"}]}}]}"
fixture /apis/postgresql.cnpg.io/v1/backups "{\"items\":[
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"short-1\"},\"spec\":{\"cluster\":{\"name\":\"short\"}},\"status\":{\"phase\":\"completed\",\"stoppedAt\":\"$(hours_ago 3)\"}},
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"settling-1\"},\"spec\":{\"cluster\":{\"name\":\"settling\"}},\"status\":{\"phase\":\"completed\",\"stoppedAt\":\"$(hours_ago 3)\"}},
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"archive-1\"},\"spec\":{\"cluster\":{\"name\":\"archive\"}},\"status\":{\"phase\":\"completed\",\"stoppedAt\":\"$(hours_ago 3)\"}},
  {\"metadata\":{\"namespace\":\"app\",\"name\":\"unbacked-failed\"},\"spec\":{\"cluster\":{\"name\":\"unbacked\"}},\"status\":{\"phase\":\"failed\",\"stoppedAt\":\"$(hours_ago 1)\"}},
  {\"metadata\":{\"namespace\":\"other\",\"name\":\"unbacked-elsewhere\"},\"spec\":{\"cluster\":{\"name\":\"unbacked\"}},\"status\":{\"phase\":\"completed\",\"stoppedAt\":\"$(hours_ago 1)\"}}]}"
fixture /apis/cert-manager.io/v1/certificates "{\"items\":[
  {\"metadata\":{\"namespace\":\"gateway\",\"name\":\"expiring\"},\"status\":{\"notAfter\":\"$(hours_ago -240)\"}},
  {\"metadata\":{\"namespace\":\"gateway\",\"name\":\"fine\"},\"status\":{\"notAfter\":\"$(hours_ago -400)\"}},
  {\"metadata\":{\"namespace\":\"gateway\",\"name\":\"pending\"},\"status\":{}}]}"
run_check || fail "problem run failed: $(cat "${test_dir}/out")"
expected="$(cat <<EOF
• Velero schedule \`velero/failing\`: latest backup \`failing-2\` is PartiallyFailed
• Velero schedule \`velero/stale\`: no completed backup since 2026-11-09T09:00:00Z
• Velero schedule \`velero/never\`: no completed backup since $(hours_ago 27)
• CloudNativePG cluster \`app/unbacked\`: no completed backup since $(hours_ago 500)
• CloudNativePG cluster \`app/short\`: 2/3 instances ready since $(hours_ago 1)
• CloudNativePG cluster \`app/archive\`: WAL archiving is False since $(hours_ago 2)
• Certificate \`gateway/expiring\` expires $(hours_ago -240); cert-manager has not renewed it
EOF
)"
[[ "$(jq -r .text "${FIXTURES}/posted.json")" == "*Platform health check*"$'\n\n'"${expected}"$'\n\n'"_See docs/dr/alerting.md for what each line means._" ]] ||
  fail "unexpected Slack text: $(jq -r .text "${FIXTURES}/posted.json")"
[[ "$(cat "${FIXTURES}/posted.config")" == "url = https://hooks.slack.test/services/x" ]] || fail "the webhook was not passed as stdin configuration"
grep -q 'hooks.slack.test' "${test_dir}/check.sh" && fail "the script must not carry a webhook"

# 3. The local placeholder reports but never delivers.
printf 'https://example.invalid/no-slack-configured' >"${test_dir}/webhook"
rm -f "${FIXTURES}/posted.json"
run_check || fail "placeholder run failed"
grep -q 'alert not delivered' "${test_dir}/out" || fail "placeholder run did not say it skipped delivery"
[[ ! -e "${FIXTURES}/posted.json" ]] || fail "the placeholder webhook was posted to"

# 4. Kinds that are not installed are skipped.
new_case
run_check || fail "a cluster without these APIs failed: $(cat "${test_dir}/out")"
[[ "$(grep -c 'API not installed; skipped.' "${test_dir}/out")" == 3 ]] || fail "expected three skipped kinds"

# 5. Fail closed on a broken read, a malformed list, a failed delivery or an unsafe webhook.
new_case
healthy_fixtures
touch "${FIXTURES}/server-error"
run_check && fail "an API error was reported as healthy"
new_case
healthy_fixtures
fixture /apis/cert-manager.io/v1/certificates '{"items":{}}'
run_check && fail "a malformed list was reported as healthy"
new_case
healthy_fixtures
fixture /apis/cert-manager.io/v1/certificates "{\"items\":[{\"metadata\":{\"namespace\":\"a\",\"name\":\"b\"},\"status\":{\"notAfter\":\"$(hours_ago -1)\"}}]}"
touch "${FIXTURES}/post-fails"
run_check && fail "a failed Slack delivery succeeded"
new_case
healthy_fixtures
printf 'http://hooks.slack.test/services/x' >"${test_dir}/webhook"
run_check && fail "a plain-http webhook was accepted"
printf 'https://hooks.slack.test/x\noutput = /tmp/x' >"${test_dir}/webhook"
run_check && fail "a webhook with a control character was accepted"

echo "platform-health-alert check passed."
