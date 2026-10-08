#!/usr/bin/env bash
# test-harness-parity.sh — the harness stays whole for all four agent kinds,
# and for the fifth (mistral, specs/110-mistral-vendor) as far as it is built
# (specs/048-agent-harness-parity §3.1). csi-spl is the canonical harness; the
# box engine it was forked from is frozen, and harness-parity.tsv says where
# each of its files went.
#
#   1. every manifest row has a known disposition and a target; a ported or
#      replaced target exists here; a deferred row names its spool issue; an
#      added target exists here; a planned row names its task (spec110:T005)
#   2. every kind (claude grok agy qwen) has: an executable adapter, an id
#      prefix, a spool-agent.sh branch, an installer branch, an MCP
#      registration branch, a /<kind>-spawn command and a trust store;
#      mistral has its /mistral-spawn command (the rest is planned, spec 110)
#   3. every template the installer renders carries only known placeholders
#   4. with HARNESS_REF_DIR=<the frozen reference feature dir>: every file of
#      it has exactly one row and no row names a file it does not have
#      (added and planned rows are new since the freeze, so not compared). This
#      is the check that catches a harness gap; it needs the private reference
#      (./run -a do_check_harness_parity), so CI runs 1-3 only.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
MAN="$T_FEAT/harness-parity.tsv"
ORC_DIR="$(cd "$T_FEAT/../../../.." && pwd)"

check "the manifest exists" test -r "$MAN"
rows() { grep -v '^#' "$MAN" | grep -v '^[[:space:]]*$'; }

# --- 1. rows ------------------------------------------------------------------
bad="" missing="" nokey="" notask="" landed=""
while IFS=$'\t' read -r ref disp target; do
  case "$disp" in
    ported|replaced|added) [ -e "$T_FEAT/$target" ] || missing="$missing $ref->$target" ;;
    deferred) [[ "$target" =~ ^SPL-[0-9]+$ ]] || nokey="$nokey $ref" ;;
    planned) [[ "$target" =~ ^spec[0-9]{3}:T[0-9]{3}[a-z]?$ ]] || notask="$notask $ref"
             [ -e "$T_FEAT/$ref" ] && landed="$landed $ref" ;;
    excluded) [ -n "$target" ] || bad="$bad $ref(no reason)" ;;
    *) bad="$bad $ref($disp)" ;;
  esac
done < <(rows)
eq "1. every row has a known disposition and a target" "" "$bad"
eq "1. every ported/replaced/added target exists in this feature" "" "$missing"
eq "1. every deferred row names its spool issue" "" "$nokey"
eq "1. every planned row names its task (spec<NNN>:T<NNN>)" "" "$notask"
[ -z "$landed" ] || echo "   note: planned but already here, flip the row to added:$landed"
eq "1. no reference path appears twice" "" "$(rows | cut -f1 | sort | uniq -d | tr '\n' ' ')"
echo "   manifest: $(rows | cut -f2 | sort | uniq -c | tr -s ' ' | tr '\n' ',')"

# --- 2. the four kinds ------------------------------------------------------------
. "$T_FEAT/lib/spool-env.inc.sh"
INSTALL="$T_FEAT/../spool-install/install.sh"
MCP_ACTION="$ORC_DIR/src/bash/run/spl-agent-mcp-install.func.sh"
for k in claude grok agy qwen; do
  p="$(spool_prefix_of_kind "$k")"
  check "2. $k: an id prefix ($p)" test -n "$p"
  check "2. $k: an executable adapter spawn-$k.sh" test -x "$T_SCRIPTS/spawn-$k.sh"
  check "2. $k: its adapter declares SPAWN_ID_PREFIX=$p" grep -qx "SPAWN_ID_PREFIX=$p" "$T_SCRIPTS/spawn-$k.sh"
  check "2. $k: spool-agent.sh starts it" grep -qE "^  $k\) +PREFIX=$p; KIND=$k ;;" "$T_SCRIPTS/spool-agent.sh"
  check "2. $k: spawn-window.sh takes it" grep -qE 'case "\$KIND" in [a-z|]*\b'"$k"'\b' "$T_SCRIPTS/spawn-window.sh"
  check "2. $k: install.sh --cli takes it" grep -qE "case \"\\\$c\" in [a-z|]*\\b$k\\b[a-z|]*\\) ;;" "$INSTALL"
  check "2. $k: do_spl_agent_mcp_install registers it" grep -qE "^        $k\) +as_agent " "$MCP_ACTION"
  check "2. $k: trust-workdir.sh has its store" grep -qE "^    \"$k\": \(" "$T_SCRIPTS/trust-workdir.sh"
  check "2. $k: a /$k-spawn command" test -r "$T_FEAT/assets/commands/$k-spawn.md"
done
check "2. mistral: a /mistral-spawn command" test -r "$T_FEAT/assets/commands/mistral-spawn.md"
check "2. mistral: /mistral-spawn starts the mistral kind" grep -q 'spawn-window.sh mistral auto' "$T_FEAT/assets/commands/mistral-spawn.md"

# --- 3. placeholders ----------------------------------------------------------------
eq "3. the templates use only HARNESS_DIR, SPOOL_ROOT, AGENT_CEILING, ORCHESTRATOR_ID" "" \
  "$(grep -rhoE '\{\{[A-Za-z_]+\}\}' "$T_FEAT/assets" | sort -u | grep -vxE '\{\{(HARNESS_DIR|SPOOL_ROOT|AGENT_CEILING|ORCHESTRATOR_ID)\}\}' | tr '\n' ' ')"

# --- 4. the frozen reference ------------------------------------------------------------
if [ -n "${HARNESS_REF_DIR:-}" ]; then
  if [ -d "$HARNESS_REF_DIR" ]; then
    ref_files="$(cd "$HARNESS_REF_DIR" && find . -type f -not -path '*/.git/*' | sed 's|^\./||' | sort)"
    man_files="$(rows | awk -F'\t' '$2 != "added" && $2 != "planned" {print $1}' | sort)"
    eq "4. every reference file has a row" "" "$(comm -23 <(printf '%s\n' "$ref_files") <(printf '%s\n' "$man_files") | tr '\n' ' ')"
    eq "4. no row names a file the reference lacks" "" "$(comm -13 <(printf '%s\n' "$ref_files") <(printf '%s\n' "$man_files") | tr '\n' ' ')"
    echo "   reference: $(printf '%s\n' "$ref_files" | wc -l) files"
  else
    nok "4. HARNESS_REF_DIR is not a directory: $HARNESS_REF_DIR"
  fi
else
  echo "   4. skipped: HARNESS_REF_DIR unset (the frozen reference is private)"
fi
t_done
