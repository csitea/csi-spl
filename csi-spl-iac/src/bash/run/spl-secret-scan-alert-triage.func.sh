#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description Triage one open GitHub secret-scanning alert of this repo
# @description (security round 1 row 8, SPL-1967: alert #1, a LinkedIn client
# @description secret in a test file) WITHOUT printing the secret. Proves it is
# @description a fixture: every location is a test file whose line, at the
# @description alert's commit, holds the alert's secret verbatim, and the
# @description sha256 of the alert's secret equals the sha256 of NO version of
# @description any real Secret Manager secret of SM_ENVS whose id holds the
# @description alert's provider (linkedin_client_secret -> *linkedin*). Real
# @description versions are read by `versions access` straight into sha256sum,
# @description as each env's project SA in a private gcloud config; no value
# @description and no real secret's hash is ever printed or stored.
# @description DRY_RUN=1 (default) prints the proof and the resolution it would
# @description make; DRY_RUN=0 resolves the alert as used_in_tests, and only
# @description when the proof holds. Anything else is refused.
# @param ALERT - required: the alert number
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SM_ENVS (optional) - the envs whose secrets are compared (default "dev prd")
# @param GH_REPO (optional) - owner/repo (default: this checkout's origin, via gh)
# @example ALERT=1 ./run -a do_spl_secret_scan_alert_triage
# @example ALERT=1 DRY_RUN=0 ./run -a do_spl_secret_scan_alert_triage
#------------------------------------------------------------------------------
do_spl_secret_scan_alert_triage() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  local dry="${DRY_RUN:-1}" alert="${ALERT:-}" repo d="$_spl_sdk_dir/alert"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$alert" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL ALERT must be an alert number, got: '$alert'"; return 2; }
  do_require_bin gh git python3 sha256sum || return 1
  repo="${GH_REPO:-$(cd "$APP_PATH" && gh repo view --json nameWithOwner -q .nameWithOwner)}" ||
    { do_log "FATAL cannot tell the repo: set GH_REPO=owner/repo"; return 1; }
  (umask 077 && mkdir -p "$d") || return 1
  gh api "repos/$repo/secret-scanning/alerts/$alert" >"$d/alert.json" || { do_log "FATAL cannot read alert #$alert of $repo"; return 1; }
  gh api "repos/$repo/secret-scanning/alerts/$alert/locations" >"$d/locations.json" || { do_log "FATAL cannot read the locations of alert #$alert"; return 1; }
  local facts stem hash
  facts="$(spl_ssa_fixture_proof "$d")" || { do_log "FATAL alert #$alert is not proven a fixture: refusing"; return 1; }
  grep '^INFO ' <<<"$facts" | while IFS= read -r l; do do_log "$l"; done
  stem="$(sed -n 's/^STEM //p' <<<"$facts")"; stem="${stem%%$'\n'*}"
  hash="$(sed -n 's/^HASH //p' <<<"$facts")"; hash="${hash%%$'\n'*}"
  spl_ssa_real_compare "$hash" "$stem" || { do_log "FATAL alert #$alert is not proven a fixture: refusing"; return 1; }
  local note="security round 1 row 8 (SPL-1967): a test fixture; its sha256 matches no version of any real *$stem* secret (do_spl_secret_scan_alert_triage)"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would resolve alert #$alert of $repo as used_in_tests: $note"
    do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0 to resolve it."
    return 0
  fi
  gh api -X PATCH "repos/$repo/secret-scanning/alerts/$alert" -f state=resolved -f resolution=used_in_tests \
    -f resolution_comment="$note" >/dev/null || { do_log "FATAL could not resolve alert #$alert"; return 1; }
  do_log "OK resolved alert #$alert of $repo as used_in_tests"
}

