#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Spec 142 section 5.2, row B4: the recorded install. An agent
# @description installs apt packages through this action instead of a raw
# @description `sudo apt-get install`; it keeps sudo, nothing is refused. In order:
# @description   1. simulate: `apt-get -s install`, the closure = every Inst line
# @description   2. flag: do_box_pkg_flag (5.3) on the simulation; a FLAG sends
# @description      ONE note to the orchestrator BEFORE the install (never a
# @description      blocker, never the owner) and stops nothing
# @description   3. snapshot (flagged only): dpkg selections, the resolv.conf
# @description      link + content, nsswitch.conf and the network config dirs
# @description   4. journal: the intent line BEFORE the install, a result line after
# @description   5. install: `apt-get install -y` of the request (not the closure)
# @description   6. verify: dpkg-query `install ok installed` per package, then the
# @description      hub health probe (resolve the hub host, fetch /version); red
# @description      after a flagged install calls the auto-undo hook (row B6)
# @description   7. print the manifest row for the agent's lane commit (D3)
# @description DRY_RUN=1 (the default) runs 1 and 2, prints 3..7 and the exact
# @description re-run line with DRY_RUN=0. Journal columns (TAB; drift reads
# @description them): utc box agent issue op requested closure flag snapshot reason.
# @description Exit: 0 done, 1 refused or nothing installed, 4 apt-get install
# @description failed, 5 a package not installed after it, 6 hub health red.
# @param BOX_PKG (required) - the package(s), space separated
# @param BOX_PKG_REASON (required) - why, free text, journaled
# @param AGENT_ID (required) - who, journaled and the note's sender
# @param BOX_PKG_ISSUE (optional) - SPL-n of the lane that needs it
# @param DRY_RUN (optional) - 1 (default) plan only; 0 install
# @param BOX_PKG_JOURNAL (optional) - default /var/lib/csi-spl/box-pkg/journal.tsv
# @param BOX_PKG_BACKUP_DIR (optional) - default /var/backups/box-pkg
# @param BOX_PKG_ROOT (optional) - root the snapshot reads under, default /
# @param BOX_PKG_SERVICES (optional) - the service map, default cnf env.box.pkg_services
# @param BOX_PKG_HUB_HOST (optional) - the probe's host, default cnf env.dns.BASE_DOMAIN
# @param BOX_PKG_AUTO_UNDO (optional) - 0 turns the auto-undo hook off (D5)
# @param BOX_PKG_BOX (optional) - the box column, default the configured box name (spl_box_name)
# @param BOX_PKG_SEND (optional) - the sender, default orc's spool-send.sh
# @param BOX_PKG_TASK (optional) - the note's task, default box-pkg
# @example BOX_PKG=jq BOX_PKG_REASON='json in the probes' AGENT_ID=c-1 ./run -a do_box_pkg_install
#------------------------------------------------------------------------------

# spl_box_name: the box name from the config, never the hostname (SPL-4201)
declare -F spl_box_name >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"

# _bpi_sudo <cmd...>: run as root, through sudo unless already root
_bpi_sudo() {
  if [[ "${EUID:-$(id -u)}" == 0 ]]; then "$@"; else sudo "$@"; fi
}

