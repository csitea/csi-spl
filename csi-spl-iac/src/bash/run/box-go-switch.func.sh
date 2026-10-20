#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Spec 071 section 3.2: switch a box's default Go to GO_VERSION,
# @description the recorded way (SPL-2739; the hand run it codifies: SPL-2717).
# @description In order:
# @description   1. before: what /usr/local/go is (symlink, plain directory or
# @description      missing) and its version
# @description   2. target: /usr/local/go<VER> exists and its VERSION says
# @description      go<VER>, or download go<VER>.linux-<arch>.tar.gz and check
# @description      its sha256 against go.dev's published one (or GO_SHA256);
# @description      a version that cannot be verified is refused
# @description   3. a plain-directory /usr/local/go moves to /usr/local/go<its
# @description      version> (kept, still runs)
# @description   4. ln -sfn go<VER> /usr/local/go
# @description   5. the box login profile (profile.d, go) appends /usr/local/go/bin to PATH when
# @description      it is not there
# @description   6. journal (utc box agent issue op from to reason), then the
# @description      after checks: the tree's go and `bash -lc 'go version'` as
# @description      each GO_SWITCH_USERS user print go<VER>; the rollback line
# @description Already at go<VER> with the PATH line: a no-op, nothing written.
# @description DRY_RUN=1 (the default) reads, prints each step, the rollback
# @description and the re-run line with DRY_RUN=0, and changes nothing.
# @description Exit: 0 done or no-op, 1 refused, 2 the sha256 does not match,
# @description 3 a step failed, 4 an after check is red.
# @param GO_VERSION (required) - e.g. 1.26.9 (a leading "go" is dropped)
# @param GO_SWITCH_REASON (required) - why, free text, journaled
# @param AGENT_ID (required) - who, journaled
# @param GO_SWITCH_ISSUE (optional) - SPL-n of the lane that needs it
# @param DRY_RUN (optional) - 1 (default) plan only; 0 switch
# @param GO_SHA256 (optional) - the tarball sha256, instead of go.dev's list
# @param GO_ARCH (optional) - default from `uname -m` (amd64, arm64)
# @param GO_DL_BASE (optional) - the download base, default https://go.dev/dl
# @param GO_SWITCH_USERS (optional) - the login users of the after check,
# @param GO_SWITCH_USERS - default "${SUDO_USER:-$USER} $SPOOL_AGENT_USER"
# @param GO_SWITCH_ROOT (optional) - the root /usr/local and /etc sit under
# @param GO_SWITCH_ROOT - (a test sandbox), default "" = /
# @param GO_SWITCH_JOURNAL (optional) - default /var/lib/csi-spl/box-go/journal.tsv
# @param GO_SWITCH_BOX (optional) - the box column, default `hostname -s`
# @example GO_VERSION=1.26.9 GO_SWITCH_REASON='SPL-n needs 1.26' AGENT_ID=c-1 ./run -a do_box_go_switch
#------------------------------------------------------------------------------

# _bgs_sudo <cmd...>: run as root, through sudo unless already root
_bgs_sudo() {
  if [[ "${EUID:-$(id -u)}" == 0 ]]; then "$@"; else sudo "$@"; fi
}

# _bgs_q <word>: the word single-quoted for a copy-pasteable shell line
_bgs_q() {
  local s="${1//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# _bgs_tree_version <dir>: the X.Y.Z of a Go tree (its VERSION file, else
# its bin/go), "" when it is not one
_bgs_tree_version() {
  local v=""
  [[ -r "$1/VERSION" ]] && v="$(head -1 "$1/VERSION")"
  [[ -n "$v" || ! -x "$1/bin/go" ]] || v="$("$1/bin/go" version 2>/dev/null | awk '{ print $3 }')"
  v="${v#go}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$v"
  return 0
}

# _bgs_arch: the go.dev arch name of this machine
_bgs_arch() {
  if [[ -n "${GO_ARCH:-}" ]]; then printf '%s' "$GO_ARCH"; return; fi
  case "$(uname -m)" in
    x86_64) printf amd64 ;;
    aarch64 | arm64) printf arm64 ;;
    *) uname -m ;;
  esac
}

# _bgs_published_sha <file>: go.dev's sha256 for that file, "" when unknown
_bgs_published_sha() {
  curl -fsSL -m 60 "${GO_DL_BASE:-https://go.dev/dl}/?mode=json&include=all" 2>/dev/null |
    python3 -c 'import json, sys
f = sys.argv[1]
for r in json.load(sys.stdin):
    for x in r.get("files", []):
        if x.get("filename") == f:
            print(x.get("sha256", ""))
            sys.exit(0)' "$1" 2>/dev/null
}

