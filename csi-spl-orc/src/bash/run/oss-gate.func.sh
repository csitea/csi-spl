#!/bin/bash
#------------------------------------------------------------------------------
# @description The go/no-go for a tree meant to leave the private repo (spec 044
# @description T003/T004, FR-OS-002/003/006, SPL-63). Runs on an EXPORTED dir
# @description (do_oss_export writes one) and FAILS on any hit of any class:
# @description   secret            gitleaks at the CI-pinned version (15 sec
# @description                     workflow), `gitleaks dir`, the repo's
# @description                     .gitleaks.toml, zero findings
# @description   hygiene           the 10 ci distribution-hygiene Sweep, read
# @description                     out of the workflow with yq, never copied
# @description   <literal classes> csi-spl-orc/cnf/oss/banned-literals.tsv
# @description                     (private only): other orgs, our hosts and
# @description                     repo path, GCP project/SA/org/billing ids,
# @description                     tenant slugs, fleet ids, box paths
# @description   forbidden-file    CLAUDE.md/AGENTS.md/GEMINI.md, .git, cnf
# @description                     env files, tfvars/tfstate, key files
# @description   image-unlicensed  any image not globbed in licensed-assets.txt
# @description   licence           AGPL-3.0 root LICENSE, notices file, a
# @description                     license field per package.json, an SPDX id
# @description                     per Go module root
# @description   dep-licence       every Go module the build compiles and every
# @description                     npm package of the WUI lockfile install,
# @description                     against the AGPL-3.0-compatible list
# @description The report (TSV: class, path, line, rule label) carries file:line
# @description and NEVER the matched value; gitleaks runs with --redact and only
# @description File/StartLine/RuleID are kept. The per-class counts go to stdout.
# @description Exit 0 = every class counted 0. 1 = hits. 2 = a class could not
# @description be measured (a tool, workflow or input missing) - never a pass.
# @description Writes nothing into DIR and needs no network once gitleaks is
# @description cached (first run downloads the pinned tarball, sha256-checked).
# @param DIR - required: the exported tree (not a git checkout)
# @param OSS_GATE_REPORT (optional) - default: <DIR>.oss-gate-report.tsv (beside DIR, never in it)
# @param OSS_GATE_RULES (optional) - default: csi-spl-orc/cnf/oss/banned-literals.tsv
# @param OSS_GATE_ASSETS (optional) - default: csi-spl-orc/cnf/oss/licensed-assets.txt
# @param OSS_GATE_NODE_MODULES (optional) - the WUI node_modules to read npm
# @param   licences from; default <DIR>/csi-spl-wui/node_modules, else the
# @param   source checkout's, used only when its pnpm-lock.yaml is byte-equal
# @param OSS_GATE_SKIP_DEPS (optional) - 1 = skip dep-licence (tests only; reported as SKIPPED, exit >= 2)
# @param GITLEAKS_BIN (optional) - a gitleaks binary; must report the pinned version
# @example DIR=/var/tmp/oss/spool ./run -a do_oss_gate
#------------------------------------------------------------------------------
OSS_GITLEAKS_VERSION="8.30.1"
OSS_GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

# oss_gitleaks_ci_version <workflow> - the version the CI secret scan downloads
oss_gitleaks_ci_version() {
  grep -oP 'gitleaks/releases/download/v\K[0-9.]+(?=/)' "$1" 2>/dev/null | sort -u
}

# oss_gitleaks_bin - print a gitleaks of the pinned version, downloading the
# release tarball into the user cache (sha256-checked) when none is given.
oss_gitleaks_bin() {
  local bin="${GITLEAKS_BIN:-}" cache tgz got
  if [[ -z "$bin" ]]; then
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/gitleaks/$OSS_GITLEAKS_VERSION"
    bin="$cache/gitleaks"
    if [[ ! -x "$bin" ]]; then
      mkdir -p "$cache" || return 1
      tgz="$cache/gitleaks.tgz"
      curl -fsSL -o "$tgz" "https://github.com/gitleaks/gitleaks/releases/download/v${OSS_GITLEAKS_VERSION}/gitleaks_${OSS_GITLEAKS_VERSION}_linux_x64.tar.gz" \
        || { echo "gitleaks download failed" >&2; return 1; }
      got=$(sha256sum "$tgz" | cut -d' ' -f1)
      [[ "$got" == "$OSS_GITLEAKS_SHA256" ]] \
        || { rm -f "$tgz"; echo "gitleaks tarball sha256 mismatch" >&2; return 1; }
      tar -xzf "$tgz" -C "$cache" gitleaks && rm -f "$tgz" || return 1
    fi
  fi
  [[ "$("$bin" version 2>/dev/null)" == "$OSS_GITLEAKS_VERSION" ]] \
    || { echo "$bin is not gitleaks $OSS_GITLEAKS_VERSION" >&2; return 1; }
  echo "$bin"
}

