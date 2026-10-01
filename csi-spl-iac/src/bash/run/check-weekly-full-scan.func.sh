#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The WEEKLY FULL SCAN (owner 2026-10-01: "use 1, but make it
# @description friday at 17:00"). Every scanner the pre-push lint parts run on
# @description touched files runs here over the WHOLE scope, plus the ones too
# @description slow for the hook (checkov, gosec, semgrep, govulncheck, trivy,
# @description OSV, gitleaks full history, pnpm audit), for csi-spl and csi-web,
# @description at CI's versions, configs and baselines. It replaces the weekly
# @description GitHub schedules of those scanners; GitHub keeps only CodeQL (60)
# @description and DAST (68), which cannot run here.
# @description csi-spl is scanned in a throwaway detached worktree of
# @description origin/master through its own do_sec_* actions (a FAIL there is
# @description a finding NEW against the action's baseline). csi-web has no
# @description scanner baselines, so each csi-web row counts its findings and
# @description reports the change against last week's report.
# @description Output: ONE report, <WEEKLY_SCAN_DIR>/<date>.md (one row per
# @description scanner: verdict, findings, change vs last week, seconds, log),
# @description a <date>.tsv for next week's deltas, and <date>.summary.txt, the
# @description short text the cron posts to #spool-hub-ops as OPS-01. No triage,
# @description no issues.
# @description DRY_RUN=1 (the default) prints the plan and scans nothing.
# @param DRY_RUN (optional) - 1 (default) prints the plan; 0 scans
# @param WEEKLY_SCAN_DIR (optional) - default ~/.cache/csi-spl/weekly-scan
# @param WEEKLY_SCAN_WEB (optional) - the csi-web checkout, default csi-web beside the shared csi-spl checkout
# @param WEEKLY_SCAN_ROWS (optional) - space list of row ids to run, default all
# @param WEEKLY_SCAN_ROW_TIMEOUT (optional) - seconds per row, default 1800
# @param WEEKLY_SCAN_DATE (optional) - the report date, default today (box local)
# @example ./run -a do_check_weekly_full_scan
# @example DRY_RUN=0 ./run -a do_check_weekly_full_scan
#------------------------------------------------------------------------------

# csi-spl rows: <id> <do_sec action> [ENV=VAL ...]
_WFS_SPL_ROWS="
spl-shellcheck do_sec_shellcheck
spl-actionlint do_sec_actionlint
spl-hadolint do_sec_hadolint
spl-eslint do_sec_eslint
spl-trufflehog do_sec_trufflehog
spl-checkov do_sec_checkov
spl-gosec do_sec_gosec
spl-semgrep do_sec_semgrep
spl-govulncheck do_sec_scan SEC_SCAN=go
spl-osv do_sec_scan SEC_SCAN=osv
spl-trivy-iac do_sec_scan SEC_SCAN=iac
spl-gitleaks do_sec_scan SEC_SCAN=secrets
spl-pnpm-audit do_sec_scan SEC_SCAN=wui
spl-lint-rest do_check_pre_push_lint PRE_PUSH_MODE=full PRE_PUSH_LINT_ONLY=lint-syntax+lint-mdlinks+lint-compose+lint-py+lint-tf+lint-wui-syntax
"
# csi-web rows (no baselines: counted, compared with last week)
_WFS_WEB_ROWS="web-shellcheck web-actionlint web-hadolint web-config-syntax web-trufflehog web-gitleaks web-typos"

_wfs_root() {
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL APP_PATH is not the csi-spl tree"; return 1
}

_wfs_want() {  # <row-id>
  [[ -z "${WEEKLY_SCAN_ROWS:-}" || " $WEEKLY_SCAN_ROWS " == *" $1 "* ]]
}

