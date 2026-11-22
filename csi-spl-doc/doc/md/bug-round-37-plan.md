# Bug-fix round 37 - plan (0 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6228 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `23b148d2-3794-4d35-9d96-94bafc270cd2` ("Bug round 37", opened by c-002@sat 02:12Z). Round 36 ([bug-round-36-plan.md](bug-round-36-plan.md)) is closed (`b220e7464`; b36-01 `ca8a0591c` + `b2a96ef8f`, b36-02 `cd1c499ee`).  
Round focus: none. Every input of section 2 was re-measured, and none is a defect with a red control that a narrow fix turns green. The one new finding is a gate-design input, measured in section 4.1: the pre-push e2e selector cannot see testids built from a `testid` prop.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. 0 rows is a valid verdict when every input is accounted for (planner brief, step 3).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-36-plan.md](bug-round-36-plan.md).

**Status: v0.1, draft, for the panel.**

Editor: **c-248@`<box2>`** (claude, `specs_and_docs`).  
Panel: asked of the holder (section 7).

**One sha:** every count below is measured on **`e46621014`** (`origin/master` at this seat's fetch, unchanged at 03:57Z), on `<box2>`, 03:46Z..03:57Z on 2026-11-22, unless a line says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b36-plan')` -> `Window: W=2026-11-22T04:08:54+02:00` (commit `b220e7464`).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 36. The public repo does not name it.

---

## 1. How to read this

- Round 36 measured on `1685e0ebe`. This plan reads round 36's first inputs for round 37 (its section 7), the R7 notes of b36-01 and b36-02, the holder's candidates file and the CI report. For each one it says why it is not a row (sections 2 to 5).
- **Paths** are repo-relative. Line numbers are as of `e46621014`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where rows could come from (measured on `e46621014`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner, member and lane reports since round 36** | the brief's inputs; the inboxes and archives of the holder, the orchestrator and the standby on `<box2>`, 2026-11-22T00:00Z..03:48Z (`ls c-00{1,2,3}/{inbox,archive} \| grep '^20261122T0[0-3]'`: 60 files without rotation, lease or ack subjects read by subject, 8 of them read whole) | no owner word; no report of a defect that has no lane | **0 rows.** The one fix that landed since W, `cdf8f5074` (SPL-6224: `logServerError` writes `http 5xx` again, so `monitoring-incident-070` reads it), fixed a regression from `316422e7c`, a commit of the same lane. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (03:46Z..03:49Z) | wf 10: 100 runs (2026-11-21T09:12Z..2026-11-22T03:45Z): 48 success, 34 cancelled, 15 failure, 3 running. First red per job: `wui: browser e2e 3/8` x8, `6/8` x6, `1/8` x6, `orc: hermetic 4/4` x2, `wui 4/8` x1. The last green of every failed job: run 44977527180 on `b220e746` (02:45Z). Every job's p90 is under 75 % of its timeout (the highest, hermetic 1/4 and 3/4, 57 %) | **0 rows.** Each red has a landed fix. The `1/8`, `3/8` and `6/8` reds of `d2557fbc4`..`61977111c` (21:17Z..23:02Z, SPL-6205): `75acaab9f`; wf 10 is green from `e4b824abe` (23:24Z) on. The 12:xxZ `3/8` and `4/8` red ("the other topic under the pointer is the one lit card"): `acf2b4555` (SPL-6143, move-by-drag step 6). The 11:xxZ hermetic 4/4 red (`hub_self_sign`): `c7c2247b6`. The other workflows since 2026-11-21T22:00Z (`gh run list -L 200`, by name and conclusion) have one red: `00 ops: spool hub deploy lag watch` 44967708480 (00:39Z, the r86-02 hub lag round 36 named), green at 01:18Z, 02:23Z and 03:20Z. |
| **3. Skipped or disabled tests** | `git diff 1685e0ebe e46621014 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file, `bug-round-36-plan.md` (its quoted grep); no test switched off | **0 rows.** |
| **4. The R7 notes of round 36** | g-158 (b36-01): FAIL on `1c75262c8` (W1, N1), then PASS on `48ca10bea`. g-161 (b36-02): PASS on `3e0bd6619`, N1-N3. Read in the seats' retired outboxes on `<box2>` | 1 W (fixed), 4 notes | **0 rows**: section 3. |
| **5. Round 36's first inputs and the holder's candidates** | round 36 section 7; the candidates file on sat (c-002@sat, msg 53225b14, 03:5xZ: `wc -l` -> 110, no line after 110) | no new entry since round 36 | **0 rows**: section 4. |

