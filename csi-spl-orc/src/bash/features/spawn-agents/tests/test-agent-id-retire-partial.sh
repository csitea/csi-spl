#!/usr/bin/env bash
# agent-id-retire.sh stopped HALF-WAY (robustness review gap 3, SPL-2353): a
# PATH shim kills the step after each one - the dir move, the registry lock,
# the identity record, the alias lock - then a plain re-run finishes it.
# Safe outcome: no id lost (every other registry row stays, unread mail is kept
# aside), never handed out twice (held or quarantined at every point), and the
# re-run leaves the end state of a clean retirement: the first generation
# stamp, one quarantine row, one alias row (a legacy --successor kept, SPL-2408).
# A private tmux server; the live box is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
RET="$T_SCRIPTS/agent-id-retire.sh"
NAI="$T_SCRIPTS/next-agent-id.sh"
export RETIRE_LANE=0
R="$SPOOL_ROOT"
t_tmux
mkdir -p "$T_TMP/bin"
# T_FAIL_AT=mv|flock|python3 (T_FAIL_N: which `flock -w 30 9` call) dies there.
for c in mv flock python3; do
  real="$(command -v "$c")"
  cat >"$T_TMP/bin/$c" <<EOS
#!/usr/bin/env bash
if [ "\${T_FAIL_AT:-}" = "$c" ]; then
  case "$c" in
    mv) case "\$*" in *"/.retired/"*) echo "planted: mv dies" >&2; exit 1 ;; esac ;;
    flock) if [ "\$*" = "-w 30 9" ]; then
             n=\$(( \$(cat "$T_TMP/flock.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$T_TMP/flock.n"
             [ "\$n" = "\${T_FAIL_N:-1}" ] && { echo "planted: flock dies" >&2; exit 1; }
           fi ;;
    python3) case " \$* " in *" retire "*) echo "planted: python3 dies" >&2; exit 1 ;; esac ;;
  esac
fi
exec "$real" "\$@"
EOS
  chmod +x "$T_TMP/bin/$c"
done

fixture() {  # c-004: dir with unread mail, a registry row, a record; c-099 beside it
  rm -rf "$R" "$T_TMP/flock.n"; mkdir -p "$R/c-004/inbox" "$R/c-099/inbox" "$R/agents"
  printf '{"v":1}\n' >"$R/c-004/inbox/unread.json"
  printf 'c-004\tclaude\t%%5\t/x\t20261002T080000Z\nc-099\tclaude\t%%6\t/y\t20261002T080000Z\n' >"$R/registry.tsv"
  printf '{"id":"c-004"}\n' >"$R/agents/c-004.json"
}
not_handed() {  # LABEL: the allocator skips c-004
  local n; n="$(bash "$NAI" --kind claude --no-reserve)"
  if [ -n "$n" ] && [ "$n" != c-004 ]; then ok "$1: the allocator skips c-004 ($n)"; else nok "$1: the allocator handed out c-004 ($n)"; fi
}
done_state() {  # LABEL: the end state of a clean retirement
  check "$1: the spool dir is gone" test ! -e "$R/c-004"
  check "$1: ...moved whole, unread mail kept aside" test -s "$R/.retired/c-004.20261002T080000Z/inbox/unread.json"
  eq "$1: one .retired dir (no second generation)" 1 "$(compgen -G "$R/.retired/c-004.*" | wc -l)"
  eq "$1: the registry keeps c-099 only" c-099 "$(cut -f1 "$R/registry.tsv")"
  check "$1: c-004 is quarantined (registry.retired.tsv)" grep -q '^c-004	claude	' "$R/registry.retired.tsv"
  eq "$1: one quarantine row (registry.retired.tsv)" 1 "$(grep -c '^c-004	' "$R/registry.retired.tsv")"
  check "$1: the record moved aside under the first generation" test ! -e "$R/agents/c-004.json" -a -s "$R/agents/retired/c-004.20261002T080000Z.json"
  eq "$1: one record generation" 1 "$(compgen -G "$R/agents/retired/c-004.*.json" | wc -l)"
  eq "$1: one alias row, c-004 -> retired" 1 "$(grep -c '^c-004	retired	claude	' "$R/agent-id-aliases.tsv" 2>/dev/null)"
  check "$1: no pending retirement left" test ! -e "$R/.retired/.pending.c-004"
  eq "$1: index.json matches the records on disk" "$(python3 "$T_SCRIPTS/agent-identity.py" --dir "$R/agents" hash)" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hash"])' "$R/agents/index.json" 2>/dev/null)"
  check "$1: c-099 is untouched" test -d "$R/c-099/inbox"
  not_handed "$1"
}

# CONTROL: a clean run reaches the end state the re-runs below must reach.
fixture
bash "$RET" --apply c-004 >/dev/null 2>&1; eq "CONTROL a clean retirement exits 0" 0 "$?"
done_state "CONTROL clean"

# stop       the step that dies   what the first run already did
for case_ in "move:mv:1" "registry:flock:1" "identity:python3:1" "alias:flock:2"; do
  IFS=: read -r stop at n <<<"$case_"
  fixture
  PATH="$T_TMP/bin:$PATH" T_FAIL_AT="$at" T_FAIL_N="$n" bash "$RET" --apply c-004 >"$T_TMP/o" 2>&1; rc=$?
  has "stop at $stop: the planted fault fired" "planted: $at dies" "$(cat "$T_TMP/o")"
  if [ "$rc" -ne 0 ]; then ok "stop at $stop: the first run fails ($rc)"; else nok "stop at $stop: the first run fails (got 0)"; fi
  not_handed "stop at $stop, half-done"
  eq "stop at $stop: c-099's row is never lost" 1 "$(grep -c '^c-099' "$R/registry.tsv")"
  SPOOL_NOW=2026-10-02T12:05:00Z bash "$RET" --apply c-004 >/dev/null 2>&1; rc=$?
  eq "stop at $stop: the re-run completes the retirement" 0 "$rc"
  done_state "stop at $stop, re-run"
done

# A legacy id retired with --successor, stopped at the alias lock: the plain
# re-run still writes CLE-77 -> c-500 (before SPL-2408 it exited 4, row lost).
rm -rf "$R" "$T_TMP/flock.n"; mkdir -p "$R/CLE-77/inbox"
printf 'CLE-77\tclaude\t%%5\t/x\t20261002T080000Z\n' >"$R/registry.tsv"
PATH="$T_TMP/bin:$PATH" T_FAIL_AT=flock T_FAIL_N=2 bash "$RET" --apply --successor c-500 CLE-77 >"$T_TMP/o" 2>&1
has "legacy stop at alias: the planted fault fired" "planted: flock dies" "$(cat "$T_TMP/o")"
bash "$RET" --apply CLE-77 >/dev/null 2>&1; eq "legacy stop at alias: the re-run completes it" 0 "$?"
eq "...the successor alias row is written once" 1 "$(grep -c '^CLE-77	c-500	' "$R/agent-id-aliases.tsv" 2>/dev/null)"
eq "...one quarantine row" 1 "$(grep -c '^CLE-77	' "$R/registry.retired.tsv")"
bash "$RET" --apply CLE-77 >/dev/null 2>&1; eq "...a third run finds nothing left (4)" 4 "$?"

t_done
