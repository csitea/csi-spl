#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1960 (security round 1, row 3): a container port this box
# @description publishes on every interface (0.0.0.0 / [::]) is published on
# @description 127.0.0.1 only. Per port in PORTS_LOOPBACK, per running
# @description container that publishes it off loopback, it names:
# @description   - the container, its compose file, project and service
# @description   - the exact change: <file>:<line>: <old>  ->  <new>, the ports
# @description     item prefixed with 127.0.0.1: (quoting and ${VAR} kept)
# @description   - the recreate verdict: the compose config rendered from the
# @description     EDITED file (env + the project's .env) must give the SAME
# @description     container name, image, bind-mount sources and environment
# @description     (compared by value, reported by name only) as the live
# @description     container. A blank ${VAR} would move a bind mount (a DB data
# @description     dir) to a new empty path, so any drift REFUSES the recreate
# @description     and says which; export the project's env and run again.
# @description DRY_RUN=0, per container that passed: the old file is copied to
# @description the undo dir, the line is replaced, then
# @description   docker compose -p <project> -f <file> --project-directory <wd>
# @description     up -d --no-deps --no-build <service>
# @description recreates that ONE service, and docker port must then show the
# @description port on 127.0.0.1 only. Nothing else is restarted. A container
# @description that is not from compose, or whose item cannot be found, is
# @description named and left alone (exit 1). Dry run unless DRY_RUN=0.
# @param PORTS_LOOPBACK (optional) - host ports, default "5432 3333"
# @param PORTS_LOOPBACK_UNDO (optional) - the undo dir on DRY_RUN=0, default $HOME/.local/state/csi-spl/ports-loopback-undo/<UTC stamp>
# @param DOCKER_BIN (optional) - default docker
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_box_ports_loopback
# @example DRY_RUN=0 ./run -a do_spl_box_ports_loopback
#------------------------------------------------------------------------------
do_spl_box_ports_loopback() {
  local ports="${PORTS_LOOPBACK:-5432 3333}" dk="${DOCKER_BIN:-docker}" apply=1 p c n=0 todo=0 bad=0 undo plan
  if spl_dry_run; then apply=0; else local drc=$?; [[ $drc -eq 1 ]] || return 1; fi
  [[ "$ports" =~ ^[0-9\ ]+$ ]] || { do_log "FATAL PORTS_LOOPBACK must be host port numbers, got: '$ports'"; return 1; }
  undo="${PORTS_LOOPBACK_UNDO:-$HOME/.local/state/csi-spl/ports-loopback-undo/$(date -u +%Y%m%dT%H%M%SZ)}"
  for p in $ports; do
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      "$dk" port "$c" 2>/dev/null | grep -E -- "-> (0\.0\.0\.0|\[::\]|[0-9a-f.:\[\]]+):$p\$" >/dev/null || continue
      "$dk" port "$c" 2>/dev/null | grep -E -- "-> .*:$p\$" | grep -vE -- '-> (127\.0\.0\.1|\[::1\]):' >/dev/null || continue
      n=$((n + 1))
      plan="$(spl_bpl_plan "$dk" "$c" "$p")"; local prc=$?
      printf '%s\n' "$plan"
      if (( prc != 0 )); then bad=1; continue; fi
      todo=$((todo + 1))
      (( apply )) || continue
      spl_bpl_apply "$dk" "$c" "$p" "$undo" "$plan" || bad=1
    done < <("$dk" ps --format '{{.Names}}' | sort)
  done
  if (( n == 0 )); then do_log "OK no container publishes ${ports// /, } off loopback: nothing to do"; return 0; fi
  if (( apply )); then
    (( bad )) && { do_log "FAIL ports off loopback: $n found, not all moved to 127.0.0.1 (see above; undo copies in $undo)"; return 1; }
    do_log "OK ports off loopback: $n moved to 127.0.0.1 (old compose files in $undo)"; return 0
  fi
  (( bad )) && { do_log "FAIL DRY_RUN $n container port(s) off loopback, $todo ready; the others are refused above"; return 1; }
  do_log "OK DRY_RUN $n container port(s) off loopback, all ready. Re-run with DRY_RUN=0 to apply (recreates those services only)."
}

# spl_bpl_labels <docker> <container> -> "<config file>|<working dir>|<project>|<service>"
spl_bpl_labels() {
  "$1" inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}' "$2"
}

# spl_bpl_file <config file label> <working dir> -> its absolute path. A
# relative label is relative to where compose was started, which is the
# working dir or, with --project-directory, a parent of it.
spl_bpl_file() {
  local f="$1" wd="$2" sub
  [[ "$f" == /* ]] && { echo "$f"; return 0; }
  sub="$(dirname "$f")"
  if [[ ! -f "$wd/$f" && "$sub" != . && "$wd" == */"$sub" ]]; then echo "${wd%/"$sub"}/$f"; else echo "$wd/$f"; fi
}

