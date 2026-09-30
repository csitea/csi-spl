#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description IaC scan (Checkov) of the terraform tree, gated against the
# @description checked-in .checkov.baseline so only NEW misconfig fails. Runs a
# @description negative control first: a planted insecure GCS bucket Checkov MUST
# @description flag. A tool that reports nothing on it proves nothing and the
# @description action fails closed. A missing tool fails closed; never a skip.
# @param SEC_CHECKOV_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_CHECKOV_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_CHECKOV_DIR (optional) - terraform dir; default csi-spl-iac/src/terraform
# @example ./run -a do_sec_checkov
#------------------------------------------------------------------------------

_SEC_CHECKOV_VER=3.3.21

_sec_checkov_root() {
  if [[ -n "${SEC_CHECKOV_ROOT:-}" ]]; then printf '%s\n' "$SEC_CHECKOV_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_CHECKOV_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_checkov_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

# A terraform file Checkov flags (a GCS bucket missing uniform access, versioning,
# logging, ...). Directory removed by the caller.
_sec_checkov_control_dir() {
  local d
  d=$(mktemp -d) || return 1
  cat >"$d/main.tf" <<'EOF'
resource "google_storage_bucket" "control" {
  name     = "checkov-control-bucket"
  location = "EU"
}
EOF
  printf '%s\n' "$d"
}

do_sec_checkov() {
  local bin="${SEC_CHECKOV_BIN:-checkov}"
  _sec_checkov_need "$bin" || return 1
  local root tfdir baseline ctl rc
  root=$(_sec_checkov_root) || return 1
  tfdir="${SEC_CHECKOV_DIR:-$root/csi-spl-iac/src/terraform}"
  [[ -d "$tfdir" ]] || { do_log "FATAL no terraform dir at $tfdir"; return 1; }
  baseline="$tfdir/.checkov.baseline"
  [[ -f "$baseline" ]] || { do_log "FATAL no $baseline -- checkov without a baseline is not this gate"; return 1; }

  # --- control: checkov must flag the planted insecure bucket ---------------
  ctl=$(_sec_checkov_control_dir) || return 1
  do_log "INFO checkov $_SEC_CHECKOV_VER control (want a failed check on an insecure bucket)"
  rc=0
  ( SEC_CHECKOV_PHASE=control "$bin" -d "$ctl" --compact --quiet ) >/dev/null 2>&1 || rc=$?
  rm -rf "$ctl"
  if [[ "$rc" -eq 0 ]]; then
    do_log "FATAL control: checkov reported no failure on an insecure bucket -- the check proved nothing"
    return 1
  fi

  # --- scan: terraform tree against the baseline -----------------------------
  do_log "INFO checkov -d $tfdir --baseline .checkov.baseline"
  local log; log=$(mktemp)
  rc=0
  ( SEC_CHECKOV_PHASE=scan "$bin" -d "$tfdir" --baseline "$baseline" --compact --quiet ) >"$log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    do_log "INFO checkov: no new terraform misconfig beyond the baseline"
    rm -f "$log"
    return 0
  fi
  do_log "FATAL checkov: NEW terraform misconfig beyond the baseline (or tool error, exit $rc)"
  sed 's/^/  /' "$log" | tail -40
  rm -f "$log"
  return 1
}