# A csi-web row: prints the number of findings, rc 0 when it could run.
_wfs_web_row() {  # <id> <web-root> <spl-root> <log>
  local id="$1" web="$2" spl="$3" log="$4" n rc=0
  local -a files=()
  case "$id" in
    web-shellcheck)
      mapfile -t files < <(git -C "$web" ls-files '*.sh' | sed "s|^|$web/|")
      shellcheck -S error -f gcc "${files[@]}" >"$log" 2>&1 || rc=$?
      [[ "$rc" -le 1 ]] || return 1
      grep -c ': error:' "$log" || true ;;
    web-actionlint)
      ( cd "$web" && SHELLCHECK_OPTS="-e SC2015 -e SC2034 -e SC2001" actionlint -no-color ) >"$log" 2>&1 || rc=$?
      [[ "$rc" -le 1 ]] || return 1
      grep -cE '^[^ ].*:[0-9]+:[0-9]+:' "$log" || true ;;
    web-hadolint)
      mapfile -t files < <(git -C "$web" ls-files | grep -E '(^|/)(Dockerfile(\.[^/]*)?|[^/]*\.dockerfile)$' | sed "s|^|$web/|")
      [[ "${#files[@]}" -gt 0 ]] || { echo 0; return 0; }
      hadolint --config "$spl/.hadolint.yaml" --no-color "${files[@]}" >"$log" 2>&1 || rc=$?
      [[ "$rc" -le 1 ]] || return 1
      grep -cE ' DL[0-9]{4} error| SC[0-9]{4} error' "$log" || true ;;
    web-config-syntax)
      mapfile -t files < <(git -C "$web" ls-files '*.yml' '*.yaml' '*.json' '*.toml' | grep -v node_modules)
      ( cd "$web" && python3 "$spl/csi-spl-iac/src/bash/scripts/config-syntax-check.py" "${files[@]}" ) >"$log" 2>&1 || rc=$?
      [[ "$rc" -le 1 ]] || return 1
      grep -vc '^config-syntax-check:' "$log" || true ;;
    web-trufflehog)
      trufflehog filesystem "$web" --only-verified --no-update --json >"$log" 2>/dev/null || return 1
      grep -c '"DetectorName"' "$log" || true ;;
    web-gitleaks)
      local cfg=(); [[ -f "$web/.gitleaks.toml" ]] && cfg=(--config "$web/.gitleaks.toml")
      gitleaks detect --source "$web" --log-opts=--all --no-banner --redact "${cfg[@]}" \
        --report-format json --report-path "$log.json" --exit-code 0 >"$log" 2>&1 || return 1
      python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])) or []))' "$log.json" ;;
    web-typos)
      ( cd "$web" && typos --config "$spl/_typos.toml" --format brief ) >"$log" 2>&1 || rc=$?
      [[ "$rc" -le 2 ]] || return 1
      grep -c . "$log" || true ;;
  esac
}

# The tools a csi-web row needs (missing -> the row FAILs, it is never skipped).
_wfs_web_tools() {  # <id>
  case "$1" in
    web-shellcheck) echo shellcheck ;; web-actionlint) echo "actionlint shellcheck" ;;
    web-hadolint) echo hadolint ;; web-config-syntax) echo python3 ;;
    web-trufflehog) echo trufflehog ;; web-gitleaks) echo "gitleaks python3" ;; web-typos) echo typos ;;
  esac
}

# Last week's findings for a row (empty when there is no earlier report).
_wfs_last() {  # <dir> <today> <row-id>
  local prev
  prev="$(find "$1" -maxdepth 1 -name '*.tsv' ! -name "$2.tsv" 2>/dev/null | sort | tail -1)"
  [[ -n "$prev" ]] && awk -F'\t' -v r="$3" '$1==r {print $3}' "$prev"
}

