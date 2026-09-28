#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: install.sh (specs/037), hermetic. A throwaway HOME; the network is a
#          `curl` stub that serves fixture installers, a Go tarball and a yq;
#          the spool build and the seat action are stubs. PATH holds no go and
#          no yq, so both download branches run.
#   1. refusals: a bad --cli, a seat with no SPOOL_HUB_URL or no tenant
#   2. --dry-run downloads and writes nothing
#   3. a full install: the three vendor installers, grok into <prefix>/bin,
#      yq + Go into tools, spool built, the shim, the config
#   4. the shim runs spool-agent.sh with the configured env/tenant/box, and
#      an option given on its command line wins
#   5. the hooks: merged into ~/.claude/settings.json, other keys kept, an
#      older spool-mirror entry replaced (one per event), a backup, idempotent
#   6. the seat: pinned -> seated; pending -> exit 0 and the one hub-pin line;
#      a failure -> exit 5; the action gets ENV/TENANT/BOX/HUB/ROOT_KEY_JSON;
#      a bare re-run uses the saved config, an option / the env win over it
#   7. a re-run: agy present -> `agy update`, no installer fetched; the
#      toolchain found in tools is not downloaded again
#   7b. --update: one pull, then the pulled installer runs (no loop)
#   8. a foreign ~/.local/bin/spool-agent is never overwritten (exit 7)
#   9. qwen (specs/048): npm into <prefix>, the vendored rg made executable;
#      no npm -> exit 3 before anything is fetched
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALL="$TEST_DIR/../install.sh"
REAL_RUN="$(cd "$TEST_DIR/../../../../.." && pwd)/run"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H" "$T/stub" "$T/www"

# ── fixtures served by the curl stub ──────────────────────────────────────────
for c in claude agy; do
  cat >"$T/www/$c-install.sh" <<EOF
#!/bin/bash
echo "vendor-$c ran" >>"$T/vendor.log"
mkdir -p "\$HOME/.local/bin"
printf '#!/bin/sh\ncase "\$1" in --version) echo "$c 9.9.9";; update) echo "$c update" >>"$T/vendor.log";; esac\n' >"\$HOME/.local/bin/$c"
chmod +x "\$HOME/.local/bin/$c"
EOF
done
cat >"$T/www/grok-install.sh" <<EOF
#!/bin/bash
echo "vendor-grok ran GROK_BIN_DIR=\$GROK_BIN_DIR" >>"$T/vendor.log"
mkdir -p "\$GROK_BIN_DIR"; printf '#!/bin/sh\necho grok 9.9.9\n' >"\$GROK_BIN_DIR/grok"; chmod +x "\$GROK_BIN_DIR/grok"
EOF
mkdir -p "$T/gobuild/go/bin"
printf '#!/bin/sh\n[ "$1" = version ] && echo "go version go1.99.0 linux/amd64"\nexit 0\n' >"$T/gobuild/go/bin/go"
chmod +x "$T/gobuild/go/bin/go"
tar -czf "$T/www/go.tgz" -C "$T/gobuild" go
printf 'go1.99.0\ntime 2026-01-01T00:00:00Z\n' >"$T/www/goversion"
printf '#!/bin/sh\necho "yq (https://github.com/mikefarah/yq/) version v4.99.0"\n' >"$T/www/yq"

cat >"$T/stub/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; --retry) shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
echo "curl \$url" >>"$T/net.log"
case "\$url" in
  https://vendor.test/claude) f=claude-install.sh ;;
  https://vendor.test/grok)   f=grok-install.sh ;;
  https://vendor.test/agy)    f=agy-install.sh ;;
  https://go.test/VERSION*)   f=goversion ;;
  https://go.test/dl/go1.99.0.*.tar.gz) f=go.tgz ;;
  https://yq.test/yq_*)       f=yq ;;
  *) echo "curl stub: no fixture for \$url" >&2; exit 22 ;;
