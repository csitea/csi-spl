#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: install.sh (specs/037), hermetic. A throwaway HOME; the network is a
#          `curl` stub that serves fixture installers, a Go tarball and a yq;
#          the spool build and the seat action are stubs. PATH holds no go and
#          no yq, so both download branches run.
#   1. refusals: a bad --cli, a seat with no SPOOL_HUB_URL or no tenant
#   2. --dry-run downloads and writes nothing
#   3. a full install: the three vendor installers, grok into <prefix>/bin,
#      yq + Go into tools, spool built and linked as <prefix>/bin/spool
#      (a real file there is kept), the shim, the config
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
#   9b. mistral (spec 110 2.2): --cli mistral --cli-only installs the cnf pin
#      through pipx and pins active_model, touches nothing else; a re-run at
#      the pin installs nothing; pin latest -> 2; no uv/pipx -> 3
#  10. the harness (specs/048): every command + skill rendered into ~/.claude
#      (and ~/.qwen/skills with qwen) with no {{placeholder}} left; a re-run
#      rewrites nothing; a hand edit is kept and named, --force-skills
#      replaces it with a backup; a foreign same-named file is never touched;
#      the tmux snippet lands in <data>; --no-skills renders nothing
#  11. a vendor URL that returns no script: that CLI is named, never run, the
#      other CLIs and the harness still install, and the run exits 4
#  12. spec 072 A49: a default install writes no fleet CLAUDE.md, no ~/.vibe/AGENTS.md,
#      no skipDangerous setting, no browser MCP; --fleet writes them and is
#      remembered; a home with the fleet block is a fleet box; =0 opts out
#  13. spec 072 A50: an unreachable hub is exit 5 naming the URL before
#      anything installs; a hub URL alone means --env self; a dry run says
#      "would render"; the skills carry no /var/spool-hub and no CLE-00
#  14. spec 072 A4b: spool is downloaded from the newest stable-* release
#      (a newer v* release is skipped), checked against spool-SHA256SUMS, and
#      no Go is fetched; a re-run fetches nothing; no asset for this OS/arch,
#      no release, offline -> the build, named in one line; a bad checksum ->
#      exit 6, nothing installed, nothing built; SPOOL_INSTALL_CLI=download
#      never builds; --fleet builds; the dry run names both paths
#  15. every path that replaces the spool binary (the --fleet build, the
#      download) keeps the old one as spool.bak (its bytes, not an older
#      .bak) and puts its owner, group and mode on the new one; the same
#      bytes again rename nothing and keep spool.bak
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
echo '{"version": "9.9.9"}' >"$T/www/version"
# the releases list: none by default, so every section above 14 builds
echo '[]' >"$T/www/rel-none.json"

cat >"$T/stub/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; --retry|--max-time) shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
echo "curl \$url" >>"$T/net.log"
case "\$url" in
  https://vendor.test/claude) f=claude-install.sh ;;
  https://vendor.test/grok)   f=grok-install.sh ;;
  https://vendor.test/agy)    f=agy-install.sh ;;
  https://go.test/VERSION*)   f=goversion ;;
  https://go.test/dl/go1.99.0.*.tar.gz) f=go.tgz ;;
  https://yq.test/yq_*)       f=yq ;;
  https://api.example.com/version|http://localhost:18478/version) f=version ;;
  https://rel.test/releases*) f="\${STUB_REL:-rel-none.json}" ;;
  https://dl.test/*)          f="dl/\${url#https://dl.test/}"; [ -f "$T/www/\$f" ] || exit 22 ;;
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
# like go build -o: a new file renamed over the target (a new inode, this
# user's owner, group and umask mode), never written in place
printf '#!/bin/sh\necho spool-stub\n' >"\$1.stub\$\$"; chmod +x "\$1.stub\$\$"; mv -f "\$1.stub\$\$" "\$1"
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

