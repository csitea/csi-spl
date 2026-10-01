#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The LINT parts of do_check_pre_push (owner 2026-10-01: "why
# @description cannot they be ran via shell actions locally before someone
# @description pushes?!"). Each GitHub scanner workflow runs here first, on the
# @description files the push TOUCHES, through the SAME named action, binary
# @description version, config, severity and baseline as CI -- so a local PASS
# @description is a CI PASS for those files:
# @description   lint-syntax      bash -n (.sh + extension-less #!..sh scripts), YAML/JSON/
# @description                    TOML parse + DUPLICATE keys (config-syntax-check.py; yq/jq
# @description                    keep the last of two equal keys silently), make -n (orc)
# @description   lint-migration   a migration already on the base is never edited, renamed
# @description                    or deleted (migrate.go refuses a changed sha256 at deploy;
# @description                    SPL_MIGRATION_EDIT_OK=<file> allows one, logged), and new
# @description                    ones parse with the PG16 grammar (pglast 6.x)
# @description   lint-compose     docker compose config -q --no-interpolate (schema)
# @description   lint-gitleaks    15's gitleaks + .gitleaks.toml over the PUSHED commits only
# @description   lint-py          touched .py: compile + ruff E9,F + a security subset
# @description                    (S102 S113 S301 S307 S506 S602 S604 S605); python
# @description                    heredocs in touched .sh/.yml compile (py-heredoc-check.py)
# @description   lint-wui-syntax  per-file Vue SFC compile (script + TEMPLATE) and TS/JS
# @description                    parse (wui-syntax-check.mjs): the template-error class
# @description                    that typecheck + nuxt generate pass (blanked dev+prd
# @description                    2026-09-30); seconds, before the wui part's minutes
# @description   lint-wui-lock    pnpm install --frozen-lockfile --lockfile-only: a
# @description                    package.json edit without its lock fails every CI install
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

_PPL_FAST="lint-syntax lint-migration lint-compose lint-shellcheck lint-actionlint lint-hadolint lint-eslint lint-mdlinks lint-py lint-trufflehog lint-gitleaks lint-wui-syntax lint-wui-lock"
_PPL_SLOW="lint-checkov lint-semgrep lint-gosec"

# ruff: syntax + pyflakes + the security codes with a zero baseline. Never
# ruff's default set (0.16 widened it: 150 style findings).
_PPL_RUFF_RULES="E9,F,S102,S113,S301,S307,S506,S602,S604,S605"

