#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the spool domain has ONE source, env.dns.BASE_DOMAIN in
#          csi-spl-cnf/csi-spl/all.env.yaml. Outside csi-spl-cnf/ (config and
#          its generated renders) and csi-spl-doc/ (docs explaining the config)
#          no tracked file may contain it.
#
#          The domain is READ from the config, never written here, and the
#          search is for its label without the TLD, so an escaped regex form
#          (label\.tld) or a split string is caught as well.
#
#          The files are git's (git ls-files), not the working tree's: a
#          gitignored build (csi-spl-wui/.output carries the domain in every
#          prerendered page) is not a tracked file and made a false red, 40
#          hits in a checkout that had run the WUI generate.
#
#          CONTROLS: a guard that finds nothing proves nothing unless it is
#          shown to find something. Control 1 plants the literal in a
#          disallowed path of a scratch repo and requires exactly that hit,
#          and not the same literal in an ignored or untracked file;
#          control 2 requires an empty BASE_DOMAIN to FAIL rather than pass
#          with an empty pattern; control 3 requires a root that is not a git
#          work tree to FAIL rather than pass with no files.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# domain_violations <root> <all.env.yaml> -> prints offending tracked files;
# rc 2 if no domain, rc 3 if <root> is not a git work tree
domain_violations() {
  local root="$1" cnf="$2" domain label label_re tld tld_re
  domain=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$cnf" 2>/dev/null)
  [[ -n "$domain" && "$domain" != null && "$domain" == *.* ]] || return 2
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 3
  label="${domain%.*}" tld="${domain##*.}"
  # Match the label only where the TLD follows it: the literal (label.tld), an
  # escaped regex form (label\.tld) or a split string ("label" + ".tld"). A
  # path segment or identifier that merely IS the label (a "<label>/" SQL dir,
  # a "<label>-api" module) is not the domain and is not a hit. (-E, not -F.)
  label_re=$(printf '%s' "$label" | sed 's/[.\\]/\\&/g')
  tld_re=$(printf '%s' "$tld" | sed 's/[.\\]/\\&/g')
  # A tracked file deleted in the work tree is not readable: grep skips it.
  git -C "$root" ls-files -z |
    grep -zvE '(^|/)(tpl-gen|bin|log)/' |
    (cd "$root" && xargs -0 -r grep -IlE -- "${label_re}[\"' +\\]*\.${tld_re}([^A-Za-z0-9-]|$)" 2>/dev/null) |
    grep -vE '^(csi-spl-cnf|csi-spl-doc)/' || true
}

CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"

# --- the real tree ------------------------------------------------------------
[[ -f "$CNF" ]] || { echo "FAIL: missing $CNF"; exit 1; }
hits=$(domain_violations "$APP_ROOT" "$CNF"); rc=$?
if [[ $rc -ne 0 ]]; then fail "could not read env.dns.BASE_DOMAIN from $CNF (rc=$rc)"
elif [[ -z "$hits" ]]; then pass "the domain appears only under csi-spl-cnf/ and csi-spl-doc/"
else fail "the domain literal appears outside csi-spl-cnf/ and csi-spl-doc/:"; printf '      %s\n' $hits; fi

# --- control 1: a planted literal in a disallowed path is found ---------------
tmp=$(mktemp -d)
mkdir -p "$tmp/csi-spl-cnf/csi-spl" "$tmp/csi-spl-doc" "$tmp/csi-spl-iac/src" "$tmp/tpl-gen"
cp "$CNF" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml"
d=$(yq -r '.env.dns.BASE_DOMAIN' "$CNF")
printf 'allowed %s\n' "$d" >"$tmp/csi-spl-doc/ok.md"
printf 'ignored %s\n' "$d" >"$tmp/tpl-gen/ignored.txt"
printf 'host="%s"\n' "${d//./\\.}" >"$tmp/csi-spl-iac/src/planted.sh"
printf 'sql=csi-spl-rdb/src/sql/postgres/%s/\npath=filepath.Join("x", "%s")\n' "${d%.*}" "${d%.*}" >"$tmp/csi-spl-iac/src/path-segment.go"
printf 'host := "%s" + ".%s"\n' "${d%.*}" "${d##*.}" >"$tmp/csi-spl-iac/src/split.go"
git -C "$tmp" init -q && git -C "$tmp" add -A
mkdir -p "$tmp/csi-spl-wui/.output/public"
printf '.output/\n' >"$tmp/csi-spl-wui/.gitignore"
printf '<a href="https://%s/">\n' "$d" >"$tmp/csi-spl-wui/.output/public/index.html"
printf 'host="%s"\n' "$d" >"$tmp/csi-spl-iac/src/untracked.sh"
hits=$(domain_violations "$tmp" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml")
[[ "$(sort <<<"$hits" | tr '\n' ' ')" == "csi-spl-iac/src/planted.sh csi-spl-iac/src/split.go " ]] && pass "control: planted escaped + split literals in csi-spl-iac are caught; a <label>/ path segment, allowed dirs, an ignored build and an untracked file are not" \
  || fail "control: expected exactly planted.sh + split.go, got: ${hits:-<nothing>}"

# --- control 2: an empty domain fails instead of matching nothing -------------
printf 'env:\n  dns:\n    BASE_DOMAIN: ""\n' >"$tmp/csi-spl-cnf/csi-spl/all.env.yaml"
domain_violations "$tmp" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml" >/dev/null; rc=$?
[[ $rc -eq 2 ]] && pass "control: an empty BASE_DOMAIN is an error, not a vacuous pass" || fail "control: empty BASE_DOMAIN returned rc=$rc"

# --- control 3: a root outside git fails instead of listing no files ----------
cp "$CNF" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml"
rm -rf "$tmp/.git"
domain_violations "$tmp" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml" >/dev/null; rc=$?
if [[ $rc -eq 3 ]]; then pass "control: a root that is not a git work tree is an error, not a vacuous pass"
else fail "control: a non-git root returned rc=$rc"; fi
rm -rf "$tmp"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
