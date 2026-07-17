#!/usr/bin/env bash
# Enforce the repo's manifest folder/file naming conventions (see AGENTS.md).
#
# Pure bash + POSIX awk/sed; no cluster, no network, bash 3.2 compatible.
# Run from anywhere:
#
#     ./scripts/validate-naming.sh
#
# Exits non-zero (and prints a grouped report) on any violation. A bash port
# of the reference platform's naming gate (platform#2315), covering:
#   1. Every directory under k8s/ is kebab-case.
#   2. Exactly one Kubernetes resource per file (vendored upstream bundles
#      exempt).
#   3. Flux Kustomization CRs (kustomize.toolkit.fluxcd.io) live only in
#      flux-kustomization*.yaml.
#   4. Kustomize build files (kustomize.config.k8s.io) live only in
#      kustomization.yaml.
#   5. In a component folder, a single-resource file's name leads with the
#      kebab-cased Kind (<kind>.yaml or <kind>-<purpose>.yaml). CR folders,
#      patch fragments (under patches/) and kustomization.yaml are exempt.
#   6. A folder that groups multiple instances of a single (non-workload)
#      Kind is a CR folder and must be named the kebab-cased plural of that
#      Kind. Organizational subfolders inside a known CR folder are exempt.
#   7. Patch fragments live under a patches/ directory and never carry a
#      redundant -patch suffix.
#   8. Files under patches/ are named by intent (<verb>-<purpose>.yaml) and
#      must not lead with the patched resource's Kind (a Flux Kustomization
#      CR patch keeps the flux-kustomization prefix per check 3).
#   9. Talos machine-config patches (talos*/ at the repo root) hold ONE YAML
#      document per file, in kebab-case, intent-describing files.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

# Vendored upstream operator bundles — synced verbatim, exempt from
# one-per-file.
one_resource_exempt="
k8s/bases/infrastructure/controllers/cdi/cdi-operator.yaml
k8s/bases/infrastructure/controllers/kubevirt/kubevirt-operator.yaml
"

# Instance-owned bootstrap variable files (.templatesyncignore's variables-*
# patterns). Renaming these to the Kind-led convention would make template-sync
# inject template-default values over an instance's tailored production config
# (the ignore patterns would no longer match), so they keep their names and are
# exempt from the Kind-led filename check.
instance_owned_exempt="
k8s/bases/bootstrap/variables-base-config-map.yaml
k8s/bases/bootstrap/variables-base-secret.enc.yaml
k8s/clusters/local/bootstrap/variables-cluster-config-map.yaml
k8s/clusters/local/bootstrap/variables-cluster-secret.enc.yaml
k8s/clusters/prod/bootstrap/variables-cluster-config-map.yaml
k8s/clusters/prod/bootstrap/variables-cluster-secret.enc.yaml
"

# CR folders: files are named <verb>-<purpose>.yaml (Kind implied by the
# folder). Extend this list when introducing a new plural-Kind folder.
cr_dir_paths="
k8s/bases/bootstrap/priority-classes
k8s/bases/infrastructure/alerts
k8s/bases/infrastructure/cluster-policies
k8s/bases/infrastructure/cluster-role-bindings
k8s/bases/infrastructure/cluster-roles
k8s/bases/infrastructure/cluster-secret-stores
k8s/bases/infrastructure/cluster-security-exceptions
k8s/bases/infrastructure/controllers/testkube/custom-resource-definitions
k8s/bases/infrastructure/external-secrets
k8s/bases/infrastructure/http-scaled-objects
k8s/bases/infrastructure/tracing-policies
k8s/providers/docker/infrastructure/cluster-issuers
k8s/providers/hetzner/infrastructure/cluster-issuers
"

# Kinds that define a component (a folder of them is named by app, not a CR
# folder).
workload_kinds=" HelmRelease HelmRepository Deployment StatefulSet DaemonSet ReplicaSet Pod Job CronJob OCIRepository Kustomization Component "

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
touch "${tmp}/folder_kinds"
for f in bad_dirs multi flux_bad build_bad kind_bad cr_name_bad \
	patch_suffix patch_misplaced patch_kind_bad talos_multi talos_kind_bad; do
	: >"${tmp}/${f}"
