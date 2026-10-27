#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the public dataset gate (spec 091 T005, sections 5.5 and 5.6; spec
# 9.3 "the gate catches plants"). Synthetic rows only: the fixture
# fixtures/public-dataset/gate/clean.sql (one workspace, 100 messages) and
# names.tsv (two made-up other workspaces and the built-in id system). Every secret-shaped plant is built
# here at run time, never written whole in the repo.
#   Part 1 (hermetic, the core src/bash/scripts/public-dataset-gate.py):
#     1. the clean candidate passes and the cleaned file is the input
#     2. C4 non-body: an e-mail, a JWT, a PEM block, another workspace's name
#        (also as a channel key), each FATAL, nothing cleaned
#     3. C4 body: each pattern class drops its message and counts it; the
#        second scan is clean; whole words only; 1 % dropped passes, 2 % fails
#     4. C3: an extra column, a never-exported table, a non-COPY line, an
#        unclassified live column, a constant that is not constant (msg, env),
#        an allow-list table with no COPY block
#     5. C1 / MEMBER / C2: an extra workspace row, a foreign tenant_id, a real
#        name or an e-mail on a member, a HUM-n not exported, a row the RLS
#        re-read does not see, a key twice in a table; several listed
#        workspaces (SPL-3808): a row per listed workspace, every block names
#        its workspace, the same channel id in two of them, matched by
#        (workspace, key)
#     6. SIZE: beyond the tolerance fails; no previous file or a new
#        allow-list version skips it; a table in the previous counts and
#        gone from the file counts as 0 rows
#     7. log capture: no planted string appears in any gate output or report
#   Part 2 (a REAL throwaway Postgres migrated by the repo's migrations, the
#   action do_spl_public_dataset_gate as the real spool_public_export login):
#     8. the clean candidate passes through the action
#     9. ALTER TABLE ... ADD COLUMN that the allow-list does not list: FATAL C3
#    10. a row of ANOTHER workspace forged to the exported id: FATAL C2 (the
#        RLS re-read does not see it)
#    11. a superuser DSN is refused (a re-read by it is not "RLS alone")
#    12. two listed workspaces with the SAME channel id: the action re-reads
#        each one and passes; the cnf listing only one of them fails C1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in yq jq python3; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done

FIX="$TEST_DIR/fixtures/public-dataset/gate"
CORE="$PROJ_ROOT/src/bash/scripts/public-dataset-gate.py"
FUNC="$PROJ_ROOT/src/bash/run/spl-public-dataset-gate.func.sh"
ALLOW_YAML="$PROJ_ROOT/cnf/public-dataset/allow-list.v1.yaml"
WS=ws-pub
mkdir -p "$T/bin"
if command -v gitleaks >/dev/null; then
  GL="$(command -v gitleaks)"
else
  # no gitleaks here: a stub that reports nothing, so case 3's gitleaks-only
  # plant is not proven on this runner (said in the output, never a SKIP)
  printf '#!/bin/sh\nfor a; do p="$r"; r="$a"; [ "$p" = --report-path ] && echo "[]" >"$a"; done\nexit 0\n' >"$T/bin/gitleaks"
  chmod +x "$T/bin/gitleaks"; GL="$T/bin/gitleaks"
  echo "INFO: no gitleaks on this runner: a stub stands in, the gitleaks-only plant is not checked"
fi
for f in "$FUNC" "$CORE" "$PROJ_ROOT/src/bash/run/spl-public-dataset-names.func.sh"; do
  [[ -s "$f" ]] && pass "the gate code file $(basename "$f") exists" || fail "the gate code file $f is missing"
done
grep -nE 'set -x|SELECT \*|pg_dump' "$FUNC" "$CORE" "$PROJ_ROOT/src/bash/run/spl-public-dataset-names.func.sh" | grep -v '^\S*:[0-9]*:#' >/dev/null \
  && fail "the gate or names code traces (set -x), selects * or dumps" || pass "no set -x, SELECT * or pg_dump in the gate and names code"

yq -o=json . "$ALLOW_YAML" >"$T/allow.json"
python3 -c 'import json, sys; a = json.load(open(sys.argv[1]))
json.dump({t: s["public"] + s["withheld"] for t, s in a["tables"].items()}, open(sys.argv[2], "w"))' "$T/allow.json" "$T/catalog.json"
reread_of() { # <candidate.sql> <out.json>: every [workspace, key] of the file, as the pinned re-reads would return them
  python3 - "$1" "$2" "${WSL:-$WS}" <<'PY'
import json, sys
keys = {"tenants": "tenant_id", "tenant_memberships": "human_id", "channels": "channel_id", "messages": "msg_id"}
out, t, cols = {k: [] for k in keys}, None, []
for line in open(sys.argv[1]).read().splitlines():
    if line.startswith("COPY "):
        t = line.split()[1]; cols = [c.strip() for c in line[line.index("(") + 1:line.index(")")].split(",")]; continue
    if line == "\\.":
        t = None; continue
    if t in keys:
        f = dict(zip(cols, line.split("\t")))
        out[t].append([f.get("tenant_id", sys.argv[3].split(",")[0]), f[keys[t]]])
json.dump(out, open(sys.argv[2], "w"))
PY
}