# the system bin dirs minus go and yq: a hosted runner ships /usr/bin/yq and a
# go, which would skip both downloads and write go telemetry into the HOME
mkdir -p "$T/sys"
for d in /usr/bin /bin; do ln -s "$d"/* "$T/sys/" 2>/dev/null; done
rm -f "$T/sys/go" "$T/sys/gofmt" "$T/sys/yq"
inst() {  # run install.sh in the throwaway HOME; output in $T/o
  env -i HOME="$H" USER="$(id -un)" PATH="$T/stub:$T/sys" TERM=dumb SPOOL_INSTALL_BOX_SETTINGS_FILE="$T/box-settings.json" \
    SPOOL_INSTALL_URL_CLAUDE=https://vendor.test/claude SPOOL_INSTALL_URL_GROK=https://vendor.test/grok \
    SPOOL_INSTALL_URL_AGY=https://vendor.test/agy SPOOL_INSTALL_URL_GO=https://go.test \
    SPOOL_INSTALL_URL_YQ=https://yq.test SPOOL_INSTALL_GO_ROOTS="" \
    SPOOL_INSTALL_REPO=example/spool SPOOL_INSTALL_URL_RELEASES=https://rel.test/releases SPOOL_INSTALL_URL_CLI=https://dl.test \
    SPOOL_INSTALL_BUILD="$T/stub/build.sh" SPOOL_INSTALL_RUN="$T/stub/run" "$@" \
    bash "$INSTALL" ${ARGS[@]+"${ARGS[@]}"} >"$T/o" 2>&1
}
HUB=https://api.example.com
TOOLS="$H/.local/share/spool-agent/tools"

# --- 1. refusals ------------------------------------------------------------------------
ARGS=(--cli 'claude,vim' --no-seat); inst; rc=$?
[[ $rc -eq 2 ]] && grep -q "got 'vim'" "$T/o" && pass "1. an unknown --cli is refused (2)" || fail "1. --cli vim: rc $rc $(cat "$T/o")"
ARGS=(--tenant t1); inst; rc=$?
[[ $rc -ne 0 ]] && grep -q 'SPOOL_HUB_URL must be set (no default)' "$T/o" && pass "1. a seat without SPOOL_HUB_URL fails fast" || fail "1. no hub: rc $rc $(cat "$T/o")"
ARGS=(); inst SPOOL_HUB_URL=$HUB; rc=$?
[[ $rc -eq 2 ]] && grep -q 'needs the tenant' "$T/o" && pass "1. a seat without a tenant is refused (2)" || fail "1. no tenant: rc $rc $(cat "$T/o")"
[[ ! -e "$T/net.log" && -z "$(ls -A "$H")" ]] && pass "1. no refusal touched the network or HOME" || fail "1. refusal side effects: $(cat "$T/net.log" 2>/dev/null; ls -A "$H")"

# --- 2. dry run ----------------------------------------------------------------------------
ARGS=(--cli 'claude,grok,agy' --tenant t1 --box box-ext --dry-run); inst SPOOL_HUB_URL=$HUB; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY RUN - nothing changed' "$T/o" && grep -q 'would: install the latest grok' "$T/o" &&
  grep -q 'would: download the latest Go' "$T/o" && grep -q "would: key + pin box-ext in t1 at $HUB" "$T/o" &&
  pass "2. the dry run prints every step" || fail "2. dry: rc $rc $(cat "$T/o")"
[[ ! -e "$T/net.log" && ! -e "$T/seat.log" && ! -e "$T/build.log" && -z "$(ls -A "$H")" ]] &&
  pass "2. the dry run downloads, builds and writes nothing" || fail "2. dry side effects: $(ls -AR "$H" | sed -n 1,10p)"

# --- 3. full install, no seat ----------------------------------------------------------------
ARGS=(--cli 'claude,grok,agy' --no-seat --env prd --tenant t9 --box box-ext); inst; rc=$?
[[ $rc -eq 0 ]] && pass "3. install exits 0" || fail "3. rc $rc: $(cat "$T/o")"
for c in claude agy; do grep -qx "vendor-$c ran" "$T/vendor.log" && [[ -x "$H/.local/bin/$c" ]] &&
  pass "3. the $c vendor installer ran and left $c" || fail "3. $c: $(cat "$T/vendor.log")"; done
grep -qx "vendor-grok ran GROK_BIN_DIR=$H/.local/bin" "$T/vendor.log" && [[ -x "$H/.local/bin/grok" ]] &&
  pass "3. grok installs into <prefix>/bin" || fail "3. grok: $(cat "$T/vendor.log")"
[[ -x "$TOOLS/bin/yq" && -x "$TOOLS/go/bin/go" ]] && grep -q 'https://go.test/dl/go1.99.0.linux-' "$T/net.log" &&
  pass "3. yq and the latest Go land in tools" || fail "3. tools: $(ls -R "$TOOLS" | sed -n 1,10p) $(cat "$T/net.log")"
grep -qE "^build $TOOLS/bin/spool\.new\.[0-9]+ go=$TOOLS/go/bin/go" "$T/build.log" && [[ -x "$TOOLS/bin/spool" ]] && ! compgen -G "$TOOLS/bin/*.new.*" >/dev/null &&
  pass "3. spool is built into tools with the tools Go on PATH" || fail "3. build: $(cat "$T/build.log")"
[[ -L "$H/.local/bin/spool" && "$(readlink "$H/.local/bin/spool")" == "$TOOLS/bin/spool" ]] &&
  [[ "$(env -i PATH="$H/.local/bin:/usr/bin:/bin" bash -c 'command -v spool && spool')" == "$H/.local/bin/spool"$'\n'spool-stub ]] &&
  pass "3. spool is on <prefix>/bin, a link to the tools build" || fail "3. spool link: $(ls -l "$H/.local/bin/spool" 2>&1) $(cat "$T/o")"
CFG="$H/.config/spool-agent/env"
[[ "$(stat -c %a "$CFG")" == 600 ]] && grep -qx 'SPOOL_ENV=prd' "$CFG" && grep -qx 'SPOOL_TENANT=t9' "$CFG" && grep -qx 'SPOOL_BOX=box-ext' "$CFG" &&
  pass "3. the config holds env/tenant/box, mode 0600" || fail "3. config: $(cat "$CFG")"
echo 'SPOOL_BOX_TAG=keep' >>"$CFG"
ARGS=(--cli none --no-seat --env prd --tenant t9 --box box-ext); inst
grep -qx 'SPOOL_BOX_TAG=keep' "$CFG" && [[ "$(grep -c '^SPOOL_ENV=' "$CFG")" == 1 ]] &&
  pass "3. a re-run keeps a config line it does not own, and writes its own once" || fail "3. config re-run: $(cat "$CFG")"
[[ -x "$H/.local/bin/spool-agent" ]] && grep -q 'written by spool-install' "$H/.local/bin/spool-agent" &&
  pass "3. spool-agent is on <prefix>/bin" || fail "3. no shim"
grep -q "not on your PATH" "$T/o" && pass "3. a <prefix>/bin off PATH is named" || fail "3. no PATH hint"

# --- 4. the shim ---------------------------------------------------------------------------------
shim() { env -i HOME="$H" PATH="/usr/bin:/bin" TMUX_PANE=%0 SPOOL_TMUX_SOCKET="$T/no-tmux" "$H/.local/bin/spool-agent" "$@" 2>&1; }
out="$(shim --as c-007 --dry-run claude)"
grep -q 'ENV=prd TENANT_ID=t9 DESK_BOX=box-ext DESK_AGENT=c-007' <<<"$out" &&
  pass "4. the shim passes the configured env/tenant/box to spool-agent.sh" || fail "4. shim: $out"
grep -q "argv: $H/.local/bin/claude" <<<"$out" && pass "4. spool-agent finds the installed claude" || fail "4. claude path: $out"
out="$(shim --as c-007 --tenant t3 --dry-run claude)"
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
out="$(shim --as c-007 --dry-run claude)"
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
  grep -qx "SPOOL_HUB_URL=$HUB SPOOL_TENANT=t1 spool hub-pin --box box-ext --pubkey PUBKEY= --root-key <root private key: a file, the key text, or - for stdin>" "$T/o" &&
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
# specs/047 W4: a self-hosted hub - any URL, ENV=self handed to do_spl_desk_pin
: >"$T/seat.log"
ARGS=(--cli none --env self --tenant main --box box-ext); inst SPOOL_HUB_URL=http://localhost:18478 ROOT_KEY_JSON=/k/root.key; rc=$?
[[ $rc -eq 0 ]] && grep -q 'seated: box-ext is pinned in main (self)' "$T/o" &&
  grep -q "^pin ENV=self TENANT_ID=main DESK_BOX=box-ext SPOOL_HUB_URL=http://localhost:18478 ROOT_KEY_JSON=/k/root.key DRY_RUN=0" "$T/seat.log" &&
  pass "6. --env self seats against any hub URL (ENV=self to do_spl_desk_pin)" || fail "6. self: rc $rc $(cat "$T/o" "$T/seat.log")"
ARGS=(--cli none --env qa --tenant main --box box-ext); inst SPOOL_HUB_URL=http://localhost:18478; rc=$?
[[ $rc -eq 2 ]] && pass "6. CONTROL: --env qa is refused (exit 2)" || fail "6. --env qa: rc $rc"

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

# --- 9b. mistral (spec 110 2.2): the cnf pin through pipx, --cli-only ----------------------------
H0="$H"; H="$T/home-mistral"; mkdir -p "$H" "$T/mbin"; : >"$T/net.log"
cat >"$T/mbin/pipx" <<EOF
#!/bin/bash
echo "pipx \$*" >>"$T/pipx.log"
case "\$1" in install) v="\${@: -1}"; v="\${v##*==}"; mkdir -p "\$HOME/.local/bin"
  printf '#!/bin/sh\ncase "\$1" in --version) echo "vibe %s";; --help) echo "[-p] [--auto-approve] [-c | --continue] [--resume]";; esac\n' "\$v" >"\$HOME/.local/bin/vibe"
  chmod +x "\$HOME/.local/bin/vibe" ;; runpip) echo "httpx==0.28.1" ;; esac
EOF
printf '#!/bin/sh\necho 3.13\n' >"$T/mbin/py"; chmod +x "$T/mbin/"*
MPIN="$(sed -n '/^ *mistral_vibe:/,/^ *model:/s/^ *version: *//p' "$TEST_DIR/../../../../../../csi-spl-cnf/csi-spl/all.env.yaml")"
MI=(SPOOL_INSTALL_PIPX="$T/mbin/pipx" SPOOL_INSTALL_UV="$T/no-uv" SPOOL_INSTALL_PYTHON="$T/mbin/py")
ARGS=(--cli mistral --cli-only); inst "${MI[@]}"; rc=$?
[[ $rc -eq 0 && -n "$MPIN" ]] && grep -qx "pipx install --force mistral-vibe==$MPIN" "$T/pipx.log" &&
  grep -q "mistral: $H/.local/bin/vibe (vibe $MPIN)" "$T/o" && grep -qx 'active_model = "mistral-vibe-cli-latest"' "$H/.vibe/config.toml" &&
  pass "9b. --cli mistral installs the cnf pin ($MPIN) through pipx, pins active_model" || fail "9b. mistral: rc $rc $(cat "$T/o")"
