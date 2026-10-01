#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Install, per user and without root, the scanners the pre-push
# @description lint parts run (do_check_pre_push_lint), at EXACTLY the versions
# @description the GitHub scanner workflows pin. The version and sha256 of each
# @description binary are READ FROM THE WORKFLOW FILE (v=... / sha=...), so a
# @description bump there is a bump here and local PASS == CI PASS. A download
# @description that does not match its pin fails closed. Idempotent: a tool
# @description already at its pinned version is left alone.
# @description   binaries  shellcheck (67) actionlint (85) hadolint (66)
# @description             trufflehog (64) gosec (62) -> LINT_TOOLS_BIN
# @description   eslint    eslint + eslint-plugin-security (63) -> LINT_TOOLS_ESLINT_DIR
# @description   python    checkov (65), semgrep (61) -> LINT_TOOLS_VENV, linked into LINT_TOOLS_BIN
# @description   typos     typos-cli, the spelling WARN (no CI workflow yet, so pinned HERE)
# @description   gitleaks  (15) -> LINT_TOOLS_BIN
# @description   ruff      the lint-py rule set (no CI workflow yet, so pinned HERE)
# @description   pglast    PG16 grammar for the migration parse (pinned HERE: 6.x is
# @description             libpg_query 16, the hub's POSTGRES_16) -> its own venv
# @param LINT_TOOLS_BIN (optional) - default ~/.local/bin (on the hook's PATH)
# @param LINT_TOOLS_ESLINT_DIR (optional) - default ~/.cache/csi-spl/eslint
# @param LINT_TOOLS_VENV (optional) - venv prefix, default ~/.cache/csi-spl/lint-venv (-<tool>)
# @param LINT_TOOLS_ONLY (optional) - space list of tools to install, default all
# @param LINT_TOOLS_SYSTEM (optional) - 1 = also copy the static binaries, root-owned,
# @param        into /usr/local/bin (sudo), so EVERY user and every `sudo -u` shell
# @param        (secure_path has no ~/.local/bin) runs the same CI-pinned binary
# @example ./run -a do_install_lint_tools
# @example LINT_TOOLS_ONLY='shellcheck actionlint' ./run -a do_install_lint_tools
# @example LINT_TOOLS_SYSTEM=1 ./run -a do_install_lint_tools
#------------------------------------------------------------------------------

# No workflow pins typos (spelling is WARN-only, CI has no gate), so its pin
# lives here. Digest checked independently by two lanes (2026-10-01).
_ILT_TYPOS_VER=1.50.3
_ILT_TYPOS_SHA=aca6b5d546307092b8d0a8e0a89dd80f9da51f2f7617c5e45c5607c1684ffbf2
# pglast 7+/8 parse the PG17/18 grammar and would pass SQL the PG16 hub rejects.
_ILT_PGLAST_VER=6.16
# ruff 0.16 widened its default rules: lint-py always passes --select.
_ILT_RUFF_VER=0.16.9
_ILT_RUFF_SHA=1bfbb819b5d4f9af501748862276b60e412d336034d99387691a4d4bce7a6f13

_ilt_root() {
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -d "$base/../.github/workflows" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -d "$base/.github/workflows" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL APP_PATH is not the csi-spl tree (no .github/workflows)"
  return 1
}

# The first `<key>=<value>` assignment in a workflow file (v=, sha=).
_ilt_pin() {  # <workflow-file> <key>
  sed -nE "s/.*(^|[ ;])$2=([A-Za-z0-9._-]+).*/\\2/p" "$1" | head -1
}

# The `<pkg>@<ver>` / `<pkg>==<ver>` pin a workflow installs.
_ilt_pkg_pin() {  # <workflow-file> <pkg> <sep>
  grep -oE "(^|[ ])$2$3[0-9][0-9A-Za-z.]*" "$1" | head -1 | sed -E "s/^ ?$2$3//"
}

# Have <bin> at <ver>? (`--version` output contains the version string.)
_ilt_have() {  # <path> <ver>
  [[ -x "$1" ]] && "$1" --version 2>&1 | grep -qF "$2"
}

