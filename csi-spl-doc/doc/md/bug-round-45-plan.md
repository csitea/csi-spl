# Bug-fix round 45 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6416 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `5b2c934d-996b-4578-9220-d92382106e95` ("Bug round 45", opened by c-002@sat 18:44Z). Round 44 ([bug-round-44-plan.md](bug-round-44-plan.md)) served both rows (b44-01 `14b6055c2`, SPL-6369; b44-02 `158664186`, SPL-6388) and is closed (`2ec8927ba`, written by this seat).  
Round focus: the sources of rounds 40 to 44 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W, owner posts), round 44's first inputs, and the holder's candidate list.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. One candidate met the bar (section 3); a planner never waits to collect more rows (5.2).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-44-plan.md](bug-round-44-plan.md).

**Status: v0.1, for the panel.** Not signed; no row lane starts before the panel signs the plan sha (rulebook 3.2).

Editor: **c-025@`<box2>`** (claude, `specs_and_docs`).  
Panel: placed by the holder (rulebook 3.2).

**One sha:** every site, line number and red control below is on **`d9030330e`** (`origin/master` at this seat's fetch, 2026-11-24T19:3xZ); the three files of the row are unchanged since `92caf63c2` (`git diff --stat 92caf63c2 d9030330e -- <the three files>` -> empty). The sources of section 2 were read on `<box2>`, 19:18Z..19:30Z on 2026-11-24. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b44-plan')` read at 19:18:37Z (before this seat's close record landed) -> `Window: W=2026-11-24T11:46:36+02:00` (commit `4577630c5`, round 44's last plan commit then). The close record `2ec8927ba` (19:20Z) is a newer `docs(b44-plan` commit; the recorded W stays (5.3: the planner reads W once). Since W, `origin/master` took 85 commits to `64123998a` (`git log origin/master --since="$W" --oneline | wc -l`).

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat, `<ws>` one customer workspace, as in rounds 21 to 44: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `d9030330e`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red control is a script printed in section 4. It copies the named sha's action file out with `git show` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs). This seat's own reads added 1 statement error to the prd log after source 1 was read (`column "slug" does not exist`, 19:27Z): the shape of source 1's lines.
- This seat runs on `<box2>`; the sat spool (the holder's outboxes, the review-go log of the lease box) and `/var/spool-hub/dispatch/c002-next-round-candidates.md` are not on it. Each source says where it was read.

---

## 2. Where rows could come from (measured since W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=10h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (19:21:13Z) | 41 entries, 09:32Z..19:15Z, 40 since W: all 40 Cloud SQL statement errors as the hub's runtime user, each a single backend pid: `column ... does not exist` x27 (`id`, `key`, `created_at`, `status`, `host`, `prefix`, `issue_key`, ...), `relation ... does not exist` x6 (`topics`, `discussions`, `asks`, `members`, `hub_messages`), `uuid ~~ unknown` x2, `invalid regular expression` x1, `array_length(jsonb, integer)` x1, `syntax error at or near "ROLLBACK"` x1 (19:15Z), others x2 | **0 rows.** Hand-written reads with wrong names, the shape rounds 41 to 44 traced to seats' `do_spl_db_query`. No hub `ERROR` line, no Cloud Run request error. |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=10h ./run -a do_gcp_list_alert_incidents` (19:21Z) | 9 policies, 0 incidents in 09:21:17Z..19:21:17Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,100), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (19:21:29Z) | 12 issues: round 44's 7 less SPL-6356 (closed), plus 6 new since W: SPL-6366, 6361, 6362 (the release-transfer tool: outbound, wip), SPL-6414 (the release-transfer tool: gpg-agent leak, wip), SPL-6415 (the release-transfer tool: rehearse s10, wip), SPL-6413 (sign-in workspace drop-down, wip, priority 1) | **0 rows.** Each new one is a live lane: SPL-6414 c-988 and c-018, SPL-6415 c-995, SPL-6413 c-975 and c-998, the outbound ones c-005, c-713 and c-721 (lane map, section 5 R3). The 6 older ones are their lanes' or the holder's. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (19:18Z..19:2xZ, background) | 100 runs, 2026-11-23T21:07Z..2026-11-24T19:17Z: 74 success, 21 cancelled, 3 failure, 2 running; every job's p90 under 75 % of its timeout (highest: hermetic 1/4, 60 %) | **0 rows**: section 3.2. |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 100` (19:23:39Z), `createdAt` after W | 23 failed runs: 20 of wf 40 (tenant host reconcile, 14:25Z..19:11Z), 3 of wf 10 (source 4) | **0 rows.** wf 40 is the live lane c-960 (spec 158 H4 + H5, SPL-6411), as the brief says: owned (R3). |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=10h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (19:21:24Z; cap not reached) | 514 entries, 510 since W: 361 `upload token refused` (`unknown_token`), 5 `ws hello refused` (`unpinned_box`), 4 `PUT /v1/me/hours/minutes` 400 (one phone), 23 `release-notes/<sha>` 404 (browser), 5 `tenant/cost-allocations` 403, 3 `operator/workspaces` 403, 2 `members` 403, 7 `short/268185` 404 (ad-tracker query strings), 4 `github: request refused`, topic and issue views 404, scanner probes | **0 rows**, section 3.3. |
| **7. R7 notes of lanes landed since W** | the `review:` lines of the commits since W (`git log origin/master --since="$W" --format=%B \| grep '^review: '`), and the hub tail of task `dispatch-bug-r44`; the sat spool is not on this box | 6 lines: a-948 (SPL-6407), a-166 (b44-02, N1 N2), c-105 (SPL-6382, N1), g-071 (r96-01, N1 N2), g-750 (b44-01, N1 N2 N3), g-063 (r96-02); 0 W | **Row b45-01** (g-750 N2, section 3.1). The rest: a wording or a comment (r96-01 N1: `spl-unanswered-sweep.func.sh:196` names a removed function, a refactor input), a corpus note, or a test detail. |
| **8. Owner and member posts** | `ENV=prd SQL="select from_id, count(*) from messages where tenant_id='t1' and from_id like 'HUM-%' and accepted_at > '2026-11-24T09:46:36Z' group by 1" ./run -a do_spl_db_query` (19:21:34Z) | 0 rows | **0 rows.** |
| **9. Round 44's first inputs** | round 44 section 7, re-run | 8 items + the carried N2s | **Row b45-01** from the first item's neighbour (g-750 N2); the rest section 3.4. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` | not on `<box2>` (`ls` -> no such file, 19:2xZ); read 19:4xZ via the holder (c-002@sat, msg d00ff6a1): 134 lines (mtime 13:14Z), round 44 read 131; lines 132-134 are refactor round 97 input (r96-01 N1) | **0 rows: 0 new bug items.** Section 3.5. |

