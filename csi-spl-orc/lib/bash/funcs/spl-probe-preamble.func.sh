#!/bin/bash
#------------------------------------------------------------------------------
# The shared preamble of the live reply probes (backfill, fallback,
# reply-count, reply, topic-reply): the bins and cnf, the DRY_RUN gate, the
# tenant, the throwaway probe box, the dry-run report and the root key + member
# password files. Each probe calls them in its own order, so every FATAL line
# and every rc is the one the probe printed before (each probe's .tst.sh greps
# them).
#
# These helpers never `exit` and never set a trap. A RETURN trap set in a
# helper fires when the HELPER returns, before the caller reads its
# out-params: any cleanup trap stays in the caller.
#------------------------------------------------------------------------------

# spl_probe_preamble <dry_out> <tenant> [t1_reason]: yq + python3, the cloud
# cnf, the DRY_RUN gate and the tenant slug. Sets <dry_out> to 1 (dry run) or
# 0. A non-empty t1_reason refuses TENANT_ID=t1 with that reason.
spl_probe_preamble() {
  local _spp_out="$1" _spp_tenant="$2" _spp_t1="${3:-}" _spp_drc
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  if spl_dry_run; then
    printf -v "$_spp_out" '%s' 1
  else
    _spp_drc=$?
    [[ $_spp_drc -eq 1 ]] || return 1
    printf -v "$_spp_out" '%s' 0
  fi
  spl_require_tenant_slug "$_spp_tenant" || return 1
  [[ -z "$_spp_t1" || "$_spp_tenant" != t1 ]] || { do_log "FATAL TENANT_ID=t1 is a real tenant: $_spp_t1"; return 1; }
}

# spl_probe_box_ok <box>: 0 for a throwaway box-* id, else FATAL and 1.
spl_probe_box_ok() {
  local box="$1"
  [[ "$box" =~ ^box-[a-z0-9][a-z0-9-]{0,26}$ && "$box" != box-wui && "$box" != box-desk ]] ||
    { do_log "FATAL PROBE_BOX must be a throwaway box-* id (not box-wui / box-desk), got: '$box'"; return 1; }
}

# spl_probe_dry_report <would>...: one "INFO DRY_RUN would: <would>" line per
# argument, then the "nothing was sent" line. Returns 0; the caller returns.
spl_probe_dry_report() {
  local line
  for line in "$@"; do
    do_log "INFO DRY_RUN would: $line"
  done
  do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
}

# spl_probe_secrets <tenant> <key_out> <pw_out> <bin>...: resolves ROOT_KEY and
# MEMBER_PW_FILE (default the tenant's m3-e2e state), refuses a key that is
# empty or not 0600 and a pw file that is not readable, then requires the bins
# and the host spool. Sets <key_out> and <pw_out> to the two paths.
spl_probe_secrets() {
  local _sps_tenant="$1" _sps_key_out="$2" _sps_pw_out="$3"
  shift 3
  local _sps_key="${ROOT_KEY:-$SPL_STATE_DIR/m3-e2e/$_sps_tenant/root.key}"
  local _sps_pw="${MEMBER_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$_sps_tenant/pw-human}"
  [[ -s "$_sps_key" && "$(stat -c %a "$_sps_key")" == 600 ]] || { do_log "FATAL ROOT_KEY $_sps_key must be a non-empty 0600 file"; return 1; }
  [[ -r "$_sps_pw" ]] || { do_log "FATAL no readable password file $_sps_pw (set MEMBER_PW_FILE)"; return 1; }
  printf -v "$_sps_key_out" '%s' "$_sps_key"
  printf -v "$_sps_pw_out" '%s' "$_sps_pw"
  do_require_bin "$@" || return 1
  spl_host_spool || return 1
}
