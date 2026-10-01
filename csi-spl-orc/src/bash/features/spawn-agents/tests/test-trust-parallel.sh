#!/usr/bin/env bash
# test-trust-parallel.sh — N parallel spawns all start TRUSTED (CLE-77829).
#
# 2026-10-01: 2 of 8 parallel spawns stopped on claude's "Is this a project you
# trust?" prompt. trust-workdir.sh locks its own edit, but a STARTING claude
# reads ~/.claude.json and later writes the whole file back, unlocked, so the
# trust entry a sibling spawn added in between is lost. Here a fake claude does
# exactly that (read -> note whether its dir is trusted -> sleep -> write back
# what it read), N spawns run in parallel against one throwaway HOME, and:
#   1. with --settle every fake claude read its dir as trusted
#   2. ... and every dir is still trusted in the store at the end
#   3. --settle exits 3 (NOT VERIFIED) when the entry can never be written
#   4. without --settle the same race is shown (informational: it is timing)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"

N="${TRUST_TEST_N:-8}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/fake-claude.py"
cat >"$FAKE" <<'PY'
import json, os, random, sys, time
target, out = sys.argv[1], sys.argv[2]
time.sleep(random.uniform(0, 0.6))  # the CLI's own start-up before it reads
path = os.path.join(os.environ["HOME"], ".claude.json")
with open(path) as fh:
    doc = json.load(fh)
ok = bool(doc.get("projects", {}).get(target, {}).get("hasTrustDialogAccepted"))
with open(out, "a") as fh:
    fh.write("%s %s\n" % (target, "trusted" if ok else "PROMPT"))
time.sleep(0.3)                      # claude's startup, then its whole-file write
doc["numStartups"] = doc.get("numStartups", 0) + 1
tmp = path + ".fake.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(doc, fh)
os.replace(tmp, path)
PY

batch() {  # <home> <settle-flag or empty> -> results in <home>/reads
  local H="$1" flag="$2" i
  mkdir -p "$H"; echo '{"projects": {}}' >"$H/.claude.json"; : >"$H/reads"
  for i in $(seq "$N"); do
    mkdir -p "$H/wt/w$i"
    ( HOME="$H" TRUST_SETTLE_SECS=1.5 bash "$T_SCRIPTS/trust-workdir.sh" $flag "$H/wt/w$i" "$(id -un)" claude >/dev/null 2>&1 \
        && HOME="$H" python3 "$FAKE" "$H/wt/w$i" "$H/reads" ) &
  done
  wait
  # let the last settler release its lock
  sleep 2
}

H="$TMP/settle"
batch "$H" --settle
eq "1. --settle: all $N parallel spawns read their dir as trusted" "$N" "$(grep -c ' trusted$' "$H/reads")"
stored="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for v in d["projects"].values() if v.get("hasTrustDialogAccepted")))' "$H/.claude.json")"
eq "2. --settle: all $N dirs still trusted in the store afterwards" "$N" "$stored"

# 3. an entry that cannot be written (read-only store) must not pass as verified
H3="$TMP/ro"; mkdir -p "$H3/wt/x"; echo '{"projects": {}}' >"$H3/.claude.json"
chmod 0444 "$H3/.claude.json"; chmod 0555 "$H3"
rc=0; HOME="$H3" TRUST_SETTLE_SECS=1 bash "$T_SCRIPTS/trust-workdir.sh" --settle "$H3/wt/x" "$(id -un)" claude >/dev/null 2>&1 || rc=$?
chmod 0755 "$H3"; chmod 0644 "$H3/.claude.json"
eq "3. --settle: an entry that never reads back -> exit 3 (NOT VERIFIED)" 3 "$rc"

H4="$TMP/plain"
batch "$H4" ""
lost="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for v in d["projects"].values() if not v.get("hasTrustDialogAccepted")) + int(sys.argv[2]) - len(d["projects"]))' "$H4/.claude.json" "$N")"
echo "info - 4. without --settle: $(grep -c ' PROMPT$' "$H4/reads") of $N fake claudes hit the trust prompt, $lost of $N entries lost from the store"

t_done