[[ ! -s "$T/net.log" && ! -e "$H/.claude" && ! -e "$H/.local/share/spool-agent" && ! -e "$H/.config/spool-agent" ]] &&
  pass "9b. --cli-only: no hub, no download, no toolchain, config or harness" || fail "9b. --cli-only side effects: $(ls -A "$H") $(cat "$T/net.log")"
: >"$T/pipx.log"
ARGS=(--cli mistral --cli-only); inst "${MI[@]}"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^pipx install' "$T/pipx.log" && grep -q "is at the pin $MPIN: not reinstalled" "$T/o" &&
  pass "9b. a re-run at the pin installs nothing" || fail "9b. re-run: rc $rc $(cat "$T/pipx.log")"
: >"$T/pipx.log"
ARGS=(--cli mistral --cli-only); inst "${MI[@]}" SPOOL_INSTALL_MISTRAL_VERSION=latest; rc=$?
[[ $rc -eq 2 && ! -s "$T/pipx.log" ]] && grep -q 'never latest' "$T/o" && pass "9b. CONTROL: pin latest is refused (2)" || fail "9b. latest: rc $rc"
ARGS=(--cli mistral --cli-only); inst "${MI[@]}" SPOOL_INSTALL_PIPX="$T/no-pipx"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'needs uv or pipx' "$T/o" && pass "9b. no uv, no pipx: exit 3, named" || fail "9b. no pipx: rc $rc $(cat "$T/o")"
H="$H0"