# oss_gate_secrets <dir> <config> <report> - gitleaks rows: secret, file, line, rule
oss_gate_secrets() {
  local dir="$1" cfg="$2" report="$3" bin tmp rc=0
  bin=$(oss_gitleaks_bin) || return 2
  tmp=$(mktemp) || return 2
  "$bin" dir "$dir" --config "$cfg" --redact --no-banner --exit-code 0 \
    --report-format json --report-path "$tmp" >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )) || ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; echo "gitleaks failed (rc=$rc)" >&2; return 2
  fi
  # File/StartLine/RuleID only: the Secret and Match fields never leave jq.
  jq -r --arg d "${dir%/}/" '.[] | ["secret", (.File | ltrimstr($d)), (.StartLine|tostring), .RuleID] | @tsv' "$tmp" >>"$report"
  rm -f "$tmp"
}

# oss_gate_hygiene <dir> <workflow> <report> - the 10 ci Sweep over <dir>
oss_gate_hygiene() {
  local dir="$1" wf="$2" report="$3" tmp out label="" line src=0 n=0
  tmp=$(mktemp) || return 2
  yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$wf" >"$tmp" 2>/dev/null
  if [[ ! -s "$tmp" ]] || ! grep -q 'allow_line=' "$tmp"; then
    rm -f "$tmp"; echo "no distribution-hygiene Sweep step in $wf" >&2; return 2
  fi
  out=$(cd "$dir" && bash "$tmp" 2>&1) || src=$?
  rm -f "$tmp"
  grep -q 'grep failed' <<<"$out" && { echo "the hygiene Sweep could not run" >&2; return 2; }
  # "::error::hygiene: <label> -- N line(s)" then "  ./path:line" rows
  while IFS= read -r line; do
    if [[ "$line" =~ ^::error::hygiene:\ (.*)\ --\  ]]; then
      label="${BASH_REMATCH[1]}"
    elif [[ -n "$label" && "$line" =~ ^\ \ \./([^:]+):([0-9]+)$ ]]; then
      printf 'hygiene\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$label" >>"$report"
      n=$((n + 1))
    elif [[ "$line" =~ ^(ok|allowed)\ -\  ]]; then
      label=""
    fi
  done <<<"$out"
  # A red Sweep whose rows this parser did not read is a format change, never
  # a pass; so is a Sweep that printed no per-label verdict at all.
  if (( src != 0 && n == 0 )) || ! grep -qE '^(ok|allowed) - |^::error::hygiene:' <<<"$out"; then
    echo "the hygiene Sweep output was not understood (rc=$src, rows=$n)" >&2; return 2
  fi
}

# oss_gate_go_list <dir> <out> - "module version dir" for every non-main
# module compiled by every Go module in <dir>, from the local module cache.
oss_gate_go_list() {
  local dir="$1" out="$2" gomod
  : >"$out"
  [[ -n "$(find "$dir" -name go.mod -not -path '*/node_modules/*' -print -quit)" ]] || return 0
  local sel="${APP_PATH:-}/csi-spl-api/src/bash/use-go-toolchain.sh"
  # shellcheck disable=SC1090
  [[ -f "$sel" ]] && source "$sel" && spl_export_go_path >/dev/null 2>&1
  command -v go >/dev/null 2>&1 || PATH="/usr/local/go/bin:$PATH"
  command -v go >/dev/null 2>&1 || { echo "no go toolchain" >&2; return 2; }
  while IFS= read -r gomod; do
    (cd "$(dirname "$gomod")" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPROXY=off \
      go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Version}} {{.Dir}}{{end}}{{end}}' ./... ) >>"$out" \
      || { echo "go list failed in $(dirname "$gomod")" >&2; return 2; }
  done < <(find "$dir" -name go.mod -not -path '*/node_modules/*')
  sort -u -o "$out" "$out"
}