# _bpi_q <word>: the word single-quoted for a copy-pasteable shell line
_bpi_q() {
  local s="${1//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# _bpi_clean <text>: one journal field, tabs and newlines folded to spaces
_bpi_clean() {
  local s="${1//$'\t'/ }"
  s="${s//$'\n'/ }"
  printf '%s' "${s//$'\r'/ }"
}

# _bpi_cnf <yq path>: one value of the shared cnf, "" when absent
_bpi_cnf() {
  local top cnf
  top="$(git -C "${PROJ_PATH:-.}" rev-parse --show-toplevel 2>/dev/null)" || return 0
  cnf="$top/csi-spl-cnf/csi-spl/all.env.yaml"
  [[ -r "$cnf" ]] && command -v yq >/dev/null 2>&1 || return 0
  yq -r "$1 // \"\"" "$cnf" 2>/dev/null
}

# _bpi_send <body>: one note to the orchestrator on the box-pkg task
_bpi_send() {
  local send="${BOX_PKG_SEND:-}"
  [[ -n "$send" ]] || send="$(git -C "${PROJ_PATH:-.}" rev-parse --show-toplevel 2>/dev/null)/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
  bash "$send" --from "$AGENT_ID" --to orchestrator --kind note \
    --task "${BOX_PKG_TASK:-box-pkg}" --body "$1" >/dev/null ||
    echo "WARN the note to the orchestrator was not sent" >&2
}

# _bpi_rerun_line: the exact command that runs this request for real
_bpi_rerun_line() {
  local l
  l="DRY_RUN=0 BOX_PKG=$(_bpi_q "$BOX_PKG") BOX_PKG_REASON=$(_bpi_q "$BOX_PKG_REASON") AGENT_ID=$(_bpi_q "$AGENT_ID")"
  [[ -z "${BOX_PKG_ISSUE:-}" ]] || l+=" BOX_PKG_ISSUE=$(_bpi_q "$BOX_PKG_ISSUE")"
  printf '%s ./run -a do_box_pkg_install\n' "$l"
}

# _bpi_closure <sim file>: the Inst package names, space separated
_bpi_closure() {
  awk '$1 == "Inst" { printf "%s%s", sep, $2; sep = " " }' "$1"
}

# _bpi_flags <sim file>: the FLAG lines of do_box_pkg_flag (5.3)
_bpi_flags() {
  local map="${BOX_PKG_SERVICES:-}"
  if ! declare -f do_box_pkg_flag >/dev/null; then
    # shellcheck disable=SC1091  # the sibling row B2 file
    source "$(dirname "${BASH_SOURCE[0]}")/box-pkg-flag.func.sh"
  fi
  [[ -n "$map" ]] || map="$(_bpi_cnf '.env.box.pkg_services')"
  BOX_PKG_SIM="$1" BOX_PKG_SERVICES="$map" do_box_pkg_flag ||
    echo "WARN the takeover check could not run; installing unflagged" >&2
}

# _bpi_snapshot <dir>: the box state a purge (row B5) restores from
_bpi_snapshot() {
  local d="$1" r="${BOX_PKG_ROOT:-}" sub
  _bpi_sudo mkdir -p "$d" || return 1
  dpkg --get-selections | _bpi_sudo tee "$d/dpkg-selections" >/dev/null || return 1
  if [[ -L "$r/etc/resolv.conf" ]]; then
    readlink "$r/etc/resolv.conf" | _bpi_sudo tee "$d/resolv.conf.link" >/dev/null
  fi
  [[ ! -e "$r/etc/resolv.conf" ]] || _bpi_sudo cp -L "$r/etc/resolv.conf" "$d/resolv.conf"
  [[ ! -e "$r/etc/nsswitch.conf" ]] || _bpi_sudo cp -L "$r/etc/nsswitch.conf" "$d/nsswitch.conf"
  for sub in NetworkManager systemd/network network; do
    [[ -d "$r/etc/$sub" ]] || continue
    _bpi_sudo mkdir -p "$(dirname "$d/etc/$sub")"
    _bpi_sudo cp -a "$r/etc/$sub" "$d/etc/$sub"
  done
  return 0
}

# _bpi_journal <op> <closure> <flags> <snapshot>: append one journal line;
# the FLAG lines join with "; "
_bpi_journal() {
  local j="${BOX_PKG_JOURNAL:-/var/lib/csi-spl/box-pkg/journal.tsv}" line
  _bpi_sudo mkdir -p "$(dirname "$j")" || return 1
  line="$(date -u +%FT%TZ)"$'\t'"${BOX_PKG_BOX:-$(spl_box_name)}"$'\t'"$AGENT_ID"
  line+=$'\t'"${BOX_PKG_ISSUE:-}"$'\t'"$1"$'\t'"$(_bpi_clean "$BOX_PKG")"$'\t'"$2"
  line+=$'\t'"$(_bpi_clean "${3//$'\n'/; }")"$'\t'"$4"$'\t'"$(_bpi_clean "$BOX_PKG_REASON")"
  printf '%s\n' "$line" | _bpi_sudo tee -a "$j" >/dev/null
}

# _bpi_verify: each requested package `install ok installed`; rc 1 if not
_bpi_verify() {
  local p st rc=0
  for p in $BOX_PKG; do
    # shellcheck disable=SC2016  # a dpkg-query field, not a shell variable
    st="$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)"
    [[ "$st" == "install ok installed" ]] || { echo "VERIFY $p not installed (${st:-no status})"; rc=1; }
  done
  return "$rc"
}

# _bpi_health: the hub host resolves and serves /version; rc 1 when red
_bpi_health() {
  local host="${BOX_PKG_HUB_HOST:-}"
  [[ -n "$host" ]] || host="$(_bpi_cnf '.env.dns.BASE_DOMAIN')"
  [[ -n "$host" ]] || { echo "HEALTH unknown: no hub host (BOX_PKG_HUB_HOST or cnf env.dns.BASE_DOMAIN)"; return 1; }
  getent hosts "$host" >/dev/null || { echo "HEALTH red: $host does not resolve"; return 1; }
  curl -fsS -m 10 "https://$host/version" >/dev/null 2>&1 ||
    { echo "HEALTH red: https://$host/version does not answer"; return 1; }
  echo "HEALTH green: $host resolves and serves /version"
}

# _bpi_auto_undo <snapshot> <flags> <health line>: THE HOOK row B6 wires to
# do_box_pkg_purge (5.4). Until then it only tells the orchestrator; it
# undoes nothing.
_bpi_auto_undo() {
  echo "AUTO-UNDO not wired yet (spec 142 row B6): purge by hand from snapshot $1"
  _bpi_send "box-pkg: health red after a flagged install by $AGENT_ID of $BOX_PKG. $3. Flags: ${2//$'\n'/; }. Snapshot: $1. Auto-undo is not wired yet (row B6)."
}

# _bpi_manifest_rows <flags>: the rows the agent adds to cnf/box-pkgs/<class>.tsv
_bpi_manifest_rows() {
  local p svc issue="${BOX_PKG_ISSUE:-<SPL-n>}"
  echo "MANIFEST add to csi-spl-iac/cnf/box-pkgs/${BOX_CLASS:-<class>}.tsv in your lane commit:"
  for p in $BOX_PKG; do
    svc="$(awk -v p="$p" '$1 == "FLAG" && $3 == p { print $2; exit }' <<<"$1")"
    printf 'apt\t%s\t\tdo_box_pkg_install\tlane %s\t%s\t%s %s\n' "$p" "$issue" "$svc" "$(date -u +%F)" "$issue"
  done
}

# _bpi_dry <closure> <flags>: the plan of steps 3..7 and the re-run line
_bpi_dry() {
  echo "DRY RUN: nothing installed, nothing journaled"
  [[ -z "$2" ]] || echo "would snapshot to ${BOX_PKG_BACKUP_DIR:-/var/backups/box-pkg}/<UTC stamp>-$AGENT_ID"
  echo "would journal to ${BOX_PKG_JOURNAL:-/var/lib/csi-spl/box-pkg/journal.tsv}: install $BOX_PKG (closure: $1)"
  echo "would run: apt-get install -y $BOX_PKG, then verify and the hub health probe"
  _bpi_manifest_rows "$2"
  echo "RE-RUN to install:"
  _bpi_rerun_line
}

# _bpi_real <closure> <flags>: steps 3..7 for real
_bpi_real() {
  local closure="$1" flags="$2" snap="" rc=0 health
  if [[ -n "$flags" ]]; then
    snap="${BOX_PKG_BACKUP_DIR:-/var/backups/box-pkg}/$(date -u +%Y%m%dT%H%M%SZ)-$AGENT_ID"
    _bpi_snapshot "$snap" || { echo "ERROR: snapshot to $snap failed; nothing installed" >&2; return 1; }
  fi
  _bpi_journal install "$closure" "$flags" "$snap" ||
    { echo "ERROR: journal write failed; nothing installed" >&2; return 1; }
  # shellcheck disable=SC2086  # BOX_PKG is a word list
  _bpi_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $BOX_PKG || rc=$?
  if [[ "$rc" == 0 ]]; then
    _bpi_journal install-ok "$closure" "$flags" "$snap"
  else
    _bpi_journal "install-fail-rc$rc" "$closure" "$flags" "$snap"
    echo "ERROR: apt-get install failed (rc $rc)" >&2
    return 4
  fi
  _bpi_verify || rc=5
  if ! health="$(_bpi_health)"; then
    [[ "$rc" != 0 ]] || rc=6
    if [[ -n "$flags" && "${BOX_PKG_AUTO_UNDO:-1}" != 0 ]]; then _bpi_auto_undo "$snap" "$flags" "$health"; fi
  fi
  echo "$health"
  _bpi_manifest_rows "$flags"
  return "$rc"
}

do_box_pkg_install() {
  : "${BOX_PKG:?BOX_PKG must be set: the package(s) to install}"
  : "${BOX_PKG_REASON:?BOX_PKG_REASON must be set: why this box needs it}"
  : "${AGENT_ID:?AGENT_ID must be set: who installs it}"
  local tmp closure flags rc=0 mode=install
  [[ "${DRY_RUN:-1}" == 0 ]] || mode="dry run"
  tmp="$(mktemp -d)" || return 1
  # shellcheck disable=SC2086  # BOX_PKG is a word list
  if ! apt-get -s install $BOX_PKG >"$tmp/sim" 2>"$tmp/sim.err"; then
    echo "ERROR: apt-get -s install $BOX_PKG failed, nothing installed: $(tail -1 "$tmp/sim.err")" >&2
    rm -rf "$tmp"
    return 1
  fi
  grep -E '^(Inst|Remv) ' "$tmp/sim" || true
  closure="$(_bpi_closure "$tmp/sim")"
  flags="$(_bpi_flags "$tmp/sim")"
  if [[ -n "$flags" ]]; then
    printf '%s\n' "$flags"
    _bpi_send "box-pkg ($mode): $AGENT_ID installs $BOX_PKG on ${BOX_PKG_BOX:-$(spl_box_name)}, a service takeover: ${flags//$'\n'/; }. Reason: $BOX_PKG_REASON"
  fi
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    _bpi_dry "$closure" "$flags"
  else
    _bpi_real "$closure" "$flags" || rc=$?
  fi
  rm -rf "$tmp"
  return "$rc"
}
