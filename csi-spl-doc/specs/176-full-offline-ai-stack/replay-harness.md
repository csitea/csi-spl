# Spec 176 T0.1: the replay-set harness

Spec 176 section 4.8 (Evaluation), phase P0 task T0.1, issue SPL-5556, epic
SPL-2402. A task kind routes to a local model only after the model passes
that kind's replay set. This harness builds the set and judges a candidate's
answers. It runs no model, installs no model server and makes no network
call. The only exception is the `keymap` step in 3.1, which reads the hub.

Code: `csi-spl-orc/src/bash/run/spl-local-replay.func.sh`
(`do_spl_local_replay`) and `csi-spl-orc/src/bash/scripts/local-replay.py`.
Test: `csi-spl-orc/src/bash/tests/spl-local-replay.tst.sh`.

## 1. What a replay case is

A case is one past lane that landed, of the kind under test:

- **the question**: the lane's brief, exactly as the spawn stored it;
- **the base**: the commit before the lane's first landed commit;
- **the known answer**: the diff from the base to the lane's last landed
  commit.

### 1.1 Where the past lanes come from

The source is the spawn's brief store (`$SPOOL_ROOT/spawn-remote/briefs`,
one file per brief, with `Kind:` and `Issue:` lines), joined to git: the
commits on `origin/master` whose subject scope cites that issue key, for
example `feat(orc, SPL-123): ...`.

- The brief store keeps the exact prompt each lane got. The hub's issues
  keep only a title and a card, so they cannot be the source of the
  question.
- Git keeps the answer that landed.
- Most author briefs have no `Issue:` line, because the spawn filed the key
  (`do_spl_lane_issue` titles the issue with the brief's heading). These
  briefs join through a keymap. `REPLAY_CMD=keymap` reads the hub issue of
  each key that git cites and matches its title to a brief heading
  (section 3.1).

### 1.2 Which lanes qualify

A lane qualifies when all of these hold:

- its brief is not a review brief (`review only`, `reviewer`, `review of`
  in the heading, or `Kind: review`);
- no other brief claims its key;
- its citing commits sit back to back on master's first-parent line, so the
  base and the answer contain nothing from another lane;
- its diff is not empty and has at most `REPLAY_MAX_LINES` changed lines
  (default 1500).

The newest landing comes first.

### 1.3 The multilingual slice

Every kind's set also takes `REPLAY_I18N` lanes of kind `i18n` (default 1).
The report scores them on their own line, `slice i18n`. Spec 176 section 4.4
uses this slice to gate a local model *drafting* the agy-led kinds in mode
B. It never replaces the agy review of multilingual text.

## 2. The throwaway repos

`REPLAY_CMD=prepare` writes `REPLAY_DIR/<kind>/`. The default `REPLAY_DIR`
is `<var>/<org>/<app>/local-replay`, from `spl_run_paths`.

| path | holds |
|---|---|
| `set.env` | kind, ref, ref sha, n |
| `manifest.tsv` | one row per case: slice, key, brief, base, landed, files, lines |
| `answers/<key>.patch` | the landed diff, kept outside every case |
| `cases/<key>/brief.md` | the brief |
| `cases/<key>/case.env` | slice, key, base, landed |
| `cases/<key>/wt/` | a fresh `git init` of the base tree, in ONE commit |

The case repo is built from `git archive <base>`, not from `git worktree`,
so no later commit and no landed answer can be reached from it. The answer
is still a file on the same disk. Keeping a candidate away from `answers/`
is the sandbox's job, which is P1 work.

## 3. Running it

### 3.1 Map the spawn-filed keys (reads the hub, once per refresh)

```bash
cd csi-spl-orc && ENV=prd TENANT_ID=t1 DESK_AGENT=<your seat> REPLAY_CMD=keymap REPLAY_KEYMAP_MAX=600 DRY_RUN=0 ./run -a do_spl_local_replay
```

Without `DRY_RUN=0` it only counts the keys. It makes one read-only
`spool issue get` per key, about 1 s each.

### 3.2 Build the set for a kind

```bash
cd csi-spl-orc && REPLAY_KIND=complex_coding REPLAY_N=5 ./run -a do_spl_local_replay
```

`REPLAY_CMD=pick` prints the rows and writes nothing.

### 3.3 Let the candidate answer

```bash
cd csi-spl-orc && REPLAY_KIND=complex_coding REPLAY_CMD=run REPLAY_CANDIDATE='<client command>' ./run -a do_spl_local_replay
```

The command runs once per case, with the case repo as its working
directory. It gets `REPLAY_BRIEF`, `REPLAY_WT`, `REPLAY_CASE_DIR` and
`REPLAY_KEY` in its environment. The candidate is a client CLI pointed at a
model endpoint (spec 176 section 4.3). This lane wires none.

### 3.4 Judge

```bash
cd csi-spl-orc && REPLAY_KIND=complex_coding REPLAY_CMD=judge REPLAY_LABEL='<client>+<model>@<rev>' ./run -a do_spl_local_replay
```

The judge commits whatever the candidate left in the case repo and writes
`candidate.patch` (the base commit to HEAD). Each case then gets one
verdict:

| verdict | when |
|---|---|
| `FAIL` | no change |
| `PASS` | the same `git patch-id --stable` as the landed answer |
| `PASS` / `FAIL` (R7 review) | `cases/<key>/review.line` holds the fleet's R7 line for the candidate commit's sha |
| `R7-PENDING` | none of the above: `cases/<key>/r7-request.md` asks a cross-vendor reviewer for that line |

The R7 line has the same form as for a landing commit:
`review: <id>@<box> <vendor> PASS|FAIL <sha> ran: ... | read: ... | log: ...`.
A line that names another sha is stale, and the case stays pending. The
judge exits 3 while any case is pending. Once every case has a verdict, it
exits 0.

## 4. The report

There is one report per kind: `REPLAY_DIR/<kind>/report.md`, plus
`results.tsv`. It states the three fields of the fleet's cross-lane finding
rule:

- **version**: `REPLAY_LABEL` (the client, the model and its revision) and
  the harness commit;
- **tree**: the ref the set was picked from and its sha, and each case's
  own base and landed sha;
- **n**: the total, and PASS, FAIL and R7-PENDING per slice.

Spec 176 section 4.8 leaves the pass bar per kind to the owner, who sets it
after reading the first report.

## 5. What was available, measured

Measured 2026-11-15 on one fleet box, on `origin/master` `1419bc151`, n = 1 run:
`REPLAY_CMD=pick REPLAY_N=9999 REPLAY_I18N=0` per kind. The brief store
held 2726 briefs. The keymap came from `REPLAY_KEYMAP_MAX=600` hub reads
(`OK read 600 hub issues, 308 briefs mapped`).

| kind | qualifying lanes, `Issue:` lines only | with the keymap |
|---|---|---|
| complex_coding | 17 | 141 |
| simple_coding | 3 | 86 |
| tests | 2 | 62 |
| specs_and_docs | 4 | 29 |
| secret | 3 | 13 |
| i18n | 2 | 2 |

The i18n slice is thin: only 2 i18n lanes qualify today. Most i18n briefs
are agy reviews, which the review filter drops, or share their key with
another brief. A larger multilingual slice needs a wider source, for
example i18n lanes whose key the keymap does not reach yet (raise
`REPLAY_KEYMAP_MAX`). That is a choice to make from the first report.
