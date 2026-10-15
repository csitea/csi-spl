#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description READ-ONLY age report of one env's secrets (security round 1
# @description row 6, SPL-1967): every Secret Manager secret with its enabled
# @description versions (number, create date, age in days) and every
# @description user-managed service account key (SA, key id prefix, created,
# @description age, expiry), as markdown. Flags: EMPTY (0 enabled versions:
# @description the owner decides keep or drop), MULTI (more than one enabled
# @description version: the older ones are still usable), OVER (older than the
# @description max age of its class), NO-EXPIRY (a key that never expires).
# @description The max ages are cnf env.secrets.max_age_days.secret_version and
# @description .sa_key, in days; null = not set (the owner decides after the
# @description inventory, SPL-1945), and then nothing is OVER.
# @description Metadata only: it never runs `versions access`, so no value is
# @description read. Runs as the env's project SA in a private gcloud config.
# @description Exit 1 when anything is OVER, else 0.
# @param ENV - required: dev or prd
# @param SECRET_AGE_NOW (optional) - the UTC instant ages count to (tests), default now
# @example ENV=prd ./run -a do_spl_secret_age_report
#------------------------------------------------------------------------------
do_spl_secret_age_report() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_require_bin yq python3 || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml" d="$_spl_sdk_dir/dump"
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  local max_sec max_key
  max_sec="$(yq -r '.env.secrets.max_age_days.secret_version // ""' "$cnf")"
  max_key="$(yq -r '.env.secrets.max_age_days.sa_key // ""' "$cnf")"
  [[ -z "$max_sec" || "$max_sec" =~ ^[1-9][0-9]*$ ]] && [[ -z "$max_key" || "$max_key" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL env.secrets.max_age_days must be positive whole days or null, got: secret_version='$max_sec' sa_key='$max_key'"; return 1; }

  do_gcp_pin_account || return 1
  spl_secret_age_dump "$p" "$GCP_ACCOUNT" "$d" || return 1
  python3 - "$d" "$p" "${max_sec:-}" "${max_key:-}" "${SECRET_AGE_NOW:-}" <<'PY'
import datetime as dt, json, os, sys
d, proj, max_sec, max_key, now = sys.argv[1:]
max_sec, max_key = (int(x) if x else None for x in (max_sec, max_key))
now = dt.datetime.fromisoformat(now.replace("Z", "+00:00")) if now else dt.datetime.now(dt.timezone.utc)
def ld(f):
    with open(os.path.join(d, f)) as fh: return json.load(fh)
def ts(s): return dt.datetime.fromisoformat(s.replace("Z", "+00:00")[:19] + "+00:00")
def age(s): return (now - ts(s)).days
cap = lambda m: f"max age {m} d" if m else "max age not set: the owner decides, SPL-1945"
over = 0
print(f"## {proj}: Secret Manager ({cap(max_sec)})\n")
print("| secret | enabled | enabled versions (n: created, age d) | flags |\n|---|---|---|---|")
for name in sorted(os.listdir(os.path.join(d, "secret"))):
    vs = [v for v in ld(f"secret/{name}") if v.get("state") == "ENABLED"]
    vs.sort(key=lambda v: int(v["name"].split("/")[-1]))
    flags = []
    if not vs: flags.append("EMPTY")
    if len(vs) > 1: flags.append("MULTI")
    if max_sec and any(age(v["createTime"]) > max_sec for v in vs): flags.append("OVER"); over += 1
    cell = ", ".join(f'{v["name"].split("/")[-1]}: {v["createTime"][:10]}, {age(v["createTime"])}' for v in vs) or "-"
    print(f"| {name[:-5]} | {len(vs)} | {cell} | {' '.join(flags)} |")
print(f"\n## {proj}: user-managed service account keys ({cap(max_key)})\n")
print("| service account | key | created | age d | expires | flags |\n|---|---|---|---|---|---|")
for name in sorted(os.listdir(os.path.join(d, "sa"))):
    for k in sorted(ld(f"sa/{name}"), key=lambda k: k.get("validAfterTime", "")):
        flags = ["DISABLED"] if k.get("disabled") else []
        exp = k.get("validBeforeTime", "")[:10]
        if exp.startswith("9999"): flags.append("NO-EXPIRY"); exp = "never"
        a = age(k["validAfterTime"])
        if max_key and a > max_key and not k.get("disabled"): flags.append("OVER"); over += 1
        print(f'| {name[:-5]} | {k["name"].split("/")[-1][:8]} | {k["validAfterTime"][:10]} | {a} | {exp} | {" ".join(flags)} |')
print(f"\nOVER: {over}")
sys.exit(1 if over else 0)
PY
}

# spl_secret_age_dump <project> <account> <dir> - the metadata the report
# reads: <dir>/secret/<name>.json (its versions) and <dir>/sa/<email>.json
# (its user-managed keys). A list that fails is a failure, never an empty row.
spl_secret_age_dump() {
  local p="$1" a="$2" d="$3" s e
  mkdir -p "$d/secret" "$d/sa" || return 1
  _sad() { gcloud "$@" --project="$p" --account="$a" --format=json --quiet </dev/null; }
  _sad secrets list >"$d/secrets.json" || { do_log "FATAL cannot list the secrets of $p as $a"; return 1; }
  for s in $(python3 -c 'import json,sys;[print(x["name"].split("/")[-1]) for x in json.load(open(sys.argv[1]))]' "$d/secrets.json"); do
    _sad secrets versions list "$s" >"$d/secret/$s.json" || { do_log "FATAL cannot list the versions of $s"; return 1; }
  done
  _sad iam service-accounts list >"$d/sas.json" || { do_log "FATAL cannot list the service accounts of $p"; return 1; }
  for e in $(python3 -c 'import json,sys;[print(x["email"]) for x in json.load(open(sys.argv[1]))]' "$d/sas.json"); do
    _sad iam service-accounts keys list --iam-account="$e" --managed-by=user >"$d/sa/$e.json" ||
      { do_log "FATAL cannot list the keys of $e"; return 1; }
  done
  unset -f _sad
}
