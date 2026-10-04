#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the host spool CLI is built only when the tree has something newer
#          (spl_host_spool), and the merged cnf is read from a content-addressed
#          cache (do_spl_cloud_cnf) - the ~3.3 s every do_spl_desk_reply spent
#          before it sent (2026-09-25, prd, n=2-3 per stage).
#   1. no binary -> one build, stamped "<HEAD> clean"
#   2. same HEAD, clean module -> no build (CONTROL: the previous function
#      builds on EVERY call)
#   3. a modified module -> build; reverted -> build again (the stamp said dirty)
#   4. a newer commit -> build; 4b. newer commits that touch no build input
#      keep the binary (CONTROLS: a newer .version builds, a DIRTY build is
#      not kept)
#   5. an OLDER tree (a worktree at HEAD~1) -> REFUSED: the binary is kept, a
#      WARN says why; SPL_SPOOL_REBUILD=1 overrides
#   6. a commit the tree does not know -> refused
#   7. the real reader: main.commit out of a real Go binary's build info
#   8. cnf cache: the second call re-uses the SAME cache file; the values
#      equal a yq read per value; an edited SPL_CNF does not leak into the next
#      call; SPL_CNF_CACHE=0 merges afresh; parallel merges agree
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
g() { git -c user.name=t -c user.email=t@example.com -C "$@"; }

# A throwaway tree shaped like the app: <app>/csi-spl-api/{src/bash/build.sh,
# src/go/spool-hub-api/}. The stub build.sh counts its runs and writes a
# "binary" carrying the tree's HEAD, which the stubbed reader returns.
A="$T/app"
mkdir -p "$A/csi-spl-api/src/bash" "$A/csi-spl-api/src/go/spool-hub-api" "$A/csi-spl-orc"
cat >"$A/csi-spl-api/src/bash/build.sh" <<'EOS'
#!/usr/bin/env bash
echo build >>"$T_BUILDS"
h="$(git -C "$(dirname "$0")" rev-parse HEAD)"
printf '#!/bin/sh\n# commit=%s\necho stub\n' "$h" >"$1" && chmod +x "$1"
EOS
echo 'package main' >"$A/csi-spl-api/src/go/spool-hub-api/main.go"
echo 0.0.1 >"$A/.version"
echo notes >"$A/README.md"
g "$A" init -q && g "$A" add -A && g "$A" commit -qm one
S="$T/state"
: >"$T/builds"

# Runs FUNC in a shell with the orc funcs sourced, APP_PATH=$A unless given.
in_orc() {
  env PROJ_PATH="$A/csi-spl-orc" APP_PATH="${APP:-$A}" SPL_ORG_APP=csi-spl SPL_STATE_DIR="$S" \
    T_BUILDS="$T/builds" ORC_LIB="$PROJ_ROOT/lib/bash/funcs" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$ORC_LIB/spl-cloud-cnf.func.sh"
    spl_host_spool_bin_rev() { local c; c="$(sed -n "s/^# commit=//p" "$1" 2>/dev/null)"; [[ -n "$c" ]] && echo "$c unknown"; }
    '"$1"
}
builds() { wc -l <"$T/builds" | tr -d ' '; }
H1="$(git -C "$A" rev-parse HEAD)"

# --- 1. first call builds ------------------------------------------------------
out="$(in_orc 'spl_host_spool && echo "SPOOL=$SPL_SPOOL"')"
eq "1 no binary: one build" 1 "$(builds)"
eq "1 SPL_SPOOL is the state-dir binary" "SPOOL=$S/bin/spool" "$(grep '^SPOOL=' <<<"$out")"
eq "1 the stamp names HEAD and a clean module" "$H1 clean" "$(cat "$S/bin/spool.src")"
ls "$S/bin" | grep '\.build\.' >/dev/null && fail "1 a build tmp was left behind" || pass "1 no build tmp left behind"

# --- 2. unchanged tree: no build; the old function builds every time ----------
in_orc 'spl_host_spool; spl_host_spool; spl_host_spool' >/dev/null
eq "2 three more calls on the same HEAD build NOTHING" 1 "$(builds)"
eq "2 the verdict says keep" "keep" "$(in_orc 'v="$(spl_host_spool_verdict "$SPL_STATE_DIR/bin/spool")"; echo "${v%% *}"')"
old_host_spool='spl_host_spool_old() {
  local build="$APP_PATH/$SPL_ORG_APP-api/src/bash/build.sh"
  SPL_SPOOL="$SPL_STATE_DIR/bin/spool"
  mkdir -p "$SPL_STATE_DIR/bin" && bash "$build" "$SPL_SPOOL" >/dev/null || return 1
}'
in_orc "$old_host_spool"'; spl_host_spool_old; spl_host_spool_old' >/dev/null
eq "2 CONTROL the previous spl_host_spool builds on EVERY call (2 more)" 3 "$(builds)"
in_orc 'spl_host_spool' >/dev/null
eq "2 …and the new one, after it, still builds nothing" 3 "$(builds)"