# mk <name> [op ...]: <name>.sql = clean.sql with the ops applied; each plant
# goes into $T/plants too (the log-capture list). Ops:
#   body:<n>:<plant>         message n's body (and its msg object) holds the plant
#   set:<table>:<row>:<col>:<plant or literal>
#   col:<table>:<col>:<value> an extra column with that value on every row
#   row:<table>:<tsv with \t> one more row
#   line:<text>              one more line at the end
#   drop:<table>             the table's whole COPY block removed
# A plant is P(<kind>), built here: email jwt pem aws slack github sa ipv4
# ipv6 stripe name.
mk() {
  local name="$1"; shift
  python3 - "$FIX/clean.sql" "$T/$name.sql" "$T/plants" "$@" <<'PY'
import base64, json, re, sys
src, out, plants, ops = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
b64 = lambda s: base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")
P = {"email": "plant.person" + "@" + "example.org",
     "jwt": b64('{"alg":"HS256","typ":"JWT"}') + "." + b64('{"sub":"plant-jwt-1234567890"}') + "." + "c2lnbmF0dXJlLXBsYW50LXh5eg",
     "pem": "-----BEGIN " + "RSA PRIVATE KEY-----",
     "aws": "AK" + "IA" + "QZPLANTXQZPLANTX",
     "slack": "xo" + "xb-" + "1234567890-plantplantplant",
     "github": "gh" + "p_" + "PlantPlantPlantPlantPlantPlantPlant12",
     "sa": "projects/plant-proj/serviceAccounts/plant-robot.iam." + "gserviceaccount.com",
     "ipv4": "10.203.44.17", "ipv6": "fd12:3456:789a:1::42",
     "stripe": "sk_" + "live_" + "Pl4ntPl4ntPl4ntPl4ntPl4nt99",
     "name": "Quokkaville"}
def val(v):
    m = re.fullmatch(r"P\((\w+)\)", v)
    if not m:
        return v
    p = P[m.group(1)]
    with open(plants, "a") as fh:
        fh.write(p + "\n")
    return "seen " + p + " here" if m.group(1) != "name" or v != "P(name)" else p
lines = open(src).read().split("\n")
def block(t):
    h = next(i for i, l in enumerate(lines) if l.startswith("COPY %s (" % t))
    e = next(i for i in range(h, len(lines)) if lines[i] == "\\.")
    return h, e
for op in ops:
    kind, rest = op.split(":", 1)
    if kind == "body":
        n, v = rest.split(":", 1); h, _ = block("messages"); i = h + int(n)
        f = lines[i].split("\t"); f[8] = val(v)
        m = json.loads(f[12]); m["body"] = f[8]; f[12] = json.dumps(m, separators=(",", ":"))
        lines[i] = "\t".join(f)
    elif kind == "set":
        t, n, c, v = rest.split(":", 3); h, _ = block(t)
        cols = [x.strip() for x in lines[h][len("COPY %s (" % t):-len(") FROM stdin;")].split(",")]
        f = lines[h + int(n)].split("\t"); f[cols.index(c)] = val(v) if v.startswith("P(") else v
        lines[h + int(n)] = "\t".join(f)
    elif kind == "col":
        t, c, v = rest.split(":", 2); h, e = block(t)
        lines[h] = lines[h].replace(") FROM stdin;", ", %s) FROM stdin;" % c)
        for i in range(h + 1, e):
            lines[i] += "\t" + v
    elif kind == "row":
        t, v = rest.split(":", 1); _, e = block(t); lines.insert(e, v.replace("\\t", "\t"))
    elif kind == "line":
        lines.insert(len(lines) - 1, rest)
    elif kind == "drop":
        h, e = block(rest); del lines[h:e + 1]
open(out, "w").write("\n".join(lines))
PY
}

