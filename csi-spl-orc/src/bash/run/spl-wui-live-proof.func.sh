#!/bin/bash
#------------------------------------------------------------------------------
# @description Run the level 1 / level 2 live proof (spec 033 T010, T014)
# @description against one env's deployed WUI, signed in as the probe member:
# @description the step workflow 30 runs after each deploy (spec 033 T015,
# @description SPL-12). The member's email and workspace are cnf
# @description (env.wui.live_proof_email / live_proof_tenant), never secret.
# @description The password comes ONLY from the env var SPL_PROBE_PW (wf 30
# @description maps the GitHub secret SPL_PROBE_PW_<ENV> onto it): it is
# @description written to a 0600 temp file for the proof's PW_FILE, removed
# @description when the run ends, never printed and never on a command line;
# @description the proof itself runs without it in its environment.
# @description An absent password or cnf member SKIPS with a ::notice:: naming
# @description what is missing and returns 0: it never fails a deploy for that.
# @description A proof that runs and fails returns 1.
# @description Surfaces: channel, lobby, home, t (dm needs an agent peer).
# @description The channel and t surfaces post into the hidden members-only
# @description test channel (cnf env.wui.live_proof_channel, default probe;
# @description owner answer 5cb37834, SPL-1632), never #lobby: lobby only
# @description renders /lobby and opens a topic there, it posts nothing.
# @description Create the channel once per env with do_spl_channel_create
# @description (ORDERED_BY = the probe member, so only it is seated).
# @param ENV - required: dev or prd
# @param SPL_PROBE_PW (optional) - the probe member's password; empty = skip
# @param LIVE_PROOF_BASE (optional) - default https://<cnf env.dns.fqdn>
# @param LIVE_PROOF_SURFACES (optional) - default channel,lobby,home,t
# @param LIVE_PROOF_OUT (optional) - the proof's evidence dir, default a temp dir
# @param LIVE_PROOF_CMD (optional) - the proof command, default node <wui>/tests/e2e/parent-level-live.proof.mjs (the tests' seam)
# @example ENV=dev ./run -a do_spl_wui_live_proof
#------------------------------------------------------------------------------
do_spl_wui_live_proof() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local org_app app cnf secret
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  app="$(cd "$PROJ_PATH/.." && pwd)"
  cnf="$app/$org_app-cnf/$org_app/${ENV}.env.json"
  secret="SPL_PROBE_PW_${ENV^^}"
  [[ -r "$cnf" ]] || { do_log "FATAL no readable cnf $cnf"; return 1; }
  local fqdn email tenant channel
  { read -r fqdn; read -r email; read -r tenant; read -r channel; } < <(python3 - "$cnf" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["env"]
w = e.get("wui", {})
print(e.get("dns", {}).get("fqdn", ""))
print(str(w.get("live_proof_email") or "").strip())
print(str(w.get("live_proof_tenant") or "").strip())
print(str(w.get("live_proof_channel") or "probe").strip())
PY
  )
  if [[ -z "${SPL_PROBE_PW:-}" ]]; then
    echo "::notice::$ENV live proof skipped: the GitHub secret $secret is not set (spec 033 T015)"
    return 0
  fi
  if [[ -z "$email" || -z "$tenant" ]]; then
    echo "::notice::$ENV live proof skipped: cnf env.wui.live_proof_email / live_proof_tenant is not set (spec 033 T015)"
    return 0
  fi
  case "$channel" in
    lobby|general) do_log "FATAL cnf env.wui.live_proof_channel is #$channel: the live proof posts only into its hidden test channel (SPL-1632)"; return 1 ;;
  esac
  local base="${LIVE_PROOF_BASE:-https://$fqdn}" surfaces="${LIVE_PROOF_SURFACES:-channel,lobby,home,t}" out pwf rc=0
  out="${LIVE_PROOF_OUT:-$(mktemp -d)}"
  pwf="$(umask 077 && mktemp)" || return 1
  printf '%s' "$SPL_PROBE_PW" >"$pwf"
  local -a cmd=(node "$app/$org_app-wui/tests/e2e/parent-level-live.proof.mjs")
  [[ -n "${LIVE_PROOF_CMD:-}" ]] && read -r -a cmd <<<"$LIVE_PROOF_CMD"
  do_log "INFO $ENV live proof: $base, workspace $tenant, as $email, channel #$channel, surfaces $surfaces"
  env -u SPL_PROBE_PW -u "$secret" BASE="$base" EMAIL="$email" PW_FILE="$pwf" OUT="$out" \
    TENANT="$tenant" CHANNEL="$channel" SURFACES="$surfaces" "${cmd[@]}" || rc=$?
  rm -f "$pwf"
  if [[ $rc -ne 0 ]]; then
    echo "::error::$ENV live proof failed (rc $rc): see the FAIL lines above, evidence in $out"
    return 1
  fi
  do_log "INFO $ENV live proof: every step PASS"
}
