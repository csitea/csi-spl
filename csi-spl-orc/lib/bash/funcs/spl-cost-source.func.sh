#!/bin/bash
#------------------------------------------------------------------------------
# The cost-source factory (spec 123 section 4.6, build lane 4; owner Q-7:
# "factory design patterns in the code to support for the future").
#
# THE CONTRACT. A cost source NAME (^[a-z][a-z0-9_]{0,31}$) is registered by
# defining one function, anywhere the orc loader sources:
#
#   spl_cost_source_<NAME> DAY OUT
#
# that reads one UTC DAY and writes, under the path prefix OUT:
#   OUT.lines  its cost_lines rows, TSV: project_or_vendor agent_id model kind
#              units origin ("-" = no agent / no model); may be empty
#   OUT.cov    its ONE cost_coverage row: state TAB reason (ok | partial |
#              missing; a reason unless ok)
# or, for a source that writes its own rows and coverage (the GCP reader),
#   OUT.self   one line saying what it wrote.
# A non-zero return is a failed read: the day is `missing`, never 0.
#
# The nightly run (do_spl_cost_rollup_daily) asks this factory for the
# sources named in cnf env.cost.sources (COST_SOURCES overrides) and runs
# each; it names no source in its own code. A new source (a box outside
# GCP, another vendor's usage record) is one new spl_cost_source_<name> and
# one cnf entry: no change to the rollup, the table or the page.
#
# A box source's rows are posted as source "<NAME>.<box>" (one coverage row
# per box and day: a box that did not report is visible), to the hub's
# operator ingest POST /v1/operator/cost/day (csi-spl-api cost_ingest.go).
# Cost data is the owner's only (HUM-10, msg 02803231): nothing here logs an
# amount or a total, only counts.
#------------------------------------------------------------------------------