# --- 10. the harness: skills + commands -----------------------------------------------------------
ASSETS="$(cd "$TEST_DIR/../../spawn-agents/assets" && pwd)"
CMD="$H/.claude/commands"; SK="$H/.claude/skills"
n_cmd="$(ls "$ASSETS/commands" | wc -l)"; n_sk="$(ls "$ASSETS/skills" | wc -l)"
# The harness skills only: a feature step (graft, spec 069 Y6) links its own skill beside them.
n_sk_got="$(for k in "$ASSETS"/skills/*/; do k="${k%/}"; [ -f "$SK/${k##*/}/SKILL.md" ] && echo; done | wc -l)"
[[ "$(ls "$CMD"/*.md 2>/dev/null | wc -l)" == "$n_cmd" && "$n_sk_got" == "$n_sk" ]] &&
  pass "10. every command ($n_cmd) and skill ($n_sk) is rendered into ~/.claude" || fail "10. rendered: $(ls -R "$H/.claude" | sed -n 1,30p)"
for k in claude grok agy qwen; do [[ -r "$CMD/$k-spawn.md" ]] || fail "10. no /$k-spawn"; done
! grep -rqE '\{\{[A-Z_]+\}\}' "$CMD" "$SK" && pass "10. no placeholder is left" || fail "10. placeholders: $(grep -rlE '\{\{[A-Z_]+\}\}' "$CMD" "$SK")"
grep -qF "$(cd "$TEST_DIR/../../spawn-agents" && pwd)/scripts/spawn-window.sh qwen auto" "$CMD/qwen-spawn.md" &&
  pass "10. /qwen-spawn runs this checkout's spawn-window.sh" || fail "10. HARNESS_DIR: $(grep spawn-window "$CMD/qwen-spawn.md")"
[[ -r "$H/.qwen/skills/qwen-spawn/SKILL.md" && -r "$H/.qwen/skills/agent-msg/SKILL.md" ]] &&
  pass "10. with qwen installed, ~/.qwen/skills gets them too" || fail "10. qwen skills: $(ls "$H/.qwen/skills" 2>&1)"
cp -a "$H/.claude" "$T/claude.before"
ARGS=(--cli none --no-seat); inst; rc=$?
[[ $rc -eq 0 ]] && diff -r "$T/claude.before" "$H/.claude" >/dev/null && grep -q 'skills: 0 written' "$T/o" &&
  pass "10. a re-run rewrites nothing" || fail "10. re-run: rc $rc $(grep skills "$T/o")"
[[ -r "$H/.local/share/spool-agent/tmux-agent-status.conf" ]] && grep -q 'source-file .*tmux-agent-status.conf' "$T/o" &&
  grep -qF "bash $(cd "$TEST_DIR/../../spawn-agents" && pwd)/scripts/agent-top.sh --status-line" "$H/.local/share/spool-agent/tmux-agent-status.conf" &&
  ! grep -q '{{' "$H/.local/share/spool-agent/tmux-agent-status.conf" &&
  pass "10. the tmux snippet lands in <data> with this checkout's agent-top, and the source-file line is printed" || fail "10. tmux: $(cat "$T/o")"
echo "my own line" >>"$CMD/riname.md"
printf 'mine, not the installer'"'"'s\n' >"$CMD/tmux-close-window.md"
ARGS=(--cli none --no-seat); inst; rc=$?
grep -q 'my own line' "$CMD/riname.md" && grep -q "riname.md was edited by hand" "$T/o" &&
  pass "10. a hand-edited file is kept and named" || fail "10. hand edit: $(tail -3 "$CMD/riname.md") $(cat "$T/o")"
grep -qx "mine, not the installer's" "$CMD/tmux-close-window.md" && grep -q 'tmux-close-window.md is not ours' "$T/o" &&
  pass "10. a foreign same-named file is never touched" || fail "10. foreign: $(cat "$CMD/tmux-close-window.md")"
ARGS=(--cli none --no-seat --force-skills); inst; rc=$?
! grep -q 'my own line' "$CMD/riname.md" && grep -q 'my own line' "$CMD/riname.md.bak-spool-install" &&
  grep -qx "mine, not the installer's" "$CMD/tmux-close-window.md" &&
  pass "10. --force-skills replaces the hand edit, keeps a backup, still skips the foreign file" || fail "10. force: rc $rc $(cat "$T/o")"
rm -rf "$H/.claude/commands"
ARGS=(--cli none --no-seat --no-skills); inst
[[ ! -e "$H/.claude/commands" ]] && pass "10. --no-skills renders nothing" || fail "10. --no-skills rendered"

# --- 11. one vendor's bad day ---------------------------------------------------------------------
printf '\x7fELF-not-a-script' >"$T/www/agy-binary"
sed -i 's#  https://vendor.test/agy)    f=agy-install.sh ;;#  https://vendor.test/agy)    f=agy-install.sh ;;\n  https://vendor.test/agybin) f=agy-binary ;;#' "$T/stub/curl"
rm -f "$H/.local/bin/agy"; rm -rf "$H/.claude/commands"; : >"$T/vendor.log"; : >"$T/npm.log"
ARGS=(--cli 'agy,qwen' --no-seat); inst SPOOL_INSTALL_URL_AGY=https://vendor.test/agybin; rc=$?
[[ $rc -eq 4 ]] && grep -q 'agybin did not return a script' "$T/o" && grep -q 'not installed: agy' "$T/o" &&
  pass "11. a non-script installer is refused, named, and the run exits 4" || fail "11. rc $rc $(cat "$T/o")"
! grep -q 'vendor-agy ran' "$T/vendor.log" && [[ ! -e "$H/.local/bin/agy" ]] && pass "11. ... and never run" || fail "11. it ran"
grep -q '^npm install' "$T/npm.log" && [[ -r "$H/.claude/commands/qwen-spawn.md" ]] &&
  pass "11. qwen and the harness still install after it" || fail "11. later steps skipped: $(cat "$T/o")"

# --- 3b. a real <prefix>/bin/spool is never replaced; a stale link is repointed ----------------
rm -f "$H/.local/bin/spool"; printf '#!/bin/sh\necho my-spool\n' >"$H/.local/bin/spool"; chmod +x "$H/.local/bin/spool"
ARGS=(--cli none --no-seat --no-skills); inst; rc=$?
[[ $rc -eq 0 && ! -L "$H/.local/bin/spool" ]] && grep -q 'echo my-spool' "$H/.local/bin/spool" && grep -q 'is not a link: left alone' "$T/o" &&
  pass "3b. a real <prefix>/bin/spool is left alone and named" || fail "3b. foreign spool: rc $rc $(cat "$T/o")"
rm -f "$H/.local/bin/spool"; ln -s "$T/old-clone/spool" "$H/.local/bin/spool"
ARGS=(--cli none --no-seat --no-skills); inst; rc=$?
[[ $rc -eq 0 && "$(readlink "$H/.local/bin/spool")" == "$TOOLS/bin/spool" ]] &&
  pass "3b. a stale spool link is repointed at this build" || fail "3b. stale link: rc $rc $(ls -l "$H/.local/bin/spool")"

# --- 8. a foreign spool-agent ------------------------------------------------------------------------------------
printf '#!/bin/sh\necho mine\n' >"$H/.local/bin/spool-agent"
ARGS=(--cli none --no-seat); inst; rc=$?
[[ $rc -eq 7 ]] && grep -qx 'echo mine' "$H/.local/bin/spool-agent" && pass "8. a foreign spool-agent is left alone (7)" || fail "8. rc $rc $(cat "$T/o")"

# --- 12. the fleet config is opt-in (spec 072 A49) ------------------------------------------------
H="$T/home-a49"; mkdir -p "$H"; CFG="$H/.config/spool-agent/env"
ARGS=(--cli none --no-seat); inst; rc=$?
[[ $rc -eq 0 && ! -e "$H/.claude/CLAUDE.md" && ! -e "$H/.vibe/AGENTS.md" && ! -e "$H/.local/mcp-bot" && -r "$H/.claude/settings.json" ]] &&
  ! grep -q skipDangerous "$H/.claude/settings.json" && grep -q 'fleet config: not written' "$T/o" && grep -qx SPOOL_INSTALL_FLEET=0 "$CFG" &&
  pass "12. a default install leaves CLAUDE.md, ~/.vibe/AGENTS.md, skipDangerous and the browser MCP alone" || fail "12. default: rc $rc $(cat "$T/o")"
ARGS=(--cli none --no-seat --fleet); inst; rc=$?
[[ $rc -eq 0 && -L "$H/.local/mcp-bot/mcp-start.sh" ]] && grep -qF '<!-- spool-install: begin claude-md' "$H/.claude/CLAUDE.md" &&
  grep -qF '<!-- spool-install: begin agents-md' "$H/.vibe/AGENTS.md" &&
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["skipDangerousModePermissionPrompt"] is True' "$H/.claude/settings.json" &&
  grep -qx SPOOL_INSTALL_FLEET=1 "$CFG" && grep -rqF 'SPOOL_ROOT=/var/spool-hub' "$H/.claude/skills" &&
  pass "12. --fleet writes the fleet CLAUDE.md, ~/.vibe/AGENTS.md, settings and browser MCP (the fleet spool root)" || fail "12. --fleet: rc $rc $(cat "$T/o")"
ARGS=(--cli none --no-seat); inst; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'fleet config: not written' "$T/o" && grep -qx SPOOL_INSTALL_FLEET=1 "$CFG" &&
  pass "12. a bare re-run keeps --fleet" || fail "12. sticky: rc $rc $(cat "$T/o")"
mkdir -p "$T/home-a49b/.claude"; cp "$H/.claude/CLAUDE.md" "$T/home-a49b/.claude/"; H="$T/home-a49b"
ARGS=(--cli none --no-seat --no-skills); inst; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'fleet config: not written' "$T/o" && grep -q skipDangerous "$H/.claude/settings.json" &&
  pass "12. a home that has the fleet block is a fleet box" || fail "12. legacy fleet box: rc $rc $(cat "$T/o")"
ARGS=(--cli none --no-seat --no-skills); inst SPOOL_INSTALL_FLEET=0; rc=$?
[[ $rc -eq 0 ]] && grep -q 'fleet config: not written' "$T/o" && grep -qx SPOOL_INSTALL_FLEET=0 "$H/.config/spool-agent/env" &&
  pass "12. SPOOL_INSTALL_FLEET=0 opts a fleet home out" || fail "12. opt out: rc $rc $(cat "$T/o")"

# --- 13. errors and defaults a stranger owns (spec 072 A50) ------------------------------------------
H="$T/home-a50"; mkdir -p "$H"; : >"$T/vendor.log"; : >"$T/seat.log"
ARGS=(--cli claude --tenant t1); inst SPOOL_HUB_URL=https://down.example.com; rc=$?
[[ $rc -eq 5 && ! -s "$T/vendor.log" && ! -s "$T/seat.log" && ! -e "$H/.local" ]] &&
  grep -q 'FATAL the hub at https://down.example.com does not answer https://down.example.com/version' "$T/o" && ! grep -q PENDING "$T/o" &&
  pass "13. an unreachable hub is exit 5 naming the URL, before anything installs" || fail "13. down hub: rc $rc $(cat "$T/o")"
ARGS=(--cli none --tenant t1 --box box-ext); inst SPOOL_HUB_URL=$HUB; rc=$?
[[ $rc -eq 0 ]] && grep -q '^pin ENV=self TENANT_ID=t1 ' "$T/seat.log" && grep -qx SPOOL_ENV=self "$H/.config/spool-agent/env" &&
  pass "13. a hub URL and no --env is env self" || fail "13. self default: rc $rc $(cat "$T/o" "$T/seat.log")"
[[ -z "$(grep -rhoE '/var/spool-hub|CLE-00' "$H/.claude")" ]] && grep -rqF "SPOOL_ROOT=$H/.local/state/spool-hub" "$H/.claude/skills" &&
  grep -rqF 'agent-send.sh --from <YOUR-ID> orchestrator ' "$H/.claude/skills" &&
  pass "13. the skills default to ~/.local/state/spool-hub and the orchestrator role" || fail "13. defaults: $(grep -rnoE '/var/spool-hub|CLE-00' "$H/.claude" | sed -n 1,3p)"
H="$T/home-a50b"; mkdir -p "$H"
ARGS=(--cli none --no-seat --fleet --dry-run); inst; rc=$?
[[ $rc -eq 0 && -z "$(ls -A "$H")" ]] && grep -q 'would render' "$T/o" && ! grep -qE 'rendered|merged' "$T/o" &&
  pass "13. a dry run says would render, never rendered" || fail "13. dry wording: rc $rc $(cat "$T/o")"

# --- 14. the CLI from the newest stable-* release (spec 072 A4b) ----------------------------------
case "$(uname -m)" in x86_64|amd64) A=amd64 ;; aarch64|arm64) A=arm64 ;; *) A="$(uname -m)" ;; esac
ASSET="spool-$(uname -s | tr '[:upper:]' '[:lower:]')-$A"
mk_stable() {  # TAG SUMS-OVERRIDE: a release dir with the asset and its spool-SHA256SUMS
  mkdir -p "$T/www/dl/$1"
  printf '#!/bin/sh\n[ "$1" = version ] && echo "spool v9.9.9 (%s)"\n' "$1" >"$T/www/dl/$1/$ASSET"
  if [ -n "${2:-}" ]; then printf '%s  %s\n' "$2" "$ASSET" >"$T/www/dl/$1/spool-SHA256SUMS"
  else (cd "$T/www/dl/$1" && sha256sum "$ASSET" >spool-SHA256SUMS); fi
}
mk_stable stable-2026-10-05
mk_stable stable-2026-10-06 "$(printf '0%.0s' $(seq 64))"
rel() { printf '{"tag_name": "%s", "draft": false, "prerelease": false, "assets": [%s]}' "$1" "$2"; }
a() { printf '{"name": "%s"}' "$1"; }
echo "[$(rel v9.9.9 "$(a "$ASSET")"), $(rel stable-2026-10-05 "$(a "$ASSET"), $(a spool-SHA256SUMS)")]" >"$T/www/rel-good.json"
echo "[$(rel stable-2026-10-05 "$(a spool-plan9-amd64), $(a spool-SHA256SUMS)")]" >"$T/www/rel-noasset.json"
echo "[$(rel stable-2026-10-06 "$(a "$ASSET"), $(a spool-SHA256SUMS)")]" >"$T/www/rel-bad.json"
cli_lines() { grep -c '^spool-install: spool CLI: ' "$T/o"; }

