#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 142 row B1 -- the package manifests per box class,
#          cnf/box-pkgs/{pc,satellite}.tsv and base-{pc,satellite}.txt.
#          Hermetic: it reads only repo files and temp fixtures; apt-get,
#          apt-mark, dpkg-query and sudo are stubs that fail the test if run.
#          1. pc.tsv and satellite.tsv: 7 columns, a fixed kind, a name,
#             needed_by never empty, a known service, an added date + issue,
#             sorted by kind then name, no duplicate row, and every
#             installed_by resolves: `play <role>` to a role dir of
#             060-gcp-vm-satellite, `do_*` to a function in a .func.sh of the
#             repo, `spool-install [--cli <name>]` to the agent-tool installer
#             and a <name> its --cli takes (SPL-2339: the agent CLIs and the
#             kill guard it writes), `backfill` only on a row whose added
#             says backfill
#          2. every satellite-replica.tsv tool has a satellite.tsv row
#          3. the base lists hold packages, none also named by the manifest
#          4. fixtures: a bad kind, 6 columns, `play no_such_role`, a
#             `backfill` installer on a non-backfill row, `spool-install --cli`
#             of a CLI it does not take, an unsorted file and a replica tool
#             without a row each FAIL
#
#          CONTROLS (row B1): a row with an empty needed_by and a row naming
#          do_no_such_action must each turn case 1 red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../../.." && pwd)
DIR="$REPO/csi-spl-iac/cnf/box-pkgs"
ROLES="$REPO/csi-spl-iac/src/terraform/060-gcp-vm-satellite/roles"
REPLICA="$REPO/csi-spl-iac/cnf/satellite-replica.tsv"
SPOOL_INSTALL="$REPO/csi-spl-orc/src/bash/features/spool-install/install.sh"
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/stub"
for b in apt-get apt-mark dpkg-query sudo; do
  printf '#!/bin/sh\necho "FAIL: the test ran %s" >&2\nexit 99\n' "$b" >"$tmp/stub/$b"
  chmod +x "$tmp/stub/$b"
done
export PATH="$tmp/stub:$PATH"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# every do_* function the repo defines, one per line
DO_FUNCS="$tmp/do-funcs"
grep -rhoE '^do_[a-z0-9_]+\(\)' --include='*.func.sh' \
  "$REPO/csi-spl-iac" "$REPO/csi-spl-orc" "$REPO/csi-spl-utl" 2>/dev/null |
  sed 's/()$//' | LC_ALL=C sort -u >"$DO_FUNCS"

# the CLIs `spool-install --cli` takes: its `case "$c" in a|b|...)` line
SPOOL_CLIS="$(grep -oE 'case "\$c" in [a-z|]+\)' "$SPOOL_INSTALL" 2>/dev/null |
  sed -nE '1s/.* in ([a-z|]+)\)/\1/p')"

# _bpm_installed_by <installed_by> <added>: rc 0 when the installer resolves
_bpm_installed_by() {
  local by="$1" added="$2"
  case "$by" in
    "play "*) [[ -n "${by#play }" && -d "$ROLES/${by#play }" ]] ;;
    backfill) [[ "$added" == *backfill* ]] ;;
    do_*) grep -qxF -- "$by" "$DO_FUNCS" ;;
    spool-install) [[ -f "$SPOOL_INSTALL" ]] ;;
    "spool-install --cli "*) [[ -f "$SPOOL_INSTALL" && "|$SPOOL_CLIS|" == *"|${by#spool-install --cli }|"* ]] ;;
    *) return 1 ;;
  esac
}