esac
if [ -n "\$out" ]; then cp "$T/www/\$f" "\$out"; else cat "$T/www/\$f"; fi
EOF
cat >"$T/stub/npm" <<EOF
#!/bin/bash
# npm stub: \`npm install --prefix P -g PKG\` lays out qwen like the real tarball (rg not executable)
echo "npm \$*" >>"$T/npm.log"
[ "\$1 \$2" = "install --prefix" ] || exit 2
p="\$3"; d="\$p/lib/node_modules/@qwen-code/qwen-code"
mkdir -p "\$d/vendor/ripgrep/x64-linux" "\$p/bin"
printf '#!/bin/sh\necho rg\n' >"\$d/vendor/ripgrep/x64-linux/rg"; chmod 644 "\$d/vendor/ripgrep/x64-linux/rg"
printf '#!/bin/sh\necho 0.99.0\n' >"\$d/cli.js"; chmod +x "\$d/cli.js"
ln -sf ../lib/node_modules/@qwen-code/qwen-code/cli.js "\$p/bin/qwen"
EOF
cat >"$T/stub/build.sh" <<EOF
#!/bin/bash
echo "build \$1 go=\$(command -v go)" >>"$T/build.log"
printf '#!/bin/sh\necho spool-stub\n' >"\$1"; chmod +x "\$1"
EOF
# the ./run stub: the mirror hooks come from the REAL action; the seat is scripted
cat >"$T/stub/run" <<EOF
#!/bin/bash
case "\$2" in
  do_spl_desk_mirror_settings) exec env PATH="/usr/local/bin:\$PATH" "$REAL_RUN" "\$@" ;;
  do_spl_desk_pin)
    echo "pin ENV=\$ENV TENANT_ID=\$TENANT_ID DESK_BOX=\$DESK_BOX SPOOL_HUB_URL=\$SPOOL_HUB_URL ROOT_KEY_JSON=\$ROOT_KEY_JSON DRY_RUN=\$DRY_RUN yq=\$(command -v yq)" >>"$T/seat.log"
    case "\${STUB_SEAT:-pinned}" in
      pinned)  echo '{"box": "'\$DESK_BOX'", "box_pubkey": "PUBKEY=", "pinned": true, "admin_cmd": null}'; exit 0 ;;
      pending) echo '{"box": "'\$DESK_BOX'", "box_pubkey": "PUBKEY=", "pinned": false, "admin_cmd": "ENV=x ./run -a do_spl_desk_pin"}'; exit 3 ;;
      *)       echo "FATAL hub down"; exit 1 ;;
    esac ;;
esac
EOF
chmod +x "$T/stub/"* "$T/www/yq"

inst() {  # run install.sh in the throwaway HOME; output in $T/o
  env -i HOME="$H" USER="$(id -un)" PATH="$T/stub:/usr/bin:/bin" TERM=dumb \
    SPOOL_INSTALL_URL_CLAUDE=https://vendor.test/claude SPOOL_INSTALL_URL_GROK=https://vendor.test/grok \
    SPOOL_INSTALL_URL_AGY=https://vendor.test/agy SPOOL_INSTALL_URL_GO=https://go.test \
    SPOOL_INSTALL_URL_YQ=https://yq.test SPOOL_INSTALL_GO_ROOTS="" \
    SPOOL_INSTALL_BUILD="$T/stub/build.sh" SPOOL_INSTALL_RUN="$T/stub/run" "$@" \
    bash "$INSTALL" ${ARGS[@]+"${ARGS[@]}"} >"$T/o" 2>&1
}
HUB=https://api.example.com
TOOLS="$H/.local/share/spool-agent/tools"

# --- 1. refusals ------------------------------------------------------------------------
ARGS=(--cli claude,vim --no-seat); inst; rc=$?
[[ $rc -eq 2 ]] && grep -q "got 'vim'" "$T/o" && pass "1. an unknown --cli is refused (2)" || fail "1. --cli vim: rc $rc $(cat "$T/o")"
ARGS=(--tenant t1); inst; rc=$?
[[ $rc -ne 0 ]] && grep -q 'SPOOL_HUB_URL must be set (no default)' "$T/o" && pass "1. a seat without SPOOL_HUB_URL fails fast" || fail "1. no hub: rc $rc $(cat "$T/o")"
ARGS=(); inst SPOOL_HUB_URL=$HUB; rc=$?
[[ $rc -eq 2 ]] && grep -q 'needs the tenant' "$T/o" && pass "1. a seat without a tenant is refused (2)" || fail "1. no tenant: rc $rc $(cat "$T/o")"
[[ ! -e "$T/net.log" && -z "$(ls -A "$H")" ]] && pass "1. no refusal touched the network or HOME" || fail "1. refusal side effects: $(cat "$T/net.log" 2>/dev/null; ls -A "$H")"

