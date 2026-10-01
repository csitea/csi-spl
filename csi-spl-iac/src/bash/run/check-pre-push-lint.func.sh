#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The LINT parts of do_check_pre_push (owner 2026-10-01: "why
# @description cannot they be ran via shell actions locally before someone
# @description pushes?!"). Each GitHub scanner workflow runs here first, on the
# @description files the push TOUCHES, through the SAME named action, binary
# @description version, config, severity and baseline as CI -- so a local PASS
# @description is a CI PASS for those files:
# @description   lint-syntax      bash -n (.sh + extension-less #!..sh scripts), yq (.yml/
# @description                    .yaml), jq (.json), make -n (csi-spl-orc Makefile / *.mk)
# @description   lint-shellcheck  67 do_sec_shellcheck  (.sh in the iac/orc/cnf bash trees)
# @description   lint-actionlint  85 do_sec_actionlint  (.github/workflows/*)
# @description   lint-hadolint    66 do_sec_hadolint    (Dockerfiles)
# @description   lint-eslint      63 do_sec_eslint      (csi-spl-wui/src .mjs/.js, vs baseline)
# @description   lint-trufflehog  64 do_sec_trufflehog  (every touched file, verified secrets)
# @description   lint-mdlinks     relative links in touched .md (and in the .md that
# @description                    link to a deleted/renamed path) must resolve
# @description   lint-typos       typos-cli (_typos.toml) on the ADDED lines: WARN only
# @description FULL tier only (too slow for the hook, CI owns them; measured
# @description 2026-10-01 over the whole tree): lint-checkov (65, 65 s, when
# @description terraform is touched), lint-semgrep (61, 152 s) and lint-gosec
# @description (62, >300 s). CodeQL (60) and DAST (68) need the whole
# @description repo / a live host and stay CI-only.
# @description A change to a scanner's own action, config, baseline or workflow
# @description re-runs that scanner over its WHOLE CI scope, as CI then does.
# @description An untouched file is never scanned, so its pre-existing finding
# @description cannot block a push. A missing tool is a FAIL naming the fix:
# @description `./run -a do_install_lint_tools` (installs the CI-pinned versions).
# @param PRE_PUSH_LINT (optional) - 0 = skip every lint part (logged SKIP-disabled per
# @param        part): the one-variable rollback of this gate, never silent
# @param (all of do_check_pre_push's) - this action is do_check_pre_push restricted to the lint parts
# @example ./run -a do_check_pre_push_lint
# @example PRE_PUSH_MODE=full ./run -a do_check_pre_push_lint
#------------------------------------------------------------------------------

_PPL_FAST="lint-syntax lint-shellcheck lint-actionlint lint-hadolint lint-eslint lint-mdlinks lint-trufflehog"
_PPL_SLOW="lint-checkov lint-semgrep lint-gosec"

# The bash trees workflow 67 scans; a .sh elsewhere (the hub's) is not CI's.
_PPL_SC_DIRS="csi-spl-iac/src/bash csi-spl-iac/lib/bash csi-spl-orc/src/bash csi-spl-orc/lib/bash csi-spl-cnf/src/bash"

