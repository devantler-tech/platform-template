#!/usr/bin/env bash

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
workflow="$repo_root/.github/workflows/bootstrap.yaml"
failures=0

fail() {
  echo "ERROR: $*" >&2
  failures=$((failures + 1))
}

step_run() {
  yq -r ".jobs.bootstrap.steps[] | select(.name == \"$1\") | .run // \"\"" "$workflow"
}

step_index() {
  yq -r ".jobs.bootstrap.steps | to_entries[] | select(.value.name == \"$1\") | .key" "$workflow"
}

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

# GitHub rejects Variables and Secrets whose names start with GITHUB_, and an
# unset reference renders as an empty string instead of failing. actionlint
# catches the Variable case only, so check both. GITHUB_TOKEN is the one
# built-in secret a workflow may reference.
reserved_names=$(
  grep -rnoE '(vars|secrets)\.[Gg][Ii][Tt][Hh][Uu][Bb]_[A-Za-z0-9_]+' "$repo_root/.github/workflows" |
    grep -vE ':secrets\.GITHUB_TOKEN$' || true
)
if [[ -n "$reserved_names" ]]; then
  fail "workflows reference Variables or Secrets with the reserved GITHUB_ prefix:"$'\n'"$reserved_names"
fi

permission_environments=$(
  yq -r '.jobs.bootstrap.steps[] | select(.name == "🎟️ Mint App token") | .with."permission-environments" // ""' "$workflow"
)
if [[ "$permission_environments" != "write" ]]; then
  fail "the bootstrap App token must request permission-environments: write"
fi

# --- Required configuration is checked before anything is changed ---
check_step="🧾 Check required configuration"
check_script=$(step_run "$check_step")
check_index=$(step_index "$check_step")
if [[ -z "$check_script" || -z "$check_index" ]]; then
  fail "could not find the '$check_step' step"
else
  for later in "🎟️ Mint App token" "🔑 Generate Age key + update .sops.yaml" "🚀 Create cluster"; do
    later_index=$(step_index "$later")
    if [[ -z "$later_index" ]] || ((check_index >= later_index)); then
      fail "'$check_step' must run before '$later'"
    fi
  done

  required_env=$(
    yq -r ".jobs.bootstrap.steps[] | select(.name == \"$check_step\") | .env | keys | .[]" "$workflow"
  )
  run_check() { # $1 = environment input, $2 = name to leave empty (or "")
    local -a assignments=("BOOTSTRAP_ENVIRONMENT=$1")
    local name
    for name in $required_env; do
      [[ "$name" == "BOOTSTRAP_ENVIRONMENT" ]] && continue
      if [[ "$name" == "$2" ]]; then
        assignments+=("$name=")
      else
        assignments+=("$name=set")
      fi
    done
    env -i PATH="$PATH" "${assignments[@]}" bash -c "$check_script" >"$test_root/check.out" 2>&1
  }

  if ! run_check prod ""; then
    fail "the configuration check rejected a complete prod configuration: $(cat "$test_root/check.out")"
  fi
  for name in SSO_GITHUB_APP_CLIENT_ID SSO_GITHUB_APP_CLIENT_SECRET; do
    if run_check prod "$name"; then
      fail "the configuration check accepted an empty $name"
    elif ! grep -q "$name" "$test_root/check.out"; then
      fail "the configuration check did not name the missing $name"
    fi
  done
  if run_check local "HCLOUD_TOKEN"; then
    :
  else
    fail "the configuration check required the prod-only HCLOUD_TOKEN for a local bootstrap"
  fi
  if run_check prod "HCLOUD_TOKEN"; then
    fail "the configuration check accepted an empty HCLOUD_TOKEN for a prod bootstrap"
  fi
  if run_check prod "HETZNER_LOCATION"; then
    fail "the configuration check accepted an empty HETZNER_LOCATION for a prod bootstrap"
  fi
  if ! run_check local "HETZNER_LOCATION"; then
    fail "the configuration check required the prod-only HETZNER_LOCATION for a local bootstrap"
  fi
fi

# --- A failed secret generator stops the encryption step ---
encrypt_script=$(step_run "🔐 Encrypt secrets into *.enc.yaml")
if [[ -z "$encrypt_script" ]]; then
  fail "could not find the secret encryption script"