done

is_kebab() {
	case "$1" in
	*[!a-z0-9-]* | -* | *- | *--*) return 1 ;;
	'') return 1 ;;
	*) return 0 ;;
	esac
}

# CamelCase Kind -> kebab-case (VerticalPodAutoscaler -> vertical-pod-autoscaler).
kebab_kind() {
	printf '%s\n' "$1" |
		sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z])([A-Z][a-z])/\1-\2/g' |
		tr '[:upper:]' '[:lower:]'
}

# Pluralize the last hyphen-segment of a kebab name (English rules).
pluralize() {
	head=""
	last="$1"
	case "$1" in *-*)
		head="${1%-*}-"
		last="${1##*-}"
		;;
	esac
	case "${last}" in
	*s | *x | *z | *ch | *sh) last="${last}es" ;;
	*[!aeiou]y) last="${last%y}ies" ;;
	*) last="${last}s" ;;
	esac
	printf '%s%s' "${head}" "${last}"
}

# Emit "NDOCS <n>" (documents with non-comment content) then one
# "DOC <apiVersion>|<kind>" line per top-level kind-bearing document.
parse_docs() {
	awk '
		# chunk MUST start numeric: uninitialized awk variables are "" as an
		# array subscript, so a file with no leading --- would store under
		# content[""] while the END loop reads content[0] — silently skipping
		# every such file (a false-negative gate).
		BEGIN { chunk = 0 }
		/^---[ \t]*$/ { chunk++; next }
		{
			line = $0; sub(/\r$/, "", line)
			if (line !~ /^[ \t]*#/ && line !~ /^[ \t]*$/) content[chunk] = 1
			if (line ~ /^kind:[ \t]*[^ \t]/) {
				k = line; sub(/^kind:[ \t]*/, "", k); sub(/[ \t]+$/, "", k); kind[chunk] = k
			}
			if (line ~ /^apiVersion:[ \t]*[^ \t]/) {
				a = line; sub(/^apiVersion:[ \t]*/, "", a); sub(/[ \t]+$/, "", a); api[chunk] = a
			}
		}
		END {
			n = 0
			for (i = 0; i <= chunk; i++) if (content[i]) n++
			print "NDOCS " n
			for (i = 0; i <= chunk; i++) if (kind[i]) print "DOC " api[i] "|" kind[i]
		}
	' "$1"
}

in_cr() {
	for d in ${cr_dir_paths}; do
		case "$1" in "${d}" | "${d}"/*) return 0 ;; esac
	done
	return 1
}

in_cr_subfolder() {
	for d in ${cr_dir_paths}; do
		case "$1" in "${d}"/*) return 0 ;; esac
	done
	return 1
}

# --- k8s/ ---------------------------------------------------------------
while IFS= read -r dir; do
	is_kebab "$(basename "${dir}")" || printf '%s\n' "${dir}" >>"${tmp}/bad_dirs"
done < <(find k8s -mindepth 1 -type d)

while IFS= read -r file; do
	fn="$(basename "${file}")"
	case "${fn}" in
	*.enc.yaml) stem="${fn%.enc.yaml}" ;;
	*.yaml) stem="${fn%.yaml}" ;;
	*.yml) stem="${fn%.yml}" ;;
	*) continue ;;
	esac
	dir="$(dirname "${file}")"
	case "${file}" in */patches/*) in_patch=1 ;; *) in_patch=0 ;; esac

	# Kebab-case applies to every k8s file stem, not just directories — the
	# Kind-led check alone accepts any suffix after "<kind>-" (config-map-BAD
	# would pass it). CR folders are exempt: they hold vendored upstream files
	# whose names (e.g. testkube CRD dumps) are synced verbatim.
	if ! in_cr "${dir}" && ! is_kebab "${stem%.enc}"; then
		printf '%s\n' "${file}" >>"${tmp}/bad_dirs"
	fi

	case "${stem}" in *-patch)
		if [ "${in_patch}" = 1 ]; then
			printf '%s\n' "${file}" >>"${tmp}/patch_suffix"
		else
			printf '%s\n' "${file}" >>"${tmp}/patch_misplaced"
		fi
		;;
	esac

	parsed="$(parse_docs "${file}")"
	kind_docs="$(printf '%s\n' "${parsed}" | grep -c '^DOC ')" || true
	if [ "${kind_docs}" = 0 ]; then
		# Kind-less content (a JSON6902 fragment) is still a patch: it must
		# live under patches/ — skipping it entirely would let a fragment
		# named by intent sit anywhere and pass the gate.
		ndocs="$(printf '%s\n' "${parsed}" | sed -n 's/^NDOCS //p')"
		if [ "${ndocs}" -gt 0 ] && [ "${in_patch}" = 0 ] && [ "${fn}" != "kustomization.yaml" ]; then
			printf '%s\n' "${file}" >>"${tmp}/patch_misplaced"
		fi
		continue
	fi
	if [ "${kind_docs}" -gt 1 ]; then
		case "${one_resource_exempt}" in *"
${file}
"*) continue ;; esac
		kinds="$(printf '%s\n' "${parsed}" | sed -n 's/^DOC .*|//p' | tr '\n' ',' | sed 's/,$//')"
		printf '%s  ->  [%s]\n' "${file}" "${kinds}" >>"${tmp}/multi"
		continue
	fi

	doc="$(printf '%s\n' "${parsed}" | sed -n 's/^DOC //p')"
	api="${doc%%|*}"
	kind="${doc#*|}"
	if [ "${fn}" != "kustomization.yaml" ] && [ "${in_patch}" = 0 ]; then
		printf '%s\t%s\n' "${dir}" "${kind}" >>"${tmp}/folder_kinds"
	fi
	if [ "${kind}" = "Kustomization" ]; then
		case "${api}" in kustomize.toolkit.fluxcd.io*)
			case "${fn}" in flux-kustomization*) ;; *) printf '%s\n' "${file}" >>"${tmp}/flux_bad" ;; esac
			continue
			;;
		esac
	fi
	case "${kind}" in Kustomization | Component)
		case "${api}" in kustomize.config.k8s.io*)
			[ "${fn}" != "kustomization.yaml" ] && printf '%s\n' "${file}" >>"${tmp}/build_bad"
			continue
			;;
		esac
		;;
	esac
	if [ "${fn}" = "kustomization.yaml" ] || in_cr "${dir}"; then
		continue
	fi
	case "${instance_owned_exempt}" in *"
${file}
"*) continue ;; esac
	kb="$(kebab_kind "${kind}")"
	if [ "${in_patch}" = 1 ]; then
		case "${stem}" in "${kb}" | "${kb}"-*)
			printf '%s  (kind %s -> name it <verb>-<purpose>.yaml, not %s-*)\n' \
				"${file}" "${kind}" "${kb}" >>"${tmp}/patch_kind_bad"
			;;
		esac
		continue
	fi
	case "${stem}" in "${kb}" | "${kb}"-*) ;; *)
		printf '%s  (kind %s -> expected %s.yaml or %s-<purpose>.yaml)\n' \
			"${file}" "${kind}" "${kb}" "${kb}" >>"${tmp}/kind_bad"
		;;
	esac
done < <(find k8s -type f \( -name '*.yaml' -o -name '*.yml' \))

# Check 6: a folder grouping >=2 instances of one non-workload Kind is a CR
# folder and must be named the kebab-cased plural of that Kind.
while IFS= read -r dir; do
	kinds="$(awk -F'\t' -v d="${dir}" '$1 == d { print $2 }' "${tmp}/folder_kinds")"
	n="$(printf '%s\n' "${kinds}" | grep -c .)" || true
	[ "${n}" -lt 2 ] && continue
	uniq_kinds="$(printf '%s\n' "${kinds}" | sort -u)"
	[ "$(printf '%s\n' "${uniq_kinds}" | grep -c .)" != 1 ] && continue
	kind="${uniq_kinds}"
	case "${workload_kinds}" in *" ${kind} "*) continue ;; esac
	in_cr_subfolder "${dir}" && continue
	expected="$(pluralize "$(kebab_kind "${kind}")")"
	if [ "$(basename "${dir}")" != "${expected}" ]; then
		printf '%s  (%s grouping -> expected folder %s/)\n' \
			"${dir}" "${kind}" "${expected}" >>"${tmp}/cr_name_bad"
	fi
done < <(cut -f1 "${tmp}/folder_kinds" | sort -u)

# --- Check 9: talos*/ machine-config patch dirs --------------------------
for talos_dir in talos*/; do
	[ -d "${talos_dir}" ] || continue
	while IFS= read -r dir; do
		is_kebab "$(basename "${dir}")" || printf '%s\n' "${dir}" >>"${tmp}/bad_dirs"
	done < <(find "${talos_dir%/}" -mindepth 1 -type d)
	while IFS= read -r file; do
		fn="$(basename "${file}")"
		case "${fn}" in
		*.yaml) stem="${fn%.yaml}" ;;
		*.yml) stem="${fn%.yml}" ;;
		*) continue ;;
		esac
		is_kebab "${stem}" || printf '%s\n' "${file}" >>"${tmp}/bad_dirs"
		case "${stem}" in *-patch) printf '%s\n' "${file}" >>"${tmp}/patch_suffix" ;; esac
		parsed="$(parse_docs "${file}")"
		ndocs="$(printf '%s\n' "${parsed}" | sed -n 's/^NDOCS //p')"
		if [ "${ndocs}" -gt 1 ]; then
			printf '%s  (%s documents -> split, one per file)\n' "${file}" "${ndocs}" >>"${tmp}/talos_multi"
			continue
		fi
		kind_docs="$(printf '%s\n' "${parsed}" | grep -c '^DOC ')" || true
		if [ "${kind_docs}" = 1 ]; then
			kind="$(printf '%s\n' "${parsed}" | sed -n 's/^DOC .*|//p')"
			kb="$(kebab_kind "${kind}")"
			case "${stem}" in "${kb}" | "${kb}"-*)
				printf '%s  (kind %s -> name it <verb>-<purpose>.yaml, not %s-*)\n' \
					"${file}" "${kind}" "${kb}" >>"${tmp}/talos_kind_bad"
				;;
			esac
		fi
	done < <(find "${talos_dir%/}" -type f \( -name '*.yaml' -o -name '*.yml' \))
