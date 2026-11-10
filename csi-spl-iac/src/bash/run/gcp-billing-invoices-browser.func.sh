#!/bin/bash
#------------------------------------------------------------------------------
# @description Save every billing account's invoice PDFs of the last 12 months
# @description from the Cloud console in a browser (spec 123 section 15,
# @description SPL-5220, the owner's choice B). No Google API returns them.
# @description
# @description The OWNER runs it at his own desk, as himself. It refuses when
# @description it sees an agent: AGENT_ID, SPOOL_AGENT_ID or CLAUDECODE set,
# @description SUDO_USER set (the fleet wraps agent calls in sudo, which drops
# @description the other markers), or an ancestor process named claude, agy,
# @description grok, vibe or qwen. It also refuses without a terminal and
# @description without a display. These are the only checks; a caller that
# @description hides all of them gets through, so nothing worth taking is kept:
# @description Chrome runs on a THROWAWAY profile (a mktemp dir, mode 700,
# @description removed when the run ends, on Ctrl-C and on TERM/HUP too), the
# @description owner logs in there himself each run, and no session, password
# @description or cookie survives the run or is read, printed or logged.
# @description
# @description FRAGILE: it reads the console's billing documents page, which
# @description Google may change at any time (then it says so and exits 2).
# @description
# @description playwright-core is PINNED to 1.65.0 and installed AT RUN TIME on
# @description the owner's desk (npm, into BILLING_PW_DIR, default
# @description $HOME/.cache/<org>-<app>/playwright-core-1.65.0), once; it drives
# @description the installed google-chrome and downloads no browser.
# @description
# @description The accounts: BILLING_ACCOUNT_IDS (comma list), else the
# @description accounts.tsv of the newest do_gcp_billing_invoices_fetch run.
# @description The PDFs go to <BILLING_OUT_DIR>/pdf/<account>/<date>-<number>.pdf,
# @description where do_gcp_billing_invoices_fetch ticks them off.
# @param BILLING_ACCOUNT_IDS (optional) - the accounts, comma separated
# @param BILLING_MONTHS (optional) - how many months, default 12
# @param BILLING_TODAY (optional) - the day of the call, YYYY-MM-DD, default today (UTC)
# @param BILLING_DRY (optional) - 1: list what it would save, save nothing
# @param BILLING_CHROME (optional) - the browser, default google-chrome
# @example ./run -a do_gcp_billing_invoices_browser
# @example BILLING_DRY=1 ./run -a do_gcp_billing_invoices_browser
#------------------------------------------------------------------------------
GBB_PLAYWRIGHT_CORE_VERSION=1.65.0

do_gcp_billing_invoices_browser() {
  local today="${BILLING_TODAY:-$(date -u +%F)}" n="${BILLING_MONTHS:-12}" chrome pwdir ids js
  _gbb_owner_only || return 1
  do_gcp_billing_months "${today}" "${n}" >/dev/null || return 1
  do_resolve_oap ORG
  do_resolve_oap APP
  do_gcp_billing_cnf || return 1
  chrome=$(command -v "${BILLING_CHROME:-google-chrome}") || { do_log "FATAL no ${BILLING_CHROME:-google-chrome} (BILLING_CHROME)"; return 1; }
  ids=$(_gbb_accounts) || return 1
  pwdir="${BILLING_PW_DIR:-${HOME}/.cache/${ORG}-${APP}/playwright-core-${GBB_PLAYWRIGHT_CORE_VERSION}}"
  _gbb_playwright "${pwdir}" || return 1
  js="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src/js/billing-invoices/download.mjs"
  [[ -f "${js}" ]] || { do_log "FATAL no ${js}"; return 1; }
  do_log "INFO $(tr ',' '\n' <<<"${ids}" | grep -c .) account(s), ${n} months to ${today}, playwright-core ${GBB_PLAYWRIGHT_CORE_VERSION}, DRY=${BILLING_DRY:-0}"
  BILLING_ACCOUNTS="${ids}" BILLING_TODAY="${today}" BILLING_MONTHS="${n}" BILLING_PDF_DIR="${BILL_OUT_ROOT}/pdf" \
    BILLING_PW_DIR="${pwdir}" BILLING_CHROME="${chrome}" BILLING_DRY="${BILLING_DRY:-0}" \
    _gbb_throwaway node "${js}"
}