# --- 2. dry run ----------------------------------------------------------------------------
ARGS=(--cli claude,grok,agy --tenant t1 --box box-ext --dry-run); inst SPOOL_HUB_URL=$HUB; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY RUN - nothing changed' "$T/o" && grep -q 'would: install the latest grok' "$T/o" &&
  grep -q 'would: download the latest Go' "$T/o" && grep -q "would: key + pin box-ext in t1 at $HUB" "$T/o" &&
  pass "2. the dry run prints every step" || fail "2. dry: rc $rc $(cat "$T/o")"
[[ ! -e "$T/net.log" && ! -e "$T/seat.log" && ! -e "$T/build.log" && -z "$(ls -A "$H")" ]] &&
  pass "2. the dry run downloads, builds and writes nothing" || fail "2. dry side effects: $(ls -AR "$H" | head)"

# --- 3. full install, no seat ----------------------------------------------------------------
ARGS=(--cli claude,grok,agy --no-seat --env prd --tenant t9 --box box-ext); inst; rc=$?
[[ $rc -eq 0 ]] && pass "3. install exits 0" || fail "3. rc $rc: $(cat "$T/o")"
for c in claude agy; do grep -qx "vendor-$c ran" "$T/vendor.log" && [[ -x "$H/.local/bin/$c" ]] &&
  pass "3. the $c vendor installer ran and left $c" || fail "3. $c: $(cat "$T/vendor.log")"; done
grep -qx "vendor-grok ran GROK_BIN_DIR=$H/.local/bin" "$T/vendor.log" && [[ -x "$H/.local/bin/grok" ]] &&
  pass "3. grok installs into <prefix>/bin" || fail "3. grok: $(cat "$T/vendor.log")"
[[ -x "$TOOLS/bin/yq" && -x "$TOOLS/go/bin/go" ]] && grep -q 'https://go.test/dl/go1.99.0.linux-' "$T/net.log" &&
  pass "3. yq and the latest Go land in tools" || fail "3. tools: $(ls -R "$TOOLS" | head) $(cat "$T/net.log")"
grep -q "^build $TOOLS/bin/spool go=$TOOLS/go/bin/go" "$T/build.log" && [[ -x "$TOOLS/bin/spool" ]] &&
  pass "3. spool is built into tools with the tools Go on PATH" || fail "3. build: $(cat "$T/build.log")"
CFG="$H/.config/spool-agent/env"
[[ "$(stat -c %a "$CFG")" == 600 ]] && grep -qx 'SPOOL_ENV=prd' "$CFG" && grep -qx 'SPOOL_TENANT=t9' "$CFG" && grep -qx 'SPOOL_BOX=box-ext' "$CFG" &&
  pass "3. the config holds env/tenant/box, mode 0600" || fail "3. config: $(cat "$CFG")"
[[ -x "$H/.local/bin/spool-agent" ]] && grep -q 'written by spool-install' "$H/.local/bin/spool-agent" &&
  pass "3. spool-agent is on <prefix>/bin" || fail "3. no shim"
grep -q "not on your PATH" "$T/o" && pass "3. a <prefix>/bin off PATH is named" || fail "3. no PATH hint"

# --- 4. the shim ---------------------------------------------------------------------------------
shim() { env -i HOME="$H" PATH="/usr/bin:/bin" TMUX_PANE=%0 SPOOL_TMUX_SOCKET="$T/no-tmux" "$H/.local/bin/spool-agent" "$@" 2>&1; }
out="$(shim --as CLE-7 --dry-run claude)"
grep -q 'ENV=prd TENANT_ID=t9 DESK_BOX=box-ext DESK_AGENT=CLE-7' <<<"$out" &&
  pass "4. the shim passes the configured env/tenant/box to spool-agent.sh" || fail "4. shim: $out"
grep -q "argv: $H/.local/bin/claude" <<<"$out" && pass "4. spool-agent finds the installed claude" || fail "4. claude path: $out"
out="$(shim --as CLE-7 --tenant t3 --dry-run claude)"
grep -q 'TENANT_ID=t3 ' <<<"$out" && pass "4. a --tenant on the command line wins" || fail "4. override: $out"