# The hub migrations (forward-only; roles/*.sql carry psql variables, hub-pg's).
_PPL_MIG_DIR="csi-spl-rdb/src/sql/postgres/spool-hub"

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
  if [[ "$sc" == lint-migration ]]; then
    # an edited, renamed or deleted migration counts even when it is gone
    while IFS= read -r f; do
      [[ "$f" == "$_PPL_MIG_DIR"/*.sql ]] && echo "$f"
    done <<<"$changed"
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" && -f "$tree/$f" ]] || continue
    b="${f##*/}"
    case "$sc" in
      lint-syntax)
        if [[ "$f" == *.sh || "$f" == *.yml || "$f" == *.yaml || "$f" == *.json || "$f" == *.toml \
              || "$f" == csi-spl-orc/Makefile || "$f" == csi-spl-orc/*.mk ]]; then echo "$f"
        elif [[ "$b" != *.* ]] && head -1 "$tree/$f" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b'; then echo "$f"
        fi ;;
      lint-shellcheck) [[ "$f" == *.sh ]] && _ppl_under "$f" "${sc_dirs[@]}" && echo "$f" ;;
      lint-actionlint) [[ "$f" == .github/workflows/*.yml || "$f" == .github/workflows/*.yaml ]] && echo "$f" ;;
      lint-hadolint)   [[ "$b" == Dockerfile || "$b" == Dockerfile.* || "$b" == *.dockerfile ]] && echo "$f" ;;
      lint-eslint)     [[ "$f" == csi-spl-wui/src/* && ( "$f" == *.mjs || "$f" == *.js ) && "$f" != */node_modules/* ]] && echo "$f" ;;
      lint-mdlinks)    [[ "$f" == *.md ]] && echo "$f" ;;
      lint-migration)  [[ "$f" == "$_PPL_MIG_DIR"/*.sql ]] && echo "$f" ;;
      lint-compose)    [[ "$b" == docker-compose*.yml || "$b" == docker-compose*.yaml ]] && echo "$f" ;;
      lint-gitleaks)   echo ALL; return 0 ;;
      lint-py)
        if [[ "$f" == *.py ]]; then echo "$f"
        elif [[ "$f" == *.sh || "$f" == *.yml || "$f" == *.yaml ]] && grep -q python "$tree/$f" 2>/dev/null; then echo "$f"
        fi ;;
      lint-wui-syntax)
        [[ "$f" == csi-spl-wui/* && "$f" =~ \.(vue|ts|tsx|mjs|js)$ && "$f" != */node_modules/* \
           && "$f" != csi-spl-wui/.nuxt/* && "$f" != csi-spl-wui/.output/* && "$f" != csi-spl-wui/dist/* ]] && echo "$f" ;;
      lint-wui-lock)   [[ "$f" == csi-spl-wui/package.json || "$f" == csi-spl-wui/pnpm-lock.yaml ]] && { echo ALL; return 0; } ;;
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
      case "$sc" in
        lint-syntax|lint-mdlinks|lint-compose|lint-wui-syntax|lint-py) sel="$(_ppl_select "$sc" "$(git -C "$tree" ls-files 2>/dev/null)" "$tree")" ;;
        lint-migration) sel="" ;;   # nothing is "edited" in a whole-tree run
      esac
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
    lint-syntax)
      _ppl_need make
      python3 -c 'import yaml, tomllib' 2>/dev/null || echo "python3 PyYAML + tomllib (3.11+) -- apt-get install python3-yaml" ;;
    lint-migration)  [[ -x "$(_ppl_pglast_py)" ]] || echo "pglast -- $fix" ;;
    lint-compose)    docker compose version >/dev/null 2>&1 || echo "docker compose -- install docker with the compose plugin" ;;
    lint-gitleaks)   _ppl_need gitleaks ;;
    lint-py)         _ppl_need python3; _ppl_need ruff ;;
    lint-wui-syntax|lint-wui-lock)
      _ppl_need node
      _pp_pnpm >/dev/null || echo "pnpm -- corepack enable pnpm, or install it into ~/.local/bin" ;;
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

_ppl_pglast_py() { printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/lint-venv-pglast/bin/python"; }

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
    lint-gitleaks) echo "cd csi-spl-iac && SEC_SCAN=secrets SEC_SCAN_GITLEAKS_LOG_OPTS='$(git -C "${_PP_TOP:-.}" merge-base "${PRE_PUSH_BASE:-origin/master}" HEAD 2>/dev/null)..HEAD' ./run -a do_sec_scan"; return 0 ;;
    lint-wui-syntax) echo "cd csi-spl-wui && node ../csi-spl-iac/src/bash/scripts/wui-syntax-check.mjs $(printf '%s\n' "$sel" | sed 's|^csi-spl-wui/||' | paste -sd' ' -)"; return 0 ;;
    lint-py) echo "ruff check --isolated --select $_PPL_RUFF_RULES $(printf '%s\n' "$sel" | grep '\.py$' | paste -sd' ' -); python3 csi-spl-iac/src/bash/scripts/py-heredoc-check.py $(printf '%s\n' "$sel" | grep -v '\.py$' | paste -sd' ' -)"; return 0 ;;
    lint-wui-lock) echo "cd csi-spl-wui && pnpm install --frozen-lockfile --lockfile-only --ignore-scripts"; return 0 ;;
    lint-migration|lint-compose|lint-syntax) echo "cd csi-spl-iac && ./run -a do_check_pre_push_lint"; return 0 ;;
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
  if [[ "${_PPL_FILES[$sc]:-}" != ALL && -z "$files" && "$sc" != lint-migration ]]; then return 0; fi
  case "$sc" in
    lint-syntax)
      local -a cfgs=()
      while IFS= read -r f; do
        case "$f" in
          csi-spl-orc/Makefile|csi-spl-orc/*.mk)
            make -C "$tree/csi-spl-orc" -n help >/dev/null || { echo "SYNTAX make -n: $f"; rc=1; } ;;
          *.sh)          bash -n "$tree/$f" || { echo "SYNTAX bash -n: $f"; rc=1; } ;;
          *.yml|*.yaml|*.json|*.toml) cfgs+=("$f") ;;
          *)             bash -n "$tree/$f" || { echo "SYNTAX bash -n: $f"; rc=1; } ;;
        esac
      done <<<"$files"
      if [[ "${#cfgs[@]}" -gt 0 ]]; then
        ( cd "$tree" && python3 "$(_ppl_scripts)/config-syntax-check.py" "${cfgs[@]}" ) || rc=1
      fi ;;
    lint-migration)  _ppl_migration "$tree" || rc=$? ;;
    lint-compose)
      while IFS= read -r f; do
        ( cd "$tree/$(dirname "$f")" && docker compose -f "${f##*/}" config -q --no-interpolate ) \
          || { echo "COMPOSE schema: $f"; rc=1; }
      done <<<"$files" ;;
    lint-py)
      local -a pys=() hds=()
      while IFS= read -r f; do
        if [[ "$f" == *.py ]]; then pys+=("$f"); else hds+=("$f"); fi
      done <<<"$files"
      if [[ "${#pys[@]}" -gt 0 ]]; then
        ( cd "$tree" && python3 -c '
import sys
bad = 0
for f in sys.argv[1:]:
    try:
        compile(open(f, encoding="utf-8").read(), f, "exec")
    except SyntaxError as e:
        bad += 1
        print("%s:%s: %s" % (f, e.lineno, e.msg))
sys.exit(1 if bad else 0)' "${pys[@]}" ) || rc=1
        ( cd "$tree" && ruff check --no-cache --isolated --target-version py310 --output-format concise \
            --select "$_PPL_RUFF_RULES" "${pys[@]}" ) || rc=1
      fi
      if [[ "${#hds[@]}" -gt 0 ]]; then
        ( cd "$tree" && python3 "$(_ppl_scripts)/py-heredoc-check.py" "${hds[@]}" ) || rc=1
      fi ;;
    lint-wui-syntax)
      local -a wf=(); while IFS= read -r f; do wf+=("$tree/$f"); done <<<"$files"
      _ppl_wui_modules || return 1
      ( cd "${_PP_TOP:-$tree}/csi-spl-wui" && node "$(_ppl_scripts)/wui-syntax-check.mjs" "${wf[@]}" ) || rc=1 ;;
    lint-wui-lock)
      ( cd "$tree/csi-spl-wui" && "$(_pp_pnpm)" install --frozen-lockfile --lockfile-only --ignore-scripts --reporter=silent ) \
        || { echo "LOCKFILE csi-spl-wui/pnpm-lock.yaml does not match package.json -- run pnpm install and commit the lock"; rc=1; } ;;
    lint-gitleaks)
      local gbase; gbase="$(git -C "$tree" merge-base "${PRE_PUSH_BASE:-origin/master}" HEAD 2>/dev/null)"
      if [[ -n "$gbase" && "$gbase" != "$(git -C "$tree" rev-parse HEAD)" ]]; then
        SEC_SCAN_ROOT="$tree" SEC_SCAN_GITLEAKS_LOG_OPTS="$gbase..HEAD" _sec_scan_secrets || rc=$?
      fi ;;
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