# gate <name> [extra core args]: the core on $T/<name>.sql; rc in $T/<name>.rc
gate() {
  local name="$1"; shift
  [[ -s "$T/$name.reread.json" ]] || reread_of "$T/$name.sql" "$T/$name.reread.json"
  python3 "$CORE" --file "$T/$name.sql" --allow-list "${ALLOW:-$T/allow.json}" --catalog "${CATALOG:-$T/catalog.json}" \
    --reread "$T/$name.reread.json" --names "$FIX/names.tsv" --workspace "${WSL:-$WS}" --out "$T/$name.out.sql" \
    --report "$T/$name.report.json" --drop-cap-pct 1 --size-tol-pct 50 --gitleaks "$GL" \
    --gitleaks-config "$APP_ROOT/.gitleaks.toml" "$@" >"$T/$name.log" 2>&1
  echo $? >"$T/$name.rc"
}
rc_of() { cat "$T/$1.rc"; }
# fatal <label> <name> <needle>: FAIL, the class line, no cleaned file
fatal() {
  [[ "$(rc_of "$2")" == 1 && ! -e "$T/$2.out.sql" ]] && grep -q -- "$3" "$T/$2.log" &&
    [[ "$(jq -r .result "$T/$2.report.json")" == FAIL ]] \
    && pass "$1" || fail "$1: rc=$(rc_of "$2") $(cat "$T/$2.log")"
}
# dropped <label> <name> <class> <n>: PASS with n messages removed under class
dropped() {
  [[ "$(rc_of "$2")" == 0 && "$(jq -r --arg c "$3" '.removed_by_class[$c] // 0' "$T/$2.report.json")" == "$4" &&
     "$(jq -r .row_counts.messages "$T/$2.report.json")" == "$((100 - $4))" &&
     "$(grep -c '^00000000-0000-4000-8000' "$T/$2.out.sql")" == "$((100 - $4))" ]] \
    && pass "$1" || fail "$1: rc=$(rc_of "$2") $(cat "$T/$2.log") $(cat "$T/$2.report.json" 2>/dev/null)"
}

# --- 1. clean ----------------------------------------------------------------------
cp "$FIX/clean.sql" "$T/clean.sql"; gate clean
[[ "$(rc_of clean)" == 0 ]] && cmp -s "$T/clean.out.sql" "$FIX/clean.sql" && grep -q '^PASS gate: 0 fatal' "$T/clean.log" &&
  [[ "$(jq -c .row_counts "$T/clean.report.json")" == '{"channels":2,"humans":2,"messages":100,"tenant_memberships":2,"tenants":1}' ]] &&
  [[ "$(jq -r .sha256 "$T/clean.report.json")" == "$(sha256sum "$FIX/clean.sql" | cut -d' ' -f1)" ]] \
  && pass "1. a clean candidate passes; the cleaned file is the input; counts and sha256 in the report" || fail "1. clean: $(cat "$T/clean.log")"
gate clean
[[ "$(rc_of clean)" == 2 ]] && grep -q 'never overwrites' "$T/clean.log" && pass "1. an existing cleaned file is never overwritten" || fail "1. overwrite: $(cat "$T/clean.log")"

# --- 2. C4 outside a body: FATAL ----------------------------------------------------
mk email 'set:channels:1:description:P(email)'; gate email
fatal "2. an e-mail in a channel description is FATAL" email 'FATAL C4 channels channel_id=dev-talk: column description: email hit'
mk jwt 'set:tenants:1:display_name:P(jwt)'; gate jwt
fatal "2. a JWT in the workspace's display name is FATAL" jwt 'FATAL C4 tenants tenant_id=ws-pub: column display_name: jwt hit'
mk pem 'set:channels:2:name:P(pem)'; gate pem
fatal "2. a PEM block in a channel name is FATAL" pem 'FATAL C4 channels channel_id=lobby: column name: pem hit'
mk nameb 'set:channels:1:description:P(name)'; gate nameb
fatal "2. another workspace's name in a non-body column is FATAL" nameb 'column description: other-workspace hit'
mk namek 'set:channels:1:channel_id:P(name)' 'set:channels:1:name:P(name)'; gate namek
fatal "2. a hit IN the key column names the row number, not the key" namek 'FATAL C4 channels row 1: column channel_id: other-workspace hit'

# --- 3. C4 in a body: drop, count, re-scan ---------------------------------------------
for k in email jwt pem aws slack github sa ipv4 ipv6 name; do
  cls=$k; case $k in aws) cls=cloud-token ;; slack) cls=slack-token ;; github) cls=github-token ;; sa) cls=service-account ;; name) cls=other-workspace ;; esac
  mk "b-$k" "body:5:P($k)"; gate "b-$k"
  dropped "3. a $k in a message body drops that message, counted as $cls" "b-$k" "$cls" 1
done
grep -q '^DROP C4 email messages msg_id=00000000-0000-4000-8000-000000000005: a body hit' "$T/b-email.log" &&
  ! grep -q 'second scan' "$T/b-email.log" && pass "3. the drop names the class and the msg_id; the second scan is clean" || fail "3. drop line: $(cat "$T/b-email.log")"
