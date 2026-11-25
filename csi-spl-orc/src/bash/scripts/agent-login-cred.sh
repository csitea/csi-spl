#!/usr/bin/env bash
# agent-login-cred.sh - the agent user's Claude login on THIS box, for
# do_spl_agent_login_check (the login self-heal). Run as the box user; every
# file read or write goes through `sudo -n -u <agent user>`. Self-contained:
# the check runs it on a peer box as `ssh <dest> bash -c "<this file>" _ <op>`,
# so it needs no checkout there.
#
#   agent-login-cred.sh stat    "<sha12> <expiresAt ms> <mtime epoch>", or "none"
#   agent-login-cred.sh probe   "<ok|expired|limited|unknown> <one short line>"
#   agent-login-cred.sh get     the credential on stdout (only ever into a pipe)
#   agent-login-cred.sh put     the credential from stdin: checked, the old one
#                               kept as <file>.bak-login-<UTC> (the newest
#                               LOGIN_BAK_KEEP, default 5), written to a temp
#                               file in the same dir, then mv; prints "<sha12>"
#   agent-login-cred.sh acct    the account label "acct-<8 hex>" (sha256 of
#                               oauthAccount.accountUuid), or "none"
#   agent-login-cred.sh acctget {oauthAccount, hasCompletedOnboarding} of the
#                               login's .claude.json (only ever into a pipe)
#   agent-login-cred.sh acctput those two fields from stdin, merged into the
#                               login's .claude.json (temp + mv, 600); nothing
#                               else of the file changes; prints the new label
#
# Every op takes an optional SLOT, the second argument (SPL-5695, spec 060
# add-on claude-account-failover.md): 1 (default) is the agent user's main
# login (~/.claude/.credentials.json, ~/.claude.json), 2 its second folder
# (LOGIN_CRED_DIR2, default ~/.claude-2: .credentials.json and .claude.json
# inside it, the probe under CLAUDE_CONFIG_DIR=<that folder>). A slot 2 put
# keeps the old one as .bak-login2-<UTC>.
#
# The f-ops (SPL-6487, do_spl_agent_cred_sync) take a FILE under the agent
# user's home, from the cnf file list of a vendor (agy, claude), in place of
# a slot; each reuses the guard of its slot op above:
#   agent-login-cred.sh fstat    FILE [JQ]  "<sha12> <expiry epoch s>" (JQ reads
#                                the expiry: ms, s or an ISO time; 0 = none), or "none"
#   agent-login-cred.sh fget     FILE       the file on stdout (only into a pipe)
#   agent-login-cred.sh fput     FILE TS    stdin -> FILE as put does (temp + mv,
#                                600, the old one kept as FILE.bak-cred-TS); "<sha12>"
#   agent-login-cred.sh facct    FILE       the account label of a .claude.json FILE
#   agent-login-cred.sh facctget FILE       its {oauthAccount, hasCompletedOnboarding}
#   agent-login-cred.sh facctput FILE TS    acctput into FILE, kept first as .bak-cred-TS
#   agent-login-cred.sh frestore FILE TS [new]  FILE.bak-cred-TS back to FILE; with
#                                no .bak and "new" (the copy made FILE) it is removed,
#                                else kept; prints "restored|removed|kept"
#   agent-login-cred.sh fprobe   BIN ENV ARG...  the probe with <home>/.local/bin/BIN
#                                (else BIN on PATH), ENV "NAME=<dir under home>" or "-"
#
# It never prints credential content: a sha256 prefix (12 chars) at most.
# Settings: SPOOL_ROOT (box.env: SPOOL_AGENT_USER), LOGIN_AGENT_USER,
# LOGIN_CLAUDE_BIN. Test seams: LOGIN_CRED_FILE (the slot 1 file),
# LOGIN_JSON_FILE (the slot 1 .claude.json), LOGIN_AGENT_HOME (the agent
# user's home), LOGIN_SUDO (the prefix, "" = none), LOGIN_PROBE_CMD (the
# probe command line; it sees LOGIN_PROBE_SLOT).
# Exit: 0 done, 1 failed, 2 usage.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

LC_EXPIRED_RE='login expired|please run /login|oauth (session|token) (has )?expired|could not be refreshed|failed to authenticate|invalid api key|not logged in'
LC_LIMITED_RE='hit your ([a-z]+ )?limit|usage limit reached|limit reached'