# spl_bpl_plan <docker> <container> <port> -> the rows for one container: the
# change line ("change <file>:<line>: <old>  ->  <new>") and the recreate
# verdict. Exit 1 when it cannot be applied safely.
spl_bpl_plan() {
  local dk="$1" c="$2" p="$3" lab file wd proj svc edit rc
  lab="$(spl_bpl_labels "$dk" "$c")"
  IFS='|' read -r file wd proj svc <<<"$lab"
  echo "container $c port $p: published off loopback ($("$dk" port "$c" | grep -E -- "-> .*:$p\$" | sed 's/.*-> //' | tr '\n' ' ' | sed 's/ $//'))"
  if [[ -z "$file" || -z "$svc" ]]; then echo "  REFUSED: not started by docker compose (no compose labels): recreate it by hand"; return 1; fi
  [[ "$file" == *,* ]] && { echo "  REFUSED: started from several compose files ($file): edit by hand"; return 1; }
  file="$(spl_bpl_file "$file" "$wd")"
  echo "  compose file $file, project $proj, service $svc"
  edit="$(spl_bpl_edit "$file" "$svc" "$p" "$wd" "")"; rc=$?
  printf '%s\n' "$edit" | sed 's/^/  /'
  (( rc == 0 )) || return 1
  spl_bpl_same "$dk" "$c" "$file" "$wd" "$proj" "$svc" "$p" | sed 's/^/  /'
  return "${PIPESTATUS[0]}"
}

# spl_bpl_edit <file> <service> <port> <working dir> <out file or ""> -> the
# "change <file>:<line>: <old>  ->  <new>" row; with an out file, writes the
# edited compose file there. Exit 1 when the item is not found or ambiguous.
spl_bpl_edit() {
  python3 - "$@" <<'PY'
import os, re, sys
path, svc, port, wd, out = sys.argv[1:6]
try:
    lines = open(path).read().split("\n")
except OSError as e:
    print(f"REFUSED: cannot read {path}: {e.strerror}"); sys.exit(1)
dotenv = {}
try:
    for l in open(os.path.join(wd, ".env")):
        m = re.match(r"\s*(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(.*?)\s*$", l)
        if m: dotenv[m.group(1)] = m.group(2).strip("'\"")
except OSError:
    pass
def expand(s):
    def one(m):
        name, dflt = m.group(1), m.group(3)
        v = os.environ.get(name, dotenv.get(name))
        if v in (None, "") and dflt is not None: return dflt
        return v or ""
    while True:  # innermost first: ${A:-${B}} nests
        t = re.sub(r"\$\{(\w+)(:?-([^{}]*))?\}", one, s)
        if t == s: return t
        s = t
def indent(l): return len(l) - len(l.lstrip(" "))
# the service block, then its ports list
i, n, start = 0, len(lines), None
for i, l in enumerate(lines):
    if re.match(r"^\s*services:\s*$", l): start = i; break
if start is None: print("REFUSED: no services: in the compose file"); sys.exit(1)
# a service key sits at the indent of the first key under services:
svi = next((indent(l) for l in lines[start + 1:] if l.strip() and not l.lstrip().startswith("#")), 0)
sv = None
for i in range(start + 1, n):
    l = lines[i]
    if l.strip() and not l.lstrip().startswith("#") and indent(l) < svi: break
    if indent(l) == svi and re.match(r"^\s*" + re.escape(svc) + r":\s*$", l): sv = i; break
if sv is None: print(f"REFUSED: no service {svc} in the compose file"); sys.exit(1)
end = n
for i in range(sv + 1, n):
    if lines[i].strip() and not lines[i].lstrip().startswith("#") and indent(lines[i]) <= svi: end = i; break
hits = []
in_ports, pi = False, None
for i in range(sv + 1, end):
    l = lines[i]
    if not l.strip() or l.lstrip().startswith("#"): continue
    m = re.match(r"^(\s*)ports:\s*$", l)
    if m: in_ports, pi = True, len(m.group(1)); continue
    if in_ports and indent(l) <= pi: in_ports = False
    if not in_ports: continue
    m = re.match(r'^(\s*-\s*)(["\']?)([^"\'#]+?)\2(\s*(#.*)?)$', l)
    if not m: continue
    item = m.group(3)
    parts = expand(item).split(":")
    if len(parts) == 2 and parts[0] == port:
        hits.append((i, m))
    elif len(parts) == 3 and parts[1] == port and parts[0] not in ("127.0.0.1", "[::1]"):
        hits.append((i, m))
if len(hits) != 1:
    print(f"REFUSED: {len(hits)} ports items of service {svc} publish host port {port} (want exactly 1): edit by hand"); sys.exit(1)
i, m = hits[0]
item = m.group(3)
parts = expand(item).split(":")
if len(parts) == 3:
    new_item = "127.0.0.1:" + item.split(":", 1)[1] if ":" in item and not item.startswith("${") else None
    if new_item is None:
        print(f"REFUSED: the host ip of '{item}' comes from a variable: edit by hand"); sys.exit(1)
else:
    new_item = "127.0.0.1:" + item
q = m.group(2) or '"'
new = f"{m.group(1)}{q}{new_item}{q}{m.group(4)}"
print(f"change {path}:{i + 1}: {lines[i].strip()}  ->  {new.strip()}")
if out:
    lines[i] = new
    open(out, "w").write("\n".join(lines))
PY
}