if [[ "$GL" != "$T/bin/gitleaks" ]]; then
  mk b-stripe 'body:7:P(stripe)'; gate b-stripe
  dropped "3. a secret only gitleaks (the repo's config) knows drops its message, class gitleaks" b-stripe gitleaks 1
fi
mk word 'body:3:seen Quokkavilles and the quokkaville-ish tool'; gate word
[[ "$(rc_of word)" == 0 && "$(jq -r .messages_dropped "$T/word.report.json")" == 0 ]] \
  && pass "3. names match whole words only (Quokkavilles, quokkaville-ish pass)" || fail "3. whole words: $(cat "$T/word.log")"
mk word2 'body:3:the zebracorp HOLDINGS team'; gate word2
dropped "3. a name matches case-insensitively, display names with spaces too" word2 other-workspace 1
# owner answer A (SPL-3671): the id `system` (the built-in docs workspace) is a
# plain word in message text and is not matched there; its display name and
# every other id still are, and `system` is still matched outside a body
mk sysw 'body:3:the system restarts'; gate sysw
[[ "$(rc_of sysw)" == 0 && "$(jq -r .messages_dropped "$T/sysw.report.json")" == 0 ]] \
  && pass "3. the id system as a word in a message body is kept" || fail "3. system word: $(cat "$T/sysw.log")"
mk sysn 'body:3:read it in Repository docs'; gate sysn
dropped "3. the system workspace's display name in a body still drops the message" sysn other-workspace 1
mk sysi 'body:3:moved to ws-other today'; gate sysi
dropped "3. another workspace's id in a body still drops the message" sysi other-workspace 1
mk sysd 'set:channels:1:description:the system channel'; gate sysd
fatal "3. the id system outside a body (a channel description) is still FATAL" sysd 'column description: other-workspace hit'
mk one 'body:9:P(email)'; gate one
dropped "3. 1 of 100 bodies hit (1 %, the cap) passes" one email 1
mk two 'body:9:P(email)' 'body:10:P(ipv4)'; gate two
fatal "3. 2 of 100 bodies hit (2 %, above the 1 % cap) fails the day" two 'FATAL C4 messages 2 of 100 messages dropped (2.00%), above the 1.0% cap'

# --- 4. C3 shape -------------------------------------------------------------------------
mk xcol 'col:messages:files:[]'; gate xcol
fatal "4. an extra column (messages.files) in the file is FATAL" xcol 'FATAL C3 messages column files is not a public column'
mk never 'line:COPY password_credentials (subject) FROM stdin;' 'line:x' 'line:\.'; gate never
fatal "4. a COPY into a never-exported table is FATAL" never 'FATAL C3 password_credentials a never-exported table'
mk setl 'line:SET search_path = plantschema;'; gate setl
fatal "4. a line that is not a COPY block is FATAL" setl 'FATAL C3 - line 119: not a COPY block'
python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); c["messages"].append("planted_col"); json.dump(c, open(sys.argv[2], "w"))' \
  "$T/catalog.json" "$T/catalog-x.json"
cp "$FIX/clean.sql" "$T/unclass.sql"; CATALOG="$T/catalog-x.json" gate unclass
fatal "4. an unclassified live column (catalog) is FATAL" unclass 'FATAL C3 messages live column planted_col is neither public nor withheld'
mk msgc 'set:messages:4:msg:{"v":1,"canary":"MSG-CANARY"}'; gate msgc
fatal "4. msg that is not the v:1 object rebuilt from the public columns is FATAL" msgc 'column msg does not hold its fixed value'
mk envc 'set:messages:4:env:\\x43414e415259'; gate envc
fatal "4. a non-empty env is FATAL" envc 'column env does not hold its fixed value'
mk rolec 'set:tenant_memberships:1:role:owner'; gate rolec
fatal "4. a role not forced to member is FATAL" rolec 'FATAL C3 tenant_memberships human_id=HUM-3: column role does not hold its fixed value'

mk nomsg 'drop:messages'; gate nomsg
fatal "4. an allow-list table with no COPY block in the file is FATAL" nomsg 'FATAL C3 messages the file has no COPY block for this allow-list table'