# _bgs_before: sets kind (link|dir|missing), from (X.Y.Z or ""), link_to
_bgs_before() {
  local g="$GS_ROOT/usr/local/go"
  link_to=""
  if [[ -L "$g" ]]; then
    kind="link"
    link_to="$(readlink "$g")"
  elif [[ -d "$g" ]]; then
    kind="dir"
  else
    kind="missing"
  fi
  from="$(_bgs_tree_version "$g")"
  echo "BEFORE /usr/local/go: $kind${link_to:+ -> $link_to}, version ${from:-unknown}"
}

# _bgs_profile_ok: the profile.d go script already puts /usr/local/go/bin on PATH
_bgs_profile_ok() {
  grep -qs '/usr/local/go/bin' "$GS_ROOT/etc/profile.d/go.sh"
}

# _bgs_rollback: the line that puts /usr/local/go back as it was
_bgs_rollback() {
  local g="$GS_ROOT/usr/local/go"
  case "$kind" in
    link) echo "ROLLBACK: sudo ln -sfn $(_bgs_q "$link_to") $(_bgs_q "$g")" ;;
    dir) echo "ROLLBACK: sudo rm $(_bgs_q "$g") && sudo mv $(_bgs_q "$g$from") $(_bgs_q "$g")" ;;
    *) echo "ROLLBACK: sudo rm $(_bgs_q "$g")" ;;
  esac
}

# _bgs_rerun_line: the exact command that switches for real
_bgs_rerun_line() {
  local l
  l="DRY_RUN=0 GO_VERSION=$(_bgs_q "$GO_VERSION") GO_SWITCH_REASON=$(_bgs_q "$GO_SWITCH_REASON") AGENT_ID=$(_bgs_q "$AGENT_ID")"
  [[ -z "${GO_SWITCH_ISSUE:-}" ]] || l+=" GO_SWITCH_ISSUE=$(_bgs_q "$GO_SWITCH_ISSUE")"
  [[ -z "${GO_SHA256:-}" ]] || l+=" GO_SHA256=$(_bgs_q "$GO_SHA256")"
  printf '%s ./run -a do_box_go_switch\n' "$l"
}

# _bgs_fetch_target <dir>: download, verify and unpack go<VER> into <dir>;
# rc 1 unverifiable, 2 sha mismatch, 3 download or unpack failed
_bgs_fetch_target() {
  local dir="$1" file want got tmp rc=0
  file="go$GO_VERSION.linux-$(_bgs_arch).tar.gz"
  want="${GO_SHA256:-$(_bgs_published_sha "$file")}"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] ||
    { echo "REFUSED: no sha256 for $file (go.dev lists none, GO_SHA256 unset); nothing changed" >&2; return 1; }
  tmp="$(mktemp -d)" || return 3
  if ! curl -fsSL -m 600 -o "$tmp/$file" "${GO_DL_BASE:-https://go.dev/dl}/$file"; then
    echo "ERROR: download of $file failed; nothing changed" >&2
    rm -rf "$tmp"
    return 3
  fi
  got="$(sha256sum "$tmp/$file" | awk '{ print $1 }')"
  if [[ "$got" != "$want" ]]; then
    echo "REFUSED: $file sha256 $got, want $want; nothing changed" >&2
    rm -rf "$tmp"
    return 2
  fi
  echo "VERIFIED $file sha256 $got"
  { mkdir -p "$tmp/x" && tar -C "$tmp/x" -xzf "$tmp/$file" && [[ -d "$tmp/x/go" ]] &&
    _bgs_sudo mv "$tmp/x/go" "$dir"; } || rc=3
  rm -rf "$tmp"
  [[ "$rc" == 0 ]] || { echo "ERROR: unpacking $file into $dir failed" >&2; return 3; }
  [[ "$(_bgs_tree_version "$dir")" == "$GO_VERSION" ]] ||
    { echo "ERROR: $dir does not say go$GO_VERSION after unpacking" >&2; return 3; }
}