# --- 3. a modified module builds, and so does reverting it --------------------
echo '// local edit' >>"$A/csi-spl-api/src/go/spool-hub-api/main.go"
in_orc 'spl_host_spool' >/dev/null
eq "3 a modified module builds" 4 "$(builds)"
eq "3 …and stamps it dirty" "$H1 dirty" "$(cat "$S/bin/spool.src")"
in_orc 'spl_host_spool' >/dev/null
eq "3 …and builds again while still modified" 5 "$(builds)"
g "$A" checkout -q -- csi-spl-api/src/go/spool-hub-api/main.go
in_orc 'spl_host_spool' >/dev/null
eq "3 reverted: a DIRTY build is not reused for a clean tree" 6 "$(builds)"
in_orc 'spl_host_spool' >/dev/null
eq "3 …then it is current again" 6 "$(builds)"
echo more >>"$A/README.md"
in_orc 'spl_host_spool' >/dev/null
eq "3 a change OUTSIDE the module does not build" 6 "$(builds)"
g "$A" checkout -q -- README.md

# --- 4. a newer commit builds ----------------------------------------------------
echo '// two' >>"$A/csi-spl-api/src/go/spool-hub-api/main.go"
g "$A" commit -qam two
H2="$(git -C "$A" rev-parse HEAD)"
in_orc 'spl_host_spool' >/dev/null
eq "4 a newer HEAD builds" 7 "$(builds)"
eq "4 …stamped with it" "$H2 clean" "$(cat "$S/bin/spool.src")"

# --- 4b. newer commits OUTSIDE the build inputs keep the binary (CLE-35076) -------
echo docs >>"$A/README.md"
g "$A" commit -qam docs
before="$(md5sum <"$S/bin/spool")"
in_orc 'spl_host_spool; spl_host_spool' >/dev/null
eq "4b a newer commit outside the module builds NOTHING" 7 "$(builds)"
eq "4b …the binary is untouched" "$before" "$(md5sum <"$S/bin/spool")"
v="$(in_orc 'spl_host_spool_verdict "$SPL_STATE_DIR/bin/spool"')"
grep -q "^keep built from ${H2:0:12}: no build input changed" <<<"$v" && pass "4b …and the verdict says why" || fail "4b verdict: $v"
echo 0.0.2 >"$A/.version"
g "$A" commit -qam version
in_orc 'spl_host_spool' >/dev/null
eq "4b CONTROL a newer .version (a build input) builds" 8 "$(builds)"
H2="$(git -C "$A" rev-parse HEAD)"
echo docs2 >>"$A/README.md"
g "$A" commit -qam docs2
printf '%s dirty\n' "$H2" >"$S/bin/spool.src"
in_orc 'spl_host_spool' >/dev/null
eq "4b CONTROL a binary built DIRTY is not kept across a newer commit" 9 "$(builds)"
H2="$(git -C "$A" rev-parse HEAD)"
g "$A" worktree add -q "$T/old" "$H1" 2>/dev/null

# --- 5. an older tree is refused -------------------------------------------------
before="$(md5sum <"$S/bin/spool")"
out="$(APP="$T/old" in_orc 'spl_host_spool && echo "rc=0 SPOOL=$SPL_SPOOL"')"
eq "5 an OLDER tree builds nothing" 9 "$(builds)"
eq "5 …the binary is untouched" "$before" "$(md5sum <"$S/bin/spool")"
grep -q '^WARN keeping .*NEWER than this tree' <<<"$out" && pass "5 …and a WARN says why" || fail "5 no WARN: $out"
grep -q "^rc=0 SPOOL=$S/bin/spool" <<<"$out" && pass "5 …while the caller still gets the (newer) binary" || fail "5 caller: $out"
APP="$T/old" SPL_SPOOL_REBUILD=1 in_orc 'spl_host_spool' >/dev/null
eq "5 SPL_SPOOL_REBUILD=1 overrides the refusal" 10 "$(builds)"
eq "5 …and the stamp says so" "$H1 clean" "$(cat "$S/bin/spool.src")"

# --- 6. an unknown commit is refused ---------------------------------------------
printf '#!/bin/sh\n# commit=%s\n' 0123456789abcdef0123456789abcdef01234567 >"$S/bin/spool"
out="$(in_orc 'spl_host_spool')"
eq "6 a binary from an unknown commit is not replaced" 10 "$(builds)"
grep -q 'does not know' <<<"$out" && pass "6 …and the WARN names it" || fail "6 no WARN: $out"