else
  stubs="$test_root/stubs"
  mkdir -p "$stubs"
  # shellcheck disable=SC2016 # $0 and $* belong to the stub and expand when it runs.
  printf '#!/usr/bin/env bash\necho "$0 $*" >>"%s/mutations"\n' "$test_root" >"$stubs/yq"
  cp "$stubs/yq" "$stubs/sops"
  chmod +x "$stubs/yq" "$stubs/sops"

  run_encrypt() { # $1 = openssl stub exit status
    printf '#!/usr/bin/env bash\n[ %s -eq 0 ] || exit %s\necho generated\n' "$1" "$1" >"$stubs/openssl"
    chmod +x "$stubs/openssl"
    rm -f "$test_root/mutations"
    env -i PATH="$stubs:$PATH" ALERTMANAGER_HEARTBEAT_URL= CLUSTER_HEARTBEAT_URL= \
      bash -euo pipefail -c "$encrypt_script" >"$test_root/encrypt.out" 2>&1
  }

  if ! run_encrypt 0; then
    fail "the encryption script failed with a working secret generator: $(cat "$test_root/encrypt.out")"
  elif [[ ! -s "$test_root/mutations" ]]; then
    fail "the encryption behavior test did not reach the secret writes"
  fi
  if run_encrypt 7; then
    fail "the encryption script continued after the secret generator failed"
  fi
  if [[ -e "$test_root/mutations" ]]; then
    fail "the encryption script wrote secrets after the secret generator failed"
  fi
fi

commit_script=$(
  yq -r '.jobs.bootstrap.steps[] | select(.name == "💾 Commit the rendered + encrypted tree") | .run' "$workflow"
)
if [[ -z "$commit_script" || "$commit_script" == "null" ]]; then
  fail "could not find the bootstrap commit-back script"
else
  repo="$test_root/repo"

  git init --quiet --initial-branch=main "$repo"
  git -C "$repo" config user.name "Bootstrap workflow test"
  git -C "$repo" config user.email "bootstrap-workflow-test@example.invalid"
  git -C "$repo" config commit.gpgsign false
  mkdir -p "$repo/talos" "$repo/k8s"
  printf 'creation_rules: []\n' >"$repo/.sops.yaml"
  printf 'distribution: Talos\n' >"$repo/ksail.prod.yaml"
  printf 'machine: {}\n' >"$repo/talos/control-plane.yaml"
  printf 'resources: []\n' >"$repo/k8s/kustomization.yaml"
  git -C "$repo" add .sops.yaml ksail.prod.yaml talos/ k8s/
  git -C "$repo" commit --quiet -m "test: seed bootstrap output"

  printf 'resources:\n  - namespace.yaml\n' >"$repo/k8s/kustomization.yaml"
  printf '#!/usr/bin/env bash\necho "intentional commit failure" >&2\nexit 42\n' >"$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"

  set +e
  (
    cd "$repo"
    GH_TOKEN=dummy REF_NAME=main bash -c "$commit_script"
  ) >"$test_root/commit.out" 2>&1
  commit_status=$?
  set -e

  if ((commit_status == 0)); then
    fail "the commit-back script treated a real git commit failure as 'nothing to commit'"
  fi
  if ! grep -q "intentional commit failure" "$test_root/commit.out"; then
    fail "the commit-back behavior test did not reach the failing commit hook"
  fi

  git -C "$repo" reset --quiet --hard HEAD
  rm "$repo/.git/hooks/pre-commit"
  set +e
  (
    cd "$repo"
    GH_TOKEN=dummy REF_NAME=main bash -c "$commit_script"
  ) >"$test_root/no-change.out" 2>&1
  no_change_status=$?
  set -e

  if ((no_change_status != 0)); then
    fail "the commit-back script failed when there was nothing to commit"
  fi
  if ! grep -q "Nothing to commit" "$test_root/no-change.out"; then
    fail "the commit-back script did not report its no-change path"
  fi
fi

if ((failures > 0)); then
  exit 1
fi

echo "Bootstrap workflow contract is valid."
