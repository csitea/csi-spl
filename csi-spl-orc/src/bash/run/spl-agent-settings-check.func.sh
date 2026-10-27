#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only check of the Claude settings every start on this box
# @description reads: the agent user's AND the box user's ~/.claude/settings.json
# @description (home from passwd). Each must be valid JSON, carry
# @description permissions.defaultMode = bypassPermissions (the fleet rule:
# @description bypass only), and hold no allow rule Claude rejects: a wildcard
# @description in the tool name outside a literal mcp__<server>__ prefix (a bare
# @description "mcp__*", "*", "Bash*"). Claude answers such a rule with a
# @description "Settings Warning" dialog that every new session waits on: on
# @description 2026-10-07 17:29Z the failover's rotation waited on it for its whole
# @description 600 s ack wait, and one box user kept the rule after the agent
# @description user's was fixed. One line per file; a verdict that CHANGES (the
# @description problems, or the file's mtime while it is bad) is told ONCE to
# @description SETTINGS_CHECK_TO with the file's mtime, and once when it is good
# @description again. Never writes either file: a human fixes it. The desk
# @description reconcile cron runs it every tick (DESK_SETTINGS_CHECK=0 off).
# @description The same line also flags a git credential.helper=store (SPL-3761):
# @description in the user's ~/.gitconfig or ~/.config/git/config (the home that
# @description holds .claude/settings.json), or in the system git config, and a
# @description non-empty ~/.git-credentials (its size only, never its content).
# @description Exit: 0 every file good, 1 a file is bad or unreadable, 2 usage.
# @param SETTINGS_CHECK_USERS (optional) - the users to check, default the agent user and the box user (box.env)
# @param SETTINGS_CHECK_FILES (optional) - "<user>=<path> ..." instead of the homes (tests)
# @param SETTINGS_CHECK_TO (optional) - who is told, default LEASE_ORCH of lease.conf, else c-001
# @param SETTINGS_CHECK_STATE_DIR (optional) - the told-marks, default <spool root>/dispatch/settings-check
# @param SETTINGS_CHECK_SEND (optional) - the sender, default spool-send.sh (tests)
# @param SETTINGS_CHECK_GIT_SYSTEM (optional) - the system git config file, default git's own (tests)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_settings_check
#------------------------------------------------------------------------------
# spl_role_seat: the role seat ids in their live vendor letter (SPL-1695)
declare -F spl_role_seat >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"
do_spl_agent_settings_check() {
  do_require_bin python3 || return 1
  local feat users u f rc=0 line
  feat="$(cd "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents" && pwd)"
  declare -F spool_env_resolve >/dev/null || source "$feat/lib/spool-env.inc.sh"
  SPOOL_ENV_NO_BINS=1 spool_env_resolve
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  local state="${SETTINGS_CHECK_STATE_DIR:-$SPOOL_ROOT/dispatch/settings-check}"
  local -a pairs=()
  if [[ -n "${SETTINGS_CHECK_FILES:-}" ]]; then
    read -r -a pairs <<<"$SETTINGS_CHECK_FILES"
  else
    users="${SETTINGS_CHECK_USERS:-${SPOOL_AGENT_USER:-} ${SPOOL_BOX_USER:-}}"
    for u in $(tr ' ' '\n' <<<"$users" | awk 'NF && !seen[$0]++'); do
      f="$(getent passwd "$u" | cut -d: -f6)"
      [[ -n "$f" ]] || { do_log "FATAL no passwd entry for '$u'"; return 2; }
      pairs+=("$u=$f/.claude/settings.json")
    done
  fi
  (( ${#pairs[@]} )) || { do_log "FATAL no user to check (SETTINGS_CHECK_USERS, or SPOOL_AGENT_USER / SPOOL_BOX_USER)"; return 2; }
  mkdir -p "$state" 2>/dev/null || true
  for f in "${pairs[@]}"; do
    [[ "$f" == ?*=?* ]] || { do_log "FATAL SETTINGS_CHECK_FILES wants <user>=<path>, got '$f'"; return 2; }
    line="$(spl_settings_verdict "${f%%=*}" "${f#*=}")"
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$line"
    [[ "$line" == "SETTINGS OK "* ]] || rc=1
    spl_settings_tell "${f%%=*}" "$line" "$state"
  done
  return "$rc"
}

# spl_settings_read USER PATH: the file's mtime (epoch) on line 1, its text
# after; read as USER (sudo -n) when this user cannot. Nothing = unreadable.
spl_settings_read() {
  local u="$1" p="$2"
  if [[ -r "$p" ]]; then stat -c %Y "$p" && cat "$p"; return; fi
  [[ "$u" == "$(id -un)" ]] && return 0
  sudo -n -u "$u" sh -c 'stat -c %Y "$1" && cat "$1"' _ "$p" 2>/dev/null || true
}

# spl_settings_verdict USER PATH: "SETTINGS OK <user> <path> mtime <ts>" or
# "SETTINGS BAD <user> <path> mtime <ts>: <problem>; <problem>".
spl_settings_verdict() {
  local u="$1" p="$2" raw git
  raw="$(spl_settings_read "$u" "$p")"
  git="$(spl_git_store_finding "$u" "$p")"
  if [[ -z "$raw" ]]; then echo "SETTINGS BAD $u $p mtime -: missing or unreadable${git:+; $git}"; return 0; fi
  python3 -c '
import datetime, json, re, sys
u, p, git, raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.stdin.read()
mt, _, text = raw.partition("\n")
try:
    ts = datetime.datetime.fromtimestamp(int(mt), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
except ValueError:
    ts = "-"
bad = []
try:
    d = json.loads(text)
except ValueError as e:
    d, bad = None, ["not valid JSON (%s)" % str(e).split(":")[0]]
if d is not None:
    perms = d.get("permissions") if isinstance(d, dict) else None
    perms = perms if isinstance(perms, dict) else {}
    mode = perms.get("defaultMode")
    if mode != "bypassPermissions":
        bad.append("permissions.defaultMode is %s, not bypassPermissions" % json.dumps(mode))
    for r in perms.get("allow") or []:
        if not isinstance(r, str):
            bad.append("allow rule %s is not a string" % json.dumps(r)); continue
        tool = r.split("(", 1)[0]
        if "*" not in tool:
            continue
        m = re.match(r"mcp__([^*]+?)__", tool)
        if not m or "*" in tool[:m.end()]:
            bad.append("allow rule %s: a wildcard tool name outside mcp__<server>__ (Claude rejects it with a Settings Warning)" % json.dumps(r))
if git:
    bad.append(git)
print("SETTINGS %s %s %s mtime %s%s" % ("BAD" if bad else "OK", u, p, ts, (": " + "; ".join(bad)) if bad else ""))
' "$u" "$p" "$git" <<<"$raw"
}

# spl_git_store_finding USER PATH: what makes git keep tokens in clear text
# for USER (the home that holds PATH's .claude/), joined by "; ", or nothing:
# a credential.helper (or credential.<url>.helper) = store in the global or
# the system git config, and a non-empty ~/.git-credentials. Reads helper
# values only; the credential file is tested for size, never read.
spl_git_store_finding() {
  local u="$1" p="$2" home f sys
  local -a out=()
  if [[ "$p" == */.claude/settings.json ]]; then
    home="${p%/.claude/settings.json}"
    for f in "$home/.gitconfig" "$home/.config/git/config"; do
      spl_git_helpers "$u" "$f" | grep -x store >/dev/null && out+=("credential.helper=store in $f (git keeps tokens in clear text)")
    done
    for f in "$home/.git-credentials" "$home/.config/git/credentials"; do
      spl_as_user "$u" "$f" test -s "$f" && out+=("$f is not empty (clear-text git credentials)")
    done
  fi
  sys="${SETTINGS_CHECK_GIT_SYSTEM:-}"
  if [[ -n "$sys" ]]; then
    spl_git_helpers "" "$sys" | grep -x store >/dev/null && out+=("credential.helper=store in the system git config ($sys)")
  else
    env -u GIT_CONFIG_NOSYSTEM git config --system --get-regexp '^credential\.(.*\.)?helper$' 2>/dev/null | awk '{ print $2 }' | grep -x store >/dev/null &&
      out+=("credential.helper=store in the system git config")
  fi
  (( ${#out[@]} )) || return 0
  printf '%s' "${out[0]}"
  (( ${#out[@]} > 1 )) && printf '; %s' "${out[@]:1}"
  return 0
}

# spl_git_helpers USER FILE: the first word of every credential helper in FILE,
# one per line.
spl_git_helpers() {
  spl_as_user "$1" "$2" git config --file "$2" --get-regexp '^credential\.(.*\.)?helper$' | awk '{ print $2 }' || true
}

# spl_as_user USER FILE CMD...: CMD as this user when it can see FILE, else as
# USER (sudo -n, from /, never prompts) when USER is another user.
spl_as_user() {
  local u="$1" f="$2"; shift 2
  if [[ -x "${f%/*}" ]] && [[ -r "$f" || ! -e "$f" ]]; then "$@" 2>/dev/null; return; fi
  [[ -n "$u" && "$u" != "$(id -un)" ]] || return 1
  (cd / && sudo -n -u "$u" "$@" 2>/dev/null)
}

# spl_settings_tell USER LINE STATE: one note per change of USER's verdict
# (the line, whose mtime part moves with every edit of a bad file), and one
# when a told bad file is good again. The mark is <state>/<user>.told.
spl_settings_tell() {
  local u="$1" line="$2" state="$3" mark prev to conf body rc=0
  mark="$state/$u.told"
  prev="$(cat "$mark" 2>/dev/null || true)"
  if [[ "$line" == "SETTINGS OK "* ]]; then
    [[ -n "$prev" && "$prev" != "SETTINGS OK "* ]] || return 0
    body="SETTINGS FIXED: $u's ${line#SETTINGS OK "$u" } (was: ${prev#SETTINGS BAD "$u" })"
  else
    [[ "$line" == "$prev" ]] && return 0
    body="SETTINGS BAD on $(spl_desk_box_default 2>/dev/null || hostname -s): ${line#SETTINGS BAD }. Every new claude session of $u stops on a dialog until it is fixed; this check never writes the file."
  fi
  conf="$SPOOL_ROOT/dispatch/lease.conf"
  to="${SETTINGS_CHECK_TO:-$(sed -n 's/^LEASE_ORCH=\([A-Za-z0-9_-]*\)$/\1/p' "$conf" 2>/dev/null | sed -n 1p)}"
  to="${to:-$(spl_role_seat 1)}"
  SPOOL_ROOT="$SPOOL_ROOT" bash "${SETTINGS_CHECK_SEND:-$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/spool-send.sh}" \
    --from "$to" --to "$to" --kind note --task agent-settings-check --no-ask --body "$body" >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  if (( rc < 10 && rc != 2 )); then
    printf '%s\n' "$line" > "$mark.tmp.$$" 2>/dev/null && mv -f "$mark.tmp.$$" "$mark" 2>/dev/null || true
    printf '%s INFO told %s: %s\n' "$(date -u +%FT%TZ)" "$to" "${body:0:160}"
  else
    printf '%s WARN could not tell %s (spool-send exit %s): told again next run\n' "$(date -u +%FT%TZ)" "$to" "$rc"
  fi
  return 0
}