# Download <url>, check sha256, and put <member> (or the file itself when
# <member> is empty) at $LINT_TOOLS_BIN/<name>.
_ilt_fetch() {  # <name> <ver> <sha> <url> <member>
  local name="$1" ver="$2" sha="$3" url="$4" member="$5" dst="$_ILT_BIN/$1" tmp
  if _ilt_have "$dst" "$ver"; then do_log "INFO $name $ver already installed at $dst"; return 0; fi
  [[ -n "$ver" && -n "$sha" ]] || { do_log "FATAL could not read the $name pin (v= / sha=) from its workflow"; return 1; }
  tmp="$(mktemp -d)" || return 1
  if ! curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$tmp/dl" "$url"; then
    do_log "FATAL $name: download failed: $url"; rm -rf "$tmp"; return 1
  fi
  if ! echo "$sha  $tmp/dl" | sha256sum -c - >/dev/null 2>&1; then
    do_log "FATAL $name: sha256 does not match the workflow pin $sha -- refusing an unknown binary"
    rm -rf "$tmp"; return 1
  fi
  case "$url" in
    *.tar.xz) tar -xJf "$tmp/dl" -C "$tmp" "$member" || { rm -rf "$tmp"; return 1; }; mv -f "$tmp/$member" "$dst" ;;
    *.tar.gz) tar -xzf "$tmp/dl" -C "$tmp" "$member" || { rm -rf "$tmp"; return 1; }; mv -f "$tmp/$member" "$dst" ;;
    *)        mv -f "$tmp/dl" "$dst" ;;
  esac
  chmod +x "$dst"; rm -rf "$tmp"
  do_log "INFO $name $ver installed at $dst (sha256 matches its pin)"
}

_ilt_bin_tool() {  # <tool>
  local wf v sha
  case "$1" in
    shellcheck)
      wf="$_ILT_WF/67_shellcheck.yml"; v="$(_ilt_pin "$wf" v)"; sha="$(_ilt_pin "$wf" sha)"
      _ilt_fetch shellcheck "$v" "$sha" \
        "https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.linux.x86_64.tar.xz" \
        "shellcheck-v$v/shellcheck" ;;
    actionlint)
      wf="$_ILT_WF/85_actionlint.yml"; v="$(_ilt_pin "$wf" v)"; sha="$(_ilt_pin "$wf" sha)"
      _ilt_fetch actionlint "$v" "$sha" \
        "https://github.com/rhysd/actionlint/releases/download/v$v/actionlint_${v}_linux_amd64.tar.gz" actionlint ;;
    hadolint)
      wf="$_ILT_WF/66_hadolint.yml"; v="$(_ilt_pin "$wf" v)"; sha="$(_ilt_pin "$wf" sha)"
      _ilt_fetch hadolint "$v" "$sha" \
        "https://github.com/hadolint/hadolint/releases/download/v$v/hadolint-Linux-x86_64" "" ;;
    trufflehog)
      wf="$_ILT_WF/64_trufflehog.yml"; v="$(_ilt_pin "$wf" v)"; sha="$(_ilt_pin "$wf" sha)"
      _ilt_fetch trufflehog "$v" "$sha" \
        "https://github.com/trufflesecurity/trufflehog/releases/download/v$v/trufflehog_${v}_linux_amd64.tar.gz" trufflehog ;;
    typos)
      v="$_ILT_TYPOS_VER"
      _ilt_fetch typos "$v" "$_ILT_TYPOS_SHA" \
        "https://github.com/crate-ci/typos/releases/download/v$v/typos-v$v-x86_64-unknown-linux-musl.tar.gz" ./typos ;;
    ruff)
      v="$_ILT_RUFF_VER"
      _ilt_fetch ruff "$v" "$_ILT_RUFF_SHA" \
        "https://github.com/astral-sh/ruff/releases/download/$v/ruff-x86_64-unknown-linux-gnu.tar.gz" \
        ruff-x86_64-unknown-linux-gnu/ruff ;;
    gitleaks)
      wf="$_ILT_WF/15_sec-deps-secrets.yml"
      v="$(grep -oE 'gitleaks/releases/download/v[0-9.]+' "$wf" | head -1 | sed 's|.*/v||')"
      sha="$(sed -n '/Install gitleaks/,/tar /s/.*sha=\([0-9a-f]\{64\}\).*/\1/p' "$wf" | head -1)"
      _ilt_fetch gitleaks "$v" "$sha" \
        "https://github.com/gitleaks/gitleaks/releases/download/v$v/gitleaks_${v}_linux_x64.tar.gz" gitleaks ;;
    gosec)
      wf="$_ILT_WF/62_gosec.yml"; v="$(_ilt_pin "$wf" v)"; sha="$(_ilt_pin "$wf" sha)"
      _ilt_fetch gosec "$v" "$sha" \
        "https://github.com/securego/gosec/releases/download/v$v/gosec_${v}_linux_amd64.tar.gz" gosec ;;
  esac
}

_ilt_eslint() {
  local wf="$_ILT_WF/63_eslint-security.yml" ev pv d="$_ILT_ESLINT"
  ev="$(_ilt_pkg_pin "$wf" eslint @)"; pv="$(_ilt_pkg_pin "$wf" eslint-plugin-security @)"
  [[ -n "$ev" && -n "$pv" ]] || { do_log "FATAL could not read the eslint pins from $wf"; return 1; }
  command -v npm >/dev/null 2>&1 || { do_log "FATAL npm not found -- install Node 20 (the version 63 sets up)"; return 1; }
  if [[ -x "$d/node_modules/.bin/eslint" ]] && "$d/node_modules/.bin/eslint" --version 2>/dev/null | grep -qF "$ev" \
     && grep -qF "\"version\": \"$pv\"" "$d/node_modules/eslint-plugin-security/package.json" 2>/dev/null; then
    do_log "INFO eslint $ev + eslint-plugin-security $pv already installed in $d"; return 0
  fi
  mkdir -p "$d" || return 1
  ( cd "$d" && npm install --no-save --no-audit --no-fund --silent "eslint@$ev" "eslint-plugin-security@$pv" ) \
    || { do_log "FATAL npm install eslint@$ev eslint-plugin-security@$pv failed in $d"; return 1; }
  do_log "INFO eslint $ev + eslint-plugin-security $pv installed in $d"
}

