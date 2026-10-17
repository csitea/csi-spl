#!/bin/bash
#
# do_box_pkg_drift: report drift between the box and the manifest.
#
# Inputs:
#   BOX_CLASS: pc or satellite (read from box.env if unset)
#   DRIFT_STRICT: exit 2 on any NOT-IN-MANIFEST (default 0)
#
# Output:
#   MISSING-FROM-BOX: packages in the manifest but not on the box
#   NOT-IN-MANIFEST: packages on the box but not in the manifest, with agent id and reason when known
#

set -euo pipefail

# --- Inputs ---
BOX_CLASS=${BOX_CLASS:-}
DRIFT_STRICT=${DRIFT_STRICT:-0}

# --- Paths ---
BOX_PKG_DIR="${BOX_PKG_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../../cnf/box-pkgs}"
MANIFEST="${BOX_PKG_DIR}/${BOX_CLASS}.tsv"
BASE_LIST="${BOX_PKG_DIR}/base-${BOX_CLASS}.txt"
JOURNAL="${JOURNAL:-/var/lib/csi-spl/box-pkg/journal.tsv}"

# --- Helpers ---
fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Read the manifest ---
read_manifest() {
    awk -F '\t' '!/^#/ && NF == 7 { print $1 "\t" $2 }' "${MANIFEST}"
}

# --- Read the box state ---
apt_mark_showmanual() {
    if [[ -n "${BOX_PKG_STUB_APT_MARK}" ]]; then
        echo "${BOX_PKG_STUB_APT_MARK}"
    else
        apt-mark showmanual
    fi
}

read_installed_packages() {
    # apt-mark showmanual, minus the base list
    comm -23 <(apt_mark_showmanual | sort -u) <(sort -u "${BASE_LIST}")
}

read_journal() {
    # Journal: time, box, agent, issue, op, requested, closure, flag, snapshot, reason
    awk -F '\t' '!/^#/ && $5 == "install" {
        n_requested = split($6, requested, " ");
        n_closure = split($7, closure, " ");
        agent = $3;
        reason = (NF >= 10 ? $10 : "");
        for (i = 1; i <= n_requested; i++) if (requested[i] != "") print "apt\t" requested[i] "\t" agent "\t" reason;
        for (i = 1; i <= n_closure; i++) if (closure[i] != "") print "apt\t" closure[i] "\t" agent "\t" reason;
    }' "${JOURNAL}" 2>/dev/null || true
}

read_bin_dirs() {
    # /usr/local/bin and ~/.local/bin (agent user)
    find /usr/local/bin -type f -printf "bin\t%f\n" 2>/dev/null || true
    find "$(eval echo ~$(id -un ai-usr))/bin" -type f -printf "bin\t%f\n" 2>/dev/null || true
}

# --- Drift logic ---
report_drift() {
    local manifest_pkgs="$(read_manifest)"
    local installed_pkgs="$(read_installed_packages)"
    local journal_entries="$(read_journal)"
    local bin_entries="$(read_bin_dirs)"
    
    # Combine all box entries: apt packages + bin tools
    local box_entries="$(echo "${installed_pkgs}" | awk '{print "apt\t" $0}')"
    box_entries="${box_entries}
${bin_entries}"
    
    # MISSING-FROM-BOX: in manifest but not on box
    while read -r kind name; do
        if ! echo "${box_entries}" | grep -q "^${kind}\t${name}$"; then
            echo "MISSING-FROM-BOX ${name}"
        fi
    done < <(echo "${manifest_pkgs}")

    # NOT-IN-MANIFEST: on box but not in manifest
    local drift_strict_exit=0
    while read -r kind name; do
        if ! echo "${manifest_pkgs}" | grep -q "^${kind}\t${name}$"; then
            local journal_info="$(echo "${journal_entries}" | awk -F '\t' -v kind="${kind}" -v name="${name}" '$1 == kind && $2 == name { print $3 " " $4 }')"
            if [[ -n "${journal_info}" ]]; then
                echo "NOT-IN-MANIFEST ${name} (${journal_info})"
            else
                echo "NOT-IN-MANIFEST ${name}"
            fi
            drift_strict_exit=2
        fi
    done < <(echo "${box_entries}")
    
    if [[ "${DRIFT_STRICT}" -eq 1 && "${drift_strict_exit}" -eq 2 ]]; then
        exit 2
    fi
}

# --- Main ---
if [[ -z "${BOX_CLASS}" ]]; then
    # Read from box.env
    if [[ -f "/opt/csi/csi-spl/box.env" ]]; then
        source "/opt/csi/csi-spl/box.env"
        BOX_CLASS=${BOX_CLASS:-}
    fi
    [[ -n "${BOX_CLASS}" ]] || fail "BOX_CLASS not set and /opt/csi/csi-spl/box.env not found"
fi

[[ -f "${MANIFEST}" ]] || fail "Manifest not found: ${MANIFEST}"
[[ -f "${BASE_LIST}" ]] || fail "Base list not found: ${BASE_LIST}"

report_drift