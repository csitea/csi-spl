#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 136 FR9 / rule 7 (lane L8): no sweep, classifier or reader in
#          csi-spl-orc (sa/ included) or in any tracked .py opens a spool's
#          encrypted/ dirs (<root>/<agent>/encrypted/{inbox,outbox,archive},
#          <root>/encrypted/files). Readers glob <root>/<agent>/inbox/*.json
#          one level deep, so a sibling encrypted/ is out of their reach; two
#          shapes would bring it back in, and the static part refuses both:
#   1. no non-comment line names an encrypted/ path ("encrypted/",
#      "/encrypted", a 'encrypted' path part in .py), outside ENC_ALLOW: the
#      writer lanes of spec 136 section 11 (setup, migrate, export, retire,
#      seat drop, rebox). The W1-W7 readers never go on it.
#   2. no recursive walk of a spool root or an agent dir: `find` over a spool
#      path with no -maxdepth that does not start in a leaf dir (inbox,
#      outbox, archive, ...), `grep -r` over a spool path, os.walk / rglob /
#      recursive glob in a .py that reads spool paths
#   3. controls: a planted reader of each shape is found by the same scan
#   4. behaviour, on a fixture root with sealed v:3 files whose ct and a fake
#      body carry a marker (and "ACCEPTED"): the W1 classifier
#      (spl_lane_rotate_accepted) and W7 agent-inbox.sh see only the plain
#      message, print no marker, write no marker outside encrypted/, and
#      leave encrypted/ byte-identical
#   The CI control that turns this red lives on a throwaway branch.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
REPO=$(cd "$ORC/.." && pwd)
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The files spec 136 section 11 lets name encrypted/ (they write or move it,
# never sweep it), relative to the repo root. A lane adds its own line.
ENC_ALLOW=(
  csi-spl-orc/src/bash/run/spl-ws-enc-setup.func.sh
  csi-spl-orc/src/bash/run/spl-ws-enc-migrate.func.sh
  csi-spl-orc/src/bash/run/spl-ws-enc-export.func.sh
  csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh
  csi-spl-orc/src/bash/features/spawn-agents/scripts/desk-seat-drop.sh
  csi-spl-orc/src/bash/run/spl-desk-rebox.func.sh
)
# The readers of spec 136 section 1.5 (W1-W7): never allowed.
READERS=(
  csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh
  csi-spl-orc/src/bash/run/spl-peer-poll.func.sh
  csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh
  csi-spl-orc/src/bash/scripts/spl-desk-reply.sh
  csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh
  csi-spl-orc/src/bash/run/spl-msg-dedup.func.sh
  csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py
  csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-mirror-check.py
  csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-inbox.sh
  csi-spl-orc/src/bash/run/spl-desk-reply.func.sh
  csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh
)

ENC_RX='(encrypted/|/encrypted([^A-Za-z0-9_-]|$)|["'"'"']encrypted["'"'"'])'
SPOOL_RX='(\$\{?(SPOOL_ROOT|SPOOL_FLEET_ROOT|SPL_WS_SPOOL_ROOT|FLEET_ROOT|spool_root|sroot|spool|SPOOL)\b|/var/spool-hub|/spool/)'
LEAF_RX='/(inbox|outbox|archive|\.pokes|\.mirror|\.hub|lifetime|files|briefs|claims)[/"'"'"' ]'
PY_SPOOL_RX='(SPOOL_ROOT|spool-hub|["'"'"']spool["'"'"']|/spool/|inbox|outbox)'

# files <dir> - the shell and .py files to scan under dir, tests excluded
files() { find "$1" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.bash' \) -not -path '*/tests/*' -not -path '*/node_modules/*' 2>/dev/null; }

# strip_root <root> - "<root>/<rel>:<n>:<text>" -> "<rel>:<n>:<text>", comment lines dropped
strip_root() { awk -v r="$1/" 'index($0, r) == 1 { $0 = substr($0, length(r) + 1) } { t = $0; sub(/^[^:]*:[0-9]+:/, "", t); if (t !~ /^[[:space:]]*#/) print }'; }

# scan_enc <root> <file...> - "<file>:<line>:<text>" for every non-comment
# line naming an encrypted/ path, allow-listed files skipped
scan_enc() {
  local root="$1"; shift
  printf '%s\0' "$@" | xargs -0 -r grep -nHE "$ENC_RX" 2>/dev/null | strip_root "$root" \
    | awk -v allow="$(printf '%s\n' "${ENC_ALLOW[@]}")" 'BEGIN { n = split(allow, a, "\n"); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
        { f = $0; sub(/:[0-9]+:.*/, "", f); if (!(f in skip)) print }'
}