# _bpm_row <file> <line no> <line>: one FAIL line per broken rule of a row
_bpm_row() {
  local f="$1" n="$2" line="$3" kind name pin by need svc added cols
  cols=$(awk -F '\t' '{print NF}' <<<"$line")
  [[ "$cols" == 7 ]] || { echo "$f:$n: $cols columns, want 7"; return 0; }
  # a TAB is IFS whitespace, so read would merge the empty fields: split on US
  IFS=$'\x1f' read -r kind name pin by need svc added <<<"${line//$'\t'/$'\x1f'}"
  case "$kind" in
    apt | deb | bin | pip | npm | go | corepack | image) ;;
    *) echo "$f:$n: kind '$kind' not in the fixed set" ;;
  esac
  [[ -n "$name" ]] || echo "$f:$n: empty name"
  [[ -n "$need" ]] || echo "$f:$n: $name: empty needed_by"
  case "$svc" in
    "" | dns | network | init | firewall | ssh) ;;
    *) echo "$f:$n: $name: service '$svc' not in the fixed set" ;;
  esac
  [[ "$added" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]\ .*SPL-[0-9]+ ]] ||
    echo "$f:$n: $name: added '$added' is not '<date> ... SPL-<n>'"
  _bpm_installed_by "$by" "$added" ||
    echo "$f:$n: $name: installed_by '$by' resolves to no role dir and no do_* function (nor spool-install --cli <name>)"
  : "$pin"
}

