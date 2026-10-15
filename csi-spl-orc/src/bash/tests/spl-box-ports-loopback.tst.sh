#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_ports_loopback (SPL-1960, security round 1 row 3) on
#          fixture compose files and a docker stub: ps / port / inspect read
#          files of fake containers, `compose config` renders the given
#          compose file with ${VAR:-default} from the env and the .env,
#          `compose up` re-publishes the ports the file now says.
#   1. refusals: DRY_RUN=2, a non-numeric PORTS_LOOPBACK
#   2. DRY_RUN is the default: names each container, compose file, the exact
#      line change; a loopback-only container is skipped; a container not
#      from compose is refused; nothing edited, no compose up
#   3. drift: without the project's env the rendered name and bind mount
#      differ from the live container -> the recreate is REFUSED; an env
#      value that differs is named, its value never printed
#   4. DRY_RUN=0 with the env: the one line edited (rest of the file kept),
#      the old file in the undo dir, `compose up` for that service only,
#      the port on 127.0.0.1; a second run has nothing to do
#   5. CONTROL: an edit that does not add 127.0.0.1 is refused by the
#      rendered-port check, nothing edited
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: no python3 yaml"; exit 0; }
F="$T/fake" P="$T/proj/app/src/docker" W="$T/proj/web"
mkdir -p "$F" "$P" "$W" "$T/stub"
cat >"$P/compose.yaml" <<'EOF'
services:
  api:
    container_name: con-${ORG}-api
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8080:8080"
  db:
    image: img-${ORG}-db
    container_name: con-${ORG}-db
    environment:
      DB_PASS: ${DB_PASS:-pw-default}
    ports:
      - "5432:5432"   # the db
    volumes:
      - "${DATA:-/var/${ORG}/db}:/var/lib/postgresql/data"
EOF
printf 'DATA_UNUSED=1\n' >"$P/.env"
cat >"$W/compose.yaml" <<'EOF'
services:
  web:
    image: img-web
    container_name: con-web
    ports:
      - '${WEB_PORT:-3333}:3333'
EOF
cp "$P/compose.yaml" "$T/app.orig"; cp "$W/compose.yaml" "$T/web.orig"
printf 'con-x-db\ncon-web\ncon-lo\ncon-raw\n' >"$F/names"
printf '5432/tcp -> 0.0.0.0:5432\n5432/tcp -> [::]:5432\n' >"$F/port.con-x-db"
printf '3333/tcp -> 0.0.0.0:3333\n' >"$F/port.con-web"
printf '5432/tcp -> 127.0.0.1:5432\n' >"$F/port.con-lo"
printf '3333/tcp -> 0.0.0.0:3333\n' >"$F/port.con-raw"
# config_files relative to the caller's cwd, as compose records it with --project-directory
printf 'src/docker/compose.yaml|%s|docker|db\n' "$P" >"$F/labels.con-x-db"
printf 'compose.yaml|%s|web|web\n' "$W" >"$F/labels.con-web"
printf '|||\n' >"$F/labels.con-raw"
printf '/con-x-db|img-x-db|/var/x/db |["DB_PASS=pw-default","PATH=/bin"]\n' >"$F/live.con-x-db"
printf '/con-web|img-web||["PATH=/bin"]\n' >"$F/live.con-web"

cat >"$T/stub/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_LOG"
case "$1" in
  ps) cat "$FAKE/names" ;;
  port) cat "$FAKE/port.$2" 2>/dev/null ;;
  inspect) if [[ "$3" == *config_files* ]]; then cat "$FAKE/labels.$4"; else cat "$FAKE/live.$4"; fi ;;
  compose)
    shift; proj="" file="" wd=""
    while [[ $# -gt 0 ]]; do case "$1" in -p) proj="$2"; shift 2 ;; -f) file="$2"; shift 2 ;; --project-directory) wd="$2"; shift 2 ;; *) break ;; esac; done
    case "$1" in
      config) python3 "$FAKE/render.py" "$file" "$wd" ;;
      up) svc="${!#}"; python3 "$FAKE/render.py" "$file" "$wd" | python3 -c '
