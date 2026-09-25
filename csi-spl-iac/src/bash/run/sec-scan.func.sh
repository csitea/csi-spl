#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Dependency and secret scans for this repo.
# @description SEC_SCAN selects one:
# @description   go       govulncheck on csi-spl-api/src/go/spool-hub-api
# @description   wui      pnpm audit --audit-level=moderate on csi-spl-wui
# @description   secrets  gitleaks over the full git history (.gitleaks.toml)
# @description   images   trivy image on the production hub base
# @description   all      the four, in that order; any failure fails the run
# @description Each scan runs a negative control first. The control must
# @description observe a real finding (govulncheck exit 3, pnpm audit exit 1
# @description with a vulnerability, gitleaks "leaks found", trivy a CVE/GO
# @description id). A tool error is not a passing control: the scan then
# @description proved nothing and the action fails closed.
# @description A missing tool fails closed. It is never a skip.
# @param SEC_SCAN (required) - go | wui | secrets | images | all
# @param SEC_SCAN_ROOT (optional) - repo root; default is the parent of APP_PATH
# @param SEC_SCAN_GO_BIN SEC_SCAN_PNPM_BIN SEC_SCAN_GITLEAKS_BIN SEC_SCAN_TRIVY_BIN
# @param        (optional) - override the tool, used by the hermetic test
# @param SEC_SCAN_IMAGES (optional) - space-separated image refs; default the
# @param        hub base gcr.io/distroless/static-debian12:nonroot
# @example SEC_SCAN=go ./run -a do_sec_scan
# @example SEC_SCAN=all ./run -a do_sec_scan
#------------------------------------------------------------------------------

# Pins. The workflow installs these. v1.8.0 of golang.org/x/vuln needs go 1.26;
# this module is go 1.25, so the scanner pin is the newest release that builds
# on 1.25. The vulnerability database is fetched at run time.
_SEC_SCAN_GOVULNCHECK_MOD=v1.7.0
_SEC_SCAN_GITLEAKS_VER=8.30.1
_SEC_SCAN_TRIVY_VER=0.74.0

_sec_scan_root() {
  if [[ -n "${SEC_SCAN_ROOT:-}" ]]; then
    printf '%s\n' "$SEC_SCAN_ROOT"
    return 0
  fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then
    (cd "$base/.." && pwd)
    return 0
  fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  do_log "FATAL SEC_SCAN_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_scan_need() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    do_log "FATAL $bin is not on PATH -- the scan proved nothing"
    return 1
  fi
}

# A module whose golang.org/x/text v0.3.5 call is still in the vuln DB.
# The directory is removed by the caller.
_sec_go_control_module() {
  local d
  d=$(mktemp -d) || return 1
  cat >"$d/go.mod" <<'EOF'
module example.com/sec-scan-control

go 1.22

require golang.org/x/text v0.3.5
EOF
  cat >"$d/main.go" <<'EOF'
package main

import "golang.org/x/text/language"

func main() {
	language.Parse("en")
}
EOF
  printf '%s\n' "$d"
}

_sec_scan_go() {
  local bin="${SEC_SCAN_GO_BIN:-govulncheck}"
  _sec_scan_need "$bin" || return 1
  local root mod ctl rc
  root=$(_sec_scan_root) || return 1
  mod="$root/csi-spl-api/src/go/spool-hub-api"
  [[ -f "$mod/go.mod" ]] || { do_log "FATAL no go.mod at $mod"; return 1; }

  ctl=$(_sec_go_control_module) || return 1
  # The control module is generated without a go.sum. govulncheck refuses
  # that (CI run 36180443797: "missing go.sum entry"). tidy fills it.
  # SEC_SCAN_GO_TIDY=0 is the hermetic test, whose stub never loads the module.
  if [[ "${SEC_SCAN_GO_TIDY:-1}" != 0 ]]; then
    command -v go >/dev/null 2>&1 || { do_log "FATAL control: go is not on PATH, cannot tidy the control module"; rm -rf "$ctl"; return 1; }
    rc=0
    ( cd "$ctl" && go mod tidy ) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      do_log "FATAL control: go mod tidy failed (exit $rc) -- govulncheck would prove nothing"
      rm -rf "$ctl"
      return 1
    fi
  fi
  do_log "INFO govulncheck control (want exit 3) $_SEC_SCAN_GOVULNCHECK_MOD"
  rc=0
  ( cd "$ctl" && SEC_SCAN_PHASE=control "$bin" ./... ) || rc=$?
  rm -rf "$ctl"
  if [[ "$rc" -ne 3 ]]; then
    do_log "FATAL control: govulncheck exited $rc, want 3 (vulnerabilities found). A tool or network error is not a passing control."
    return 1
  fi
  do_log "INFO govulncheck on $mod"
  rc=0
  ( cd "$mod" && SEC_SCAN_PHASE=scan "$bin" ./... ) || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    do_log "INFO govulncheck: no reachable vulnerabilities"
    return 0
  fi
  if [[ "$rc" -eq 3 ]]; then
    do_log "FATAL govulncheck: reachable vulnerabilities (exit 3)"
    return 1
  fi
  do_log "FATAL govulncheck failed (exit $rc) -- the scan proved nothing"
  return 1
}

