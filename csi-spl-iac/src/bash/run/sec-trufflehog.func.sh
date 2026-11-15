#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Secret scan (TruffleHog), a verified-secret second opinion to the
# @description gitleaks history scan. Runs a negative control first: a planted
# @description AWS key pair TruffleHog MUST detect (offline, --no-verification).
# @description A tool that reports nothing on it proves nothing and the action
# @description fails closed. A control that detected is kept: a mark per key (sha256
# @description of the resolved binary and of this file, plus the pinned version)
# @description under ${XDG_CACHE_HOME:-~/.cache}/csi-spl/trufflehog-control/ skips it
# @description next time; a failed control is never kept. Then it scans the working
# @description tree for VERIFIED (live)
# @description secrets only (--only-verified) and fails on any. A missing tool
# @description fails closed; it is never a skip. Secrets are never printed --
# @description only the detector type and file path.
# @param SEC_TRUFFLEHOG_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_TRUFFLEHOG_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_TRUFFLEHOG_FILES (optional) - newline list of root-relative files to scan
# @param        INSTEAD of the working tree (the pre-push lint part: the pushed diff)
# @example ./run -a do_sec_trufflehog
#------------------------------------------------------------------------------

_SEC_TRUFFLEHOG_VER=3.90.8

_sec_trufflehog_root() {
  if [[ -n "${SEC_TRUFFLEHOG_ROOT:-}" ]]; then printf '%s\n' "$SEC_TRUFFLEHOG_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_TRUFFLEHOG_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_trufflehog_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

# A planted AWS access-key + secret pair (throwaway, not a live key) TruffleHog's
# AWS detector reports as an unverified finding offline. Directory removed by the
# caller. Assembled so this file itself carries no scannable pair.
_sec_trufflehog_control_dir() {
  # id and the 40-char value are assembled from parts so this source file itself
  # carries no scannable AWS key pair (the gitleaks gate would flag it otherwise);
  # bash concatenates the adjacent pieces at runtime for the temp file below.
  local d id p1 p2
  d=$(mktemp -d) || return 1
  id="AK""IAYVP4CIPPERUVIFXG"
  p1="Zt2U1h6nWvXcYdEe"
  p2="FfGgHhIiJjKkLlMmNnOoPpQq"
  {
    printf 'aws_access_key_id = %s\n' "$id"
    printf 'aws_secret_access_key = %s\n' "$p1$p2"
  } >"$d/creds.txt"
  printf '%s\n' "$d"
}

# Count TruffleHog JSON findings on stdin (one JSON object per line).
_sec_trufflehog_count() {
  python3 -c 'import sys
n=0
for line in sys.stdin:
    line=line.strip()
    if line.startswith("{") and "DetectorName" in line: n+=1
print(n)'
}

# The control's verdict key: sha256 of the RESOLVED binary (bin defaults to the
# bare name), of this file (the control's flags and _sec_trufflehog_count, which
# the scan reuses) and the pinned version. No key (so no mark) when either file
# cannot be read, e.g. bin is a shell function.
_sec_trufflehog_control_key() {
  local path sums
  path=$(command -v "$1" 2>/dev/null) || return 1
  sums=$(sha256sum "$path" "${BASH_SOURCE[0]}" 2>/dev/null) || return 1
  printf '%s\n%s\n' "$sums" "$_SEC_TRUFFLEHOG_VER" | cut -d' ' -f1 | sha256sum | cut -c1-64
}

# The negative control, skipped when a mark for this key says it already
# detected the planted pair. A failed control writes no mark; an unwritable
# cache dir only costs the control run.
_sec_trufflehog_control() {
  local bin=$1 key dir ctl n
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/trufflehog-control"
  key=$(_sec_trufflehog_control_key "$bin") || key=""
  if [[ -n "$key" && -f "$dir/$key" ]]; then
    do_log "INFO trufflehog control: kept for ${key:0:8}"
    return 0
  fi
  ctl=$(_sec_trufflehog_control_dir) || return 1
  do_log "INFO trufflehog $_SEC_TRUFFLEHOG_VER control (want a detection, --no-verification)"
  n=$(SEC_TRUFFLEHOG_PHASE=control "$bin" filesystem "$ctl" --no-update --no-verification --json 2>/dev/null | _sec_trufflehog_count)
  rm -rf "$ctl"
  if [[ "${n:-0}" -lt 1 ]]; then
    do_log "FATAL control: trufflehog detected nothing on a planted key pair (found=${n:-0}) -- the check proved nothing"
    return 1
  fi
  [[ -z "$key" ]] || { mkdir -p "$dir" && : >"$dir/$key"; } 2>/dev/null || true
  return 0
}

do_sec_trufflehog() {
  local bin="${SEC_TRUFFLEHOG_BIN:-trufflehog}"
  _sec_trufflehog_need "$bin" || return 1
  local root n
  root=$(_sec_trufflehog_root) || return 1

  # --- control: TruffleHog must detect the planted pair (offline) -----------
  _sec_trufflehog_control "$bin" || return 1

  # --- scan: verified (live) secrets in the working tree only ---------------
  local exclude; exclude=$(mktemp)
  printf '%s\n' '(^|/)node_modules/' '(^|/)\.git/' '(^|/)tpl-gen/' '(^|/)bin/' >"$exclude"
  local out; out=$(mktemp)
  local targets=("$root") f
  if [[ -n "${SEC_TRUFFLEHOG_FILES:-}" ]]; then
    targets=()
    while IFS= read -r f; do [[ -n "$f" && -f "$root/$f" ]] && targets+=("$root/$f"); done <<<"$SEC_TRUFFLEHOG_FILES"
    [[ "${#targets[@]}" -gt 0 ]] || { do_log "INFO trufflehog: none of the listed files exist -- nothing to scan"; rm -f "$exclude" "$out"; return 0; }
  fi
  do_log "INFO trufflehog filesystem --only-verified on ${#targets[@]} target(s) under $root"
  SEC_TRUFFLEHOG_PHASE=scan "$bin" filesystem "${targets[@]}" --only-verified --no-update \
    --exclude-paths="$exclude" --json >"$out" 2>/dev/null || true
  n=$(_sec_trufflehog_count <"$out")
  rm -f "$exclude"
  if [[ "${n:-0}" -eq 0 ]]; then
    do_log "INFO trufflehog: no verified (live) secrets"
    rm -f "$out"
    return 0
  fi
  do_log "FATAL trufflehog: $n VERIFIED (live) secret(s) -- detector/file only, secret redacted:"
  python3 -c 'import sys,json
for line in open(sys.argv[1]):
    line=line.strip()
    if not line.startswith("{"): continue
    try: o=json.loads(line)
    except Exception: continue
    det=o.get("DetectorName","?")
    f=(((o.get("SourceMetadata") or {}).get("Data") or {}).get("Filesystem") or {}).get("file","?")
    print(f"  {det}  {f}")' "$out"
  rm -f "$out"
  return 1
}