do_oss_gate() {
  do_require_bin python3 jq yq git curl || return 2
  local dir="${DIR:-}"
  [[ -n "$dir" && -d "$dir" ]] || { do_log "FATAL DIR must name the exported tree, got: '$dir'"; return 2; }
  dir=$(cd "$dir" && pwd)
  local orc="${PROJ_PATH:-$APP_PATH/csi-spl-orc}"
  local report="${OSS_GATE_REPORT:-${dir}.oss-gate-report.tsv}"
  local rules="${OSS_GATE_RULES:-$orc/cnf/oss/banned-literals.tsv}"
  local assets="${OSS_GATE_ASSETS:-$orc/cnf/oss/licensed-assets.txt}"
  local wf_q="$APP_PATH/.github/workflows/10_ci-quality.yml"
  local wf_s="$APP_PATH/.github/workflows/15_sec-deps-secrets.yml"
  local py="$orc/src/bash/scripts/oss-gate.py" cfg="$APP_PATH/.gitleaks.toml"
  local unmeasured=() golist ci_ver nm
  [[ "$report" != "$dir"/* ]] || { do_log "FATAL OSS_GATE_REPORT must not be inside DIR (it would ship)"; return 2; }
  [[ -f "$rules" ]] || { do_log "FATAL no literal rules at $rules"; return 2; }
  [[ -f "$cfg" ]] || { do_log "FATAL no gitleaks config at $cfg"; return 2; }
  ci_ver=$(oss_gitleaks_ci_version "$wf_s")
  [[ "$ci_ver" == "$OSS_GITLEAKS_VERSION" ]] \
    || { do_log "FATAL CI pins gitleaks '$ci_ver', this gate pins $OSS_GITLEAKS_VERSION - move both together"; return 2; }

  {
    echo "# do_oss_gate report - class<TAB>path<TAB>line<TAB>rule (never the matched value)"
    echo "# dir=$dir"
    echo "# src=$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null) gitleaks=$OSS_GITLEAKS_VERSION utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$report" || return 2

  oss_gate_secrets "$dir" "$cfg" "$report" || unmeasured+=(secret)
  oss_gate_hygiene "$dir" "$wf_q" "$report" || unmeasured+=(hygiene)
  python3 "$py" scan --dir "$dir" --rules "$rules" --assets "$assets" --report "$report" || unmeasured+=(literals)

  if [[ "${OSS_GATE_SKIP_DEPS:-0}" == 1 ]]; then
    unmeasured+=(dep-licence:SKIPPED)
  else
    golist=$(mktemp)
    nm="${OSS_GATE_NODE_MODULES:-}"
    if [[ -z "$nm" ]]; then
      if [[ -d "$dir/csi-spl-wui/node_modules" ]]; then
        nm="$dir/csi-spl-wui/node_modules"
      elif [[ -f "$dir/csi-spl-wui/pnpm-lock.yaml" ]] \
        && cmp -s "$dir/csi-spl-wui/pnpm-lock.yaml" "$APP_PATH/csi-spl-wui/pnpm-lock.yaml" \
        && [[ -d "$APP_PATH/csi-spl-wui/node_modules" ]]; then
        nm="$APP_PATH/csi-spl-wui/node_modules"
      fi
    fi
    if [[ -f "$dir/csi-spl-wui/package.json" && -z "$nm" ]]; then
      do_log "ERROR no node_modules matching the exported pnpm-lock.yaml - npm licences not measured"
      unmeasured+=(dep-licence:npm)
    fi
    if oss_gate_go_list "$dir" "$golist"; then
      python3 "$py" deps --report "$report" --go-list "$golist" ${nm:+--node-modules "$nm"} || unmeasured+=(dep-licence)
    else
      unmeasured+=(dep-licence:go)
    fi
    rm -f "$golist"
  fi

  local classes rc=0
  classes="secret,hygiene,forbidden-file,image-unlicensed,licence,dep-licence,$(grep -v '^#' "$rules" | cut -f1 | grep . | sort -u | paste -sd,)"
  python3 "$py" summary --report "$report" --classes "$classes" || rc=1
  if (( ${#unmeasured[@]} )); then
    do_log "FATAL not measured: ${unmeasured[*]} - this gate proved nothing for them (report $report)"
    return 2
  fi
  if (( rc )); then
    do_log "FATAL the export gate FAILS: hits above, file:line in $report"
    return 1
  fi
  do_log "INFO the export gate is clean: every class 0 (report $report)"
}