# --- 7. the real reader, on a real Go binary -------------------------------------
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || true
GO="$(command -v go || true)"
if [[ -n "$GO" ]]; then
  mkdir -p "$T/gobin"
  printf 'module x\n\ngo 1.21\n' >"$T/gobin/go.mod"
  printf 'package main\n\nvar commit = "unknown"\n\nfunc main() { println(commit) }\n' >"$T/gobin/main.go"
  want=89abcdef0123456789abcdef0123456789abcdef
  ( cd "$T/gobin" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local GOCACHE="$T/gocache" \
      "$GO" build -buildvcs=false -ldflags "-X main.version=1 -X main.commit=$want -X main.builtAt=now" -o "$T/gobin/x" . )
  got="$(PATH="$(dirname "$GO"):$PATH" bash -c 'source "$1"; spl_host_spool_bin_rev "$2"' _ "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh" "$T/gobin/x")"
  eq "7 main.commit is read out of a real Go binary" "$want unknown" "$got"
else
  echo "SKIP: 7 no go toolchain"
fi

# --- 8. the merged cnf is cached -------------------------------------------------
cnf_run() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/cnfstate" ENV=dev "$@" bash -c '
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf || exit 1
    c="$(ls "$SPL_STATE_DIR"/cnf/dev.*.env.yaml)"
    echo "$SPL_CNF|$c $(stat -c %i "$c")"
    echo "$SPL_PROJECT|$SPL_REGION|$SPL_FQDN|$SPL_IMAGE_REF|$SPL_IMAGE_SQL_SRC|$SPL_MIGRATIONS_DIR|$SPL_SQL_INSTANCE|$SPL_DB_NAME|$SPL_DB_USER|$SPL_DSN_SECRET|$SPL_DB_OWNER_USER|$SPL_OWNER_DSN_SECRET|$SPL_SQL_PROXY_IMAGE"
    g() { yq -r "$1 // \"\"" "$SPL_CNF"; }
    echo "$(g .env.gcp.gcp_project)|$(g .env.gcp.gcp_region)|$(g .env.dns.fqdn)|$(g .env.hub.image.ref)|$APP_PATH/$(g .env.hub.image.sql_src)|$(g .env.hub.env.SPOOL_HUB_MIGRATIONS_DIR)|$(g ".env.steps.\"040-cloud-sql-postgres\".instance_name")|$(g ".env.steps.\"040-cloud-sql-postgres\".database_name")|$(g .env.hub.db_user)|$(g .env.hub.secret_env.SPOOL_HUB_DB_DSN)|$(g .env.hub.db_owner_user)|$(g .env.hub.db_owner_dsn_secret)|$(g .env.hub.cloud_sql_proxy_image)"
    [[ -n "${MUTATE:-}" ]] && yq -i ".env.gcp.gcp_region = \"$MUTATE\"" "$SPL_CNF"
    true'
}
r1="$(cnf_run)"; r2="$(cnf_run)"
l1="$(sed -n 1p <<<"$r1")"
[[ "$l1" =~ ^$T/cnfstate/dev\.env\.yaml\|$T/cnfstate/cnf/dev\.[0-9a-f]{16}\.env\.yaml\ [0-9]+$ ]] &&
  pass "8 SPL_CNF keeps its path; the cache is content-addressed" || fail "8 paths: $l1"
eq "8 the second call re-uses the SAME cache file (same inode)" "$l1" "$(sed -n 1p <<<"$r2")"
eq "8 the one-yq values equal a yq read per value" "$(sed -n 3p <<<"$r1")" "$(sed -n 2p <<<"$r1")"
[[ "$(sed -n 2p <<<"$r1")" == csi-spl-dev\|* ]] && pass "8 …and they are real values" || fail "8 values: $(sed -n 2p <<<"$r1")"
cnf_run MUTATE=mutated-region >/dev/null
[[ "$(sed -n 2p <<<"$(cnf_run)")" == "$(sed -n 2p <<<"$r1")" ]] &&
  pass "8 an action that EDITS its SPL_CNF does not poison the next one" || fail "8 the cache was poisoned"
r3="$(cnf_run SPL_CNF_CACHE=0)"
[[ "$(sed -n 1p <<<"$r3")" != "$l1" ]] && pass "8 SPL_CNF_CACHE=0 merges afresh (new inode)" || fail "8 SPL_CNF_CACHE=0 re-used the cache"
for i in 1 2 3 4 5 6; do cnf_run SPL_CNF_CACHE=0 >"$T/par.$i" 2>&1 & done; wait
ok=1; for i in 1 2 3 4 5 6; do [[ "$(sed -n 2p "$T/par.$i")" == "$(sed -n 2p <<<"$r1")" && "$(sed -n 3p "$T/par.$i")" == "$(sed -n 2p <<<"$r1")" ]] || ok=0; done
eq "8 six PARALLEL fresh merges all read whole, equal values" 1 "$ok"
ls "$T/cnfstate" "$T/cnfstate/cnf" | grep '\.tmp\.' >/dev/null && fail "8 a tmp was left behind" || pass "8 no tmp left behind"

echo "--- $fails failure(s)"
[[ "$fails" -eq 0 ]]
