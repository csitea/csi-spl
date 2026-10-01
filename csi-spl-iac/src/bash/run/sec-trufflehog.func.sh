#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Secret scan (TruffleHog), a verified-secret second opinion to the
# @description gitleaks history scan. Runs a negative control first: a planted
# @description AWS key pair TruffleHog MUST detect (offline, --no-verification).
# @description A tool that reports nothing on it proves nothing and the action
# @description fails closed. Then it scans the working tree for VERIFIED (live)
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

do_sec_trufflehog() {
  local bin="${SEC_TRUFFLEHOG_BIN:-trufflehog}"
  _sec_trufflehog_need "$bin" || return 1
  local root ctl rc n
  root=$(_sec_trufflehog_root) || return 1

  # --- control: TruffleHog must detect the planted pair (offline) -----------
  ctl=$(_sec_trufflehog_control_dir) || return 1
  do_log "INFO trufflehog $_SEC_TRUFFLEHOG_VER control (want a detection, --no-verification)"
  n=$(SEC_TRUFFLEHOG_PHASE=control "$bin" filesystem "$ctl" --no-update --no-verification --json 2>/dev/null | _sec_trufflehog_count)
  rm -rf "$ctl"
  if [[ "${n:-0}" -lt 1 ]]; then
    do_log "FATAL control: trufflehog detected nothing on a planted key pair (found=${n:-0}) -- the check proved nothing"
    return 1
  fi

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
