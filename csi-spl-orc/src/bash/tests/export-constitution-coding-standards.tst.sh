#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_export_constitution_coding_standards (spec 135,
#          coding-standards-panel-plan.md build row 02) copies the developer
#          guide's Coding Standards section, cut by its qto node anchor, into
#          the constitution's BEGIN/END CODING STANDARDS block.
#   1. a fixture guide with a planted anchor: the block is written, the
#      slice runs from the anchor to the next "## " anchor (a "### " anchor
#      inside stays), the envelope outside the markers is untouched, the
#      version goes one patch past the higher of body and footer, the dates
#      are the stamp time
#   2. a second run changes nothing (no version bump); DRY_RUN=1 on the
#      synced pair exits 0
#   3. DRY_RUN=1 after the guide changed exits 1 with the diff, writes nothing
#   4. a section that ends at the end of the file; a "# " anchor also ends
#      it; the patch step is numeric (0.2.9 -> 0.2.10)
#   5. CONTROLS, each non-zero and the constitution byte-identical: a
#      duplicate END marker, a missing BEGIN marker, END before BEGIN, the
#      anchor missing, the anchor twice, an anchor with no "## " heading,
#      no node id, a bad node id, no footer version line, two body version
#      lines
#   Nothing outside the throwaway dir is written.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0 passes=0
pass() { echo "PASS: $1"; passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
do_log() { echo "$*"; }
# shellcheck source=/dev/null
source "$PROJ_ROOT/src/bash/run/spl-export-constitution-coding-standards.func.sh"

N=aaaaaaaa-1111-4111-8111-111111111111
NOW=2026-10-24T12:00:00Z
G="$T/guide.md" C="$T/constitution.md"
export EXPORT_CS_GUIDE="$G" EXPORT_CS_CONSTITUTION="$C" EXPORT_CS_NODE="$N" EXPORT_CS_NOW="$NOW"

mk_guide() {  # [section 2 body line]
  cat >"$G" <<EOF
# Developer guide

<a id="ws-doc-11111111-0000-4000-8000-000000000001"></a>
## 1. The strategy

one

<a id="ws-doc-$N"></a>
## 2. Coding standards

${1:-Every rule.}

<a id="ws-doc-11111111-0000-4000-8000-000000000002"></a>
### 2.1 Small functions

80 lines.

<a id="ws-doc-11111111-0000-4000-8000-000000000003"></a>
## 3. Never force-push

three
EOF
}

want_slice() {
  cat <<EOF
<a id="ws-doc-$N"></a>
## 2. Coding standards

Every rule.

<a id="ws-doc-11111111-0000-4000-8000-000000000002"></a>
### 2.1 Small functions

80 lines.
EOF
}

mk_con() {  # [body version] [footer version]
  cat >"$C" <<EOF
<!-- Sync Impact Report -->
# csi-spl Constitution

## Core Principles

<!-- BEGIN CODING STANDARDS (exported from developer-guide.md; DO NOT EDIT DIRECTLY) -->
old block
<!-- END CODING STANDARDS -->

## Governance
  \`<!-- version: X · updated: DATE · last-edit: ISO-8601-UTC -->\` (a template)

**Version**: ${1:-0.2.0} | **Ratified**: 2026-09-18 | **Last Amended**: 2026-09-18 (added csi-spl-api)

<!-- version: ${2:-0.2.1} · updated: 2026-09-18 · last-edit: 2026-09-18T16:15:00Z -->
EOF
}

run() { do_spl_export_constitution_coding_standards >"$T/out" 2>&1; }

# 1. the first export
mk_guide; mk_con
rc=0; run || rc=$?
block="$(awk '/^<!-- BEGIN CODING/{f=1; next} /^<!-- END CODING/{f=0} f' "$C" | sed '1{/^$/d}' | sed '${/^$/d}')"
if (( rc == 0 )) && [[ "$block" == "$(want_slice)" ]]; then pass "1a the block holds the slice, the ### anchor kept, the ## 3 anchor not"; else fail "1a rc=$rc block: $block / $(cat "$T/out")"; fi
if grep -qx '\*\*Version\*\*: 0.2.2 | \*\*Ratified\*\*: 2026-09-18 | \*\*Last Amended\*\*: 2026-10-24 (Coding Standards exported from developer-guide.md)' "$C" \
  && grep -qx '<!-- version: 0.2.2 · updated: 2026-10-24 · last-edit: 2026-10-24T12:00:00Z -->' "$C"; then
  pass "1b body and footer: 0.2.2 (past the higher 0.2.1), dated $NOW"
else fail "1b version lines: $(grep -n 'ersion' "$C")"; fi
env_out="$(awk '/^<!-- BEGIN CODING/{f=1} !f; /^<!-- END CODING/{f=0}' "$C" | grep -v 'ersion')"
env_in="$(mk_con; awk '/^<!-- BEGIN CODING/{f=1} !f; /^<!-- END CODING/{f=0}' "$C" | grep -v 'ersion')"
mk_guide; mk_con; run
if [[ "$env_out" == "$env_in" ]] && grep -qF '(a template)' "$C"; then pass "1c the envelope outside the markers is untouched (the quoted template line too)"; else fail "1c envelope differs"; fi

# 2. idempotent
sum1="$(md5sum <"$C")"; rc=0; run || rc=$?
if (( rc == 0 )) && [[ "$(md5sum <"$C")" == "$sum1" ]] && grep -q 'nothing written' "$T/out"; then pass "2a a second run changes nothing, no bump"; else fail "2a rc=$rc $(cat "$T/out")"; fi
rc=0; DRY_RUN=1 run || rc=$?
if (( rc == 0 )) && [[ "$(md5sum <"$C")" == "$sum1" ]]; then pass "2b DRY_RUN=1 on the synced pair exits 0"; else fail "2b rc=$rc $(cat "$T/out")"; fi

# 3. the check after the guide moved
mk_guide "Every rule, now with a gate."
rc=0; DRY_RUN=1 run || rc=$?
if (( rc == 1 )) && [[ "$(md5sum <"$C")" == "$sum1" ]] && grep -q '^+Every rule, now with a gate.' "$T/out" && grep -q 'FAIL the constitution' "$T/out"; then
  pass "3 DRY_RUN=1 on a moved guide exits 1 with the diff, writes nothing"
else fail "3 rc=$rc $(cat "$T/out")"; fi

# 4. the section's other ends, the numeric patch step
mk_guide; head -n 17 "$G" >"$T/g2"; cp "$T/g2" "$G"; mk_con 0.2.9 0.2.3
rc=0; run || rc=$?
block="$(awk '/^<!-- BEGIN CODING/{f=1; next} /^<!-- END CODING/{f=0} f' "$C" | sed '1{/^$/d}' | sed '${/^$/d}')"
if (( rc == 0 )) && [[ "$block" == "$(want_slice)" ]] && grep -q '^\*\*Version\*\*: 0.2.10 ' "$C"; then pass "4a a section ending at EOF; 0.2.9 -> 0.2.10"; else fail "4a rc=$rc $block $(grep Version "$C")"; fi
mk_guide; sed -i 's/^## 3\. Never force-push/# Appendix/' "$G"; mk_con
rc=0; run || rc=$?
block="$(awk '/^<!-- BEGIN CODING/{f=1; next} /^<!-- END CODING/{f=0} f' "$C" | sed '1{/^$/d}' | sed '${/^$/d}')"
if (( rc == 0 )) && [[ "$block" == "$(want_slice)" ]]; then pass "4b a '# ' anchor ends the section too"; else fail "4b rc=$rc $block"; fi

# 5. controls: refused, the constitution byte-identical
control() {  # <label> <want text> <setup cmd>
  local label="$1" want="$2" before rc=0
  # shellcheck disable=SC2034 # EXPORT_CS_NODE_ID is the sourced action's
  EXPORT_CS_NODE="$N" EXPORT_CS_NODE_ID=""
  mk_guide; mk_con; eval "$3"; before="$(md5sum <"$C")"
  run || rc=$?
  if (( rc != 0 )) && [[ "$(md5sum <"$C")" == "$before" ]] && grep -qF -- "$want" "$T/out"; then pass "5 CONTROL $label: rc $rc, unchanged"
  else fail "5 CONTROL $label: rc=$rc, changed=$([[ "$(md5sum <"$C")" == "$before" ]] && echo no || echo yes), out: $(cat "$T/out")"; fi
}
control "duplicate END marker" "want one END CODING STANDARDS marker, found lines: 8 9" \
  "sed -i '8a <!-- END CODING STANDARDS -->' \"\$C\""
control "missing BEGIN marker" "want one BEGIN CODING STANDARDS marker, found lines: none" \
  "sed -i '/^<!-- BEGIN CODING/d' \"\$C\""
control "END before BEGIN" "is before the BEGIN marker" \
  "printf '<!-- END CODING STANDARDS -->\n<!-- BEGIN CODING STANDARDS -->\nx\n**Version**: 0.1.0 | x\n<!-- version: 0.1.0 · x -->\n' >\"\$C\""
control "anchor missing" "appears 0 times, want 1" "sed -i '/ws-doc-$N/d' \"\$G\""
control "anchor twice" "appears 2 times, want 1" "printf '<a id=\"ws-doc-%s\"></a>\n## again\n' $N >>\"\$G\""
control "anchor with no ## heading" "is not followed by a '## ' heading" "sed -i 's/^## 2\. Coding standards/### 2. Coding standards/' \"\$G\""
control "no node id" "node id is not set" "EXPORT_CS_NODE= EXPORT_CS_NODE_ID="
control "bad node id" "not a uuid ('nope')" "EXPORT_CS_NODE=nope"
control "no footer version" "want one '<!-- version: X.Y.Z' footer line, found: none" "sed -i '/^<!-- version: 0/d' \"\$C\""
control "two body versions" "want one '**Version**: X.Y.Z' line" "printf '**Version**: 0.9.0 | x\n' >>\"\$C\""
echo "export-constitution-coding-standards: $passes passed, $fails failed"
(( fails == 0 ))