_sec_wui_control_dir() {
  local d
  d=$(mktemp -d) || return 1
  # minimist 1.2.5 is GHSA-xvch-5gv4-984h, critical, fixed in 1.2.6.
  # Measured 2026-09-25, pnpm 9.15.4, n=1: audit --audit-level=moderate
  # exits 1 and prints "1 vulnerabilities found" / "critical".
  cat >"$d/package.json" <<'EOF'
{
  "name": "sec-scan-control",
  "private": true,
  "dependencies": { "minimist": "1.2.5" }
}
EOF
  printf '%s\n' "$d"
}

_sec_scan_wui() {
  local bin="${SEC_SCAN_PNPM_BIN:-pnpm}"
  _sec_scan_need "$bin" || return 1
  local root wui ctl rc log
  root=$(_sec_scan_root) || return 1
  wui="$root/csi-spl-wui"
  [[ -f "$wui/pnpm-lock.yaml" ]] || { do_log "FATAL no pnpm-lock.yaml at $wui"; return 1; }

  ctl=$(_sec_wui_control_dir) || return 1
  log=$(mktemp)
  do_log "INFO pnpm audit control (want a moderate-or-higher advisory)"
  rc=0
  ( cd "$ctl" && SEC_SCAN_PHASE=control "$bin" install --ignore-scripts --lockfile-only ) >"$log" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 || ! -f "$ctl/pnpm-lock.yaml" ]]; then
    do_log "FATAL control: pnpm install did not write a lockfile (exit $rc) -- the audit would prove nothing"
    sed 's/^/  /' "$log"
    rm -rf "$ctl" "$log"
    return 1
  fi
  rc=0
  ( cd "$ctl" && SEC_SCAN_PHASE=control "$bin" audit --audit-level=moderate ) >"$log" 2>&1 || rc=$?
  rm -rf "$ctl"
  if [[ "$rc" -eq 0 ]] || grep -q 'ERR_PNPM_AUDIT_NO_LOCKFILE' "$log" \
    || ! grep -qiE 'vulnerabilit|critical|high|moderate' "$log"; then
    do_log "FATAL control: pnpm audit did not report a vulnerability (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$log"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"

  do_log "INFO pnpm audit --audit-level=moderate on $wui"
  log=$(mktemp)
  rc=0
  ( cd "$wui" && SEC_SCAN_PHASE=scan "$bin" audit --audit-level=moderate ) >"$log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    do_log "INFO pnpm audit: no moderate, high, or critical advisories"
    rm -f "$log"
    return 0
  fi
  do_log "FATAL pnpm audit failed (exit $rc)"
  sed 's/^/  /' "$log"
  rm -f "$log"
  return 1
}

# Throwaway git repo with one planted cloud access-key id. The key is
# assembled at runtime so this file does not itself contain a match.
_sec_secrets_control_repo() {
  local d key prefix body
  d=$(mktemp -d) || return 1
  prefix="AK""IA"
  body="J7K2M9P4Q8R1""T5VW"
  key="${prefix}${body}"
  git -C "$d" init -q
  printf 'apikey=%s\n' "$key" >"$d/planted.env"
  git -C "$d" add planted.env
  git -C "$d" -c user.name="Sec Scan" -c user.email="sec-scan@example.com" commit -qm planted
  printf '%s\n' "$d"
}