_ppl_under() {  # <file> <dirs...>
  local f="$1" d; shift
  for d in "$@"; do [[ "$f" == "$d"/* ]] && return 0; done
  return 1
}

# The files of <changed> one scanner looks at (root-relative, present in the
# tree), or the word ALL when the scanner's own definition changed.
_ppl_select() {  # <scanner> <changed> <tree>
  local sc="$1" changed="$2" tree="$3" f b
  local -a own=() sc_dirs
  read -r -a sc_dirs <<<"$_PPL_SC_DIRS"
  case "$sc" in
    lint-shellcheck) own=(csi-spl-iac/src/bash/run/sec-shellcheck.func.sh .github/workflows/67_shellcheck.yml) ;;
    lint-actionlint) own=(csi-spl-iac/src/bash/run/sec-actionlint.func.sh .github/actionlint.yaml .github/actionlint.yml) ;;
    lint-hadolint)   own=(csi-spl-iac/src/bash/run/sec-hadolint.func.sh .hadolint.yaml .github/workflows/66_hadolint.yml) ;;
    lint-eslint)     own=(csi-spl-iac/src/bash/run/sec-eslint.func.sh .eslint-security.config.mjs .eslint-security-baseline.txt .github/workflows/63_eslint-security.yml) ;;
    lint-checkov)    own=(csi-spl-iac/src/bash/run/sec-checkov.func.sh .github/workflows/65_iac-checkov.yml) ;;
  esac
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    for b in "${own[@]}"; do [[ "$f" == "$b" ]] && { echo ALL; return 0; }; done
  done <<<"$changed"
  while IFS= read -r f; do
    [[ -n "$f" && -f "$tree/$f" ]] || continue
    b="${f##*/}"
    case "$sc" in
      lint-syntax)
        if [[ "$f" == *.sh || "$f" == *.yml || "$f" == *.yaml || "$f" == *.json \
              || "$f" == csi-spl-orc/Makefile || "$f" == csi-spl-orc/*.mk ]]; then echo "$f"
        elif [[ "$b" != *.* ]] && head -1 "$tree/$f" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b'; then echo "$f"
        fi ;;
      lint-shellcheck) [[ "$f" == *.sh ]] && _ppl_under "$f" "${sc_dirs[@]}" && echo "$f" ;;
      lint-actionlint) [[ "$f" == .github/workflows/*.yml || "$f" == .github/workflows/*.yaml ]] && echo "$f" ;;
      lint-hadolint)   [[ "$b" == Dockerfile || "$b" == Dockerfile.* || "$b" == *.dockerfile ]] && echo "$f" ;;
      lint-eslint)     [[ "$f" == csi-spl-wui/src/* && ( "$f" == *.mjs || "$f" == *.js ) && "$f" != */node_modules/* ]] && echo "$f" ;;
      lint-mdlinks)    [[ "$f" == *.md ]] && echo "$f" ;;
      lint-trufflehog) echo "$f" ;;
      lint-checkov)    [[ "$f" == csi-spl-iac/src/terraform/* ]] && { echo ALL; return 0; } ;;
      lint-semgrep)    [[ "$f" == *.go || "$f" == csi-spl-wui/src/* ]] && { echo ALL; return 0; } ;;
      lint-gosec)      [[ "$f" == *.go || "$f" == */go.mod || "$f" == */go.sum ]] && { echo ALL; return 0; } ;;
    esac
  done <<<"$changed"
  return 0
}

# Plan the lint parts: sets _PPL_FILES[<scanner>] and _PPL_SELECTED (the
# scanners to run). Never call it in $(...): the subshell would drop both.
# FULL mode runs every scanner over its whole scope.
_ppl_plan() {  # <changed> <mode> <tier> <tree>
  local changed="$1" mode="$2" tier="$3" tree="$4" sc sel
  local scanners="$_PPL_FAST"
  _PPL_SELECTED=""
  if [[ "${PRE_PUSH_LINT:-1}" == 0 ]]; then
    do_log "WARN pre-push: PRE_PUSH_LINT=0 -- every lint part is SKIPPED (the CI scanners 61..67/85 still run after the push)"
    return 0
  fi
  [[ "$tier" == full ]] && scanners+=" $_PPL_SLOW"
  for sc in $scanners; do
    if [[ "$mode" == full ]]; then
      sel=ALL
      [[ "$sc" == lint-syntax || "$sc" == lint-trufflehog ]] && sel="$(git -C "$tree" ls-files 2>/dev/null)"
      [[ "$sc" == lint-syntax || "$sc" == lint-mdlinks ]] && sel="$(_ppl_select "$sc" "$(git -C "$tree" ls-files 2>/dev/null)" "$tree")"
    else
      sel="$(_ppl_select "$sc" "$changed" "$tree")"
      # a deleted / renamed path breaks the links that point AT it
      [[ "$sc" == lint-mdlinks ]] && sel="$(printf '%s\n%s\n' "$sel" "$(_ppl_md_referrers "$tree")" | sed '/^$/d' | sort -u)"
    fi
    [[ -n "$sel" ]] || continue
    _PPL_FILES[$sc]="$sel"
    _PPL_SELECTED+="${_PPL_SELECTED:+ }$sc"
  done
}