# --- 5. the hooks -----------------------------------------------------------------------------------
S="$H/.claude/settings.json"
n_mirror() { python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]; print(sum("spool-mirror.py" in json.dumps(e) for e in h.get(sys.argv[2],[])))' "$S" "$1"; }
[[ "$(n_mirror UserPromptSubmit)" == 1 && "$(n_mirror Stop)" == 1 ]] && grep -qF "$(readlink -f "$TEST_DIR/../../spawn-agents/scripts/spool-mirror.py")" "$S" &&
  pass "5. both events call this checkout's spool-mirror.py" || fail "5. hooks: $(cat "$S")"
cat >"$S" <<'EOF'
{"model": "keep-me", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "python3 /old/clone/spool-mirror.py hook"}]},
                                       {"hooks": [{"type": "command", "command": "echo other-hook"}]}]}}
EOF
rm -f "$S.bak-spool-install"
ARGS=(--cli none --no-seat); inst; inst; rc=$?
grep -q 'WARN clone this repo' "$T/o" && fail "5. this checkout (or its main tree) read as a misplaced clone" || pass "5. no clone-path warning for this checkout"
[[ $rc -eq 0 && "$(n_mirror Stop)" == 1 && "$(n_mirror UserPromptSubmit)" == 1 ]] && ! grep -q /old/clone "$S" &&
  pass "5. an older spool-mirror entry is replaced, one per event after two runs" || fail "5. merge: rc $rc $(cat "$S")"
grep -q 'keep-me' "$S" && grep -q 'echo other-hook' "$S" && pass "5. other keys and hooks are kept" || fail "5. lost keys: $(cat "$S")"
grep -q /old/clone "$S.bak-spool-install" && pass "5. the first merge left a backup" || fail "5. no backup"
out="$(shim --as CLE-7 --dry-run claude)"
grep -q 'hooks: already in ~/.claude/settings.json' <<<"$out" && ! grep -q -- '--settings' <<<"$out" &&
  pass "5. spool-agent then adds no second copy" || fail "5. double hooks: $out"
ARGS=(--cli none --no-seat --no-hooks); cp "$S" "$T/s.before"; inst
cmp -s "$S" "$T/s.before" && pass "5. --no-hooks leaves settings.json alone" || fail "5. --no-hooks changed it"

# --- 6. the seat ------------------------------------------------------------------------------------------
: >"$T/net.log"
ARGS=(--cli none --env dev --tenant t1 --box box-ext); inst SPOOL_HUB_URL=$HUB ROOT_KEY_JSON=/k/t1.json; rc=$?
[[ $rc -eq 0 ]] && grep -q 'seated: box-ext is pinned in t1 (dev)' "$T/o" && pass "6. a pinned box reads seated" || fail "6. pinned: rc $rc $(cat "$T/o")"
grep -q "^pin ENV=dev TENANT_ID=t1 DESK_BOX=box-ext SPOOL_HUB_URL=$HUB ROOT_KEY_JSON=/k/t1.json DRY_RUN=0 yq=$TOOLS/bin/yq" "$T/seat.log" &&
  pass "6. do_spl_desk_pin gets env/tenant/box/hub/root key and the tools PATH" || fail "6. seat env: $(cat "$T/seat.log")"
inst SPOOL_HUB_URL=$HUB STUB_SEAT=pending; rc=$?
[[ $rc -eq 0 ]] && grep -q 'seat PENDING' "$T/o" &&
  grep -qx "SPOOL_HUB_URL=$HUB SPOOL_TENANT=t1 spool hub-pin --box box-ext --pubkey PUBKEY= --root-key <root private key file>" "$T/o" &&
  pass "6. pending: exit 0 and the one hub-pin line for the admin" || fail "6. pending: rc $rc $(cat "$T/o")"
inst SPOOL_HUB_URL=$HUB STUB_SEAT=down; rc=$?
[[ $rc -eq 5 ]] && grep -q 'hub down' "$T/o" && pass "6. a failed seat exits 5 with the reason" || fail "6. failure: rc $rc $(cat "$T/o")"
grep -qx "SPOOL_HUB_URL=$HUB" "$CFG" && pass "6. the config records the hub" || fail "6. hub not in config"
: >"$T/seat.log"
ARGS=(--cli none); inst; rc=$?
[[ $rc -eq 0 ]] && grep -q "^pin ENV=dev TENANT_ID=t1 DESK_BOX=box-ext SPOOL_HUB_URL=$HUB " "$T/seat.log" && grep -q 'seated: box-ext' "$T/o" &&
  pass "6. a bare re-run seats with the saved tenant / box / hub" || fail "6. bare re-run: rc $rc $(cat "$T/o" "$T/seat.log")"