# _bgs_journal <op>: one TAB line, utc box agent issue op from to reason
_bgs_journal() {
  local j="${GO_SWITCH_JOURNAL:-/var/lib/csi-spl/box-go/journal.tsv}" r="${GO_SWITCH_REASON//$'\t'/ }"
  _bgs_sudo mkdir -p "$(dirname "$j")" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${GO_SWITCH_BOX:-$(hostname -s)}" \
    "$AGENT_ID" "${GO_SWITCH_ISSUE:-}" "$1" "${from:-}" "$GO_VERSION" "${r//$'\n'/ }" |
    _bgs_sudo tee -a "$j" >/dev/null
}

# _bgs_after: the tree's go and each user's login shell print go<VER>
_bgs_after() {
  local u v rc=0 users="${GO_SWITCH_USERS-${SUDO_USER:-${USER:-}} ${SPOOL_AGENT_USER:-}}" seen=" "
  v="$(_bgs_tree_version "$GS_ROOT/usr/local/go")"
  if [[ "$v" == "$GO_VERSION" ]]; then echo "AFTER /usr/local/go: go$v"
  else echo "AFTER red: /usr/local/go is go${v:-unknown}, want go$GO_VERSION"; rc=4; fi
  for u in $users; do
    [[ "$seen" != *" $u "* ]] || continue
    seen+="$u "
    # shellcheck disable=SC2016  # the login shell expands nothing here
    v="$(sudo -u "$u" bash -lc 'go version' 2>&1 | awk '{ print $3 }')"
    if [[ "$v" == "go$GO_VERSION" ]]; then echo "AFTER $u login shell: $v"
    else echo "AFTER red: $u login shell prints ${v:-nothing}, want go$GO_VERSION"; rc=4; fi
  done
  return "$rc"
}

# _bgs_plan: the steps a real run takes, from the before state
_bgs_plan() {
  local g="$GS_ROOT/usr/local/go"
  if [[ "$kind" == dir && "$from" == "$GO_VERSION" ]]; then echo "STEP mv $g $g$from (it is the target)"
  else
    if [[ -d "$g$GO_VERSION" ]]; then echo "STEP target $g$GO_VERSION exists"
    else echo "STEP download go$GO_VERSION.linux-$(_bgs_arch).tar.gz, check its sha256 (${GO_SHA256:-the go.dev list}), unpack to $g$GO_VERSION"; fi
    [[ "$kind" != dir ]] || echo "STEP mv $g $g$from (the old tree is kept)"
  fi
  echo "STEP ln -sfn go$GO_VERSION $g"
  _bgs_profile_ok || echo "STEP append /usr/local/go/bin to PATH in $GS_ROOT/etc/profile.d/go.sh"
  echo "STEP journal to ${GO_SWITCH_JOURNAL:-/var/lib/csi-spl/box-go/journal.tsv}, then the after checks"
}

# _bgs_target: the target tree in place, the old plain tree kept
_bgs_target() {
  local g="$GS_ROOT/usr/local/go" t
  if [[ "$kind" == dir ]] && [[ -z "$from" || -e "$g$from" ]]; then
    echo "REFUSED: cannot keep the old tree (version '${from:-unknown}', or $g$from exists); nothing changed" >&2
    return 1
  fi
  if [[ "$kind" != dir || "$from" != "$GO_VERSION" ]] && [[ ! -d "$g$GO_VERSION" ]]; then
    _bgs_fetch_target "$g$GO_VERSION" || return $?
  fi
  t="$(_bgs_tree_version "$g$GO_VERSION")"
  if [[ "$kind" != dir || "$from" != "$GO_VERSION" ]] && [[ "$t" != "$GO_VERSION" ]]; then
    echo "REFUSED: $g$GO_VERSION says go${t:-unknown}, not go$GO_VERSION; nothing changed" >&2
    return 1
  fi
  [[ "$kind" != dir ]] || _bgs_sudo mv "$g" "$g$from" || return 3
}

# _bgs_real: steps 2..6 for real
_bgs_real() {
  local g="$GS_ROOT/usr/local/go" rc=0
  _bgs_target || return $?
  _bgs_sudo ln -sfn "go$GO_VERSION" "$g" || return 3
  if ! _bgs_profile_ok; then
    # shellcheck disable=SC2016  # the line is for the login shell to expand
    { _bgs_sudo mkdir -p "$GS_ROOT/etc/profile.d" &&
      printf '%s\n' 'case ":$PATH:" in *:/usr/local/go/bin:*) ;; *) PATH="$PATH:/usr/local/go/bin" ;; esac' |
      _bgs_sudo tee -a "$GS_ROOT/etc/profile.d/go.sh" >/dev/null; } || return 3
  fi
  _bgs_journal switch || echo "WARN the journal line was not written" >&2
  _bgs_after || rc=$?
  _bgs_rollback
  return "$rc"
}

do_box_go_switch() {
  : "${GO_VERSION:?GO_VERSION must be set: the Go to switch to, e.g. 1.26.9}"
  : "${GO_SWITCH_REASON:?GO_SWITCH_REASON must be set: why this box needs it}"
  : "${AGENT_ID:?AGENT_ID must be set: who switches it}"
  GO_VERSION="${GO_VERSION#go}"
  [[ "$GO_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
    { echo "REFUSED: GO_VERSION '$GO_VERSION' is not X.Y or X.Y.Z" >&2; return 1; }
  local GS_ROOT="${GO_SWITCH_ROOT:-}" kind from link_to
  _bgs_before
  if [[ "$from" == "$GO_VERSION" ]] && _bgs_profile_ok; then
    echo "NO-OP: /usr/local/go is already go$GO_VERSION and on PATH; nothing changed"
    return 0
  fi
  _bgs_plan
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    echo "DRY RUN: nothing changed"
    _bgs_rollback
    echo "RE-RUN to switch:"
    _bgs_rerun_line
    return 0
  fi
  _bgs_real
}