# The .md files that mention the basename of a path the push deletes/renames.
_ppl_md_referrers() {  # <tree>
  local tree="$1" base="${PRE_PUSH_BASE:-origin/master}" p
  git -C "$tree" diff --name-only --diff-filter=DR "$base"...HEAD 2>/dev/null | while IFS= read -r p; do
    [[ -n "$p" ]] && git -C "$tree" grep -l -F -- "${p##*/}" -- '*.md' 2>/dev/null
  done
  return 0
}

# The cache paths of a lint part: its files, or '.' for a whole-scope run.
_ppl_paths() {  # <scanner>
  local sel="${_PPL_FILES[$1]:-}"
  [[ "$sel" == ALL ]] && { echo .; return 0; }
  printf '%s\n' "$sel" | paste -sd' ' -
}

_ppl_missing() {  # <scanner>
  local fix="cd csi-spl-iac && ./run -a do_install_lint_tools"
  _ppl_need() { command -v "$1" >/dev/null 2>&1 || echo "$1 -- $fix"; }
  case "$1" in
    lint-syntax)     _ppl_need yq; _ppl_need jq; _ppl_need make ;;
    lint-shellcheck) _ppl_need shellcheck ;;
    lint-actionlint) _ppl_need actionlint; _ppl_need shellcheck ;;
    lint-hadolint)   _ppl_need hadolint ;;
    lint-eslint)
      [[ -x "$(_ppl_eslint_dir)/node_modules/.bin/eslint" ]] || echo "eslint -- $fix"
      _ppl_need python3 ;;
    lint-trufflehog) _ppl_need trufflehog; _ppl_need python3 ;;
    lint-mdlinks)    _ppl_need python3 ;;
    lint-checkov)    _ppl_need checkov ;;
    lint-semgrep)    _ppl_need semgrep ;;
    lint-gosec)      _ppl_need gosec ;;
  esac
}

# The repo scripts the lint parts run (md-rel-links.py), beside this file's tree.
_ppl_scripts() { (cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd); }

_ppl_eslint_dir() { printf '%s' "${SEC_ESLINT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/eslint}"; }

# The selected files that exist in <tree> (a baseline tree may lack new ones).
_ppl_present() {  # <tree> <scanner>
  local f
  while IFS= read -r f; do [[ -n "$f" && -f "$1/$f" ]] && echo "$f"; done <<<"${_PPL_FILES[$2]:-}"
}

# The exact command that reproduces one scanner's run, for a FAIL.
_ppl_repro() {  # <scanner>
  local sel="${_PPL_FILES[$1]:-}" var act files
  case "$1" in
    lint-shellcheck) var=SEC_SHELLCHECK_FILES act=do_sec_shellcheck ;;
    lint-actionlint) var=SEC_ACTIONLINT_FILES act=do_sec_actionlint ;;
    lint-hadolint)   var=SEC_HADOLINT_FILES act=do_sec_hadolint ;;
    lint-eslint)     var=SEC_ESLINT_FILES act=do_sec_eslint ;;
    lint-trufflehog) var=SEC_TRUFFLEHOG_FILES act=do_sec_trufflehog ;;
    lint-checkov)    act=do_sec_checkov ;; lint-semgrep) act=do_sec_semgrep ;; lint-gosec) act=do_sec_gosec ;;
    lint-mdlinks) echo "python3 csi-spl-iac/src/bash/scripts/md-rel-links.py $(printf '%s\n' "$sel" | paste -sd' ' -)"; return 0 ;;
    *) echo "cd csi-spl-iac && ./run -a do_check_pre_push_lint"; return 0 ;;
  esac
  if [[ -z "${var:-}" || "$sel" == ALL ]]; then echo "cd csi-spl-iac && ./run -a $act"; return 0; fi
  files="$(printf '%s\n' "$sel" | paste -sd' ' -)"
  echo "cd csi-spl-iac && $var=\"\$(printf '%s\\n' $files)\" ./run -a $act"
}

