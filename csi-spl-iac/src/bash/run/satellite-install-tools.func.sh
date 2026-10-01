#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057, owner topic 5fe56859 ("the same replica ... all of the
# @description Terraform and other connections should work the way they work
# @description from the box machine"): install on the satellite, as its box
# @description user, the tools the box PC's agents run that the bootstrap does
# @description not. Idempotent and re-runnable after a recreate (each part
# @description checks before it changes anything; one TOOL verdict line each):
# @description   pnpm             corepack, into ~/.local/bin
# @description   cloud-sql-proxy  THIS box's binary, copied over ssh and
# @description                    sha256-checked against it on arrival
# @description   lint + terraform the repo's own do_install_lint_tools there:
# @description                    the CI-pinned scanners and the cnf terraform
# @description   tpl-gen          the repo's do_setup_tpl_gen there, from the
# @description                    remote of this box's tpl-gen clone (https,
# @description                    with the pushed GitHub token)
# @description Needs do_satellite_bootstrap (+ creds push) first. The tool list
# @description and how each is verified: cnf/satellite-replica.tsv.
# @param SATELLITE_TOOLS (optional) - space list of parts, default
# @param        "pnpm cloud-sql-proxy lint tpl-gen"
# @param TPL_GEN_REPO_URL (optional) - default: the origin of $APP_PATH/tpl-gen
# @example ./run -a do_satellite_install_tools
# @example SATELLITE_TOOLS=cloud-sql-proxy ./run -a do_satellite_install_tools
#------------------------------------------------------------------------------
do_satellite_install_tools() {
  do_satellite_ssh_opts || return 1
  local parts=" ${SATELLITE_TOOLS:-pnpm cloud-sql-proxy lint tpl-gen} " repo dir fails=0 p
  repo=$(do_satellite_cnf gh_repo 120-github-general-secrets) || return 1
  dir="/opt/csi/${repo##*/}"
  for p in $parts; do
    case "$p" in pnpm | cloud-sql-proxy | lint | tpl-gen) ;; *) do_log "FATAL unknown part '$p' in SATELLITE_TOOLS"; return 1 ;; esac
  done

  if [[ "$parts" == *" cloud-sql-proxy "* ]]; then
    local bin sum
    bin=$(command -v cloud-sql-proxy) || { do_log "FATAL no cloud-sql-proxy on this box to replicate"; return 1; }
    sum=$(sha256sum "$bin" | cut -d' ' -f1)
    # shellcheck disable=SC2029
    if ssh "${SATELLITE_SSH[@]}" "[ \"\$(sha256sum \"\$HOME/.local/bin/cloud-sql-proxy\" 2>/dev/null | cut -d' ' -f1)\" = '${sum}' ]"; then
      echo "TOOL cloud-sql-proxy OK the box's binary (${sum:0:12})"
    elif ssh "${SATELLITE_SSH[@]}" "mkdir -p \"\$HOME/.local/bin\" && f=\"\$HOME/.local/bin/cloud-sql-proxy\" && cat >\"\$f.part\" \
        && [ \"\$(sha256sum \"\$f.part\" | cut -d' ' -f1)\" = '${sum}' ] && chmod 755 \"\$f.part\" && mv \"\$f.part\" \"\$f\"" <"$bin"; then
      echo "TOOL cloud-sql-proxy CHANGED copied the box's binary (${sum:0:12})"
    else
      echo "TOOL cloud-sql-proxy FAIL copy or sha256 mismatch"; fails=$((fails + 1))
    fi
  fi

  local url=""
  if [[ "$parts" == *" tpl-gen "* ]]; then
    url="${TPL_GEN_REPO_URL:-$(git -C "${APP_PATH}/tpl-gen" remote get-url origin 2>/dev/null)}"
    [[ -n "$url" ]] || { do_log "FATAL no TPL_GEN_REPO_URL and no ${APP_PATH}/tpl-gen clone to read it from"; return 1; }
    # the satellite reaches GitHub over https with the pushed token
    [[ "$url" =~ ^git@([^:]+):(.+)$ ]] && url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi

  # shellcheck disable=SC2016,SC2029
  ssh "${SATELLITE_SSH[@]}" "PARTS='${parts}' DIR='${dir}' TPL_URL='${url}' bash -s" <<'REMOTE' || fails=$((fails + 1))
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/spool-agent/tools/bin:$HOME/.local/share/spool-agent/tools/go/bin:$HOME/go/bin:$PATH"
f=0
[[ -d "$DIR/.git" ]] || { echo "TOOL repo FAIL no $DIR: run do_satellite_bootstrap first"; exit 1; }
if [[ "$PARTS" == *" pnpm "* ]]; then
  # the version the WUI pins (packageManager), never corepack's "latest".
  # corepack links RELATIVE paths and never replaces a link, so it gets the
  # real dir (~/.local is a link into the data disk, do_satellite_home_persist)
  # and a dangling pnpm/pnpx link is removed first
  pm=$(jq -r '.packageManager // ""' "$DIR/csi-spl-wui/package.json" 2>/dev/null); pm=${pm%%+*}
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  if [[ -n "$pm" && "$(pnpm --version 2>/dev/null)" == "${pm#pnpm@}" ]]; then
    echo "TOOL pnpm OK ${pm#pnpm@}"
  elif [[ "$pm" == pnpm@* ]]; then
    bindir=$(readlink -f "$HOME/.local/bin"); mkdir -p "$bindir"
    for l in pnpm pnpx; do [[ -L "$bindir/$l" && ! -e "$bindir/$l" ]] && rm -f "$bindir/$l"; done
    if corepack enable --install-directory "$bindir" pnpm >/dev/null 2>&1 && corepack prepare "$pm" --activate >/dev/null 2>&1 \
        && [[ "$(pnpm --version 2>/dev/null)" == "${pm#pnpm@}" ]]; then
      echo "TOOL pnpm CHANGED corepack ${pm#pnpm@}"
    else echo "TOOL pnpm FAIL corepack $pm"; f=1; fi
  else echo "TOOL pnpm FAIL no packageManager in csi-spl-wui/package.json"; f=1; fi