---

## 3. Round 36's R7 notes, re-read

| note | text (short) | why not a row |
|---|---|---|
| b36-01 g-158 W1 | the placement slug reached `spl_spawn_place_brief` with no `/` or `..` check | **Fixed** in `b2a96ef8f` (g-158 PASS on `48ca10bea`: "section 15 dotdot seat stays feature"). |
| b36-01 g-158 N1, b36-02 g-161 N3 | the author's brief (`dispatch/briefs/hand-sat-...`) is on sat; the R7 seat on `<box2>` could not read its Do and Never (`ls` exit 2) | **Not a code defect.** The holder wrote the seat brief by hand, with a path on its own box, and both seats judged the change against the plan row instead. A process input for the holder: copy the author's brief into the seat brief, or place the seat on the author's box (section 5). |
| b36-02 g-161 N1 | `SPL_CBR_ESTATE_RX` (`csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh:94`) has an optional opening quote, no closer and no end anchor, so `localized` matches as `local` | **Not a bug.** A deny list that refuses more than it names fails closed. The bare form matched the same way before b36-02, and the check refuses no shipped file (the `ctrl` case of round 36's rc02). |
| b36-02 g-161 N2 | `SPL_CBR_INLINE_VAULT_RX` (`:65`) skips a full-line comment but refuses an inline comment or a quoted mention of `!vault` | **Not a bug**, for the same reason: it fails closed, and the shipped set passes. |

---

## 4. Round 36's carried inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| The e2e cut that left `topic-menu-parity.test.mjs` out of SPL-6205's selection | section 4.1, `rc01.sh` | the selector cannot see the testids `UiPointMenu` builds from its `testid` prop, and a prefix key alone does not select the test | **Not a row**: a gate-design input, measured below. |
| SPL-6174's link to the relay hash `3e2c61b1` | `git log origin/master --since=2026-11-21T20:00Z --format='%h %s' \| grep -iE 'SPL-6174\|relay'` -> 0 | the writer of the link is still not named | **Not a row**: no writer, no red control. Carried. |
| b34-01 R7 c-855 N2 (`TestDocAssetHeldDoorCatalogue` passes on a NULL `proacl`) | round 36 section 4 | nothing is wrong on the tree | **Test-shaped**: an input for a test or refactor round, as round 36 read it. Carried. |
| The other items round 36 carried (the topic loop's hourly cap, the done-claim `job` label, the lease vendor order writer, b33-01 N1, the AltGr picker, the blog switcher's Enter and the rest of its section 4's last row) | no new report since round 36 (source 1); no sighting in the 100 runs (source 2) | - | **As round 36 read them.** Carried. This seat did not re-run the sat-only reads (the done-claim log, `lease.conf`). |

### 4.1 The e2e selector cannot see a composed testid

`do_check_pre_push_e2e` (`csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh`) ranks the e2e files by the testids that a changed WUI source declares (`_ppe_keys`, `:119-127`). `src/components/MessageMenu.vue:14` passes `testid="msg-menu"` to `UiPointMenu`, which renders each entry as `testid + '-' + item.id` (`src/components/UiPointMenu.vue:50`). `UiConfirm.vue` and `UndoSnackbar.vue` build `${testid}-<part>` the same way. `_ppe_keys` reads `msg-menu` as an exact key, and an exact key must end at a non-testid character (`_ppe_score`, `:186-188`), so no `msg-menu-<id>` that a test names counts. The entry ids live in `src/utils/msg-menu.mjs` (`:129`, `export-topic-pdf`), which declares no testid.

Measured with `rc01.sh` (below, sha256 first 12 hex `a76d454d20ea`, 2706 B). Each run takes about 30 s on `<box2>`:

| run | output |
|---|---|
| `bash rc01.sh e46621014` | `rc01 keys: got=exact-only want=has-prefix` / `rc01 sel: got=cut 37 want=selected` / `rc01 ctrl: got=selected want=selected` / `rc01 sha=e46621014 keys=[msg-menu] wrong=2`, exit 1 |
| `bash rc01.sh d2557fbc4` (the sha that went red) | `wrong=2`, exit 1 |
| `RC01_PLANT=1 bash rc01.sh e46621014` (a `testid="x"` prop also gives the prefix key `x-`) | `keys` green, `sel: got=cut 46`, `wrong=1`, exit 1: the prefix key raises the test from 37 to 46, and it is still cut |
| a clone at `e46621014`, `WUI_E2E_CHANGED=csi-spl-wui/src/components/MessageMenu.vue`, without and with the plant | the same six files in the same order, each 9 points higher with the plant (`topic-menu-parity` 19 -> 28, sixth either way) |

**Why not a row:** a prefix key adds the same 9 to every test that names any `msg-menu-*` testid, so the ranking does not change, and the cap (6 files, 240 s) still cuts the test. To select it, the selector would have to read which entry id the diff added (a diff-aware key), or take a different cap when a shared menu changes. That is a change to the gate's design, not a missed spelling. No fix turns `sel` green, so there is no red control a narrow lane can close. The `keys` half alone would be a correct but ineffective change. The CI cost is in source 2: 3 jobs red over 15 runs, 21:17Z..23:24Z. **Handed to the holder** as a gate input (section 5).

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b37-01 red control. On <sha>'s tree, the pre-push e2e
# selector (do_check_pre_push_e2e, csi-spl-iac) reads the testids a WUI
# source declares (_ppe_keys). A component that passes a testid PROP to a
# composing component (UiPointMenu renders testid + '-' + item.id) declares
# every "<prop>-<id>" testid, so the key must also be the prefix "<prop>-".
#   keys : _ppe_keys of src/components/MessageMenu.vue holds "msg-menu-"
#                                           (RED: only "msg-menu", exact)
#   sel  : the range 6a0cc0146^..6a0cc0146 (SPL-6205, the new menu entry
#          export-topic-pdf) selects tests/e2e/topic-menu-parity.test.mjs,
#          the file that names msg-menu-export-topic-pdf and went red on
#          trunk at d2557fbc4      (RED: CUT, or not listed)
#   ctrl : the same range still selects tests/e2e/msg-export-pdf.test.mjs
#          (control: holds on every sha)
# A temp clone (git clone --shared), no network, no browser, nothing installed.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
top="$(git rev-parse --show-toplevel)"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git clone -q --shared --no-checkout "$top" "$T/r" || exit 2
git -C "$T/r" -c advice.detachedHead=false checkout -q "$full" || exit 2
F="$T/r/csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh"
# RC01_PLANT=1: a sketch fix in the clone (a testid="x" prop also gives "x-")
if [[ "${RC01_PLANT:-0}" == 1 ]]; then
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '      sed -E "s/.*[\'\\`\\"]([a-z0-9-]+)$/\\1/"\n'
new = old + '    grep -oE "(^|[[:space:]])testid=\\"[a-z0-9][a-z0-9-]{3,}\\"" "$1/$2" 2>/dev/null | sed -E \'s/.*="([a-z0-9-]+)"$/\\1-/\'\n'
assert old in s, "plant anchor not found"
open(p, "w").write(s.replace(old, new, 1))
PY
fi
keys="$(cd "$T/r/csi-spl-iac" && bash -c 'source src/bash/run/check-pre-push-e2e.func.sh; _ppe_keys ../csi-spl-wui src/components/MessageMenu.vue' 2>/dev/null | paste -sd' ')"
sel="$(cd "$T/r/csi-spl-iac" && WUI_E2E_RANGE=6a0cc0146^..6a0cc0146 ./run -a do_check_pre_push_e2e 2>/dev/null)"
pick() { awk -v f="$1" '$1 == f { print "selected"; exit } $1 == "CUT" && $2 == f { print "cut " $3; exit }' <<<"$sel"; }
bad=0
chk() { echo "rc01 $1: got=$2 want=$3"; [[ "$2" == "$3" ]] || bad=$((bad + 1)); }
chk keys "$(grep -qw -- 'msg-menu-' <<<"${keys// /$'\n'}" && echo has-prefix || echo exact-only)" has-prefix
s="$(pick tests/e2e/topic-menu-parity.test.mjs)"; chk sel "${s:-absent}" selected
s="$(pick tests/e2e/msg-export-pdf.test.mjs)"; chk ctrl "${s:-absent}" selected
echo "rc01 sha=${full:0:9} keys=[$keys] wrong=$bad"
(( bad == 0 ))
```

The script is also on `<box2>`, in this seat's scratch, and is printed here so a seat on sat can rebuild it. It makes a throwaway `git clone --shared` of the checkout it runs from and checks out the sha. No network, no browser, no push, nothing installed: bash, git, awk, and python3 for `RC01_PLANT=1` only. No fix was written in the repo.

---

## 5. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes | their lanes | 0 rows, so no row file can collide. This plan's one file: `lane-map.sh --check csi-spl-doc/doc/md/bug-round-37-plan.md,csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh --agent c-248` (03:57:01Z) -> `WARN no live lane lists` them, exit 4: 4 sat lanes record no files (c-035 SPL-5882 T3 hub errors, c-054 s154 B7 contacts scope, c-894 s184 H1 hub agent model, g-080 an R7 seat), none plan- or selector-shaped. The queue: `do_spl_spawn_queue` (03:47:54Z) -> `0 queued, 0 placing`. Refactor round 87's planner (c-230@`<box2>`, SPL-6227) plans beside this round; this round adds no row file to keep disjoint. |
| The e2e selector's composed testids (section 4.1) | the holder, as a gate input | Handed over (section 6). It fits a refactor or gate round with a design row, not a bug row. |
| The R7 seat that cannot read the author's brief on another box (section 3) | the holder | A process input. |

---

## 6. Counts

| item | count |
|---|---|
| rows | 0 |
| inputs re-measured | 5 sources; 100 wf 10 runs (15 failures, every first-red job with its landed fix) and the other workflows since 22:00Z (1 red, green since); 5 R7 notes of round 36 (1 W fixed, 4 notes); round 36's carried and first inputs; the candidates file (110 lines, unchanged, the holder's read); 1 measurement script (n=1 on `e46621014`, n=1 on `d2557fbc4`, n=1 planted, n=1 per side on `MessageMenu.vue` alone) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b37-'` -> 0; `git ls-remote origin 'refs/heads/review/b37-*' 'refs/heads/wip/*b37*' 'refs/heads/*-b37-*'` -> nothing; `<box2>`: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b37\|bug-round-37'` -> this planner's brief only, `git worktree list \| grep -E 'b37-[0-9]{2}\|bug-round-37'` -> this planner's only; sat (c-002@sat, msg 53225b14): 1 brief, this planner's, and 0 of 201 worktrees |
| first inputs for round 38 | the selector's composed testids (section 4.1, if no gate round takes it); SPL-6174's relay-hash link, once its writer is named; b34-01 N2 (a test or refactor round); every item carried in section 4 |

---

## 7. Panel and reviewer (rulebook 3.2)

- **Editor:** c-248@`<box2>` (claude, `specs_and_docs`).
- **Panel:** asked of the holder: one cross-vendor seat (not claude) reviews the plan only. It re-runs the slug proof, the CI report, `rc01.sh` on `e46621014` and planted, and the lane map; it writes no code.
- **Row reviewer (R7):** none; no row.
- **Review history:**
  - 2026-11-22 04:0xZ: v0.1, pushed to `review/c002-bug-round-37-planner`.

---

## 8. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-248@`<box2>` | v0.1 |
| Panel | asked of the holder | - |
| Holder | c-002@sat | - |
