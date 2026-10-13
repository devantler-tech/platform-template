# Contributing to the platform template

Improvements to the shared scaffold are welcome: a clearer explanation, a corrected manifest, a
safer default or a focused check. Discuss anything substantial in an
[issue](https://github.com/devantler-tech/platform-template/issues) first.

This guide is for the **public upstream template**, not for a platform created from it. A change
merged here reaches every such platform through the weekly template sync, so prefer additive,
backward-compatible changes and keep placeholders (`example.com`, `admin@example.com`,
`<INSTANCE_AGE_PUBLIC_KEY>`) in place of real values.

> **If you run a platform created from this template:** this file is yours to replace with your own
> process. It is listed in [`.templatesyncignore`](.templatesyncignore), so the sync leaves your
> version alone, but a platform created before the entry existed does not have it yet. Check that
> `CONTRIBUTING.md` is in **your** `.templatesyncignore` and commit it there before the next sync
> runs. If a sync pull request is already open, restore your guide and commit the entry before you
> merge it; the entry does not undo a change that is already proposed.

Never put credentials, real domains, private platform details or an undisclosed vulnerability in a
public issue or pull request. Report a vulnerability privately as [`SECURITY.md`](SECURITY.md)
describes.

## Make a first change

You need Git, [KSail](https://github.com/devantler-tech/ksail), `kubectl`,
[Mike Farah's yq v4](https://mikefarah.gitbook.io/yq/) and `jq`, plus network access: the renders
download pinned public charts and policies. No cluster, Docker engine, cloud account, GitHub App or
secret is needed, and none of the commands below contacts a cluster.

Fork `devantler-tech/platform-template` on GitHub, replace `YOUR-LOGIN` with your login, and work
from your fork:

```bash
git clone https://github.com/YOUR-LOGIN/platform-template.git
cd platform-template
git switch -c docs/first-contribution
```

Make a small wording improvement in `README.md`, then run the checks from the repository root:

```bash
ksail --config ksail.yaml workload validate
GHCR_TOKEN=placeholder ksail --config ksail.prod.yaml workload validate
./scripts/validate-shared-cluster-policies.sh
./scripts/validate-recommended-labels-option.sh
git diff --check
```

Every command must exit 0. Each `ksail` run takes a minute or two, prints one `✔ … validated` line
per directory and file, and ends with `✔ 265 files validated` (the number grows with the scaffold).
The two scripts each end with a `✓` line, and `git diff --check` prints nothing. `GHCR_TOKEN` is a
dummy value that lets a field in `ksail.prod.yaml` expand; nothing is pushed anywhere.

`⚠` lines are warnings, not failures. `skipped Helm render` means a chart could not be downloaded
(no network, or no registry access), so that release was checked as written and not rendered.
`Kyverno policy warning … not evaluable offline` means a rule needs a live namespace to decide.

Without KSail you can still confirm that both cluster entry points build, which catches a broken
reference but not a schema error:

```bash
kubectl kustomize k8s/clusters/local/ > /dev/null
kubectl kustomize k8s/clusters/prod/ > /dev/null
```

## Which checks a change needs

| You changed | Also run |
|---|---|
| Anything under `k8s/`, `talos*/`, or a `ksail*.yaml` file | The five commands above |
| The Coroot or audit-log-forwarder options | `./scripts/validate-observability-option.sh` |
| `.github/workflows/bootstrap.yaml` or its documented inputs | `./scripts/validate-bootstrap-workflow.sh` |
| A manifest's file or directory name | The naming check in [`AGENTS.md`](AGENTS.md#file-and-directory-naming-conventions) (needs Go) |

Do not edit `*.enc.yaml` files or [`.sops.yaml`](.sops.yaml): they are encrypted placeholders that
the bootstrap replaces. [`AGENTS.md`](AGENTS.md) explains where a manifest change belongs (a shared
base or one cluster's overlay) and the naming rules.

## What only hosted CI covers

A pull request to this repository runs
[`validate-scaffold.yaml`](.github/workflows/validate-scaffold.yaml), which repeats the checks above
with a pinned KSail version and adds the single sign-on redirect and default-deny network checks
under [`scripts/tests`](scripts/tests). [`ci.yaml`](.github/workflows/ci.yaml) checks manifest names
and scans the documentation for links to retired repositories, using the scope in
[`.github/retired-repo-links.json`](.github/retired-repo-links.json). That scan runs only here: a
platform created from the template owns its own scan scope and exceptions, and the sync leaves them
alone.

Nothing here starts a cluster. The system test on a throwaway cluster and the production deployment
run only in a platform created from the template, where the needed secrets exist. A green pull
request here therefore shows that the scaffold renders and passes its contracts, not that it has
been deployed.

## Submit your change

Review the diff, set up commit signing, and stage only the paths you changed. For the README-only
first change:

```bash
git add README.md
git commit -S -m "docs: clarify platform template onboarding"
git push -u origin docs/first-contribution
```

Open a **draft** pull request to `devantler-tech/platform-template:main` using the inherited
[pull request template](https://github.com/devantler-tech/.github/blob/main/.github/PULL_REQUEST_TEMPLATE.md).
Give it a [Conventional Commit](https://www.conventionalcommits.org) title, since releases are cut
from the titles. Say in plain language what problem the change solves and for whom, link the issue
for substantial work, and disclose AI assistance when you used it. Pin any GitHub Action you add to
a full commit hash. Required CI and a review of the current head must pass before merge.

Follow the inherited
[code of conduct](https://github.com/devantler-tech/.github/blob/main/.github/CODE_OF_CONDUCT.md)
and keep the [license](LICENSE). Installing the GitHub App, running the Bootstrap workflow and
anything that needs a Hetzner or Cloudflare account are steps for someone running their own
platform, not for contributing here.
