#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the per-kind vendor split (spec 115) has ONE source, cnf
#          env.box.agent_split_by_kind in csi-spl-cnf/csi-spl/all.env.yaml.
#          Two copies of its default rows are compiled into code and must
#          equal it, row for row:
#            wui  DEFAULT_SPLIT_KINDS in csi-spl-wui/src/utils/tenant-settings.mjs
#                 (the mock hub serves it; normalizeAgentSplitKinds falls back
#                 to it)
#            hub  DefaultSplitKinds() in
#                 csi-spl-api/src/go/spool-hub-api/internal/store/agent_split_kind.go
#                 (the rows GET /v1/agent-split shows for a kind a workspace
#                 has not set)
#          Neither can read the cnf at run time: the WUI module is imported by
#          plain node tests and the mock with no build step, and the hub's
#          defaults are Go literals. So this check compares them instead.
#
#          Why (SPL-4876, t1 8e1fd458): e696477ab (SPL-4826, 01:27Z) changed
#          the cnf rows and left both copies; wf 10's tenant-settings e2e
#          (8m-8o) was red on every master run for ~3.5 h until 93c36aebe
#          updated the copies by hand. It is a cheap iac test so the pre-push
#          gate runs it in about a second on a push that touches any of the
#          three files (part iac-cross, its _PPX_MAP row), not only inside the
#          3..5 min wui part.
#
#          CONTROLS (scratch copies of the three files): a tests row planted
#          in the cnf alone reds both copies; a drift planted in one
#          copy names only that copy; a copy whose rows cannot be read, or that
#          lacks a kind, fails closed.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CNF=csi-spl-cnf/csi-spl/all.env.yaml
WUI=csi-spl-wui/src/utils/tenant-settings.mjs
HUB=csi-spl-api/src/go/spool-hub-api/internal/store/agent_split_kind.go

# drift <root> -> one line per disagreement, nothing when the copies equal the
# cnf: "DRIFT <copy> <kind> cnf=<row> <copy>=<row>", "UNREAD <copy>" when a
# copy yields no row (a renamed const, a new literal form), "MISSING <copy>
# <kind>" when a copy lacks a cnf kind or carries one the cnf does not have.
drift() {
  python3 - "$1" "$CNF" "$WUI" "$HUB" <<'PY'
import re, sys, yaml
root, cnf_p, wui_p, hub_p = sys.argv[1:5]
VENDORS = ['claude', 'grok', 'agy', 'qwen', 'mistral']

def row(weights, backup):
    extra = sorted(set(weights) - set(VENDORS))
    return ' '.join(f'{v}={int(weights.get(v, 0))}' for v in VENDORS) + f' backup={backup}' + ''.join(f' {x}=?' for x in extra)

def read(p):
    with open(f'{root}/{p}', encoding='utf-8') as f:
        return f.read()

def cnf_rows():
    kinds = (((yaml.safe_load(read(cnf_p)) or {}).get('env') or {}).get('box') or {}).get('agent_split_by_kind') or {}
    return {k: row({v: n for v, n in r.items() if v != 'backup'}, r.get('backup', '')) for k, r in kinds.items()}

def wui_rows():
    m = re.search(r'^export const DEFAULT_SPLIT_KINDS = Object\.freeze\(\{\n(.*?)^\}\)', read(wui_p), re.S | re.M)
    rx = r"^\s+([a-z0-9_]+): \{ weights: \{([^}]*)\}, backup: '([a-z]+)' \},?$"
    return {k: row({v: int(n) for v, n in re.findall(r'([a-z]+): (\d+)', w)}, b)
            for k, w, b in re.findall(rx, m.group(1) if m else '', re.M)}

def hub_rows():
    m = re.search(r'^func DefaultSplitKinds\(\) \[\]SplitKind \{\n(.*?)^\}', read(hub_p), re.S | re.M)
    rx = r'row\("([a-z0-9_]+)", "([a-z]+)", map\[string\]int\{([^}]*)\}\)'
    return {k: row({v: int(n) for v, n in re.findall(r'"([a-z]+)": (\d+)', w)}, b)
            for k, b, w in re.findall(rx, m.group(1) if m else '')}

cnf = cnf_rows()
if not cnf:
    print('UNREAD cnf')
for name, rows in (('wui', wui_rows()), ('hub', hub_rows())):
    if not rows:
        print(f'UNREAD {name}')
        continue
    for k in sorted(set(cnf) | set(rows)):
        if k not in cnf or k not in rows:
            print(f'MISSING {name} {k}')
        elif rows[k] != cnf[k]:
            print(f'DRIFT {name} {k} cnf={cnf[k].replace(" ", ",")} {name}={rows[k].replace(" ", ",")}')
PY
}