lc_user() {
  local u="${LOGIN_AGENT_USER:-}"
  local env="${SPOOL_ROOT:-/var/spool-hub}/box.env" rd=cat
  # a peer's ssh login user may not read box.env (the satellite's): sudo -n
  [ -r "$env" ] || rd="sudo -n cat"
  [ -n "$u" ] || u="$($rd "$env" 2>/dev/null | sed -n 's/^SPOOL_AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' | tail -1)"
  [ -n "$u" ] || u="$(id -un)"
  printf '%s' "$u"
}

LC_USER="$(lc_user)"
if [ -n "${LOGIN_SUDO+x}" ]; then LC_SU="$LOGIN_SUDO"
elif [ "$LC_USER" = "$(id -un)" ]; then LC_SU=""
else LC_SU="sudo -n -u $LC_USER"; fi
LC_HOME="${LOGIN_AGENT_HOME:-$(getent passwd "$LC_USER" | cut -d: -f6)}"
# an f-op's second argument is a file, not a slot
if [[ "${1:-}" == f* ]]; then LC_SLOT=1; else LC_SLOT="${2:-1}"; fi
case "$LC_SLOT" in
  1) LC_DIR2=""; LC_FILE="${LOGIN_CRED_FILE:-$LC_HOME/.claude/.credentials.json}"
     LC_JSON="${LOGIN_JSON_FILE:-$LC_HOME/.claude.json}"; LC_BAK="bak-login" ;;
  2) LC_DIR2="${LOGIN_CRED_DIR2:-$LC_HOME/.claude-2}"; LC_FILE="$LC_DIR2/.credentials.json"
     LC_JSON="$LC_DIR2/.claude.json"; LC_BAK="bak-login2" ;;
  *) echo "usage: the slot is 1 or 2, got: '$LC_SLOT'" >&2; exit 2 ;;
esac

# shellcheck disable=SC2086  # LC_SU is a command prefix, split on purpose
lc_as() { $LC_SU "$@"; }

lc_stat() {
  lc_as test -s "$LC_FILE" || { echo none; return 0; }
  local sha exp mt
  sha="$(lc_as sha256sum "$LC_FILE" | cut -c1-12)"
  exp="$(lc_as jq -r '.claudeAiOauth.expiresAt // 0' "$LC_FILE" 2>/dev/null)"
  [[ "$exp" =~ ^[0-9]+$ ]] || exp=0
  mt="$(lc_as stat -c %Y "$LC_FILE")"
  printf '%s %s %s\n' "$sha" "$exp" "$mt"
}

lc_put() {
  lc_mkdir2 || { echo "put: cannot make ${LC_FILE%/*}" >&2; return 1; }
  lc_write "$LC_FILE" "$LC_BAK" "$(date -u +%Y%m%dT%H%M%SZ)" lc_is_claude_login
}

lc_is_claude_login() {
  lc_as jq -e '.claudeAiOauth.refreshToken | strings | length > 0' "$1" >/dev/null 2>&1 && return 0
  echo "put: refused: the input is no Claude login" >&2; return 1
}