import json, sys
s = json.load(sys.stdin)["services"][sys.argv[1]]
for p in s.get("ports", []):
    print(str(p["target"]) + "/tcp -> " + (p.get("host_ip") or "0.0.0.0") + ":" + p["published"])' "$svc" >"$FAKE/port.$(python3 "$FAKE/render.py" "$file" "$wd" | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"][sys.argv[1]]["container_name"])' "$svc")" ;;
    esac ;;
esac
STUB
cat >"$F/render.py" <<'PY'
import json, os, re, sys, yaml
path, wd = sys.argv[1:3]
env = dict(os.environ)
def ex(s):
    if not isinstance(s, str): return s
    while True:
        t = re.sub(r"\$\{(\w+)(:?-([^{}]*))?\}", lambda m: env.get(m.group(1)) or (m.group(3) or ""), s)
        if t == s: return t
        s = t
d = yaml.safe_load(open(path))
out = {}
for n, s in d["services"].items():
    o = {"container_name": ex(s.get("container_name", "")), "image": ex(s.get("image", ""))}
    o["environment"] = {k: ex(v) for k, v in (s.get("environment") or {}).items()}
    o["volumes"] = [{"type": "bind", "source": ex(v).split(":")[0]} for v in s.get("volumes", [])]
    ports = []
    for p in s.get("ports", []):
        parts = ex(p).split(":")
        q = {"target": int(parts[-1]), "published": parts[-2]}
        if len(parts) == 3: q["host_ip"] = parts[0]
        ports.append(q)
    o["ports"] = ports
    out[n] = o
print(json.dumps({"services": out}))
PY
chmod +x "$T/stub/docker"
bp() { SNIPPET="${SNIP:-do_spl_box_ports_loopback}" in_orc FAKE="$F" PORTS_LOOPBACK_UNDO="$T/undo" "$@" >"$T/o" 2>&1; }

# --- 1. refusals -------------------------------------------------------------------------------
bp DRY_RUN=2 && fail "accepts DRY_RUN=2" || pass "refuses DRY_RUN=2"
bp PORTS_LOOPBACK='5432;x' && fail "accepts a bad PORTS_LOOPBACK" || pass "refuses a non-numeric PORTS_LOOPBACK"

# --- 2. DRY_RUN default ------------------------------------------------------------------------
: >"$T/calls.log"
bp ORG=x; rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL DRY_RUN 3 container port(s) off loopback, 2 ready" "$T/o" &&
  pass "dry run: 3 off loopback, 2 ready (the refusals fail the run)" || fail "dry run verdict: rc=$rc $(cat "$T/o")"
grep -qF "change $P/compose.yaml:15: - \"5432:5432\"   # the db  ->  - \"127.0.0.1:5432:5432\"   # the db" "$T/o" &&
  pass "dry run: the exact line change (depends_on db: skipped, comment kept, label path resolved)" || fail "dry run db change: $(cat "$T/o")"
grep -qF "change $W/compose.yaml:6: - '\${WEB_PORT:-3333}:3333'  ->  - '127.0.0.1:\${WEB_PORT:-3333}:3333'" "$T/o" &&
  pass "dry run: a \${VAR:-default} item keeps its variable and quote" || fail "dry run web change: $(cat "$T/o")"
grep -q "compose file $P/compose.yaml, project docker, service db" "$T/o" && grep -q "^container con-x-db port 5432: published off loopback (0.0.0.0:5432 \[::\]:5432)" "$T/o" &&
  pass "dry run: names the container, its binds, compose file, project, service" || fail "dry run names: $(cat "$T/o")"
! grep -q "con-lo" "$T/o" && pass "a loopback-only container is skipped" || fail "loopback container listed"
grep -A1 "^container con-raw" "$T/o" | grep "REFUSED: not started by docker compose" >/dev/null &&
  pass "a container not from compose is refused" || fail "raw container: $(cat "$T/o")"