H="$T/home-a4b"; mkdir -p "$H"; TOOLS="$H/.local/share/spool-agent/tools"; : >"$T/net.log"; : >"$T/build.log"
ARGS=(--cli none --no-seat --no-skills); inst STUB_REL=rel-good.json; rc=$?
[[ $rc -eq 0 ]] && grep -q "spool CLI: downloaded $ASSET of stable-2026-10-05 (https://dl.test/stable-2026-10-05/$ASSET, sha256 checked against spool-SHA256SUMS)" "$T/o" &&
  [[ "$(cli_lines)" == 1 ]] && cmp -s "$TOOLS/bin/spool" "$T/www/dl/stable-2026-10-05/$ASSET" &&
  pass "14. spool is the $ASSET of the newest stable-* (the newer v* skipped), sha256 checked, one line" || fail "14. download: rc $rc $(cat "$T/o")"
[[ ! -s "$T/build.log" && ! -e "$TOOLS/go" ]] && ! grep -q go.test "$T/net.log" &&
  pass "14. a downloaded spool needs no Go and no build" || fail "14. built anyway: $(cat "$T/build.log" "$T/net.log")"
[[ "$(env -i PATH="$H/.local/bin:/usr/bin:/bin" bash -c 'spool version')" == "spool v9.9.9 (stable-2026-10-05)" ]] &&
  pass "14. ... and is on <prefix>/bin as spool" || fail "14. not on PATH: $(ls -l "$H/.local/bin/spool" 2>&1)"