# scan_walk <root> <file...> - "<file>:<line>:<text>" for every recursive walk
# of a spool root or an agent dir
scan_walk() {
  local root="$1" sh=() py=() f; shift
  for f in "$@"; do case "$f" in *.py) py+=("$f") ;; *) sh+=("$f") ;; esac; done
  if (( ${#py[@]} )); then
    printf '%s\0' "${py[@]}" | xargs -0 -r grep -lE "$PY_SPOOL_RX" 2>/dev/null | tr '\n' '\0' \
      | xargs -0 -r grep -nHE 'os\.walk\(|\.rglob\(|recursive *= *True' 2>/dev/null | grep -vE '\.(grok|claude)/' | strip_root "$root"
  fi
  (( ${#sh[@]} )) || return 0
  printf '%s\0' "${sh[@]}" | xargs -0 -r grep -nHE "\bfind\b[^|;]*$SPOOL_RX" 2>/dev/null \
    | grep -v -- '-maxdepth' | grep -vE "$LEAF_RX" | strip_root "$root"
  printf '%s\0' "${sh[@]}" | xargs -0 -r grep -nHE "\bgrep\b +(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive|--dereference-recursive)[^|;]*$SPOOL_RX" 2>/dev/null \
    | strip_root "$root"
}

# ---- 1 + 2: the real tree ----------------------------------------------------
mapfile -t ORC_FILES < <(files "$ORC/src/bash")
mapfile -t PY_FILES < <(git -C "$REPO" ls-files '*.py' 2>/dev/null | grep -v '/tests/' | sed "s|^|$REPO/|")
mapfile -t ALL < <(printf '%s\n' "${ORC_FILES[@]}" "${PY_FILES[@]}" | sort -u)
(( ${#ALL[@]} > 100 )) && pass "0. the scan covers ${#ALL[@]} files (orc + sa + every .py)" || fail "0. only ${#ALL[@]} files found to scan"
declare -A SCANNED=()
for f in "${ALL[@]}"; do SCANNED["$f"]=1; done
for r in "${READERS[@]}"; do
  [[ -f "$REPO/$r" ]] || { fail "0. reader $r is gone: update READERS"; continue; }
  [[ -n "${SCANNED["$REPO/$r"]:-}" ]] || fail "0. reader $r is not scanned"
  for a in "${ENC_ALLOW[@]}"; do [[ "$a" == "$r" ]] && fail "0. reader $r is on ENC_ALLOW"; done
done

hits="$(scan_enc "$REPO" "${ALL[@]}")"
[[ -z "$hits" ]] && pass "1. no reader names an encrypted/ path" \
  || fail "1. encrypted/ named outside ENC_ALLOW (spec 136 rule 7; a writer lane adds itself to ENC_ALLOW):"$'\n'"$hits"
hits="$(scan_walk "$REPO" "${ALL[@]}")"
[[ -z "$hits" ]] && pass "2. no recursive walk of a spool root or agent dir" \
  || fail "2. recursive spool walks reach encrypted/ (add -maxdepth 1, or start in inbox/ archive/):"$'\n'"$hits"

# ---- 3: controls ---------------------------------------------------------------
P="$T/plant"; mkdir -p "$P/run" "$P/py"
plant() { printf '%s\n' "$2" >"$P/$1"; }
plant run/a.func.sh 'grep -lsE ACCEPTED "$SPOOL_ROOT/$1"/encrypted/inbox/*.json'
plant run/b.func.sh 'for f in "$root/$id/encrypted"/archive/*.json; do :; done'
plant py/c.py 'p = os.path.join(SPOOL_ROOT, agent, "encrypted", "inbox")'
plant run/d.func.sh 'find "$SPOOL_ROOT/$id" -name "*.json" -newer "$mark"'
plant run/e.func.sh 'grep -rl ACCEPTED "$SPOOL_ROOT/$id"'
plant py/f.py $'import os\nfor d, _, fs in os.walk(os.environ["SPOOL_ROOT"]):\n    pass'
plant run/ok.func.sh $'# comment: never reads encrypted/\nfind "$SPOOL_ROOT/$id/inbox" -maxdepth 1 -name "*.json"\nfind "$d/spool/$t/inbox" -name "*.json"\nspool recv --encrypted --as "$id"'
mapfile -t PL < <(files "$P")
e="$(scan_enc "$P" "${PL[@]}")"; w="$(scan_walk "$P" "${PL[@]}")"
for k in run/a.func.sh run/b.func.sh py/c.py; do
  grep -q "^$k:" <<<"$e" && pass "3. control: planted encrypted/ reader $k is found" || fail "3. control: $k not found"
done
for k in run/d.func.sh run/e.func.sh py/f.py; do
  grep -q "^$k:" <<<"$w" && pass "3. control: planted recursive walk $k is found" || fail "3. control: $k not found"
done
grep -q '^run/ok.func.sh:' <<<"$e$w" && fail "3. control: a safe reader is flagged: $(grep '^run/ok' <<<"$e$w")" \
  || pass "3. control: comments, leaf finds and spool recv --encrypted pass"
ENC_ALLOW+=(run/a.func.sh)
grep -q '^run/a.func.sh:' <<<"$(scan_enc "$P" "${PL[@]}")" && fail "3. control: ENC_ALLOW not honoured" \
  || pass "3. control: an ENC_ALLOW file is skipped"
unset 'ENC_ALLOW[-1]'

# ---- 4: the readers on a fixture root -----------------------------------------
S="$T/spool"; ID=c-901 M="ENCMARK$$x$RANDOM"
mkdir -p "$S/$ID"/{inbox,outbox,archive} "$S/$ID"/encrypted/{inbox,outbox,archive} "$S/encrypted/files"
for d in inbox archive outbox; do
  printf '{"v":3,"msg_id":"e-%s","task_id":"t","ts":"2026-10-13T10:00:00Z","from":"c-902","to":"%s","kind":"note","enc":"age","for":["%s"],"ct":"%s","body":"ACCEPTED %s","files":[]}\n' \
    "$d" "$ID" "$ID" "$M" "$M" >"$S/$ID/encrypted/$d/2026-10-13T10:00:00Z--c-902--e-$d.age.json"
done
printf '%s\n' "$M" >"$S/encrypted/files/0000"
printf '{"v":1,"msg_id":"p-1","task_id":"t","ts":"2026-10-13T09:00:00Z","from":"c-903","to":"%s","kind":"note","body":"plain hello","files":[]}\n' \
  "$ID" >"$S/$ID/inbox/2026-10-13T09:00:00Z--c-903--plain-hello.json"
before="$(cd "$S" && find encrypted "$ID/encrypted" -type f -exec md5sum {} + | sort)"
export SPOOL_ROOT="$S" SPOOL_TEST=1 SPOOL_ENV_NO_BINS=1

out="$( (do_log() { :; }
  # shellcheck disable=SC1091
  source "$ORC/src/bash/run/spl-lane-rotate.func.sh" && spl_lane_rotate_accepted "$ID") 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && pass "4. W1 classifier: a sealed ACCEPTED under encrypted/ is not an ACCEPTED" \
  || fail "4. W1 classifier rc=$rc (want 1): $out"
grep -q "$M" <<<"$out" && fail "4. W1 classifier printed the marker" || pass "4. W1 classifier prints no marker"

out="$(bash "$ORC/src/bash/features/spawn-agents/scripts/agent-inbox.sh" --as "$ID" --peek 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'plain hello' <<<"$out" && pass "4. W7 agent-inbox lists the plain message" \
  || fail "4. W7 agent-inbox rc=$rc: $out"
grep -q "$M" <<<"$out" && fail "4. W7 agent-inbox printed the marker: $out" || pass "4. W7 agent-inbox prints no marker"

leak="$(grep -rlF "$M" "$S" | grep -vE "^$S/(encrypted|$ID/encrypted)/")"
[[ -z "$leak" ]] && pass "4. no marker outside encrypted/ after the readers" || fail "4. marker copied out: $leak"
[[ "$(cd "$S" && find encrypted "$ID/encrypted" -type f -exec md5sum {} + | sort)" == "$before" ]] \
  && pass "4. encrypted/ is byte-identical after the readers" || fail "4. encrypted/ changed"

[[ $fails -eq 0 ]] && echo "OK enc-dirs-untouched: $n passed" || { echo "FAILED enc-dirs-untouched: $fails of $n"; exit 1; }