# --- 5. C1, MEMBER, C2 -----------------------------------------------------------------------
mk ws2 'row:tenants:ws-other\tOther\t2026-09-01 10:00:00+00\tinternal\tdefault\t\\x'"$(printf '00%.0s' {1..32})"; gate ws2
fatal "5. an extra workspace row is FATAL (C1)" ws2 'FATAL C1 tenants the file must hold exactly one row per listed workspace (1), it holds 2'
grep -q 'ws-other' "$T/ws2.log" && fail "5. the foreign workspace id is printed" || pass "5. ... and the foreign workspace id is not printed"
mk tid 'set:tenant_memberships:2:tenant_id:ws-other'; gate tid
fatal "5. a foreign tenant_id on a row is FATAL (C1)" tid 'FATAL C1 tenant_memberships row 2: tenant_id is not an exported workspace'
mk realname 'set:humans:1:display_name:Plantina Example'; gate realname
fatal "5. a member's display name other than its HUM-n id is FATAL (Q1b)" realname 'FATAL MEMBER humans human_id=HUM-3: display_name is not the HUM-n id'
mk hmail 'set:humans:2:email:P(email)'; gate hmail
fatal "5. a member's e-mail is FATAL" hmail 'FATAL MEMBER humans human_id=HUM-7: e-mail is not NULL'
mk nonm 'set:messages:3:from_id:HUM-9'; gate nonm
fatal "5. a message naming a HUM-n that is not exported is FATAL" nonm 'FATAL MEMBER messages msg_id=00000000-0000-4000-8000-000000000003: from_id names a member that is not exported'
mk hid 'set:humans:1:human_id:plant-person'; gate hid
fatal "5. a member id that is not HUM-n is FATAL" hid 'FATAL MEMBER humans row 1: human_id is not a HUM-n id'
cp "$FIX/clean.sql" "$T/rls.sql"; reread_of "$T/rls.sql" "$T/rls.reread.json"
jq '.messages -= [["ws-pub", "00000000-0000-4000-8000-000000000042"]]' "$T/rls.reread.json" >"$T/x.json" && mv "$T/x.json" "$T/rls.reread.json"
gate rls
fatal "5. a row the RLS re-read does not see is FATAL (C2)" rls 'FATAL C2 messages msg_id=00000000-0000-4000-8000-000000000042: not found by the re-read'

mk dupk 'row:channels:lobby\tlobby\tforeign private channel text\tHUM-3\t2026-09-01 10:00:00+00'; gate dupk
fatal "5. a second channels row with a public channel_id is FATAL (C1 and C2 match by key)" dupk 'FATAL C3 channels row 3: a key seen twice in the table'
grep -q 'foreign private channel text' "$T/dupk.log" && fail "5. the duplicate row's text is printed" || pass "5. ... and the duplicate row's text is not printed"

# several listed workspaces (SPL-3808, owner: t1, spool and demo)
TWO_ROWS=('row:tenants:ws-two\tSecond Space\t2026-09-01 10:00:00+00\tinternal\tdefault\t\\x'"$(printf '00%.0s' {1..32})"
  'row:tenant_memberships:ws-two\tHUM-3\tmember\t2026-09-01 10:00:00+00\tseed')
cp "$FIX/clean.sql" "$T/m-one.sql"; WSL=ws-pub,ws-two gate m-one
fatal "5. two listed workspaces and one tenants row is FATAL (C1)" m-one 'FATAL C1 tenants the file must hold exactly one row per listed workspace (2), it holds 1'
mk m-notid "${TWO_ROWS[@]}"; WSL=ws-pub,ws-two gate m-notid
fatal "5. two listed workspaces and a block with no tenant_id is FATAL (C1)" m-notid 'FATAL C1 channels the COPY carries no tenant_id: with 2 listed workspaces a row must name its own'
mk m-two "${TWO_ROWS[@]}" 'col:channels:tenant_id:ws-pub' 'col:messages:tenant_id:ws-pub' \
  'row:channels:dev-talk\tdev-talk\tTalk in the second space\tHUM-3\t2026-09-01 10:00:00+00\tws-two'; WSL=ws-pub,ws-two gate m-two
[[ "$(rc_of m-two)" == 0 && "$(jq -c .row_counts "$T/m-two.report.json")" == '{"channels":3,"humans":2,"messages":100,"tenant_memberships":3,"tenants":2}' ]] \
  && pass "5. two listed workspaces, each row naming its own, the same channel id in both: passes" || fail "5. two workspaces: $(cat "$T/m-two.log")"
mk m-gone "${TWO_ROWS[@]}" 'col:channels:tenant_id:ws-pub' 'col:messages:tenant_id:ws-pub' \
  'row:channels:dev-talk\tdev-talk\tTalk in the second space\tHUM-3\t2026-09-01 10:00:00+00\tws-two'
WSL=ws-pub,ws-two reread_of "$T/m-gone.sql" "$T/m-gone.reread.json"
jq '.channels -= [["ws-two", "dev-talk"]]' "$T/m-gone.reread.json" >"$T/x.json" && mv "$T/x.json" "$T/m-gone.reread.json"
WSL=ws-pub,ws-two gate m-gone
fatal "5. a channel the re-read of ITS workspace does not see is FATAL (C2), though the other workspace has that id" m-gone 'FATAL C2 channels channel_id=dev-talk: not found by the re-read'
mk m-dup "${TWO_ROWS[@]}" 'col:channels:tenant_id:ws-pub' 'col:messages:tenant_id:ws-pub' \
  'row:channels:dev-talk\tdev-talk\tagain\tHUM-3\t2026-09-01 10:00:00+00\tws-pub'; WSL=ws-pub,ws-two gate m-dup
