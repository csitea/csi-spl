# Perf round 13: editor seat (c-882, claude)

Issue SPL-5774, epic SPL-2402, spec `csi-spl-doc/specs/027-spool-performance`,
round topic `2776cdb8`; report to the dispatch lease holder (c-002@sat at
06:22Z) on task `dispatch-perf-r13`. The plan:
[perf-round-13-plan.md](../perf-round-13-plan.md).

## 1. Done

- STEP 0: developer guide acked (blob `8b1916cd`), fetched.
- One sha for every baseline: **`9310612f3`** (`origin/master` at 06:2xZ,
  2026-11-17). The row files did not change between the brief's
  `457116142` and it:
  `diff <(git show 457116142:csi-spl-iac/src/bash/run/check-pre-push.func.sh) <(git show 9310612f3:csi-spl-iac/src/bash/run/check-pre-push.func.sh)`
  prints nothing.
- Rulebook 4.4 on `9310612f3` (06:23:50Z), the command verbatim:
  `perf 18 refactor 101 perf-share 15.1% under-20`.
- Slug: `git log origin/master --oneline -E --grep='\(p13-'` -> 0 lines;
  `git ls-tree -r --name-only origin/master | grep -c perf-round-13` -> 0.
- Retro: `git ls-tree -r --name-only origin/master | grep -cE 'perf-round-12-retro'`
  -> 0.

## 2. Measurements

### 2.1 The sat pre-push log (`~/.cache/csi-spl/pre-push.log` of the push user)

The log the pre-push gate writes, one `PART` line per part run (the agent
user's own log has 19 non-SKIP lines in the same 7 days and changes no
number below). Window 1: 7 days, 2026-11-10T06:20Z..11-17T06:20Z. Window 2:
since SPL-5588 landed (`1d7bae644`, 2026-11-15T12:45:06Z), when a timed-out
tree stopped being compared with trunk.

The command (window 1; window 2 changes the start):

```bash
sudo awk -v s="2026-11-10T06:20" '$1>=s && $3=="PART" {gsub(/s$/,"",$6); k=$4" "$5; n[k]++; t[k]+=$6} END{for(k in n) printf "%-40s n=%d sum=%d mean=%d\n",k,n[k],t[k],t[k]/n[k]}' ~/.cache/csi-spl/pre-push.log | sort
```

| part verdict | 7 days: n, sum s, mean s | since 1d7bae644: n, sum s, mean s |
|---|---|---|
| `wui` WARN-pre-existing | 177, 158,639, 896 | 0 |
| `wui` FAIL | 43, 53,820, 1,251 | 2, 2,487, 1,243 |
| `wui` PASS | 191, 148,192, 775 | 52, 35,802, 688 |
| `orc-features` WARN-pre-existing | 31, 33,806, 1,090 | 0 |
| `orc-features` FAIL | 40, 69,937, 1,748 | 0 |
| `orc` WARN-pre-existing | 31, 140,986, 4,547 | 16, 33,891, 2,118 |
| `api` PASS, tier full | - | 14, 2,355..3,419 s each |
| `api` PASS, tier fast | - | 32, 28..562 s each |
| `lint-gosec` PASS (tier full only) | - | 44, 45,731, 1,039 (628..1,696 s) |

- The 177 `wui` WARN-pre-existing runs were `TIMED OUT after 420s` on the
  tree, then the whole part again on trunk (every detail field of the 15
  largest groups reads `TIMED OUT after 420s`). By day: 22, 67, 30, 28, 20,
  10 from 11-10 to 11-15; 0 on 11-16 and 11-17.
- `orc-features` WARN-pre-existing by day: 6, 5, 19, 1 from 11-10 to 11-13,
  then 0.
- The `orc` WARN-pre-existing runs since `1d7bae644` predate p12-01
  (`d5f6f6887`, 2026-11-16T23:52Z); after it, `orc` and `iac` read only
  `SKIP-untouched` up to 06:20Z. That is the p12 retro's to measure, not this
  plan's.

### 2.2 Timed-out tree runs since SPL-5588 (row 01)

```bash
sudo awk '$1>="2026-11-15T12:45:06Z" && /TIMED OUT after/' ~/.cache/csi-spl/pre-push.log
```

n=2 (one lane, c-664, HEAD `9a38c150c`, tier full):

- `wui-e2e FAIL 2881s ... TIMED OUT after 1870s ... trunk=0a6e9d22e-green timed-out-not-compared`
- `api FAIL 5408s ... TIMED OUT after 2700s ... trunk=77154caf0-red timed-out-not-compared`

The part's total minus its budget is the trunk re-check with its base
worktree: **1,011 s and 2,708 s**. Both verdicts are FAIL. On `9310612f3`
`_pp_timed_out` (`check-pre-push.func.sh:1149-1159`) FAILs whatever `brc`
is; the re-check only colours `trunk=` and one log phrase.

Before SPL-5588 the re-check did decide the verdict (WARN-pre-existing):
7 days of `TIMED OUT after` lines whose seconds exceed the budget -> n=466,
358,438 s past the budget. That says how often parts time out under load;
it is not the saving.

### 2.3 lint-gosec: whole module vs one package (row 02 candidate)

Probe `gosec-ab.sh` (scratch, never committed): `git archive 9310612f3
csi-spl-api` into a scratch dir, then, alternating, `gosec -fmt=json -quiet
-severity high <pkgs>` with A = `./...` (today's scan,
`sec-gosec.func.sh:117`), B = `./internal/wire/...`, C =
`./internal/store/...`; seconds, the 1-minute load and the issue count per
run.

Running at 06:37Z: run 1, arm A (`./...`) still scanning after 15 min 49 s, load 40..62; another `gosec ./...` (a pre-push) ran beside it. Results go in v0.2.

## 3. R3 reads

- Lane map, every machine, 06:21:44Z: `lane-map.sh --check
  csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh,csi-spl-iac/src/bash/run/sec-gosec.func.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-doc/doc/md/perf-round-13-plan.md,csi-spl-doc/doc/md/perf-round-13/editor.md
  --agent c-882` -> exit 4: 0 `owned by` lines, 17 `unknown:` lines, all on
  the second box (8 rotation seats and 9 lanes; no slug names the pre-push
  gate or gosec).
- Spawn queue, 06:21:53Z (`ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`): `3 queued, 0 placing`:
  `c001-spl5735-doc-announce-refusal-followup` (docs) and two agy i18n
  reviews (`spl5706`, `spl5707`).
- Round rows: p12-01, p12-02 landed; `git log origin/master --format=%s -E
  --grep='\(<r>-[0-9]{2}-'` -> r59 6 lines, r60 0, r61 0, r62 0.

## 4. Sent

- c-002@sat, task `dispatch-perf-r13`, msg ad164a03 (06:23:11Z): the panel
  seat request.
- c-001@sat, task `dispatch-perf-r13` (06:23Z): the six carried non-perf
  candidates, as their own asks.
- c-002@sat relayed c-001 cbada223 (msg c91e9816): e895dea6 carries to p13; the mistral seat is ask 9c0a6cef.