# _bpm_check <manifest>: every FAIL line of one manifest; rc 1 when any
_bpm_check() {
  local f="$1" n=0 line out=""
  [[ -s "$f" ]] || { echo "$f: missing or empty"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    out+="$(_bpm_row "${f##*/}" "$n" "$line")"$'\n'
  done <"$f"
  grep -v '^#' "$f" | sed '/^$/d' | LC_ALL=C sort -c -t $'\t' -k1,1 -k2,2 2>/dev/null ||
    out+="${f##*/}: not sorted by kind then name"$'\n'
  out+="$(grep -v '^#' "$f" | cut -f1,2 | sed '/^\s*$/d' | LC_ALL=C sort | uniq -d | sed 's/^/duplicate row: /')"
  out="$(sed '/^$/d' <<<"$out")"
  [[ -z "$out" ]] && return 0
  printf '%s\n' "$out"
  return 1
}

# _bpm_replica <replica> <satellite manifest>: a FAIL line per replica tool
# with no row; an img-* tool is matched by the image its version command names
_bpm_replica() {
  local tool cmd want out=""
  declare -A alias=([psql]=postgresql-client [gcloud]=google-cloud-cli
    [google-chrome]=google-chrome-stable [docker]=docker.io [node]=nodejs)
  while IFS=$'\t' read -r tool cmd _; do
    [[ -z "$tool" || "$tool" == \#* ]] && continue
    want="${alias[$tool]:-$tool}"
    [[ "$tool" == img-* ]] && want="${cmd##* }"
    awk -F '\t' -v w="$want" '!/^#/ { n = $2; sub(/.*\//, "", n); if ($2 == w || n == w) f = 1 }
      END { exit !f }' "$2" || out+="replica tool $tool ($want): no row in ${2##*/}"$'\n'
  done <"$1"
  [[ -z "$out" ]] && return 0
  printf '%s' "$out"
  return 1
}

# _bpm_base <base list> <manifest>: packages only, none the manifest names
_bpm_base() {
  local pkgs both
  pkgs=$(sed -e 's/#.*//' -e '/^\s*$/d' "$1")
  [[ -n "$pkgs" ]] || { echo "${1##*/}: no package"; return 1; }
  grep -vqE '^[a-z0-9][a-z0-9.+-]*$' <<<"$pkgs" && { echo "${1##*/}: a line that is not one package name"; return 1; }
  both=$(LC_ALL=C comm -12 <(LC_ALL=C sort -u <<<"$pkgs") \
    <(awk -F '\t' '!/^#/ && ($1 == "apt" || $1 == "deb") { print $2 }' "$2" | LC_ALL=C sort -u))
  [[ -z "$both" ]] && return 0
  echo "${1##*/}: also in ${2##*/}: $(tr '\n' ' ' <<<"$both")"
  return 1
}

# --- 1. the two manifests
for c in pc satellite; do
  if out=$(_bpm_check "$DIR/$c.tsv"); then
    pass "1 $c.tsv: $(grep -vc '^#' "$DIR/$c.tsv") rows, every rule holds"
  else
    fail "1 $c.tsv:"$'\n'"$out"
  fi
done

# --- 2. every replica tool has a satellite row
if out=$(_bpm_replica "$REPLICA" "$DIR/satellite.tsv"); then
  pass "2 every one of the $(grep -vc '^#' "$REPLICA") satellite-replica.tsv tools has a satellite.tsv row"
else
  fail "2 replica:"$'\n'"$out"
fi

# --- 3. the base lists
for c in pc satellite; do
  if out=$(_bpm_base "$DIR/base-$c.txt" "$DIR/$c.tsv"); then
    pass "3 base-$c.txt: $(grep -vc '^#' "$DIR/base-$c.txt") packages, none also in $c.tsv"
  else
    fail "3 $out"
  fi
done

# --- 4. fixtures: each broken file must FAIL
T=$'\t'
ok_row="apt${T}jq${T}${T}play 02_os_binaries${T}do_require_bin jq${T}${T}2026-10-17 SPL-2271"
fixture() {  # <name> <want in output> <rows...>
  local name="$1" want="$2" out
  shift 2
  printf '%s\n' "$@" >"$tmp/$name.tsv"
  if out=$(_bpm_check "$tmp/$name.tsv"); then
    fail "4 $name: passed, want a FAIL"
  elif [[ "$out" == *"$want"* && "$out" != *" jq: "* ]]; then
    pass "4 $name -> $want"
  else
    fail "4 $name: '$out', want '$want'"
  fi
}
fixture empty-needed-by "empty needed_by" "$ok_row" \
  "apt${T}zz${T}${T}play 02_os_binaries${T}${T}${T}2026-10-17 SPL-2271"
fixture no-such-action "resolves to no role dir and no do_* function" "$ok_row" \
  "apt${T}zz${T}${T}do_no_such_action${T}lane SPL-1${T}${T}2026-10-17 SPL-2271"
fixture no-such-role "resolves to no role dir" "$ok_row" \
  "apt${T}zz${T}${T}play no_such_role${T}lane SPL-1${T}${T}2026-10-17 SPL-2271"
fixture backfill-not-backfill "installed_by 'backfill'" "$ok_row" \
  "apt${T}zz${T}${T}backfill${T}lane SPL-1${T}${T}2026-10-17 SPL-2271"
fixture no-such-cli "installed_by 'spool-install --cli nosuchcli'" "$ok_row" \
  "bin${T}zz${T}${T}spool-install --cli nosuchcli${T}lane SPL-1${T}${T}2026-10-17 SPL-2339"
fixture bad-kind "kind 'snap'" "$ok_row" \
  "snap${T}zz${T}${T}play 02_os_binaries${T}lane SPL-1${T}${T}2026-10-17 SPL-2271"
fixture six-columns "6 columns" "$ok_row" \
  "apt${T}zz${T}play 02_os_binaries${T}lane SPL-1${T}${T}2026-10-17 SPL-2271"
fixture unsorted "not sorted" \
  "bin${T}zz${T}${T}play 02_os_binaries${T}lane SPL-1${T}${T}2026-10-17 SPL-2271" "$ok_row"
fixture duplicate "duplicate row" "$ok_row" "$ok_row"
# spool-install rows that must resolve (SPL-2339), checked alone
printf '%s\n' "bin${T}grok${T}${T}spool-install --cli grok${T}lane SPL-1${T}${T}2026-10-17 SPL-2339" \
  "bin${T}pkill${T}${T}spool-install${T}lane SPL-1${T}${T}2026-10-17 SPL-2339" >"$tmp/spool-install-ok.tsv"
if [[ -n "$SPOOL_CLIS" ]] && out=$(_bpm_check "$tmp/spool-install-ok.tsv"); then
  pass "4 spool-install rows resolve (--cli takes $SPOOL_CLIS)"
else
  fail "4 spool-install rows: '${out:-no --cli list read from $SPOOL_INSTALL}'"
fi
printf 'jq\tjq --version\tx\nnot-a-tool\tnot-a-tool -v\tx\n' >"$tmp/replica.tsv"
if out=$(_bpm_replica "$tmp/replica.tsv" "$DIR/satellite.tsv"); then
  fail "4 replica fixture: passed, want a FAIL"
else
  [[ "$out" == *"not-a-tool"* && "$out" != *"tool jq"* ]] && pass "4 replica fixture -> only not-a-tool FAILs" ||
    fail "4 replica fixture: '$out'"
fi

echo "box-pkgs-manifest: $fails failure(s)"
((fails == 0))