# spl_ssa_fixture_proof <dir> - from alert.json + locations.json: refuse
# unless the alert is open and every location is a test file whose lines, at
# the alert's commit, hold the secret. Prints INFO lines, "STEM <provider>"
# and "HASH <sha256 of the alert's secret>" (the alert's, not a real one).
spl_ssa_fixture_proof() {
  local d="$1" path sha s e
  python3 - "$d" >"$d/locs.tsv" <<'PY' || return 1
import json, sys
a = json.load(open(sys.argv[1] + "/alert.json"))
if a.get("state") != "open":
    sys.exit(f"ERROR alert state is {a.get('state')}, not open")
for l in json.load(open(sys.argv[1] + "/locations.json")):
    x = l.get("details", {})
    print(f"{x.get('path', '')}\t{x.get('commit_sha', '')}\t{x.get('start_line', 0)}\t{x.get('end_line', 0)}")
PY
  [[ -s "$d/locs.tsv" ]] || { echo "ERROR no location" >&2; return 1; }
  while IFS=$'\t' read -r path sha s e; do
    [[ "$path" =~ (^|/)(tests?|testdata|fixtures)/ || "$path" == *.tst.sh ]] || { echo "ERROR $path is not a test file" >&2; return 1; }
    git -C "$APP_PATH" show "$sha:$path" >"$d/file" 2>/dev/null || { echo "ERROR cannot read $path at $sha" >&2; return 1; }
    sed -n "${s},${e}p" "$d/file" >"$d/lines"
    spl_ssa_hold "$d" "$path:$s at ${sha:0:9}" || return 1
  done <"$d/locs.tsv"
}

# spl_ssa_hold <dir> <where> - the line(s) in <dir>/lines hold the alert's
# secret: print the proof line, STEM and HASH; never the secret.
spl_ssa_hold() {
  python3 - "$@" <<'PY'
import hashlib, json, re, sys
d, where = sys.argv[1:]
a = json.load(open(d + "/alert.json"))
s, lines = a.get("secret") or "", open(d + "/lines").read()
if not s or s not in lines:
    sys.exit(f"ERROR the alert's secret is not on {where}")
i = lines.index(s)
h = hashlib.sha256(s.encode()).hexdigest()
h2 = hashlib.sha256(lines[i:i + len(s)].encode()).hexdigest()
stem = re.split(r"[_-]", a.get("secret_type", ""))[0].lower()
print(f"INFO alert {a['number']} ({a.get('secret_type')}): {where} holds its secret verbatim (sha256 of the fixture string {h2[:12]}..., of the alert secret {h[:12]}...)")
print(f"STEM {stem}")
print(f"HASH {h}")
PY
}

# spl_ssa_real_compare <alert sha256> <stem> - for each env of SM_ENVS, as its
# project SA, every version of every secret whose id holds <stem>: its sha256
# must differ. Fails on a match, or when no such secret was compared at all.
spl_ssa_real_compare() {
  local want="$1" stem="$2" e n=0 hit=0 out
  [[ "$stem" =~ ^[a-z0-9]+$ ]] || { do_log "ERROR no provider in the alert's secret type"; return 1; }
  for e in ${SM_ENVS:-dev prd}; do
    out="$(ENV="$e" spl_ssa_env_compare "$want" "$stem")" || { do_log "ERROR cannot compare the $e secrets"; return 1; }
    n=$((n + ${out%% *})); hit=$((hit + ${out##* }))
  done
  (( n > 0 )) || { do_log "ERROR no real *$stem* secret version was compared: nothing proven"; return 1; }
  (( hit == 0 )) || { do_log "ERROR the alert's secret EQUALS $hit real secret version(s): rotate it, do not close the alert"; return 1; }
  do_log "INFO the alert's sha256 matches none of $n real *$stem* secret version(s) in ${SM_ENVS:-dev prd}"
}

# spl_ssa_env_compare <sha256> <stem> - prints "<versions compared> <matches>"
# for ENV; each value goes from `versions access` straight into sha256sum.
spl_ssa_env_compare() {
  do_gcp_spl_proj_id >&2 || return 1
  do_gcp_pin_account >&2 || return 1
  local p="$PROJ_ID" a="$GCP_ACCOUNT" s v h n=0 hit=0
  for s in $(gcloud secrets list --project="$p" --account="$a" --format='value(name.basename())' --quiet </dev/null | grep -F -- "$2"); do
    for v in $(gcloud secrets versions list "$s" --project="$p" --account="$a" --filter='state!=DESTROYED' --format='value(name.basename())' --quiet </dev/null); do
      h="$(gcloud secrets versions access "$v" --secret="$s" --project="$p" --account="$a" --quiet </dev/null | sha256sum)" || return 1
      n=$((n + 1)); [[ "${h%% *}" == "$1" ]] && hit=$((hit + 1))
    done
  done
  echo "$n $hit"
}