done

# --- Report ---------------------------------------------------------------
problems=0
report() {
	title="$1"
	f="$2"
	[ -s "${f}" ] || return 0
	n="$(grep -c . "${f}")"
	problems=$((problems + n))
	printf '\n✗ %s (%s):\n' "${title}" "${n}"
	sort "${f}" | sed 's/^/   /'
}

report "Directories or filenames not kebab-case" "${tmp}/bad_dirs"
report "Files with more than one resource" "${tmp}/multi"
report "Flux Kustomization CRs not named flux-kustomization*.yaml" "${tmp}/flux_bad"
report "Kustomize build files not named kustomization.yaml" "${tmp}/build_bad"
report "Filename does not lead with its Kind" "${tmp}/kind_bad"
report "CR-grouping folder not named by Kind plural" "${tmp}/cr_name_bad"
report "Patch fragments outside a patches/ directory" "${tmp}/patch_misplaced"
report "Patch filenames with redundant -patch suffix" "${tmp}/patch_suffix"
report "Patch filename leads with the patched Kind instead of intent" "${tmp}/patch_kind_bad"
report "Talos patch files with more than one YAML document" "${tmp}/talos_multi"
report "Talos patch filename leads with the document kind instead of intent" "${tmp}/talos_kind_bad"

if [ "${problems}" -gt 0 ]; then
	printf '\n%s naming violation(s). See AGENTS.md manifest naming conventions.\n' "${problems}"
	exit 1
fi
echo "✓ All manifest naming conventions satisfied."