# The SFC check resolves typescript + vue from the pushing tree's WUI
# node_modules; a fresh worktree has none, so install them (the wui part
# would install them anyway, a few lines later).
_ppl_wui_modules() {
  local wui="${_PP_TOP:-.}/csi-spl-wui" pn
  [[ -d "$wui/node_modules/typescript" && -d "$wui/node_modules/vue" ]] && return 0
  pn="$(_pp_pnpm)" || { echo "pnpm not found"; return 127; }
  echo "pre-push: WUI node_modules absent -- pnpm install --frozen-lockfile (once per worktree)"
  ( cd "$wui" && export PATH="$HOME/.local/bin:$PATH" && "$pn" install --frozen-lockfile --reporter=silent )
}

# Forward-only + PG16 parse. On the BASE tree there is no edit to refuse and
# a new file is absent, so it passes there: a finding is always "new".
_ppl_migration() {  # <tree>
  local tree="$1" base="${PRE_PUSH_BASE:-origin/master}" f rc=0 ok="${SPL_MIGRATION_EDIT_OK:-}"
  [[ "$tree" == "${_PP_TOP:-}" ]] || return 0
  local -a parse=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if git -C "$tree" cat-file -e "$base:$f" 2>/dev/null; then
      if [[ -f "$tree/$f" ]] && git -C "$tree" diff --quiet "$base" -- "$f" 2>/dev/null; then continue; fi
      if [[ -n "$ok" && " $ok " == *" $f "* ]]; then
        do_log "WARN pre-push: SPL_MIGRATION_EDIT_OK -- the edit of $f (already on $base) is ALLOWED by the pusher"
        [[ -f "$tree/$f" ]] && parse+=("$f")
        continue
      fi
      echo "MIGRATION $f is already on $base and was edited, renamed or deleted -- add a NEW NNNN file instead (migrate.go refuses a changed sha256 at deploy)"
      rc=1
    elif [[ -f "$tree/$f" && "$f" != */spool-hub-roles/* ]]; then
      parse+=("$f")
    fi
  done <<<"${_PPL_FILES[lint-migration]:-}"
  if [[ "${#parse[@]}" -gt 0 ]]; then
    ( cd "$tree" && "$(_ppl_pglast_py)" -c '
import sys, pglast
bad = 0
for f in sys.argv[1:]:
    try:
        pglast.parse_sql(open(f, encoding="utf-8").read())
    except Exception as exc:
        bad += 1
        print("MIGRATION %s: PG16 parse: %s" % (f, " ".join(str(exc).split())))
sys.exit(1 if bad else 0)' "${parse[@]}" ) || rc=1
  fi
  return "$rc"
}

# One function per lint part, the shape _pp_run calls: <fn> <tree>.
_pp_part_lint_syntax()     { _ppl_run_one lint-syntax "$1"; }
_pp_part_lint_shellcheck() { _ppl_run_one lint-shellcheck "$1"; }
_pp_part_lint_actionlint() { _ppl_run_one lint-actionlint "$1"; }
_pp_part_lint_hadolint()   { _ppl_run_one lint-hadolint "$1"; }
_pp_part_lint_eslint()     { _ppl_run_one lint-eslint "$1"; }
_pp_part_lint_trufflehog() { _ppl_run_one lint-trufflehog "$1"; }
_pp_part_lint_mdlinks()    { _ppl_run_one lint-mdlinks "$1"; }
_pp_part_lint_migration()  { _ppl_run_one lint-migration "$1"; }
_pp_part_lint_compose()    { _ppl_run_one lint-compose "$1"; }
_pp_part_lint_gitleaks()   { _ppl_run_one lint-gitleaks "$1"; }
_pp_part_lint_py()         { _ppl_run_one lint-py "$1"; }
_pp_part_lint_wui_syntax() { _ppl_run_one lint-wui-syntax "$1"; }
_pp_part_lint_wui_lock()   { _ppl_run_one lint-wui-lock "$1"; }
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