_ppl_files_env() {  # <tree> <scanner> -> the list for the action, or empty for ALL
  [[ "${_PPL_FILES[$2]:-}" == ALL ]] && return 0
  _ppl_present "$1" "$2"
}

# A lint part on <tree>: rc 0 clean, non-zero findings. On the base tree it
# scans only the selected files that exist there; none -> clean (so a finding
# in a NEW file is never mistaken for a pre-existing one).
_ppl_run_one() {  # <scanner> <tree>
  local sc="$1" tree="$2" files rc=0 f
  files="$(_ppl_files_env "$tree" "$sc")"
  if [[ "${_PPL_FILES[$sc]:-}" != ALL && -z "$files" ]]; then return 0; fi
  case "$sc" in
    lint-syntax)
      while IFS= read -r f; do
        case "$f" in
          csi-spl-orc/Makefile|csi-spl-orc/*.mk)
            make -C "$tree/csi-spl-orc" -n help >/dev/null || { echo "SYNTAX make -n: $f"; rc=1; } ;;
          *.sh)          bash -n "$tree/$f" || { echo "SYNTAX bash -n: $f"; rc=1; } ;;
          *.yml|*.yaml)  yq e '.' "$tree/$f" >/dev/null || { echo "SYNTAX yaml: $f"; rc=1; } ;;
          *.json)        jq empty "$tree/$f" || { echo "SYNTAX json: $f"; rc=1; } ;;
          *)             bash -n "$tree/$f" || { echo "SYNTAX bash -n: $f"; rc=1; } ;;
        esac
      done <<<"$files" ;;
    lint-shellcheck) SEC_SHELLCHECK_ROOT="$tree" SEC_SHELLCHECK_FILES="$files" do_sec_shellcheck || rc=$? ;;
    lint-actionlint) SEC_ACTIONLINT_ROOT="$tree" SEC_ACTIONLINT_FILES="$files" do_sec_actionlint || rc=$? ;;
    lint-hadolint)   SEC_HADOLINT_ROOT="$tree" SEC_HADOLINT_FILES="$files" do_sec_hadolint || rc=$? ;;
    lint-eslint)     SEC_ESLINT_DIR="$(_ppl_eslint_dir)" SEC_ESLINT_ROOT="$tree" SEC_ESLINT_FILES="$files" do_sec_eslint || rc=$? ;;
    lint-trufflehog) SEC_TRUFFLEHOG_ROOT="$tree" SEC_TRUFFLEHOG_FILES="$files" do_sec_trufflehog || rc=$? ;;
    lint-mdlinks)
      local -a mds=(); mapfile -t mds <<<"$files"
      ( cd "$tree" && python3 "$(_ppl_scripts)/md-rel-links.py" "${mds[@]}" ) || rc=$? ;;
    lint-checkov)    SEC_CHECKOV_ROOT="$tree" do_sec_checkov || rc=$? ;;
    lint-semgrep)    SEC_SEMGREP_ROOT="$tree" do_sec_semgrep || rc=$? ;;
    lint-gosec)      SEC_GOSEC_ROOT="$tree" do_sec_gosec || rc=$? ;;
  esac
  [[ "$rc" -eq 0 ]] && return 0
  # rc 127 stays 127 so the gate reports an environment gap, never "pre-existing".
  [[ "$rc" -eq 127 ]] && return 127
  if [[ "$tree" == "${_PP_TOP:-}" ]]; then
    do_log "ERROR pre-push: $sc found something -- reproduce it with: $(_ppl_repro "$sc")"
  fi
  return 1
}

# One function per lint part, the shape _pp_run calls: <fn> <tree>.
_pp_part_lint_syntax()     { _ppl_run_one lint-syntax "$1"; }
_pp_part_lint_shellcheck() { _ppl_run_one lint-shellcheck "$1"; }
_pp_part_lint_actionlint() { _ppl_run_one lint-actionlint "$1"; }
_pp_part_lint_hadolint()   { _ppl_run_one lint-hadolint "$1"; }
_pp_part_lint_eslint()     { _ppl_run_one lint-eslint "$1"; }
_pp_part_lint_trufflehog() { _ppl_run_one lint-trufflehog "$1"; }
_pp_part_lint_mdlinks()    { _ppl_run_one lint-mdlinks "$1"; }
_pp_part_lint_checkov()    { _ppl_run_one lint-checkov "$1"; }
_pp_part_lint_semgrep()    { _ppl_run_one lint-semgrep "$1"; }
_pp_part_lint_gosec()      { _ppl_run_one lint-gosec "$1"; }

# Spelling: WARN only (owner: no CI gate yet). typos-cli with the repo-root
# _typos.toml on the touched whole files, reporting only the lines the push
# ADDS, so old debt never shows. One verdict line; a missing typos is a WARN
# too, never a block.
_ppl_typos() {  # <changed> <tree>
  local changed="$1" tree="$2" f start="$SECONDS" out n added base mb
  base="${PRE_PUSH_BASE:-origin/master}"
  local -a files=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$tree/$f" ]] && files+=("$f")
  done <<<"$changed"
  [[ "${#files[@]}" -gt 0 ]] || { _pp_verdict lint-typos SKIP-untouched 0; return 0; }
  if ! command -v typos >/dev/null 2>&1; then
    _pp_verdict lint-typos WARN-missing-tool 0 "typos -- cd csi-spl-iac && ./run -a do_install_lint_tools"
    do_log "WARN pre-push: typos not installed, spelling check skipped (WARN only) -- cd csi-spl-iac && ./run -a do_install_lint_tools"
    return 0
  fi
  mb="$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null)"
  # <file>:<line> of every added line: committed + working tree vs the merge
  # base, and every line of an untracked file.
  added="$( { [[ -n "$mb" ]] && git -C "$tree" diff -U0 "$mb" -- "${files[@]}" 2>/dev/null | awk '
      /^\+\+\+ b\//{f=substr($0,7)} /^@@/{split($3,a,/[+,]/); s=a[2]; c=(a[3]==""?1:a[3]); for(i=0;i<c;i++) print f":"s+i}'
    git -C "$tree" ls-files --others --exclude-standard -- "${files[@]}" 2>/dev/null | while IFS= read -r f; do
      awk -v f="$f" '{print f":"NR}' "$tree/$f"; done; } )"
  out="$(cd "$tree" && typos --format brief --force-exclude -- "${files[@]}" 2>/dev/null \
    | awk -F: 'NR==FNR{ok[$1":"$2]=1; next} ($1":"$2) in ok' <(printf '%s\n' "$added") -)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  if [[ "$n" -gt 0 ]]; then
    _pp_verdict lint-typos WARN-typos "$((SECONDS - start))" "n=$n"
    do_log "WARN pre-push: $n possible typo(s) on lines this push adds (WARN only; fix, or add a real word to _typos.toml):"
    printf '%s\n' "$out" | sed 's/^/  /'
  else
    _pp_verdict lint-typos PASS "$((SECONDS - start))"
  fi
  _pp_record "typos (added lines, WARN only: $n)" "$([[ "$n" -gt 0 ]] && echo WARN || echo PASS)" "$((SECONDS - start))"
}

do_check_pre_push_lint() {
  PRE_PUSH_ONLY=lint do_check_pre_push
}