ARGS=(--cli none --tenant t2); inst SPOOL_BOX=box-env; grep -q "TENANT_ID=t2 DESK_BOX=box-env " "$T/seat.log" &&
  pass "6. an option and the environment win over the saved config" || fail "6. precedence: $(tail -1 "$T/seat.log")"

# --- 7. re-run -------------------------------------------------------------------------------------------------
: >"$T/net.log"; : >"$T/vendor.log"
ARGS=(--cli agy --no-seat); inst; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'agy update' "$T/vendor.log" && ! grep -q 'vendor.test/agy' "$T/net.log" &&
  pass "7. agy present: its own update, no installer fetched" || fail "7. agy: rc $rc $(cat "$T/vendor.log" "$T/net.log")"
! grep -qE 'go.test|yq.test' "$T/net.log" && pass "7. the tools Go and yq are not downloaded again" || fail "7. redownload: $(cat "$T/net.log")"

# --- 7b. --update pulls once, then the updated installer runs without it --------------------------
cat >"$T/stub/git" <<EOF
#!/bin/bash
case "\$*" in
  *" pull "*) echo "git \$*" >>"$T/git.log"; exit 0 ;;
  *" status --porcelain"*) exit 0 ;;
esac
exec /usr/bin/git "\$@"
EOF
chmod +x "$T/stub/git"
ARGS=(--update --cli none --no-seat); inst; rc=$?
[[ $rc -eq 0 && "$(grep -c ' pull ' "$T/git.log")" == 1 ]] && grep -q 'running the updated installer' "$T/o" && grep -q 'spool-agent: ' "$T/o" &&
  pass "7b. --update pulls once, then the re-exec-ed installer finishes the run" || fail "7b. update: rc $rc $(cat "$T/git.log" "$T/o")"
rm -f "$T/stub/git"

# --- 9. qwen via npm -------------------------------------------------------------------------------
: >"$T/net.log"
ARGS=(--cli qwen --no-seat --dry-run); inst; rc=$?
[[ $rc -eq 0 ]] && grep -q 'would: npm install --prefix .* -g @qwen-code/qwen-code@latest' "$T/o" && [[ ! -e "$T/npm.log" ]] &&
  pass "9. the dry run names the npm install and runs none" || fail "9. dry: rc $rc $(cat "$T/o")"
ARGS=(--cli qwen --no-seat); inst; rc=$?
QD="$H/.local/lib/node_modules/@qwen-code/qwen-code"
[[ $rc -eq 0 ]] && grep -q "^npm install --prefix $H/.local -g @qwen-code/qwen-code@latest" "$T/npm.log" && [[ -x "$H/.local/bin/qwen" ]] &&
  pass "9. qwen installs through npm into <prefix>" || fail "9. qwen: rc $rc $(cat "$T/o" "$T/npm.log")"
[[ -x "$QD/vendor/ripgrep/x64-linux/rg" ]] && grep -q 'made .*rg executable' "$T/o" &&
  pass "9. the vendored rg gets its execute bit" || fail "9. rg: $(ls -l "$QD/vendor/ripgrep/x64-linux/rg")"
: >"$T/npm.log"
ARGS=(--cli qwen --no-seat); inst SPOOL_INSTALL_NPM="$T/no-such-npm"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'needs npm' "$T/o" && [[ ! -s "$T/npm.log" ]] &&
  pass "9. no npm: exit 3, named, nothing run" || fail "9. no npm: rc $rc $(cat "$T/o")"

# --- 8. a foreign spool-agent ------------------------------------------------------------------------------------
printf '#!/bin/sh\necho mine\n' >"$H/.local/bin/spool-agent"
ARGS=(--cli none --no-seat); inst; rc=$?
[[ $rc -eq 7 ]] && grep -qx 'echo mine' "$H/.local/bin/spool-agent" && pass "8. a foreign spool-agent is left alone (7)" || fail "8. rc $rc $(cat "$T/o")"

[[ $fails -eq 0 ]] && echo "OK test-install: $n passed" || { echo "FAILED test-install: $fails of $n"; exit 1; }