# lc_write FILE BAK TS [CHECK]: stdin -> a temp file next to FILE; CHECK <temp>
# must pass; mode 600; the old FILE kept as FILE.BAK-TS (the newest
# LOGIN_BAK_KEEP); then mv. Prints "<sha12>".
lc_write() {
  local file="$1" bak="$2" ts="$3" check="${4:-}" tmp
  tmp="$(lc_as mktemp "${file%/*}/.cred-in.XXXXXX")" || { echo "put: cannot make a temp file" >&2; return 1; }
  # shellcheck disable=SC2016  # expanded by the inner shell
  lc_as bash -c 'umask 077; cat > "$1"' _ "$tmp" || { lc_as rm -f "$tmp"; return 1; }
  if [ -n "$check" ] && ! "$check" "$tmp"; then lc_as rm -f "$tmp"; return 1; fi
  lc_as chmod 600 "$tmp" || { lc_as rm -f "$tmp"; return 1; }
  if lc_as test -e "$file"; then lc_as cp -p "$file" "$file.$bak-$ts" || { lc_as rm -f "$tmp"; return 1; }; fi
  lc_as mv -f "$tmp" "$file" || { lc_as rm -f "$tmp"; return 1; }
  # shellcheck disable=SC2016
  lc_as bash -c 'ls -1 "$1".$3-* 2>/dev/null | sort -r | tail -n +$(( $2 + 1 )) | xargs -r rm -f' _ "$file" "${LOGIN_BAK_KEEP:-5}" "$bak"
  lc_as sha256sum "$file" | cut -c1-12
}

# The second folder, made 700 when a slot 2 write needs it; slot 1: nothing.
lc_mkdir2() {
  [ -n "$LC_DIR2" ] || return 0
  lc_as mkdir -p "$LC_DIR2" && lc_as chmod 700 "$LC_DIR2"
}

# The account label of the slot's .claude.json: "acct-<8 hex>", or "none".
lc_acct() {
  local u
  u="$(lc_as jq -r '.oauthAccount.accountUuid // empty' "$LC_JSON" 2>/dev/null)"
  if [ -n "$u" ]; then printf 'acct-%s\n' "$(printf '%s' "$u" | sha256sum | cut -c1-8)"; else echo none; fi
}

# Merge {oauthAccount, hasCompletedOnboarding} from stdin into the slot's
# .claude.json (Q3 of the design: nothing else crosses boxes), temp + mv, 600.
lc_acctput() {
  local in tmp
  in="$(jq -c '{oauthAccount, hasCompletedOnboarding}' 2>/dev/null)"
  jq -e '.oauthAccount.accountUuid | strings | length > 0' >/dev/null 2>&1 <<<"$in" ||
    { echo "acctput: refused: the input names no account" >&2; return 1; }
  lc_mkdir2 || return 1
  tmp="$(lc_as mktemp "${LC_JSON%/*}/.acct-in.XXXXXX")" || return 1
  # shellcheck disable=SC2016  # expanded by the inner shell
  if ! lc_as bash -c 'umask 077; { cat "$2" 2>/dev/null || echo "{}"; } | jq -c --argjson a "$3" ". + \$a" > "$1"' _ "$tmp" "$LC_JSON" "$in" ||
     ! lc_as chmod 600 "$tmp" || ! lc_as mv -f "$tmp" "$LC_JSON"; then
    lc_as rm -f "$tmp"; return 1
  fi
  lc_acct
}

lc_probe() {
  local out rc cmd bin
  if [ -n "${LOGIN_PROBE_CMD:-}" ]; then cmd="$LOGIN_PROBE_CMD"
  elif [ -n "${LC_PROBE_LINE:-}" ]; then cmd="$LC_PROBE_LINE"
  else
    bin="${LOGIN_CLAUDE_BIN:-$LC_HOME/.local/bin/claude}"
    cmd="$LC_SU env HOME=$LC_HOME${LC_DIR2:+ CLAUDE_CONFIG_DIR=$LC_DIR2} timeout ${LOGIN_PROBE_TIMEOUT:-120} $bin -p 'Reply with the single word ok.' --model haiku"
  fi
  out="$(cd / && LOGIN_PROBE_SLOT="$LC_SLOT" bash -c "$cmd" </dev/null 2>&1)"; rc=$?
  out="$(printf '%s' "$out" | tr -s '\n\r\t' '   ' | cut -c1-160)"
  if grep -qiE "$LC_EXPIRED_RE" <<<"$out"; then echo "expired $out"
  elif grep -qiE "$LC_LIMITED_RE" <<<"$out"; then echo "limited $out"
  elif [ "$rc" = 0 ] && grep -qiE '\bok\b' <<<"$out"; then echo "ok $out"
  else echo "unknown rc=$rc $out"; fi
}

# ---- the f-ops (SPL-6487) ----------------------------------------------------
# lc_rel FILE: <home>/FILE for a relative path with no ".."; else usage, exit 2
lc_rel() {
  case "$1" in "" | /* | *..*) echo "usage: a file under the agent home, got: '$1'" >&2; exit 2 ;; esac
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "usage: a file under the agent home, got: '$1'" >&2; exit 2; }
  printf '%s/%s' "$LC_HOME" "$1"
}

lc_ts() { [[ "${1:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "usage: TS is <yyyymmdd>T<hhmmss>Z, got: '${1:-}'" >&2; exit 2; }; }

# The folder of FILE, made as the agent user (a new one 700); an old one keeps its mode.
# shellcheck disable=SC2016  # expanded by the inner shell
lc_mkparent() { lc_as bash -c 'umask 077; mkdir -p "$1"' _ "${1%/*}"; }

# lc_fstat FILE [JQ]: "<sha12> <expiry epoch s>" or "none"
lc_fstat() {
  local f="$1" jqx="${2:-}" sha exp=""
  lc_as test -s "$f" || { echo none; return 0; }
  sha="$(lc_as sha256sum "$f" | cut -c1-12)"
  [ -n "$jqx" ] && exp="$(lc_as jq -r "($jqx) // empty" "$f" 2>/dev/null)"
  if [[ "$exp" =~ ^[0-9]+$ ]]; then (( exp > 100000000000 )) && exp=$(( exp / 1000 ))
  elif [ -n "$exp" ]; then exp="$(date -u -d "$exp" +%s 2>/dev/null)"; fi
  [[ "$exp" =~ ^[0-9]+$ ]] || exp=0
  printf '%s %s\n' "$sha" "$exp"
}

# lc_frestore FILE TS [new]: FILE.bak-cred-TS back; with none, "new" (the
# copy made FILE) removes it, else FILE is left as it is
lc_frestore() {
  local f="$1" ts="$2" new="${3:-}"
  if lc_as test -e "$f.bak-cred-$ts"; then lc_as mv -f "$f.bak-cred-$ts" "$f" && echo restored
  elif [ "$new" = new ]; then lc_as rm -f "$f" && echo removed
  else echo kept; fi
}

# lc_fprobe BIN ENV ARG...: the probe line with that CLI, as the agent user
lc_fprobe() {
  local bin="$1" ev="$2" a; shift 2
  [[ "$bin" =~ ^[a-z0-9-]+$ ]] || { echo "usage: BIN is a CLI name, got: '$bin'" >&2; exit 2; }
  for a in "$@"; do [[ "$a" =~ ^[A-Za-z0-9._=-]+$ ]] || { echo "usage: a probe arg, got: '$a'" >&2; exit 2; }; done
  [ -x "$LC_HOME/.local/bin/$bin" ] && bin="$LC_HOME/.local/bin/$bin"
  case "$ev" in
    -) ev="" ;;
    *) [[ "$ev" =~ ^[A-Z_][A-Z0-9_]*=[A-Za-z0-9._/-]+$ ]] || { echo "usage: ENV is NAME=<dir> or -, got: '$ev'" >&2; exit 2; }
       ev=" ${ev%%=*}=$(lc_rel "${ev#*=}")" ;;
  esac
  LC_PROBE_LINE="$LC_SU env HOME=$LC_HOME$ev timeout ${LOGIN_PROBE_TIMEOUT:-120} $bin -p 'Reply with the single word ok.'${*:+ $*}"
  lc_probe
}

case "${1:-}" in
  fstat) lc_fstat "$(lc_rel "${2:-}")" "${3:-}" ;;
  fget)  lc_as cat "$(lc_rel "${2:-}")" ;;
  fput)  lc_ts "${3:-}"; f="$(lc_rel "${2:-}")"; lc_mkparent "$f" && lc_write "$f" bak-cred "$3" ;;
  facct) LC_JSON="$(lc_rel "${2:-}")"; lc_acct ;;
  facctget) lc_as jq -c '{oauthAccount, hasCompletedOnboarding}' "$(lc_rel "${2:-}")" ;;
  facctput) lc_ts "${3:-}"; LC_JSON="$(lc_rel "${2:-}")"
            if lc_as test -e "$LC_JSON"; then lc_as cp -p "$LC_JSON" "$LC_JSON.bak-cred-$3" || exit 1; fi
            lc_mkparent "$LC_JSON" && lc_acctput ;;
  frestore) lc_ts "${3:-}"; lc_frestore "$(lc_rel "${2:-}")" "$3" "${4:-}" ;;
  fprobe) shift; lc_fprobe "${1:-}" "${2:--}" "${@:3}" ;;
  stat)  lc_stat ;;
  probe) lc_probe ;;
  get)   lc_as cat "$LC_FILE" ;;
  put)   lc_put ;;
  acct)  lc_acct ;;
  acctget) lc_as jq -c '{oauthAccount, hasCompletedOnboarding}' "$LC_JSON" ;;
  acctput) lc_acctput ;;
  *) echo "usage: agent-login-cred.sh stat|probe|get|put|acct|acctget|acctput [1|2], or an f-op (see the header)" >&2; exit 2 ;;
esac