do_check_weekly_full_scan() {
  local root web dir date dry="${DRY_RUN:-1}" to="${WEEKLY_SCAN_ROW_TIMEOUT:-1800}"
  root="$(_wfs_root)" || return 1
  # beside the SHARED checkout (the common git dir names it), so the default is
  # the same from an agent worktree, the desk-cron checkout or the shared one
  local common shared
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  shared="$(dirname "${common:-$root/.git}")"
  web="${WEEKLY_SCAN_WEB:-$(dirname "$shared")/csi-web}"
  dir="${WEEKLY_SCAN_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/weekly-scan}"
  date="${WEEKLY_SCAN_DATE:-$(date +%F)}"

  local id act rest
  if [[ "$dry" != 0 ]]; then
    do_log "INFO DRY_RUN weekly full scan plan (report -> $dir/$date.md):"
    while read -r id act rest; do
      [[ -n "$id" ]] && _wfs_want "$id" && echo "  csi-spl  $id  ${rest:+$rest }./run -a $act"
    done <<<"$_WFS_SPL_ROWS"
    for id in $_WFS_WEB_ROWS; do
      _wfs_want "$id" && echo "  csi-web  $id  ($(_wfs_web_tools "$id")) over $web"
    done
    do_log "OK DRY_RUN nothing was scanned. Re-run with DRY_RUN=0."
    return 0
  fi

  mkdir -p "$dir" || return 1
  local logs="$dir/$date.logs"; rm -rf "$logs"; mkdir -p "$logs"
  local tsv="$dir/$date.tsv"; : >"$tsv"

  # csi-spl: a detached worktree of origin/master, so nothing another agent or
  # the desk-cron checkout does mid-scan changes what is scanned.
  local wt="" sha="?" any_spl=0
  while read -r id act rest; do [[ -n "$id" ]] && _wfs_want "$id" && any_spl=1; done <<<"$_WFS_SPL_ROWS"
  if [[ "$any_spl" == 0 ]]; then
    sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '?')"
  elif git -C "$root" fetch -q origin master 2>/dev/null && wt="$(mktemp -d)" \
     && git -C "$root" worktree add -q --detach "$wt" origin/master >/dev/null 2>&1; then
    sha="$(git -C "$wt" rev-parse --short HEAD)"
  else
    do_log "WARN could not make an origin/master worktree -- scanning $root as it is"
    [[ -n "$wt" ]] && rmdir "$wt" 2>/dev/null; wt=""
    sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '?')"
  fi
  local tree="${wt:-$root}"

  local start rc v n last delta secs
  _wfs_row() {  # <repo> <id> <verdict> <findings> <secs>
    last="$(_wfs_last "$dir" "$date" "$2")"
    delta="-"; [[ -n "$last" && "$4" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] && delta="$(( $4 - last ))"
    [[ "$delta" =~ ^[0-9]+$ && "$delta" -gt 0 ]] && delta="+$delta"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$delta" "$5" "$1" >>"$tsv"
  }

  while read -r id act rest; do
    [[ -n "$id" ]] && _wfs_want "$id" || continue
    do_log "INFO weekly scan: $id"
    start=$SECONDS; rc=0
    # shellcheck disable=SC2086
    ( cd "$tree/csi-spl-iac" && timeout -k 10 "$to" env $rest ./run -a "$act" ) >"$logs/$id.log" 2>&1 || rc=$?
    secs=$((SECONDS - start))
    case "$rc" in 0) v=PASS ;; 124|137) v=TIMEOUT ;; *) v=FAIL ;; esac
    # a FAIL of a do_sec action is a finding NEW against its baseline (or a
    # missing tool / control failure, which the log names)
    n="-"; [[ "$v" == PASS ]] && n=0
    _wfs_row csi-spl "$id" "$v" "$n" "$secs"
  done <<<"$_WFS_SPL_ROWS"

  local t miss
  for id in $_WFS_WEB_ROWS; do
    _wfs_want "$id" || continue
    start=$SECONDS
    if [[ ! -d "$web/.git" && ! -f "$web/.git" ]]; then
      _wfs_row csi-web "$id" FAIL - 0; echo "no csi-web checkout at $web" >"$logs/$id.log"; continue
    fi
    miss=""; for t in $(_wfs_web_tools "$id"); do command -v "$t" >/dev/null 2>&1 || miss+=" $t"; done
    if [[ -n "$miss" ]]; then
      _wfs_row csi-web "$id" FAIL - 0; echo "missing tool:$miss -- cd csi-spl-iac && ./run -a do_install_lint_tools" >"$logs/$id.log"; continue
    fi
    do_log "INFO weekly scan: $id"
    if n="$(_wfs_web_row "$id" "$web" "$tree" "$logs/$id.log" | tail -1)" && [[ "$n" =~ ^[0-9]+$ ]]; then
      if [[ "$n" -eq 0 ]]; then v=PASS; else v=FINDINGS; fi
    else
      v=FAIL; n="-"
    fi
    _wfs_row csi-web "$id" "$v" "$n" "$((SECONDS - start))"
  done

  [[ -n "$wt" ]] && { git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; }

  # The report.
  local md="$dir/$date.md" bad=0 total=0 r_id r_v r_n r_d r_s r_repo
  {
    echo "# Weekly full scan $date"
    echo
    echo "csi-spl at origin/master \`$sha\`, csi-web at \`$(git -C "$web" rev-parse --short HEAD 2>/dev/null || echo '?')\`. FAIL on a csi-spl row = a finding NEW against that scanner's baseline (or a tool/control failure, see its log). csi-web has no baselines: FINDINGS rows count everything, with the change vs last week."
    echo
    echo "| repo | scanner | verdict | findings | vs last week | secs | log |"
    echo "|---|---|---|---|---|---|---|"
    while IFS=$'\t' read -r r_id r_v r_n r_d r_s r_repo; do
      echo "| $r_repo | $r_id | $r_v | $r_n | $r_d | $r_s | \`$logs/$r_id.log\` |"
    done <"$tsv"
  } >"$md"
  while IFS=$'\t' read -r r_id r_v _; do
    total=$((total + 1)); [[ "$r_v" == PASS ]] || bad=$((bad + 1))
  done <"$tsv"
  {
    echo "**Weekly full scan $date** (csi-spl \`$sha\` + csi-web): $((total - bad))/$total scanners clean."
    if [[ "$bad" -gt 0 ]]; then
      echo
      echo "| scanner | verdict | findings | vs last week |"
      echo "|---|---|---|---|"
      while IFS=$'\t' read -r r_id r_v r_n r_d _; do
        [[ "$r_v" == PASS ]] || echo "| $r_id | $r_v | $r_n | $r_d |"
      done <"$tsv"
    fi
    echo
    echo "Report on the box: \`$md\`"
  } >"$dir/$date.summary.txt"
  do_log "INFO weekly full scan: $((total - bad))/$total clean -- report $md"
  return 0
}