fi
if [[ "$PARTS" == *" lint "* ]]; then
  if (cd "$DIR/csi-spl-iac" && ./run -a do_install_lint_tools) >/tmp/satellite-lint-tools.log 2>&1; then
    echo "TOOL lint+terraform OK do_install_lint_tools (log /tmp/satellite-lint-tools.log)"
  else echo "TOOL lint+terraform FAIL do_install_lint_tools: $(tail -n 3 /tmp/satellite-lint-tools.log | tr '\n' ' ')"; f=1; fi
fi
if [[ "$PARTS" == *" tpl-gen "* ]]; then
  [[ -r "$HOME/.github/token" ]] || { echo "TOOL tpl-gen FAIL no ~/.github/token: DRY_RUN=0 ./run -a do_satellite_creds_push"; exit 1; }
  # the token reaches git through a helper that reads the file; never argv
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.https://github.com.helper
  export GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$(cat "$HOME/.github/token")"; }; f'
  if (cd "$DIR/csi-spl-iac" && TPL_GEN_REPO_URL="$TPL_URL" ./run -a do_setup_tpl_gen) >/tmp/satellite-tpl-gen.log 2>&1; then
    echo "TOOL tpl-gen OK $DIR/tpl-gen at $(git -C "$DIR/tpl-gen" rev-parse --short HEAD)"
  else echo "TOOL tpl-gen FAIL do_setup_tpl_gen: $(tail -n 3 /tmp/satellite-tpl-gen.log | tr '\n' ' ')"; f=1; fi
fi
exit "$f"
REMOTE
  ((fails == 0)) || { do_log "FATAL a TOOL part failed (the lines above)"; return 1; }
  do_log "OK the satellite has the box PC's tools: ./run -a do_satellite_verify"
}