---

## 3. The candidates, read

### 3.1 b45-01: since b44-01, rule [4] reads a conditional apply step as a prohibition and lets it through

- **What happens.** b44-01 (`14b6055c2`) added a third negation to `_spl_review_go_instr`'s `neg` regex (`csi-spl-orc/src/bash/run/spl-review-go.func.sh:675`): `no` plus up to three words on the line, none of them and / then / but / so, before `apply`. The match is removed from the instruction text (`:677`, `re.sub(neg, "", ...)`), so the owner-go scan (`_spl_review_go_owner_go`, rule [4]) no longer sees the keyword. A step written as a condition without a comma has the same words: "If no errors apply the migration to prd." matches `no errors apply`, and "When the plan shows no drift apply step 053." matches `no drift apply`. Both are instructions to apply, and both now pass rule [4] with no `Owner-go:` line (rc 0, GO); on `14b6055c2^` both were held (rc 1).
- **Seen.** g-750@`<box2>` (grok), the R7 of b44-01, note N2 (in `14b6055c2`'s body, on `8088c0c41`): "unpunctuated fixture 'if no errors apply' strips helper rc 0 at spl-review-go.func.sh:675; punctuated 'if no errors, apply' holds; none of the 7 freed is that form". Left out of b44-01 and not in round 44's first inputs. Re-measured here (section 4.1).
- **Direction.** This is the fail-open direction of a safety hold: a brief that asks for an apply (a prd mutation or a terraform apply needs the owner's go, repo `CLAUDE.md`) gets a GO without an `Owner-go:` line. Round 44's rows were the fail-closed direction (a hand GO).
- **Measured on the briefs.** Over this box's readable dispatch and spawn-remote briefs (6747; 650 hold the word `apply`, `grep -lis '\bapply\b'`): the instruction text keeps no `apply` in 106 of the 650 on `d9030330e`, and in 106 with the fix shape of section 4.1; 0 briefs differ (19:25Z). A first fix-shape that also kept the `does not apply` branch after a condition word changed 2 briefs ("or re-make the change ... if it does not apply"): the fix must touch the `no` branch only. **Harm today: latent.** No brief on this box uses the form; the hold exists for the brief that will.
- **Red control** (`rc01-b45.sh`, section 4.1): on `d9030330e`, two fixture briefs with a conditional apply step (`## Do` "If no errors apply the migration to prd."; `## Steps` "When the plan shows no drift apply step 053.") -> rc 0 each (want 1); b44-01's two prohibitions -> rc 0 (want 0); `rc01 exit 1`. **Control**: `fix-shape` -> rc 1, 1, 0, 0, `rc01 exit 0`. On `14b6055c2^` -> rc 1, 1, 1, 1, `rc01 exit 1` (the two prohibitions held: b44-01's defect), so the row keeps b44-01's gain.
- **Suite with the fix shape.** `REVIEW_GO_FUNC=<the fix-shape copy> bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` -> `spl-review-go: 0 failure(s)` (case 29's prohibitions and its 5 controls included); the tree's own copy -> 0 failure(s) (19:3xZ).
- **Fix scope.** `csi-spl-orc/src/bash/run/spl-review-go.func.sh` (`_spl_review_go_instr`: the `no` branch of `neg` at `:675`, applied at `:677`; its comment `:626-628`; the `@description` at `:59`) and `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (a new case 30 after case 29, `:1171-1189`: the two conditional steps -> rc 4; case 29's prohibitions still GO). The fix shape is the shape, not the fix: the lane picks the form (a condition word earlier in the same clause keeps the `no ... apply` a keyword, or the `no` branch only at a clause start), keeps the `does not apply` / `never apply` branches as they are, and re-runs the brief count (0 freed briefs re-held is expected; each one that changes is read). Docs: `csi-spl-doc/specs/157-dispatch-automation/spec.md:259` names the negated forms: the same commit says when `no ... apply` is not one.

### 3.2 CI reds in the 100 runs, read

| run | job | first red line | why not a row |
|---|---|---|---|
| 45459967138, 45462959758 (18:28Z, 18:45Z, `0f872e92e`), 45464640778 (18:55Z, `ac53314e4`) | wui e2e 1/8, 4/8, 6/8 | `browser Back: Back returns to #alerts and the feed loads`; `settings@360 browser Back closes the modal`; `P4 390: the X closes it` | **Owned**: red since `0f872e92e` (SPL-6379, phone Back from a channel's topics). The live lane c-087@sat (`c-087-c002-bug-acfc125c-topics-list-back-to-channels`, topic `acfc125c`) is that topic's bug lane; wf 10 was still not green on master at 19:2xZ (the later runs cancelled or running). For the holder's trunk-red watch (2.11.3), not a row. |
| 45464640778 (18:55Z, `ac53314e4`) | orc hermetic 3/4 | `FAIL: 5 assertion(s) in spl-private-overlay-install-cron.tst.sh` (case 6: the new token-path check) | **Owned**: `ac53314e4` is c-960's own SPL-6411 commit (live). |
| 45328560134 (04:45Z) | hub gofmt/vet/test | `TestKeyDeskOnListensWithIdentity` | **Served**: b43-01 `c581dc43d`. |

The hermetic 2/4 timeout of rounds 42 to 44: 0 sightings in these 100 runs (p90 56 %).

### 3.3 The prd WARNING lines, read

| candidate | read | why not a row |
|---|---|---|
| `upload token refused`, 361 in 10 h (round 44: 390 in 6 h) | `reason=unknown_token` | **Not a row**, round 43 section 3.3: the holder's box question. Carried. |
| `PUT /v1/me/hours/minutes` 400, 4 (12:50Z..13:00Z, one Android phone, a `csitea` workspace tab) | The hub logs no reason for a 400. The response is 385 B where that origin's 200s are 306 B: 79 B more than `{"stored":NN}` (14 B), i.e. a 93 B body; `bad_minutes` "at must be within the last 45 days and not in the future" is 92 B, the other 400 bodies 63 to 75 B. So, by size only, a minute more than 2 min ahead of the hub (`hoursMinuteSkew`, `csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me.go:33`, checked at `:541`): a phone clock ahead. The hub refuses the whole batch (`:560-563`) and the WUI drops a refused batch as final (`csi-spl-wui/src/utils/hours-recorder.mjs:121-127`), so every minute of those 4 batches is lost. The same phone's 10 earlier PUTs (09:59Z..11:58Z) were 200. | **Not a row yet**: n=4, the cause read from a byte count, not a logged reason; the member could not be named from `hours_minutes` (a SELECT per member and 10 min, 19:27Z, shows a gap 12:30..12:59 for one csitea member, not provably the phone's); spec 107 says nothing on clock skew. **Carried** to round 46 with a first step: the hub logs the `bad_minutes` detail on a 400 (or the WUI keeps the in-window rows); then a skew test with a red control. |
| `release-notes/<sha>` 404, 23 (browser, a `csitea` tab and the root host) | the shape of rounds 42 to 44 | **Not a row**: round 42 section 3.3 (SPL-6274's design). Carried. |
| `tenant/cost-allocations` 403, 5 (other workspaces' tabs) | `csi-spl-wui/src/pages/tenant-settings.vue:84` `probeCostAllocDoor` | **Not a row**: the page probes the door by design; a member without the share gets 403. |
| `operator/workspaces` 403, 3; `members` 403, 2; `admin/perf/summary` 403, 1 (a script) | a non-operator's reads | **Not a row**: refused as designed. |
| `short/268185` 404, 7; `.env`, `sftp-config.json`, `v1/models`, `auth/session` ... | ad-tracker query strings and scanner probes | **Not a row.** |
| topic and issue views 404 (`view/topics/<id>`, `view/issues/CSI-<n>`) | another workspace's or a removed topic's id | **Not a row**: as rounds 43 and 44 (`view/issues/SPL-5232`). |
| `ws hello refused` 5; `github: request refused` 4 | as round 44 | **Not a row.** |

### 3.4 Round 44's first inputs, re-read

| candidate | result | why not a row |
|---|---|---|
| the non-instruction `apply` rule [4] holds (a noun, another lane's status), 2 sightings | `grep -c "owner-go keyword 'apply'" /var/csi/csi-spl/review-go/cron.out` on `<box2>` -> 1 (undated line; the GO is sent from the lease box, sat, where the log was not read) | **Not a row**: no new sighting read; still a 4th candidate. Its neighbour in the other direction is row b45-01. Carried. |
| the topic loop cap race | `git log origin/master --since="$W" -- '<api>/internal/hub/topic_loop_fire.go'` -> 0 | **Not a row**: unproven, needs a two-fires test first. Carried. |
| the store tests' fresh-DB need | hub-pg green in the 100 runs | **Not a row**: a test-hygiene input. Carried. |
| the `unknown_token` box | source 6: 361 | **Carried** with the holder. |
| the hub dir mode | unchanged | **Not a row**: no exposure (round 43 section 3.1). Carried. |
| the hermetic 2/4 timeout | 0 sightings in 100 runs | **Carried** (2.11.3). |
| the composed testids | a gate-design input with the holder | **Carried.** |
| SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`, g-162 N2 | not re-measured here | **Carried.** |

### 3.5 The holder's candidate list

Not on this seat's box; read 19:4xZ via the holder (c-002@sat, msg d00ff6a1): **0 new bug items** since round 44's read. `wc -l` -> 134 (mtime 13:14Z; round 44 read 131 at 09:00Z). The 3 new lines are the refactor round 97 section: r96-01 R7 g-071 N1 (`spl-unanswered-sweep.func.sh:196` still names `send_to_peers_on`), refactor-shaped. The last bug-shaped section (round 43's heading) is the rule [4] false HOLD on a prohibition, which b44-01 took; row b45-01 is the same scan from the other side.

---

## 4. Red control, as run

### 4.1 `rc01-b45.sh` (b45-01), sha256 first 12 hex `cc6ed6fecc0a`, 2674 B

Run from any checkout: `bash rc01-b45.sh d9030330e` (exit 1), then `bash rc01-b45.sh d9030330e fix-shape` (exit 0). Under 1 s.

```bash
#!/usr/bin/env bash
# rc01-b45.sh <sha>: b45-01 red control. On <sha>'s tree, the review-go
# owner-go scan (_spl_review_go_owner_go, rule [4]) must HOLD (rc 1) a brief
# whose step is a conditional apply written without a comma ("If no errors
# apply the migration to prd."), and must still pass the prohibitions b44-01
# freed ("no terraform apply", "Run NO terraform plan or apply"). The action
# file is copied out of <sha> with git show into a mktemp dir; nothing in the
# checkout changes. fix-shape: a negation match whose clause (since the last
# . ; : , ! ? or line start) holds a condition word (if, when, unless, once,
# while, after, until) is kept as a keyword: the shape, not the fix.
set -uo pipefail
sha="${1:?usage: rc01-b45.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" show "$sha:csi-spl-orc/src/bash/run/spl-review-go.func.sh" >"$tmp/rg.sh" || exit 2
if [ "${2:-}" = fix-shape ]; then
  python3 - "$tmp/rg.sh" <<'PY2' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = 'print(re.sub(neg, "", "\\n".join(out)))'
new = ('txt = "\\n".join(out)\n'
       'cond = re.compile(r"(?i)\\b(?:if|when|unless|once|while|after|until)\\b[^.;:,!?\\n]*$")\n'
       'print(re.sub(neg, lambda m: m.group(0) if m.group(0)[:2].lower() == "no" and cond.search(txt, 0, m.start()) else "", txt))')
assert s.count(old) == 1, "fix-shape: print line not found once"
open(p, "w").write(s.replace(old, new))
PY2
  echo "rc01 fix-shape: a 'no ... apply' after a condition word in the same clause stays a keyword"
fi
run() { SPOOL_ROOT="$tmp" SPL_STATE_DIR="$tmp" bash -c 'source "$1"; _spl_review_go_owner_go "$2" c-000' _ "$tmp/rg.sh" "$1" >/dev/null 2>&1; echo $?; }
printf '%s\n' '# Lane brief' '## Do' '3. If no errors apply the migration to prd.' >"$tmp/pos1.md"
printf '%s\n' '# Lane brief' '## Steps' '4. When the plan shows no drift apply step 053.' >"$tmp/pos2.md"
printf '%s\n' '# Lane brief' '## Do' '3. Gates for the trees you touch. No GCP mutation, no prd write, no terraform apply.' >"$tmp/neg1.md"
printf '%s\n' '# Lane brief' '## Steps' '5. Hygiene. Run NO terraform plan or apply, nothing against dev, prd or GCP.' >"$tmp/neg2.md"
p1=$(run "$tmp/pos1.md"); p2=$(run "$tmp/pos2.md"); n1=$(run "$tmp/neg1.md"); n2=$(run "$tmp/neg2.md")
echo "rc01 'If no errors apply the migration' -> rc $p1 (want 1); 'no drift apply step 053' -> rc $p2 (want 1); 'no terraform apply' -> rc $n1 (want 0); 'NO terraform plan or apply' -> rc $n2 (want 0)"
rc=0
[ "$p1" = 1 ] || rc=1; [ "$p2" = 1 ] || rc=1; [ "$n1" = 0 ] || rc=1; [ "$n2" = 0 ] || rc=1
echo "rc01 exit $rc"
exit "$rc"
```

Output on `d9030330e` (`<box2>`, 19:3xZ):

| run | output |
|---|---|
| `bash rc01-b45.sh d9030330e` | `rc01 'If no errors apply the migration' -> rc 0 (want 1); 'no drift apply step 053' -> rc 0 (want 1); 'no terraform apply' -> rc 0 (want 0); 'NO terraform plan or apply' -> rc 0 (want 0)` / `rc01 exit 1` |
| `bash rc01-b45.sh d9030330e fix-shape` | `rc01 fix-shape: a 'no ... apply' after a condition word in the same clause stays a keyword` / `rc01 'If no errors apply the migration' -> rc 1 (want 1); 'no drift apply step 053' -> rc 1 (want 1); 'no terraform apply' -> rc 0 (want 0); 'NO terraform plan or apply' -> rc 0 (want 0)` / `rc01 exit 0` |
| `bash rc01-b45.sh 14b6055c2^` | `... -> rc 1 (want 1); ... -> rc 1 (want 1); ... -> rc 1 (want 0); ... -> rc 1 (want 0)` / `rc01 exit 1` (the regression's parent: conditionals held, b44-01's prohibitions held) |

---

## 5. Rows

| # | id | practice | sites (file:line on `d9030330e`) | evidence | red control (fails on `d9030330e`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b45-01-orc-review-go-conditional-apply-held` | a safety hold fails closed | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:675` (the `no` branch of `neg`), `:677` (where it is removed), `:626-628` and `:59` (its words); `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 30 after `:1189`); `csi-spl-doc/specs/157-dispatch-automation/spec.md:259` | g-750 N2 in `14b6055c2`'s R7 line; section 4.1 | `bash rc01-b45.sh d9030330e` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | **`bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`** (every case, 24 to 30; 29 unchanged); `bash rc01-b45.sh <fix sha>` -> exit 0 (without `fix-shape`: its patch then finds nothing to change or must not be needed); the brief count re-run (650 with `apply` on `<box2>`), every changed brief read | section 3.1: the `no` branch only; `does not apply` / `never apply` unchanged; no other keyword, no section rule | where the holder places it (`do_spl_box_pick` 19:29Z: both boxes over their high mark, `<box2>` least past, for agy and claude) | claude | an agy seat if the holder finds agy quota (`BOX_PICK_KIND=agy` read `agy weekly unknown`, 19:29Z; a-166 agy reviewed b44-02 at 17:xxZ), else the claude waiver seat (1a7c70da) | `simple_coding` | 1 |

- **R1:** one row.
- **R3** (19:28:19Z): `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md,csi-spl-doc/doc/md/bug-round-45-plan.md --agent c-025` -> exit 4: no live lane lists these paths; 5 live lanes on sat record no files (`unknown:` c-074 spec 187 planner, c-087 the phone Back bug, c-148 rotate, c-159 spec 186 M3 WUI, c-164 spec 153 Q2 store): **not free until the holder re-runs `--check` at placement**. The queue, `./run -a do_spl_spawn_queue` (19:28:23Z): 20 rows (perf p19 and p20 rows, one bug row `c002-bug-tmp-unproven-trees-sweep`, features and spec seats), none on these files by slug.
- **R7:** a claude-authored code row: an agy seat when agy has quota, else the claude waiver seat (planner brief, c-001 77ba5669). No grok (c-001 dc84300a). No mistral (coding kind).
- **Pushes:** aim 1 (1.2).
- **Priority 2** (5.4): the row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| wf 10 wui e2e 1/8, 4/8, 6/8 red since `0f872e92e` (SPL-6379) | c-087@sat (topic `acfc125c`) | live; trunk-red watch (2.11.3). |
| wf 10 hermetic 3/4 `spl-private-overlay-install-cron.tst.sh` on `ac53314e4`; wf 40 tenant host reconcile | c-960 (SPL-6411) | live. |
| SPL-6413, 6414, 6415, 6361, 6362, 6366 | their live lanes (source 3) | live. |
| The `unknown_token` box | the holder, as a box question | carried. |
| The hours-minutes 400s (section 3.3) | round 46 input | carried with a first step. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 10 sources; 40 prd error entries since W (10 h read); 510 prd WARNING entries since W (401s left out, cap not reached); 9 alert policies (0 incidents); 12 open bug issues; 100 wf 10 runs (3 failures); 23 failed runs of other workflows since W (20 wf 40, 3 wf 10); 6 R7 lines since W; 0 owner posts; round 44's first inputs (8 + the carried N2s); `rc01-b45.sh` n=1 each way on `d9030330e` and once on `14b6055c2^`; 650 briefs through `_spl_review_go_instr` twice; the review-go suite twice (tree, fix shape) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b45-'` -> 0; `git ls-remote origin 'refs/heads/review/b45-*' 'refs/heads/wip/*b45*' 'refs/heads/*-b45-*' 'refs/heads/*bug-round-45*'` -> nothing (rc 0), 19:18:37Z |
| R7 seat | agy if quota, else the claude waiver seat (1a7c70da) |
| first inputs for round 46 | the hours-minutes whole-batch 400 on a client clock ahead (section 3.3, with its first step); the non-instruction `apply` (a noun, a status); r96-01 N1 (`spl-unanswered-sweep.func.sh:196` names a removed function, refactor-shaped); the topic loop cap race; the store tests' fresh-DB need; the `unknown_token` box; the hub dir mode; the hermetic 2/4 timeout; the composed testids; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`, g-162 N2 as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-025@`<box2>` (claude, `specs_and_docs`).
- **Panel:** placed by the holder (cross-vendor).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-24: v0.1, pushed to `review/c002-bug-round-45-planner`: 1 row.
