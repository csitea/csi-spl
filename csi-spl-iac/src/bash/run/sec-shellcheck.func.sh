#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Bash static analysis (shellcheck) for this repo's shell, gate on
# @description ERROR level. Runs a negative control first: a planted broken
# @description script shellcheck MUST flag. A tool that reports nothing on it
# @description proves nothing and the action fails closed. Then it scans every
# @description *.sh under the iac + orc + cnf bash trees at severity error.
# @description A missing tool fails closed; it is never a skip. Then the
# @description warning level is held to .shellcheck-warning-baseline.txt.
# @param SEC_SHELLCHECK_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_SHELLCHECK_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_SHELLCHECK_SEVERITY (optional) - default error
# @param SEC_SHELLCHECK_WARN_BASELINE (optional) - default <root>/.shellcheck-warning-baseline.txt
# @param SEC_SHELLCHECK_FILES (optional) - newline list of root-relative *.sh to scan
# @param        INSTEAD of the whole tree (the pre-push lint part: touched files only)
# @param SEC_SHELLCHECK_JOBS (optional) - parallel shellcheck processes; default nproc
# @example ./run -a do_sec_shellcheck
#------------------------------------------------------------------------------

_SEC_SHELLCHECK_VER=0.10.0

_sec_shellcheck_root() {
  if [[ -n "${SEC_SHELLCHECK_ROOT:-}" ]]; then printf '%s\n' "$SEC_SHELLCHECK_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_SHELLCHECK_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_shellcheck_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

# A script shellcheck flags at error level regardless of version: `-f` with a
# glob (SC2144). Directory removed by the caller.
_sec_shellcheck_control_dir() {
  local d
  d=$(mktemp -d) || return 1
  cat >"$d/bad.sh" <<'EOF'
#!/bin/bash
if [ -f *.log ]; then
  echo has-log
fi
EOF
  printf '%s\n' "$d"
}

do_sec_shellcheck() {
  local bin="${SEC_SHELLCHECK_BIN:-shellcheck}"
  _sec_shellcheck_need "$bin" || return 1
  local root sev ctl rc
  root=$(_sec_shellcheck_root) || return 1
  sev="${SEC_SHELLCHECK_SEVERITY:-error}"

  ctl=$(_sec_shellcheck_control_dir) || return 1
  do_log "INFO shellcheck $_SEC_SHELLCHECK_VER control (want a finding at -S $sev, non-zero)"
  rc=0
  SEC_SHELLCHECK_PHASE=control "$bin" -S "$sev" -f gcc "$ctl/bad.sh" >"$ctl/out" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] || ! grep -qE 'SC[0-9]{4}' "$ctl/out"; then
    do_log "FATAL control: shellcheck reported nothing on a broken script (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$ctl/out"
    rm -rf "$ctl"
    return 1
  fi
  rm -rf "$ctl"

  # Scope: the bash the owner named -- "every bash action" -- plus its libs and
  # tests under iac + orc + cnf. The hub (csi-spl-api) bash is the hub lane's;
  # extending shellcheck there is a follow-up (coordination + one SC2144 there).
  local scan_dirs=() d
  for d in \
    "$root/csi-spl-iac/src/bash" "$root/csi-spl-iac/lib/bash" \
    "$root/csi-spl-orc/src/bash" "$root/csi-spl-orc/lib/bash" \
    "$root/csi-spl-cnf/src/bash"; do
    [[ -d "$d" ]] && scan_dirs+=("$d")
  done
  if [[ "${#scan_dirs[@]}" -eq 0 ]]; then
    do_log "FATAL no bash tree found under $root -- refusing a scan that checks nothing"
    return 1
  fi

  local files=() f
  if [[ -n "${SEC_SHELLCHECK_FILES:-}" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$root/$f"); done <<<"$SEC_SHELLCHECK_FILES"
  else
    while IFS= read -r f; do files+=("$f"); done < <(
      find "${scan_dirs[@]}" -type f -name '*.sh' 2>/dev/null | grep -v '/node_modules/' | sort
    )
  fi
  if [[ "${#files[@]}" -eq 0 ]]; then
    do_log "FATAL no *.sh found under the bash trees -- refusing a scan that checks nothing"
    return 1
  fi

  _sec_shellcheck_scan "$bin" "$root" "$sev" "${files[@]}"
}

# One parallel -S warning pass serves both gates when the gate is error
# level (perf round 4, C4): an error pass then a warning pass read the same
# ~690 files twice, serially (wf67 step median 110 s, n=12). Warning output
# holds every error line, so the error verdict is its `: error:` lines.
_sec_shellcheck_scan() {
  local bin="$1" root="$2" sev="$3" rc; shift 3
  local files=("$@")
  local log; log=$(mktemp)
  if [[ "$sev" == error ]]; then
    do_log "INFO shellcheck -S warning on ${#files[@]} script(s) (iac + orc + cnf), error gate + warning ratchet"
    rc=0
    _sec_shellcheck_par "$bin" warning warn "$log" "${files[@]}" || rc=$?
    if [[ "$rc" -ne 0 ]] || grep -q ': error: ' "$log"; then
      do_log "FATAL shellcheck: error-level findings (or tool error, exit $rc)"
      if [[ "$rc" -ne 0 ]]; then sed 's/^/  /' "$log"; else grep ': error: ' "$log" | sed 's/^/  /'; fi
      rm -f "$log"
      return 1
    fi
    do_log "INFO shellcheck: no error-level findings"
    _sec_shellcheck_warn_ratchet "$root" "$log" "${files[@]}"
    rc=$?
    rm -f "$log"
    return "$rc"
  fi
  do_log "INFO shellcheck -S $sev on ${#files[@]} script(s) (iac + orc + cnf)"
  rc=0
  _sec_shellcheck_par "$bin" "$sev" scan "$log" "${files[@]}" || rc=$?
  if [[ "$rc" -ne 0 ]] || [[ -s "$log" ]]; then
    do_log "FATAL shellcheck: $sev-level findings (or tool error, exit $rc)"
    sed 's/^/  /' "$log"
    rm -f "$log"
    return 1
  fi
  do_log "INFO shellcheck: no $sev-level findings"
  : >"$log"
  _sec_shellcheck_par "$bin" warning warn "$log" "${files[@]}" || {
    do_log "FATAL shellcheck warning pass: tool error"; sed 's/^/  /' "$log"; rm -f "$log"; return 1
  }
  _sec_shellcheck_warn_ratchet "$root" "$log" "${files[@]}"
  rc=$?
  rm -f "$log"
  return "$rc"
}

# _sec_shellcheck_par <bin> <severity> <phase> <log> <file>...
# Runs the tool over the files in batches of 40, SEC_SHELLCHECK_JOBS (default
# nproc) at a time. Each batch writes its own file, so lines never interleave;
# the log is their lines stably sorted by file name. Exit 1 (findings) is not
# an error here, the caller reads the lines; any other exit of any batch is a
# tool error: its output stays in the log and this returns 2.
_sec_shellcheck_par() {
  local bin="$1" sev="$2" phase="$3" log="$4" d; shift 4
  local jobs="${SEC_SHELLCHECK_JOBS:-$(nproc 2>/dev/null || echo 4)}"
  d=$(mktemp -d) || return 1
  printf '%s\0' "$@" | SEC_SHELLCHECK_PHASE="$phase" xargs -0 -P "$jobs" -n 40 bash -c '
    d="$1" bin="$2" sev="$3"; shift 3
    out=$(mktemp "$d/b.XXXXXX") || exit 255
    rc=0; "$bin" -S "$sev" -f gcc "$@" >"$out" 2>&1 || rc=$?
    [[ "$rc" -le 1 ]] || echo "$rc" >"$out.rc"
    exit 0' _ "$d" "$bin" "$sev"
  local xrc=$? bad
  find "$d" -name 'b.*' ! -name '*.rc' -exec cat {} + | LC_ALL=C sort -s -t: -k1,1 >"$log"
  bad=$(find "$d" -name '*.rc' -exec cat {} + | sort -u | tr '\n' ' ')
  rm -rf "$d"
  [[ "$xrc" -eq 0 && -z "$bad" ]] && return 0
  printf 'shellcheck tool error: exit %s(xargs %s)\n' "$bad" "$xrc" >>"$log"
  return 2
}

# Warning level is a RATCHET, not a wall (CLE-77915, refactor item 4): 328
# warnings sat below the error gate on 2026-10-01, most of them deliberate
# (a tilde in a message, `yes | cp`, a constant-word `case` membership test).
# Counts per (code, file) may not grow past .shellcheck-warning-baseline.txt;
# a NEW warning fails, a fixed one is reported so the baseline can shrink.
# Counts, not line numbers, so ordinary edits do not churn.
# <log> is the -S warning output of the files (from _sec_shellcheck_par).
_sec_shellcheck_warn_ratchet() {
  local root="$1" log="$2"; shift 2
  local wbase="${SEC_SHELLCHECK_WARN_BASELINE:-$root/.shellcheck-warning-baseline.txt}"
  [[ -f "$wbase" ]] || { do_log "FATAL no $wbase -- the warning ratchet has nothing to hold"; return 1; }
  local verdict rc=0
  verdict=$(python3 - "$log" "$wbase" "$root" "$@" <<'PY'
import collections, re, sys
log, bl, root, files = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/") + "/", sys.argv[4:]
rel = lambda f: f[len(root):] if f.startswith(root) else f
scanned = {rel(f) for f in files}
base = collections.Counter()
for line in open(bl):
    line = line.strip()
    if line and not line.startswith("#"):
        code, path, n = line.split("|")
        base[(code, path)] = int(n)
cur = collections.Counter()
for line in open(log):
    m = re.match(r"^(.+?):\d+:\d+: (?:warning|error): .*\[(SC\d+)\]$", line.rstrip())
    if m:
        cur[(m.group(2), rel(m.group(1)))] += 1
new = [f"NEW {c} {f}: {n} found, {base.get((c, f), 0)} baselined" for (c, f), n in sorted(cur.items()) if n > base.get((c, f), 0)]
fixed = [f"FIXED {c} {f}: {n} baselined, {cur.get((c, f), 0)} found" for (c, f), n in sorted(base.items()) if f in scanned and cur.get((c, f), 0) < n]
print("\n".join(new + fixed))
PY
) || rc=$?
  [[ "$rc" -eq 0 ]] || { do_log "FATAL shellcheck warning ratchet could not read $wbase (exit $rc)"; return 1; }
  if grep -q '^NEW ' <<<"$verdict"; then
    do_log "FATAL shellcheck: NEW warning-level finding(s) beyond $wbase (fix it, or add a line with the reason):"
    grep '^NEW ' <<<"$verdict" | sed 's/^/  /'
    return 1
  fi
  if grep -q '^FIXED ' <<<"$verdict"; then
    do_log "INFO shellcheck: fewer warnings than baselined -- lower these lines in $wbase:"
    grep '^FIXED ' <<<"$verdict" | sed 's/^/  /'
  fi
  do_log "INFO shellcheck: no new warning-level findings (baseline holds)"
  return 0
}