: >"$T/net.log"
ARGS=(--cli none --no-seat --no-skills); inst STUB_REL=rel-good.json; rc=$?
[[ $rc -eq 0 ]] && grep -q 'already spool-.* of stable-2026-10-05 (sha256 matches) - not downloaded again' "$T/o" && ! grep -q "dl.test/stable-2026-10-05/$ASSET" "$T/net.log" &&
  pass "14. a re-run on the same stable downloads nothing" || fail "14. re-run: rc $rc $(cat "$T/o" "$T/net.log")"

H="$T/home-a4b-bad"; mkdir -p "$H"; TOOLS="$H/.local/share/spool-agent/tools"; : >"$T/build.log"
ARGS=(--cli none --no-seat --no-skills); inst STUB_REL=rel-bad.json; rc=$?
[[ $rc -eq 6 && ! -e "$TOOLS/bin/spool" && ! -s "$T/build.log" && ! -e "$H/.local/bin/spool-agent" ]] &&
  grep -q "FATAL the sha256 of https://dl.test/stable-2026-10-06/$ASSET is .*, its spool-SHA256SUMS says 0\{64\}: refused, .* untouched. Re-run install.sh" "$T/o" &&
  pass "14. a bad checksum is refused (6): nothing installed, nothing built, the URL named" || fail "14. bad sum: rc $rc $(cat "$T/o")"

