#!/bin/bash
#------------------------------------------------------------------------------
# @description The weekly tax index sync (spec 143 taxes-tab.md section 3
# @description step 1, build slice S4, SPL-6438; owner HUM-10, csitea topic
# @description dc7c9c9a, msg fc8f964e: "Weekly, after the weekly tax check"):
# @description read one <year>/index.tsv of the main box's private tax project
# @description (read only) and POST it as one snapshot to the hub's
# @description /v1/operator/tax/snapshots, as the env's project service
# @description account, into the tax workspace (cnf SPOOL_HUB_TAX_WORKSPACE).
# @description The header must be exactly the nine columns arrival_date, kind,
# @description type, tax_type, period, due_date, category, sha256, file_name
# @description (a changed index never leaks a new column); file_name is never
# @description sent: the documents stay on the main box. Dates are YYYY-MM-DD
# @description or D.M.YYYY. Nothing printed or logged carries a row's value:
# @description counts, the tax year and the snapshot id only.
# @description DRY_RUN=1 (default): read and check the index, call nothing.
# @param ENV (required) - dev or prd
# @param TAX_INDEX_FILE (required) - the year's index.tsv, e.g. <tax project>/2026/index.tsv
# @param TAX_YEAR (optional) - the tax year, default the index's parent dir name (YYYY)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TAX_INDEX_FILE=<tax project>/2026/index.tsv ./run -a do_spl_tax_sync
# @example ENV=prd TAX_INDEX_FILE=<tax project>/2026/index.tsv DRY_RUN=0 ./run -a do_spl_tax_sync
#------------------------------------------------------------------------------
do_spl_tax_sync() {
  do_require_bin jq || return 1
  local dry=1 d year n
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_require_cloud_env || return 1
  d="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$d'; trap - RETURN" RETURN
  _spl_tax_body "$d/body.json" || return 1
  year="$(jq -r '.tax_year' "$d/body.json")" n="$(jq -r '.documents | length' "$d/body.json")"
  if (( dry )); then
    do_log "OK DRY_RUN would file $n document(s) of tax year $year in $ENV; sent nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_require_bin yq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call POST /v1/operator/tax/snapshots "@$d/body.json" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
    { do_log "FATAL the tax snapshot was not filed (http $SPL_HUB_OP_STATUS, $(jq -r '.error // "no error code"' <<<"$SPL_HUB_OP_BODY" 2>/dev/null))"; return 1; }
  do_log "OK filed tax snapshot $(jq -r '.snapshot_id' <<<"$SPL_HUB_OP_BODY"): $(jq -r '.documents' <<<"$SPL_HUB_OP_BODY") document(s) of tax year $year on $SPL_HUB_URL ($ENV)"
}

# _spl_tax_body <out> -> writes the snapshot body from TAX_INDEX_FILE and
# TAX_YEAR. Every refusal is made here, before cnf, gcloud or the hub, and
# names no value of the index (a row is named by its line number only).
_spl_tax_body() {
  local out="$1" f="${TAX_INDEX_FILE:-}" year="${TAX_YEAR:-}" want head
  [[ -n "$f" ]] || { do_log "FATAL TAX_INDEX_FILE is required: the year's index.tsv"; return 1; }
  [[ -f "$f" && -r "$f" ]] || { do_log "FATAL TAX_INDEX_FILE is not a readable file"; return 1; }
  [[ -n "$year" ]] || year="$(basename "$(dirname "$f")")"
  [[ "$year" =~ ^20[0-9]{2}$ ]] || { do_log "FATAL TAX_YEAR must be YYYY (or the index's parent dir named so)"; return 1; }
  want=$'arrival_date\tkind\ttype\ttax_type\tperiod\tdue_date\tcategory\tsha256\tfile_name'
  head="$(head -n 1 "$f" | tr -d '\r')"
  [[ "$head" == "$want" ]] || { do_log "FATAL the index header is not the nine known columns (arrival_date..file_name, tab-separated): refused, nothing sent"; return 1; }
  local uuid
  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || uuid="$(uuidgen 2>/dev/null)"
  [[ "$uuid" =~ ^[0-9a-f-]{36}$ ]] || { do_log "FATAL no uuid source"; return 1; }
  # one document per non-empty row; file_name (column 9) is dropped here
  tail -n +2 "$f" | tr -d '\r' | jq -R -s --arg id "$uuid" --argjson y "$year" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def day: if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . elif test("^[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{4}$")
      then (split(".") | "\(.[2])-\(.[1] | if length == 1 then "0" + . else . end)-\(.[0] | if length == 1 then "0" + . else . end)")
      else error("date") end;
    [split("\n") | to_entries[] | select(.value != "") | (.key + 2) as $line | (.value | split("\t")) as $c
      | if ($c | length) != 9 then error("line \($line): \($c | length) columns, want 9") else . end
      | {arrival_date: ($c[0] | try day catch error("line \($line): arrival_date")), kind: $c[1], doc_type: $c[2],
         tax_type: $c[3], period: $c[4], due_date: (if $c[5] == "" then "" else ($c[5] | try day catch error("line \($line): due_date")) end),
         category: $c[6], content_sha256: ($c[7] | ascii_downcase)}] as $docs
    | if ($docs | length) > 10000 then error("more than 10000 rows") else . end
    | {snapshot_id: $id, tax_year: $y, taken_at: $at, documents: $docs}' >"$out" 2>"$out.err" ||
    { do_log "FATAL the index was refused, nothing sent: $(sed -n 's/^jq: error (at [^)]*): //p' "$out.err" | head -1 | cut -c1-80)"; return 1; }
}