# spl_cost_source_factory NAME: print the function implementing NAME, or say
# why there is none and return 1.
spl_cost_source_factory() {
  local name="$1"
  [[ "$name" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || { echo "not a cost source name: '$name'" >&2; return 1; }
  declare -F "spl_cost_source_$name" >/dev/null || { echo "no cost source '$name' is registered (no spl_cost_source_$name)" >&2; return 1; }
  printf 'spl_cost_source_%s\n' "$name"
}

# spl_cost_sources [CNF]: the registered sources to run, one per line, from
# COST_SOURCES (space-separated) or the cnf's env.cost.sources.
spl_cost_sources() {
  if [[ -n "${COST_SOURCES:-}" ]]; then
    tr ' ' '\n' <<<"$COST_SOURCES" | grep .
    return 0
  fi
  [[ -r "${1:-}" ]] || { do_log "FATAL no cnf to read env.cost.sources from (and COST_SOURCES is empty)"; return 1; }
  yq -r '.env.cost.sources // [] | .[]' "$1" | grep . ||
    { do_log "FATAL env.cost.sources is empty in $1"; return 1; }
}

# spl_cost_source_run NAME DAY OUT: run NAME through the factory. Always
# leaves either OUT.self or a valid OUT.cov (missing with the reason when the
# source is unknown, failed or broke the contract) and OUT.lines.
spl_cost_source_run() {
  local name="$1" day="$2" out="$3" fn err rc=0
  rm -f "$out.lines" "$out.cov" "$out.self" "$out.err"
  if ! fn="$(spl_cost_source_factory "$name" 2>"$out.err")"; then
    : >"$out.lines"; printf 'missing\t%s\n' "$(head -c 400 "$out.err")" >"$out.cov"; return 0
  fi
  "$fn" "$day" "$out" 2>"$out.err" || rc=$?
  [[ -s "$out.self" ]] && return 0
  [[ -f "$out.lines" ]] || : >"$out.lines"
  err="$(grep -v '^$' "$out.err" | tail -n 1 | tr '\t' ' ' | cut -c 1-300)"
  if (( rc != 0 )); then
    : >"$out.lines"; printf 'missing\tthe %s read failed (rc %d)%s\n' "$name" "$rc" "${err:+: $err}" >"$out.cov"
  elif ! awk -F'\t' 'NR == 1 && ($1 == "ok" || (($1 == "partial" || $1 == "missing") && $2 != "")) { ok = 1 } END { exit !(ok && NR == 1) }' "$out.cov" 2>/dev/null; then
    : >"$out.lines"; printf 'missing\tthe %s source wrote no valid coverage row (contract, spec 123 4.6)\n' "$name" >"$out.cov"
  fi
  return 0
}

# spl_cost_day_json SOURCE DAY RUN_ID OUT: the POST /v1/operator/cost/day body
# from OUT.lines and OUT.cov.
spl_cost_day_json() {
  jq -cn --arg source "$1" --arg day "$2" --arg run "$3" --rawfile lines "$4.lines" --rawfile cov "$4.cov" '
    ($cov | split("\n")[0] | split("\t")) as $c
    | {day: $day, source: $source, run_id: $run,
       coverage: {state: $c[0], reason: ($c[1] // "")},
       lines: [$lines | split("\n")[] | select(. != "") | split("\t")
               | {project_or_vendor: .[0], kind: .[3], units: (.[4] | tonumber), origin: .[5]}
                 + (if .[1] != "-" and .[1] != "" then {agent_id: .[1]} else {} end)
                 + (if .[2] != "-" and .[2] != "" then {model: .[2]} else {} end)]}'
}

# spl_cost_post SOURCE DAY RUN_ID OUT: post one day of one source to the
# ENV hub as the env's service account. Needs do_spl_cloud_cnf,
# spl_hub_operator_url and do_gcp_pin_account to have run. Prints counts.
spl_cost_post() {
  local body
  body="$(spl_cost_day_json "$@")" || { do_log "FATAL cannot build the cost day body of $1 $2"; return 1; }
  spl_hub_operator_call POST /v1/operator/cost/day "$body" || return 1
  if [[ "$SPL_HUB_OP_STATUS" != 200 ]]; then
    do_log "FATAL the hub refused the $1 $2 cost day (http $SPL_HUB_OP_STATUS): $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null | cut -c 1-300)"
    return 1
  fi
  do_log "OK posted $1 $2: $(jq -r '"state=\(.state) lines=\(.lines) written=\(.written) removed=\(.removed)"' <<<"$SPL_HUB_OP_BODY")"
}

# spl_cost_box: the box tag a box source's rows carry (COST_BOX overrides).
spl_cost_box() {
  local b="${COST_BOX:-$(spl_desk_box_default)}"
  b="$(tr '[:upper:]' '[:lower:]' <<<"$b")"
  [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { do_log "FATAL the box tag '$b' is not ^[a-z0-9][a-z0-9-]{0,30}\$ (set COST_BOX)"; return 1; }
  printf '%s\n' "$b"
}

# spl_cost_agent_vendor ROOT ID: the vendor of a spool agent, from its record's
# kind, else its id prefix.
spl_cost_agent_vendor() {
  local kind
  kind="$(jq -r '.kind // empty' "$1/agents/$2.json" 2>/dev/null || true)"
  [[ -n "$kind" ]] || case "$2" in
    a-*|AGY-*) kind=agy ;; g-*|GRK-*) kind=grok ;; m-*) kind=mistral ;; q-*|QWN-*) kind=qwen ;; *) kind=claude ;;
  esac
  printf '%s\n' "$kind"
}

# spl_cost_hub_login: the ENV hub's operator door as the env's service
# account (never the owner account): cnf, hub URL, pinned identity.
spl_cost_hub_login() {
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
}

# spl_cost_reader_post NAME DAY FILE MAPFN: a box reader's own post of its
# day FILE as source NAME.<box>, mapped by MAPFN FILE OUT, when ENV is set and
# DRY_RUN=0. COST_POST=0 (the source adapters, i.e. the rollup) posts nothing.
spl_cost_reader_post() {
  local name="$1" day="$2" file="$3" map="$4" box tmp rc=0
  [[ "${COST_POST:-1}" == 0 ]] && return 0
  if [[ -z "${ENV:-}" || "${DRY_RUN:-1}" != 0 ]]; then
    echo "file only, not posted: ENV=<dev|prd> DRY_RUN=0 posts it as cost source $name.<box>"
    return 0
  fi
  box="$(spl_cost_box)" || return 1
  tmp="$(umask 077 && mktemp -d)" || return 1
  if "$map" "$file" "$tmp/day"; then
    spl_cost_hub_login && spl_cost_post "$name.$box" "$day" "$name-read-$box-$(date -u +%Y%m%dT%H%M%SZ)-$$" "$tmp/day" || rc=1
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