fatal "5. the same (workspace, channel id) twice is FATAL" m-dup 'FATAL C3 channels row 3: a key seen twice in the table'

# --- 6. SIZE -------------------------------------------------------------------------------------
jq -n '{allow_list_version: 1, row_counts: {tenants: 1, humans: 2, tenant_memberships: 2, channels: 2, messages: 300}}' >"$T/prev-big.json"
jq -n '{allow_list_version: 1, row_counts: {tenants: 1, humans: 2, tenant_memberships: 2, channels: 2, messages: 120}}' >"$T/prev-ok.json"
jq -n '{allow_list_version: 0, row_counts: {messages: 9000}}' >"$T/prev-v0.json"
cp "$FIX/clean.sql" "$T/sz1.sql"; gate sz1 --prev-manifest "$T/prev-big.json"
fatal "6. 100 messages against 300 in the previous file (beyond 50 %) is FATAL" sz1 'FATAL SIZE messages 100 rows against 300'
cp "$FIX/clean.sql" "$T/sz2.sql"; gate sz2 --prev-manifest "$T/prev-ok.json"
[[ "$(rc_of sz2)" == 0 ]] && pass "6. within the tolerance passes" || fail "6. sz2: $(cat "$T/sz2.log")"
cp "$FIX/clean.sql" "$T/sz3.sql"; gate sz3 --prev-manifest "$T/prev-v0.json"
[[ "$(rc_of sz3)" == 0 ]] && grep -q 'allow-list version changed' "$T/sz3.log" && pass "6. a new allow-list version skips the size check" || fail "6. sz3: $(cat "$T/sz3.log")"
jq 'del(.tables.messages)' "$T/allow.json" >"$T/allow-nomsg.json"
mk sz4 'drop:messages'; ALLOW="$T/allow-nomsg.json" gate sz4 --prev-manifest "$T/prev-ok.json"
fatal "6. a table in the previous counts and not in the file is compared as 0 rows" sz4 'FATAL SIZE messages 0 rows against 120'
grep -q 'no previous manifest' "$T/one.log" && pass "6. no previous file (the first) skips the size check" || fail "6. first file"