# _gbb_throwaway <cmd...> - run <cmd> with TMPDIR set to a fresh mode-700
# mktemp dir, where Chrome keeps its profile (playwright's launch() puts its
# user-data-dir under TMPDIR), and remove that dir when <cmd> ends, on Ctrl-C,
# TERM and HUP too. Only a SIGKILL leaves it, under the system tmp dir.
_gbb_throwaway() (
  local tmp rc
  tmp=$(mktemp -d) || { do_log "FATAL cannot make the throwaway profile dir"; exit 1; }
  chmod 700 "${tmp}"
  trap 'rm -rf "${tmp}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  TMPDIR="${tmp}" "$@"
  rc=$?
  exit "${rc}"
)

# _gbb_owner_only - a person at a terminal with a display; refuses every agent
# marker it can see (the env markers, sudo, an agent binary up the tree).
_gbb_owner_only() {
  local c
  if [[ -n "${AGENT_ID:-}${SPOOL_AGENT_ID:-}${CLAUDECODE:-}" ]]; then
    do_log "FATAL an agent never runs this: the owner runs it at his own desk and logs in himself"
    return 1
  fi
  [[ -z "${SUDO_USER:-}" ]] || { do_log "FATAL run under sudo: an agent never runs this; the owner runs it as himself"; return 1; }
  while read -r c; do
    case "${c}" in
      claude | agy | grok | vibe | qwen) do_log "FATAL an agent never runs this (${c} is an ancestor process): the owner runs it at his own desk"; return 1 ;;
    esac
  done < <(_gbb_ancestor_comms)
  [[ -t 0 ]] || { do_log "FATAL no terminal: the owner runs it by hand"; return 1; }
  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || { do_log "FATAL no display: it opens a visible Chrome for the owner's login"; return 1; }
  for c in node npm; do command -v "${c}" &>/dev/null || { do_log "FATAL ${c} is not installed"; return 1; }; done
}

# _gbb_ancestor_comms - the comm of every ancestor of this shell, nearest
# first, read from /proc (PPid in status), up to pid 1.
_gbb_ancestor_comms() {
  local p="${BASHPID}" n=0
  while [[ "${p}" =~ ^[0-9]+$ ]] && ((p > 1 && n < 64)); do
    p=$(awk '/^PPid:/ {print $2}' "/proc/${p}/status" 2>/dev/null) || break
    [[ "${p}" =~ ^[0-9]+$ ]] && ((p > 1)) || break
    cat "/proc/${p}/comm" 2>/dev/null
    n=$((n + 1))
  done
}

# _gbb_accounts - BILLING_ACCOUNT_IDS, else the newest fetch run's accounts.tsv.
_gbb_accounts() {
  local ids="${BILLING_ACCOUNT_IDS:-}" tsv
  if [[ -z "${ids}" ]]; then
    tsv=$(for f in "${BILL_OUT_ROOT}"/[0-9]*/accounts.tsv; do [[ -s "${f}" ]] && echo "${f}"; done | sort | tail -n 1)
    [[ -n "${tsv}" ]] || { do_log "FATAL no BILLING_ACCOUNT_IDS and no do_gcp_billing_invoices_fetch run to read them from: run it first" >&2; return 1; }
    ids=$(cut -f1 "${tsv}" | paste -sd, -)
  fi
  [[ "${ids}" =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}(,[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6})*$ ]] \
    || { do_log "FATAL the account ids are no billing account ids (XXXXXX-XXXXXX-XXXXXX, comma separated)" >&2; return 1; }
  printf '%s' "${ids}"
}

# _gbb_playwright <dir> - the pinned playwright-core, installed once into <dir>.
_gbb_playwright() {
  local dir="$1" have
  have=$(jq -r '.version // ""' "${dir}/node_modules/playwright-core/package.json" 2>/dev/null)
  [[ "${have}" == "${GBB_PLAYWRIGHT_CORE_VERSION}" ]] && return 0
  do_log "INFO installing playwright-core@${GBB_PLAYWRIGHT_CORE_VERSION} into BILLING_PW_DIR (once; no browser download)"
  mkdir -p "${dir}" || { do_log "FATAL cannot make BILLING_PW_DIR"; return 1; }
  [[ -f "${dir}/package.json" ]] || printf '{"private":true}\n' >"${dir}/package.json"
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --prefix "${dir}" --no-audit --no-fund --silent \
    "playwright-core@${GBB_PLAYWRIGHT_CORE_VERSION}" >/dev/null || { do_log "FATAL npm install playwright-core@${GBB_PLAYWRIGHT_CORE_VERSION} failed"; return 1; }
}
