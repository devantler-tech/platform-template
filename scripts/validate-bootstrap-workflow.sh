#!/usr/bin/env bash

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
workflow="$repo_root/.github/workflows/bootstrap.yaml"
failures=0

fail() {
  echo "ERROR: $*" >&2
  failures=$((failures + 1))
}

permission_environments=$(
  yq -r '.jobs.bootstrap.steps[] | select(.name == "🎟️ Mint App token") | .with."permission-environments" // ""' "$workflow"
)
if [[ "$permission_environments" != "write" ]]; then
  fail "the bootstrap App token must request permission-environments: write"
fi

commit_script=$(
  yq -r '.jobs.bootstrap.steps[] | select(.name == "💾 Commit the rendered + encrypted tree") | .run' "$workflow"
)
if [[ -z "$commit_script" || "$commit_script" == "null" ]]; then
  fail "could not find the bootstrap commit-back script"
else
  test_root=$(mktemp -d)
  trap 'rm -rf "$test_root"' EXIT
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