H="$T/home-a4b-noasset"; mkdir -p "$H"; TOOLS="$H/.local/share/spool-agent/tools"; : >"$T/build.log"
ARGS=(--cli none --no-seat --no-skills); inst STUB_REL=rel-noasset.json; rc=$?
[[ $rc -eq 0 && "$(cli_lines)" == 1 ]] && grep -q "spool CLI: building from this checkout - stable-2026-10-05 has no $ASSET (this OS/arch)" "$T/o" &&
  grep -qE "^build $TOOLS/bin/spool\.new\.[0-9]+ go=$TOOLS/go/bin/go" "$T/build.log" &&
  pass "14. no asset for this OS/arch: the Go build, named in one line" || fail "14. no asset: rc $rc $(cat "$T/o" "$T/build.log")"
: >"$T/build.log"
ARGS=(--cli none --no-seat --no-skills); inst; rc=$?
[[ $rc -eq 0 ]] && grep -q "spool CLI: building from this checkout - no stable-\* release at https://rel.test/releases" "$T/o" && [[ -s "$T/build.log" ]] &&
  pass "14. no stable-* release: the build" || fail "14. no release: rc $rc $(cat "$T/o")"
: >"$T/build.log"
ARGS=(--cli none --no-seat --no-skills); inst STUB_REL=no-such-file; rc=$?
[[ $rc -eq 0 ]] && grep -q "spool CLI: building from this checkout - cannot read the releases at https://rel.test/releases" "$T/o" && [[ -s "$T/build.log" ]] &&
  pass "14. offline (the releases do not answer): the build, the URL named" || fail "14. offline: rc $rc $(cat "$T/o")"
: >"$T/build.log"
ARGS=(--cli none --no-seat --no-skills); inst SPOOL_INSTALL_CLI=download; rc=$?
[[ $rc -eq 6 && ! -s "$T/build.log" ]] && grep -q 'FATAL SPOOL_INSTALL_CLI=download, but no stable-\* release at https://rel.test/releases: unset SPOOL_INSTALL_CLI' "$T/o" &&
  pass "14. SPOOL_INSTALL_CLI=download never builds (6, what to run next)" || fail "14. download-only: rc $rc $(cat "$T/o")"