# --- 7. log capture ---------------------------------------------------------------------------------
leaked=""
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  grep -rlF -- "$p" "$T"/*.log "$T"/*.report.json >/dev/null 2>&1 && leaked+="$p "
done < <(sort -u "$T/plants"; echo "Plantina Example"; echo "MSG-CANARY"; echo plantschema)
[[ -z "$leaked" && "$(sort -u "$T/plants" | wc -l)" -ge 10 ]] \
  && pass "7. no planted string ($(sort -u "$T/plants" | wc -l) kinds) appears in any gate output or report" || fail "7. leaked into the output: ${leaked:-<too few plants>}"

# --- part 2: a real Postgres, the action --------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the database part is not run"
  [[ "$fails" -eq 0 ]] && { echo "PASS: $(basename "$0") hermetic part"; exit 0; }
  echo "FAIL: $fails assertion(s)"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
BIN="${SPOOL_BIN:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  # shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
  source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
  spl_export_go_path || { fail "no go toolchain"; exit 1; }
  BIN="$T/spool"
  (cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
fi
PG_CTR="spl-pdg-pg-$$"
trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$TEST_DIR/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
sleep 1
SUPER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
DB_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/pdg?sslmode=disable"
OWNER_DSN="postgres://pdg_owner:owner@127.0.0.1:$PGPORT/pdg?sslmode=disable"
EXPORT_DSN="postgres://spool_public_export:export-pw@127.0.0.1:$PGPORT/pdg?sslmode=disable"
psql -X -q -v ON_ERROR_STOP=1 "$SUPER_DSN" \
  -c "CREATE ROLE pdg_owner LOGIN NOSUPERUSER NOBYPASSRLS CREATEDB CREATEROLE PASSWORD 'owner'" \
  -c "CREATE DATABASE pdg OWNER pdg_owner" >/dev/null || { fail "create the owner role"; exit 1; }
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null \
  || { fail "spool migrate as the non-superuser owner"; exit 1; }
# the synthetic rows, as the superuser (RLS does not bind it): the exported
# workspace as in clean.sql, and ws-other with a channel of the SAME id
psql -X -q -v ON_ERROR_STOP=1 "$DB_DSN" >/dev/null <<SQL || { fail "load the synthetic rows"; exit 1; }
INSERT INTO tenants (tenant_id, root_pubkey, display_name) VALUES
  ('$WS', decode(repeat('00', 32), 'hex'), 'Public Space'), ('ws-other', decode(repeat('00', 32), 'hex'), 'Zebracorp Holdings') ON CONFLICT (tenant_id) DO NOTHING;
INSERT INTO humans (human_id) VALUES ('HUM-3'), ('HUM-7'), ('HUM-9') ON CONFLICT DO NOTHING;
INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
  ('$WS', 'HUM-3', 'developer', 'seed'), ('$WS', 'HUM-7', 'developer', 'seed'), ('ws-other', 'HUM-9', 'developer', 'seed')
  ON CONFLICT DO NOTHING;
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES
  ('$WS', 'dev-talk', 'dev-talk', 'HUM-3'), ('$WS', 'lobby', 'lobby', 'c-001'), ('ws-other', 'dev-talk', 'dev-talk', 'HUM-9')
  ON CONFLICT DO NOTHING;
INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_id, to_id, kind, body, expires_at, msg, env, env_sig, from_box, to_box)
SELECT '$WS', ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, ('00000000-0000-4000-9000-' || lpad(((i + 9) / 10)::text, 12, '0'))::uuid,
       'dev-talk', now(), 'HUM-3', 'c-001', 'note', 'message ' || i, now() + interval '1 day', '{}', '\x', '', 'seed', 'seed'
  FROM generate_series(1, 100) i;
INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_id, to_id, kind, body, expires_at, msg, env, env_sig, from_box, to_box)
VALUES ('ws-other', '00000000-0000-4000-8000-000000000777', '00000000-0000-4000-9000-000000000777', 'dev-talk', now(), 'HUM-9',
        'c-001', 'note', 'other workspace', now() + interval '1 day', '{}', '\x', '', 'seed', 'seed');
SQL
# fence 1 as T004 applies it (the export login, its column grants) and the
# public_export_workspace row (rdb 0126's restrictive policy reads it)
ROLES="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles"
{ psql -X -q -v ON_ERROR_STOP=1 -v export_verifier=export-pw -f "$ROLES/public-export-role.sql" "$OWNER_DSN" &&
  psql -X -q -v ON_ERROR_STOP=1 -f "$ROLES/public-export-grants.sql" "$OWNER_DSN" &&
  psql -X -q -v ON_ERROR_STOP=1 -c "INSERT INTO public_export_workspace (workspace_id) VALUES ('$WS')" "$OWNER_DSN"; } >/dev/null ||
  { fail "apply the T004 roles files"; exit 1; }
# a PROJ_PATH whose allow-list v1 also lists, as withheld, the live columns
# migrations added after it (the test proves the gate, not the list's age)
mkdir -p "$T/proj/cnf/public-dataset" && ln -s "$PROJ_ROOT/lib" "$T/proj/lib" && ln -s "$PROJ_ROOT/src" "$T/proj/src"
live="$(psql -X -At "$OWNER_DSN" -c "SELECT json_object_agg(relname, cols) FROM (SELECT c.relname, json_agg(a.attname::text) cols
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
    AND c.relname IN ('tenants', 'channels', 'messages', 'humans', 'tenant_memberships') GROUP BY c.relname) t")"
LIVE="$live" python3 -c 'import json, os, sys
a, live = json.load(open(sys.argv[1])), json.loads(os.environ["LIVE"])
for t, s in a["tables"].items():
    s["withheld"] += [c for c in live[t] if c not in s["public"] + s["withheld"]]
print(json.dumps(a))' "$T/allow.json" >"$T/proj/cnf/public-dataset/allow-list.v1.yaml" &&
  [[ "$(yq -r '.["version"]' "$T/proj/cnf/public-dataset/allow-list.v1.yaml")" == 1 ]] || { fail "write the test allow-list"; exit 1; }
printf 'env:\n  public_dataset:\n    workspace_ids: [%s]\n    body_drop_cap_pct: 1\n    size_tolerance_pct: 50\n    allow_list_version: 1\n' "$WS" >"$T/cnf.yaml"
# act <name> <dsn>: the ACTION on $T/<name>.sql as the given login
act() {
  env PROJ_PATH="$T/proj" APP_PATH="$APP_ROOT" PATH="$T/bin:$PATH" ENV=dev SPL_CNF_STUB="$T/cnf.yaml" \
    PD_GATE_FILE="$T/$1.sql" PD_GATE_OUT="$T/$1.act.sql" PD_GATE_REPORT="$T/$1.act.json" PD_NAMES_FILE="$FIX/names.tsv" \
    PD_EXPORT_DSN="$2" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF="$SPL_CNF_STUB"; }
    do_spl_public_dataset_gate' >"$T/$1.act.log" 2>&1 </dev/null
  echo $? >"$T/$1.act.rc"
}
cp "$FIX/clean.sql" "$T/d-clean.sql"; act d-clean "$EXPORT_DSN"
[[ "$(cat "$T/d-clean.act.rc")" == 0 ]] && grep -q '^OK public dataset gate (dev)' "$T/d-clean.act.log" && cmp -s "$T/d-clean.act.sql" "$FIX/clean.sql" \
  && pass "8. the action passes the clean candidate as spool_public_export (live catalog, RLS re-read)" || fail "8. action clean: $(cat "$T/d-clean.act.log")"
psql -X -q -c "ALTER TABLE messages ADD COLUMN planted_col text" "$OWNER_DSN" >/dev/null
cp "$FIX/clean.sql" "$T/d-col.sql"; act d-col "$EXPORT_DSN"
psql -X -q -c "ALTER TABLE messages DROP COLUMN planted_col" "$OWNER_DSN" >/dev/null
[[ "$(cat "$T/d-col.act.rc")" == 1 && ! -e "$T/d-col.act.sql" ]] && grep -q 'FATAL C3 messages live column planted_col is neither public nor withheld' "$T/d-col.act.log" \
  && pass "9. ALTER TABLE messages ADD COLUMN (unlisted) fails the action with C3" || fail "9. unclassified: $(cat "$T/d-col.act.log")"
sed 's/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000777/g' "$FIX/clean.sql" >"$T/d-forge.sql"; act d-forge "$EXPORT_DSN"
[[ "$(cat "$T/d-forge.act.rc")" == 1 ]] && grep -q 'FATAL C2 messages msg_id=00000000-0000-4000-8000-000000000777: not found by the re-read pinned by RLS alone' "$T/d-forge.act.log" \
  && pass "10. another workspace's message in the file is FATAL C2 (the RLS re-read does not see it)" || fail "10. forged row: $(cat "$T/d-forge.act.log")"
cp "$FIX/clean.sql" "$T/d-super.sql"; act d-super "$DB_DSN"
[[ "$(cat "$T/d-super.act.rc")" == 1 ]] && grep -q 'must read as spool_public_export' "$T/d-super.act.log" \
  && pass "11. a superuser DSN is refused" || fail "11. superuser: $(cat "$T/d-super.act.log")"
grep -lF -e Zebracorp -e Quokkaville -e export-pw "$T"/*.act.log >/dev/null && fail "11. a name or the password reached the action output" \
  || pass "11. no name and no password in the action output"
psql -X -q -v ON_ERROR_STOP=1 "$DB_DSN" >/dev/null <<SQL || { fail "load the second exported workspace"; exit 1; }
INSERT INTO tenants (tenant_id, root_pubkey, display_name) VALUES ('ws-two', decode(repeat('00', 32), 'hex'), 'Second Space');
INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES ('ws-two', 'HUM-3', 'developer', 'seed');
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('ws-two', 'dev-talk', 'dev-talk', 'HUM-3');
SQL
psql -X -q -v ON_ERROR_STOP=1 -c "INSERT INTO public_export_workspace (workspace_id) VALUES ('ws-two')" "$OWNER_DSN" >/dev/null ||
  fail "12. public_export_workspace takes a second row (rdb 0238)"
printf 'env:\n  public_dataset:\n    workspace_ids: [%s, ws-two]\n    body_drop_cap_pct: 1\n    size_tolerance_pct: 50\n    allow_list_version: 1\n' "$WS" >"$T/cnf.yaml"
cp "$T/m-two.sql" "$T/d-two.sql"; act d-two "$EXPORT_DSN"
[[ "$(cat "$T/d-two.act.rc")" == 0 ]] && grep -q '^OK public dataset gate (dev)' "$T/d-two.act.log" \
  && pass "12. two listed workspaces with the same channel id: the action re-reads each one as spool_public_export and passes" || fail "12. two: $(cat "$T/d-two.act.log")"
printf 'env:\n  public_dataset:\n    workspace_ids: [%s]\n    body_drop_cap_pct: 1\n    size_tolerance_pct: 50\n    allow_list_version: 1\n' "$WS" >"$T/cnf.yaml"
cp "$T/m-two.sql" "$T/d-two1.sql"; act d-two1 "$EXPORT_DSN"
[[ "$(cat "$T/d-two1.act.rc")" == 1 ]] && grep -q 'FATAL C1 tenants the file must hold exactly one row per listed workspace (1), it holds 2' "$T/d-two1.act.log" \
  && pass "12. the same file with the cnf listing one workspace fails C1" || fail "12. one listed: $(cat "$T/d-two1.act.log")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