python3 -c 'import yaml' 2>/dev/null || { fail "python3 with PyYAML is required (the iac suite's other yaml tests use it)"; exit 1; }

# ---- the real tree ----------------------------------------------------------
out=$(drift "$APP_ROOT"); rc=$?
if [[ $rc -ne 0 ]]; then
  fail "the split reader crashed (rc $rc): $out"
elif [[ -n "$out" ]]; then
  fail "a compiled copy of env.box.agent_split_by_kind disagrees with $CNF; change the copy, not the cnf (owner decisions, spec 115):"
  sed 's/^/      /' <<<"$out"
else
  pass "the wui and hub default rows equal cnf env.box.agent_split_by_kind"
fi

# ---- controls on a scratch copy of the three files --------------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fresh() {
  rm -rf "${scratch:?}"/*
  local p
  for p in "$CNF" "$WUI" "$HUB"; do mkdir -p "$scratch/$(dirname "$p")"; cp "$APP_ROOT/$p" "$scratch/$p"; done
}
# set_cnf_row <kind> <flow row>: rewrite one cnf row the way a hand edit does.
set_cnf_row() {
  sed -i -E "s/^(\s+$1:\s*)\{[^}]*\}/\1{ $2 }/" "$scratch/$CNF"
}

# CONTROL 1: the cnf moves, the copies do not (e696477ab's shape). qwen 100
# is a row no real split carries, so the plant differs from any current value.
fresh
set_cnf_row tests 'qwen: 100, backup: claude'
got=$(drift "$scratch")
if grep -q '^DRIFT wui tests ' <<<"$got" && grep -q '^DRIFT hub tests ' <<<"$got" && [[ $(wc -l <<<"$got") -eq 2 ]]; then
  pass "CONTROL: a cnf-only change of the tests row reds both copies, naming the kind"
else
  fail "CONTROL: a cnf-only change of the tests row was not caught in both copies (got: '$got')"
fi

# CONTROL 2: a drift in the WUI copy alone names only the WUI.
fresh
sed -i -E "s/^(\s+i18n: \{ weights: \{ )claude: 0,/\1claude: 1,/" "$scratch/$WUI"
got=$(drift "$scratch")
if [[ "$got" == "DRIFT wui i18n "* && $(wc -l <<<"$got") -eq 1 ]]; then
  pass "CONTROL: a WUI-only drift (i18n claude 1) names the wui copy alone"
else
  fail "CONTROL: a WUI-only drift was not named (got: '$got')"
fi

# CONTROL 3: a drift in the hub copy alone names only the hub (a backup this time).
fresh
sed -i -E 's/^(\s+row\("secret", )"[a-z]+"/\1"mistral"/' "$scratch/$HUB"
got=$(drift "$scratch")
if [[ "$got" == "DRIFT hub secret "* && $(wc -l <<<"$got") -eq 1 ]]; then
  pass "CONTROL: a hub-only drift (secret backup) names the hub copy alone"
else
  fail "CONTROL: a hub-only drift was not named (got: '$got')"
fi

# CONTROL 4: fail closed -- an unreadable copy and a missing kind are failures,
# never an empty pass.
fresh
sed -i 's/^export const DEFAULT_SPLIT_KINDS = /export const DEFAULT_SPLIT_KINDS_RENAMED = /' "$scratch/$WUI"
sed -i '/^\s*row("orchestration", /d' "$scratch/$HUB"
got=$(drift "$scratch")
if grep -qx 'UNREAD wui' <<<"$got" && grep -qx 'MISSING hub orchestration' <<<"$got"; then
  pass "CONTROL: an unreadable WUI copy is UNREAD and a hub copy without orchestration is MISSING"
else
  fail "CONTROL: an unreadable copy or a missing kind passed (got: '$got')"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all agent-split-one-source.tst.sh assertions"
exit "$fails"