: >"$T/build.log"; : >"$T/net.log"
ARGS=(--cli none --no-seat --no-skills --fleet); inst STUB_REL=rel-good.json; rc=$?
[[ $rc -eq 0 && -s "$T/build.log" ]] && grep -q 'spool CLI: building from this checkout - a fleet box (--fleet)' "$T/o" && ! grep -q 'rel.test' "$T/net.log" &&
  pass "14. a --fleet box builds this checkout, no release read" || fail "14. fleet: rc $rc $(cat "$T/o")"
ARGS=(--cli none --no-seat --no-skills); inst SPOOL_INSTALL_CLI=nope; rc=$?
[[ $rc -eq 2 ]] && pass "14. CONTROL: SPOOL_INSTALL_CLI=nope is refused (2)" || fail "14. bad mode: rc $rc"
H="$T/home-a4b-dry"; mkdir -p "$H"; : >"$T/net.log"
ARGS=(--cli none --no-seat --dry-run); inst STUB_REL=rel-good.json; rc=$?
[[ $rc -eq 0 && -z "$(ls -A "$H")" && ! -s "$T/net.log" ]] && grep -q "would: download $ASSET of the newest stable-\* release (example/spool" "$T/o" &&
  grep -q 'would: build spool from .* (only when the download is impossible)' "$T/o" &&
  pass "14. the dry run names the download and the fallback, fetches nothing" || fail "14. dry: rc $rc $(cat "$T/o")"
grep -c 'releases/download' "$INSTALL" >/dev/null && pass "14. spec check: install.sh names releases/download" || fail "14. no releases/download in install.sh"

# --- 15. every replace keeps the old binary as spool.bak, owner/group/mode kept ------------------
# The 2026-10-08 fleet-box run: --fleet rebuilt the binary in place, spool.bak was
# still the build before last, and the owner moved to the agent user.
H="$T/home-bak"; TOOLS="$H/.local/share/spool-agent/tools"; mkdir -p "$TOOLS/bin"
printf '#!/bin/sh\necho old-spool-12h\n' >"$TOOLS/bin/spool"; chmod 751 "$TOOLS/bin/spool"
echo 'the build before last' >"$TOOLS/bin/spool.bak"
cp -p "$TOOLS/bin/spool" "$T/old-spool"
g2="$(id -G | tr ' ' '\n' | grep -vx "$(id -g)" | sed -n 1p)"
[ -n "$g2" ] && chgrp "$g2" "$TOOLS/bin/spool"
want_ugm="$(stat -c '%u %g %a' "$TOOLS/bin/spool")"
: >"$T/build.log"
ARGS=(--cli none --no-seat --no-skills --fleet --force-skills); inst; rc=$?
[[ $rc -eq 0 && -s "$T/build.log" ]] && cmp -s "$T/old-spool" "$TOOLS/bin/spool.bak" && grep -q 'spool-stub' "$TOOLS/bin/spool" &&
  grep -q "spool: the old $TOOLS/bin/spool kept as $TOOLS/bin/spool.bak" "$T/o" &&
  pass "15. a forced --fleet build keeps the replaced binary as spool.bak (its old bytes, not the build before)" || fail "15. fleet bak: rc $rc $(cat "$T/o")"
[[ "$(stat -c '%u %g %a' "$TOOLS/bin/spool")" == "$want_ugm" ]] &&
  pass "15. ... owner, group${g2:+ ($g2, not the primary)} and mode 751 kept" || fail "15. ugm: $(stat -c '%u %g %a' "$TOOLS/bin/spool") want $want_ugm"
! compgen -G "$TOOLS/bin/*.new.*" >/dev/null && ! compgen -G "$TOOLS/bin/*.tmp.*" >/dev/null && pass "15. no temp file left beside it" || fail "15. temp left: $(ls "$TOOLS/bin/")"
ARGS=(--cli none --no-seat --no-skills --fleet); inst; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$T/old-spool" "$TOOLS/bin/spool.bak" && grep -q 'is unchanged (the same bytes)' "$T/o" &&
  pass "15. a re-run with the same bytes keeps spool.bak (the real previous build)" || fail "15. re-run: rc $rc $(cat "$T/o")"
H="$T/home-bak-dl"; TOOLS="$H/.local/share/spool-agent/tools"; mkdir -p "$TOOLS/bin"
printf '#!/bin/sh\necho old-dl\n' >"$TOOLS/bin/spool"; chmod 750 "$TOOLS/bin/spool"; cp -p "$TOOLS/bin/spool" "$T/old-dl"
ARGS=(--cli none --no-seat --no-skills); inst STUB_REL=rel-good.json; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$T/old-dl" "$TOOLS/bin/spool.bak" && cmp -s "$TOOLS/bin/spool" "$T/www/dl/stable-2026-10-05/$ASSET" &&
  [[ "$(stat -c %a "$TOOLS/bin/spool")" == 750 ]] &&
  pass "15. a download keeps the replaced binary as spool.bak, mode kept" || fail "15. download bak: rc $rc $(cat "$T/o")"

[[ $fails -eq 0 ]] && echo "OK test-install: $n passed" || { echo "FAILED test-install: $fails of $n"; exit 1; }