# pglast is a library, not a CLI: its own venv, probed by import + version.
_ilt_pglast() {
  local venv="$_ILT_VENV-pglast" ver="$_ILT_PGLAST_VER"
  if [[ -x "$venv/bin/python" ]] && "$venv/bin/python" -c "import pglast,sys; sys.exit(0 if pglast.__version__.startswith('$ver') else 1)" 2>/dev/null; then
    do_log "INFO pglast $ver already installed in $venv"; return 0
  fi
  [[ -x "$venv/bin/pip" ]] || python3 -m venv "$venv" \
    || { do_log "FATAL python3 -m venv $venv failed (apt-get install python3-venv)"; return 1; }
  "$venv/bin/pip" install --disable-pip-version-check --quiet "pglast==$ver.*" \
    || { do_log "FATAL pip install pglast==$ver.* failed"; return 1; }
  do_log "INFO pglast $ver installed in $venv"
}

_ilt_py() {  # <tool> (checkov | semgrep)
  local tool="$1" wf ver
  case "$tool" in
    checkov)   wf="$_ILT_WF/65_iac-checkov.yml" ;;
    semgrep)   wf="$_ILT_WF/61_semgrep.yml" ;;
  esac
  ver="$(_ilt_pkg_pin "$wf" "$tool" ==)"
  [[ -n "$ver" ]] || { do_log "FATAL could not read the $tool pin from $wf"; return 1; }
  if _ilt_have "$_ILT_BIN/$tool" "$ver"; then do_log "INFO $tool $ver already installed"; return 0; fi
  local venv="$_ILT_VENV-$tool"
  [[ -x "$venv/bin/pip" ]] || python3 -m venv "$venv" \
    || { do_log "FATAL python3 -m venv $venv failed (apt-get install python3-venv)"; return 1; }
  "$venv/bin/pip" install --disable-pip-version-check --quiet "$tool==$ver" \
    || { do_log "FATAL pip install $tool==$ver failed"; return 1; }
  ln -sf "$venv/bin/$tool" "$_ILT_BIN/$tool"
  do_log "INFO $tool $ver installed in $venv, linked at $_ILT_BIN/$tool"
}

do_install_lint_tools() {
  local root; root="$(_ilt_root)" || return 1
  local _ILT_WF="$root/.github/workflows"
  local _ILT_BIN="${LINT_TOOLS_BIN:-$HOME/.local/bin}"
  local _ILT_ESLINT="${LINT_TOOLS_ESLINT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/eslint}"
  local _ILT_VENV="${LINT_TOOLS_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/lint-venv}"
  local only="${LINT_TOOLS_ONLY:-shellcheck actionlint hadolint trufflehog gosec eslint checkov semgrep typos gitleaks pglast ruff}"
  mkdir -p "$_ILT_BIN" || return 1
  local t fails=0
  for t in $only; do
    case "$t" in
      shellcheck|actionlint|hadolint|trufflehog|gosec|typos|gitleaks|ruff) _ilt_bin_tool "$t" || fails=$((fails + 1)) ;;
      eslint) _ilt_eslint || fails=$((fails + 1)) ;;
      pglast) _ilt_pglast || fails=$((fails + 1)) ;;
      checkov|semgrep) _ilt_py "$t" || fails=$((fails + 1)) ;;
      *) do_log "FATAL unknown lint tool '$t'"; fails=$((fails + 1)) ;;
    esac
  done
  if [[ "${LINT_TOOLS_SYSTEM:-0}" == 1 ]]; then
    for t in shellcheck actionlint hadolint trufflehog gosec typos gitleaks ruff; do
      [[ " $only " == *" $t "* && -x "$_ILT_BIN/$t" ]] || continue
      if sudo install -m 0755 -o root -g root "$_ILT_BIN/$t" "/usr/local/bin/$t"; then
        do_log "INFO $t copied to /usr/local/bin (root-owned, every user)"
      else
        do_log "FATAL could not copy $t to /usr/local/bin (needs sudo)"; fails=$((fails + 1))
      fi
    done
  fi
  [[ "$fails" -eq 0 ]] || { do_log "FATAL $fails lint tool(s) not installed"; return 1; }
  do_log "INFO lint tools ready in $_ILT_BIN (eslint in $_ILT_ESLINT)"
}