cmp -s "$P/compose.yaml" "$T/app.orig" && cmp -s "$W/compose.yaml" "$T/web.orig" && ! grep -q "compose .* up" "$T/calls.log" && [[ ! -e $T/undo ]] &&
  pass "dry run: no file edited, no compose up, no undo dir" || fail "dry run changed something"

# --- 3. drift without the project's env --------------------------------------------------------
printf 'con-x-db\n' >"$F/names"
bp ORG=
grep -q "recreate: REFUSED: the rendered service differs from the live container: container name con--db != live con-x-db" "$T/o" &&
  grep -q "bind mounts \['/var//db'\] != live \['/var/x/db'\]" "$T/o" &&
  pass "drift: a blank \${ORG} moves the name and the data mount -> recreate refused" || fail "drift: $(cat "$T/o")"
bp ORG=x DB_PASS=other-secret-value
grep -q "environment differs (names only): DB_PASS" "$T/o" && ! grep -q "other-secret-value\|pw-default" "$T/o" &&
  pass "drift: a differing env value is named, never printed" || fail "env drift: $(cat "$T/o")"

# --- 4. DRY_RUN=0 with the env -----------------------------------------------------------------
printf 'con-x-db\ncon-web\ncon-lo\n' >"$F/names"
: >"$T/calls.log"
bp ORG=x DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK ports off loopback: 2 moved to 127.0.0.1" "$T/o" &&
  pass "applied: 2 moved to 127.0.0.1" || fail "apply: rc=$rc $(cat "$T/o")"
diff <(sed 's/"5432:5432"/"127.0.0.1:5432:5432"/' "$T/app.orig") "$P/compose.yaml" >/dev/null &&
  pass "applied: exactly the one line changed in the compose file" || fail "apply diff: $(diff "$T/app.orig" "$P/compose.yaml")"
cmp -s "$T/undo/docker.db.compose.yaml" "$T/app.orig" && cmp -s "$T/undo/web.web.compose.yaml" "$T/web.orig" &&
  pass "applied: the old files are in the undo dir" || fail "undo: $(ls -la "$T/undo")"
[[ "$(grep -c 'compose .* up' "$T/calls.log")" == 2 ]] && grep -q "up -d --no-deps --no-build db$" "$T/calls.log" &&
  grep -q "up -d --no-deps --no-build web$" "$T/calls.log" &&
  pass "applied: compose up --no-deps --no-build for those services only" || fail "up calls: $(cat "$T/calls.log")"
[[ "$(cat "$F/port.con-x-db")" == "5432/tcp -> 127.0.0.1:5432" ]] && grep -q "^OK con-x-db: port 5432 now on 127.0.0.1 only" "$T/o" &&
  pass "applied: the port is on 127.0.0.1 only afterwards" || fail "port after: $(cat "$F/port.con-x-db")"
bp ORG=x DRY_RUN=0
grep -q "^OK no container publishes 5432, 3333 off loopback: nothing to do" "$T/o" && pass "second run: nothing to do" || fail "rerun: $(cat "$T/o")"

# --- 5. CONTROL: an edit without 127.0.0.1 ----------------------------------------------------
cp "$T/app.orig" "$P/compose.yaml"; printf '5432/tcp -> 0.0.0.0:5432\n' >"$F/port.con-x-db"; printf 'con-x-db\n' >"$F/names"
: >"$T/calls.log"
SNIP='eval "$(declare -f spl_bpl_edit | sed "s/new_item = \"127.0.0.1:\" + item$/new_item = item/")"; do_spl_box_ports_loopback' bp ORG=x DRY_RUN=0 &&
  fail "CONTROL: an edit without 127.0.0.1 passes: $(cat "$T/o")" ||
  { grep -q "rendered port 5432 is not on 127.0.0.1 only" "$T/o" && cmp -s "$P/compose.yaml" "$T/app.orig" && ! grep -q "compose .* up" "$T/calls.log" &&
    pass "CONTROL: an edit without 127.0.0.1 is refused, nothing edited, no up" || fail "CONTROL: $(cat "$T/o")"; }

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