_sec_scan_secrets() {
  local bin="${SEC_SCAN_GITLEAKS_BIN:-gitleaks}"
  _sec_scan_need "$bin" || return 1
  local root cfg ctl rc log
  root=$(_sec_scan_root) || return 1
  cfg="$root/.gitleaks.toml"
  [[ -f "$cfg" ]] || { do_log "FATAL no $cfg -- a scan on the default config alone is not this gate"; return 1; }
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { do_log "FATAL $root is not a git checkout -- history cannot be scanned"; return 1; }

  ctl=$(_sec_secrets_control_repo) || return 1
  log=$(mktemp)
  do_log "INFO gitleaks $_SEC_SCAN_GITLEAKS_VER control (want leaks found, exit 1)"
  rc=0
  SEC_SCAN_PHASE=control "$bin" detect --source "$ctl" --no-banner --redact \
    --config "$cfg" --exit-code 1 >"$log" 2>&1 || rc=$?
  rm -rf "$ctl"
  if [[ "$rc" -ne 1 ]] || ! grep -q 'leaks found' "$log"; then
    do_log "FATAL control: gitleaks did not report a leak (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$log"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"

  log=$(mktemp)
  do_log "INFO gitleaks --log-opts=--all on $root"
  rc=0
  SEC_SCAN_PHASE=scan "$bin" detect --source "$root" --log-opts="--all" --no-banner --redact \
    --config "$cfg" --exit-code 1 >"$log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    do_log "INFO gitleaks: no leaks outside the triaged allowlist"
    rm -f "$log"
    return 0
  fi
  if [[ "$rc" -eq 1 ]]; then
    do_log "FATAL gitleaks: leaks found (redacted)"
    sed 's/^/  /' "$log"
    rm -f "$log"
    return 1
  fi
  do_log "FATAL gitleaks failed (exit $rc) -- the scan proved nothing"
  sed 's/^/  /' "$log"
  rm -f "$log"
  return 1
}

# A go.mod of a module version the vuln DB still lists. trivy fs reports it
# without pulling a container image, which is the proof the binary works.
_sec_image_control_dir() {
  local d
  d=$(mktemp -d) || return 1
  cat >"$d/go.mod" <<'EOF'
module example.com/sec-scan-image-control

go 1.21

require golang.org/x/text v0.3.5
EOF
  printf '%s\n' "$d"
}

_sec_scan_images() {
  local bin="${SEC_SCAN_TRIVY_BIN:-trivy}"
  _sec_scan_need "$bin" || return 1
  local ctl rc log img
  ctl=$(_sec_image_control_dir) || return 1
  log=$(mktemp)
  do_log "INFO trivy $_SEC_SCAN_TRIVY_VER control (want a vulnerability id, exit 1)"
  rc=0
  SEC_SCAN_PHASE=control "$bin" fs --scanners vuln --severity HIGH,CRITICAL \
    --exit-code 1 --no-progress "$ctl" >"$log" 2>&1 || rc=$?
  rm -rf "$ctl"
  if [[ "$rc" -ne 1 ]] || ! grep -qE 'CVE-[0-9]{4}-[0-9]+|GO-[0-9]{4}-[0-9]+' "$log"; then
    do_log "FATAL control: trivy did not report a vulnerability (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$log"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"

  # The hub image is this base plus a static binary and SQL. The binary is
  # govulncheck's job. Operator python images are not the deployed hub and
  # are not in this list. --ignore-unfixed keeps the gate on issues that
  # have a fix; an unfixed upstream CVE does not redden trunk forever.
  local images="${SEC_SCAN_IMAGES:-gcr.io/distroless/static-debian12:nonroot}"
  for img in $images; do
    log=$(mktemp)
    do_log "INFO trivy image --severity HIGH,CRITICAL --ignore-unfixed $img"
    rc=0
    SEC_SCAN_PHASE=scan "$bin" image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
      --exit-code 1 --no-progress "$img" >"$log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      do_log "FATAL trivy image $img exited $rc"
      sed 's/^/  /' "$log"
      rm -f "$log"
      return 1
    fi
    do_log "INFO trivy: no fixed HIGH/CRITICAL in $img"
    rm -f "$log"
  done
  return 0
}

do_sec_scan() {
  local which="${SEC_SCAN:-}"
  case "$which" in
    go) _sec_scan_go ;;
    wui) _sec_scan_wui ;;
    secrets) _sec_scan_secrets ;;
    images) _sec_scan_images ;;
    all)
      local rc=0
      _sec_scan_go || rc=1
      _sec_scan_wui || rc=1
      _sec_scan_secrets || rc=1
      _sec_scan_images || rc=1
      return "$rc"
      ;;
    *)
      do_log "FATAL SEC_SCAN must be one of: go, wui, secrets, images, all"
      return 1
      ;;
  esac
}