# spl_bpl_same <docker> <container> <file> <wd> <project> <service> <port>:
# render the EDITED file and compare it with the live container. Exit 1 on drift.
spl_bpl_same() {
  local dk="$1" c="$2" file="$3" wd="$4" proj="$5" svc="$6" p="$7" tmp js live bad=0
  tmp="$(mktemp -d)"
  spl_bpl_edit "$file" "$svc" "$p" "$wd" "$tmp/compose.yaml" >/dev/null || { rm -rf "$tmp"; echo "recreate: REFUSED (no edit)"; return 1; }
  if ! js="$("$dk" compose -p "$proj" -f "$tmp/compose.yaml" --project-directory "$wd" config --format json 2>"$tmp/err")"; then
    echo "recreate: REFUSED: docker compose config fails on the edited file: $(grep -v 'level=warning' "$tmp/err" | sed -n 1,2p | tr '\n' ' ')"
    local unset
    unset="$(grep -o 'The \\"[A-Za-z_0-9]*\\" variable is not set' "$tmp/err" | sed 's/The \\"\(.*\)\\".*/\1/' | sort -u | tr '\n' ' ')"
    [[ -n "$unset" ]] && echo "  unset variables: ${unset% }"
    rm -rf "$tmp"; return 1
  fi
  live="$("$dk" inspect -f '{{.Name}}|{{.Config.Image}}|{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}|{{json .Config.Env}}' "$c")"
  rm -rf "$tmp"
  python3 -c '
import json, sys
svc, proj, live, port = sys.argv[1:5]
d = json.loads(sys.stdin.read())["services"].get(svc)
if d is None: print("recreate: REFUSED: the rendered config has no service " + svc); sys.exit(1)
lname, limg, lmnt, lenv = live.split("|", 3)
lenv = dict(e.split("=", 1) for e in json.loads(lenv or "[]") if "=" in e)
envd = [k for k, v in sorted((d.get("environment") or {}).items()) if v is not None and lenv.get(k) != str(v)]
lname = lname.lstrip("/")
name = d.get("container_name") or f"{proj}-{svc}-1"
mnt = sorted(v["source"] for v in d.get("volumes", []) if v.get("type") == "bind")
pub = [x for x in d.get("ports", []) if str(x.get("published")) == port]
bad = []
if name != lname: bad.append(f"container name {name} != live {lname}")
img = d.get("image") or ""
if img and img != limg: bad.append(f"image {img} != live {limg}")
if mnt != sorted(lmnt.split()): bad.append(f"bind mounts {mnt} != live {sorted(lmnt.split())}")
if envd: bad.append("environment differs (names only): " + " ".join(envd))
if not pub or any(x.get("host_ip") != "127.0.0.1" for x in pub): bad.append(f"rendered port {port} is not on 127.0.0.1 only: {pub}")
if bad:
    print("recreate: REFUSED: the rendered service differs from the live container: " + "; ".join(bad)); sys.exit(1)
print(f"recreate: ok: docker compose -p {proj} -f <file> up -d --no-deps --no-build {svc} keeps name {name}, image, {len(mnt)} bind mount(s)")
' "$svc" "$proj" "$live" "$p" <<<"$js" || bad=1
  return "$bad"
}

# spl_bpl_apply <docker> <container> <port> <undo dir> <plan>: back up, edit,
# recreate the one service, prove the port is on loopback only.
spl_bpl_apply() {
  local dk="$1" c="$2" p="$3" undo="$4" lab file wd proj svc
  lab="$(spl_bpl_labels "$dk" "$c")"
  IFS='|' read -r file wd proj svc <<<"$lab"
  file="$(spl_bpl_file "$file" "$wd")"
  local old
  old="$undo/$proj.$svc.$(basename "$file")"
  if ! { mkdir -p "$undo" && cp -p "$file" "$old"; }; then echo "FAIL $c: cannot back up $file to $undo"; return 1; fi
  if ! { spl_bpl_edit "$file" "$svc" "$p" "$wd" "$undo/.new" >/dev/null && cat "$undo/.new" >"$file" && rm -f "$undo/.new"; }; then
    echo "FAIL $c: cannot write $file"; return 1
  fi
  if ! "$dk" compose -p "$proj" -f "$file" --project-directory "$wd" up -d --no-deps --no-build "$svc"; then
    cat "$old" >"$file"
    echo "FAIL $c: docker compose up failed: the old compose file is back in place"; return 1
  fi
  if "$dk" port "$c" 2>/dev/null | grep -E -- "-> .*:$p\$" | grep -vE -- '-> 127\.0\.0\.1:' >/dev/null; then
    echo "FAIL $c: port $p is still published off loopback after the recreate"; return 1
  fi
  echo "OK $c: port $p now on 127.0.0.1 only"
}
