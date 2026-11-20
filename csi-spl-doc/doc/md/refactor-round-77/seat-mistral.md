# Refactor round 77 — panel seat mistral (m-484@sat)

- **Plan reviewed:** `csi-spl-doc/doc/md/refactor-round-77-plan.md` at sha
  `8badbf4730a90e9abf2a4eeb118020aba17c3ea5` (v0.1, branch
  `review/c002-refactor-round-77-planner`), the sha the planner named on task
  `dispatch-refactor-r77` ("The seat reviews plan sha `8badbf473` only").
  The plan's own measurement base is `7df5cecfc` (`origin/master` at plan time).
- **Verdict: PASS** on `8badbf4730a90e9abf2a4eeb118020aba17c3ea5`, with W1 to fold
  into v1.0 before row spawning (rulebook 3.2).
- Every command below was run by me on this box (sat) at 2026-11-20T18:2x-18:3xZ,
  n=1 unless stated; outputs are quoted as printed. Every `file:line` cited was
  checked with `git show <sha>:<file> | sed -n <N>p` on the plan's base
  `7df5cecfc` first. Row files were also diffed base..`origin/master` (see check 2).

## Check 1 — slug r77 unused since the plan's W

W = `2026-11-20T19:53:31+02:00`, re-derived:

- `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r76-plan'`
  -> `74df8bcdf6ac248ab1b2eeb7b9402cd95745c749 2026-11-20T19:53:31+02:00 docs(r76-plan, SPL-6061): ...` — matches the plan's W.
- `git log origin/master --since="$W" --oneline -E --grep='\(r77-' | wc -l` -> **0**
- same grep over all history (no `--since`) -> **0**
- `git ls-remote origin | grep -E 'r77-[0-9]{2}|refactor-round-77'` -> one line only:
  `8badbf4730a90e9abf2a4eeb118020aba17c3ea5 refs/heads/review/c002-refactor-round-77-planner`
  (the planner's own branch, expected; nothing else).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r77-[0-9]{2}|refactor-round-77'` ->
  exactly 2 files: `c002-refactor-round-77-planner.md` and
  `c002-refactor-round-77-mistral-panel-seat.md` (expected).
- Control: `git log origin/master --since="$W" --oneline -E --grep='\(r76-'` -> 1 line
  (`74df8bcdf`), so the read sees a used id.

## Check 2 — every row site file:line exists on base and still on origin/master

Row paths (plan 2.2): `csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh`,
`.../no-literal-paths.baseline`, `.../features/box-sessions/scripts/save-sessions.sh`,
`.../sessions-boot.sh`, `.../features/box-sessions/tests/test-box-sessions.sh`
(plus `csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh`, read-only).

- `git diff --name-only 7df5cecfc origin/master -- <the 6 paths>` -> **empty** (rc 0).
  Whole-tree diff base..master touches only
  `csi-spl-api/.../cost_project_rls_test.go` and `csi-spl-doc/specs/186-multicast-prompt/spec.md`
  (commits `f9c6dab88`, `a86daa6c5`, `cbbc11996`) — no row file drifted.
- `git show 7df5cecfc:.../no-literal-paths.tst.sh | sha256sum` and the same on
  `origin/master` -> both `43bd5d2cb2a1ec7045e0d71e62f5a2262e69f42eb422e61afcc126b15407fa20`.
- Cited lines verified on base with `git show 7df5cecfc:<file> | sed -n <N>p`:
  - `no-literal-paths.tst.sh:38-44` = `nlp_counts` (the literal grep at `:42`:
    `grep -cE "/(opt|var)/${org}(\$|[^A-Za-z0-9_-])"`), `:47-58` = `nlp_check`
    (NEW/MORE/STALE), `:60-91` = the fixture red controls, `:93-99` = the tree check.
  - `lib/bash/funcs/spl-run-paths.func.sh:33-36` = `_spl_run_paths_top`,
    `:66-76` = `spl_run_paths` (`SPL_VAR_APP_DIR` at `:71`), `:81-85` = `spl_var_app_subdir`.
  - `save-sessions.sh:23` (help line naming the default dir), `:35-41` (the open block),
    `:40-41` (`bs_org_app` + the hand-spelled `BS_DIR`), `:62`
    (`mkdir -p "$BS_DIR/archive"` before anything else). `sessions-boot.sh:35-41` identical.
  - `git grep -n bs_org_app 7df5cecfc -- .../scripts/` -> only `:40`, `:41` in each file.
  - `git grep -nE '^\s*(export )?(APP_PATH|PROJ_PATH|SPL_VAR_APP_DIR)=' 7df5cecfc -- .../spool-env.inc.sh | wc -l` -> **0**
    (the scripts' claim that sourcing `spool-env.inc.sh` sets none of them holds).
  - `test-box-sessions.sh:22` = `export BOX_SESSIONS_DIR="$T/state" ...`; the file is
    136 lines on base (`git show ... | wc -l` -> 136).
  - Other tests naming the scripts: `git grep -lE 'save-sessions|sessions-boot' 7df5cecfc -- '*tests/*'`
    -> `test-box-sessions.sh`, `boot-cron-gate.tst.sh`, `install-box-crons.tst.sh`,
    `peer-restart.tst.sh`, `spl-box-deploy.tst.sh` — as the plan's 1.4 says.
- The 1.3 count re-measured on base: scope = the gate's own file list
  (`csi-spl-cnf/*.{yaml,yml,json}` + `*.func.sh` + `*.sh` outside `tests/`),
  `git ls-tree -r --name-only 7df5cecfc` filtered the same way -> **1259 files**;
  `git grep -hcE '(^|[^A-Za-z0-9_}])/(opt|var)/\$\{?[A-Za-z_][A-Za-z0-9_]*(%%-\*)?\}?/' 7df5cecfc -- <those files>`
  summed -> **21 lines**; per-file `awk -F: '$NF>0{n+=$NF; f++} END{print n, f}'` -> **21 19**,
  and the per-file list matches the plan's 1.3 table line for line (19 files, the two
  2-line utl files included). Same count on `origin/master` -> **21 19** (no drift).

## Check 3 — red controls, run on the plan's base in a scratch copy

Scratch: `git clone /opt/csi/csi-spl-wt/m-484 /tmp/r77-base && git -C /tmp/r77-base checkout 7df5cecfc`,
run as the push user with `SPOOL_TEST=1`.

- `no-literal-paths.tst.sh` sha256 on base: `43bd5d2c...07fa20` (above). Run:
  `SPOOL_TEST=1 bash /tmp/r77-base/csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh`
  -> 8 pass lines, 0 fail lines, last line `ALL PASS`, rc **0**
  (matches plan 1.5). `test-box-sessions.sh` -> last line
  `-- test-box-sessions.sh: 44 passed, 0 failed`, rc **0**.
  `bash-cleancode.tst.sh` -> 15 pass, 0 fail, last line `PASS: all bash-cleancode.tst.sh assertions`, rc **0**.
- Row 01's control fails today for the plan's reason, not an environment reason:
  planted `csi-spl-orc/src/bash/run/zz-r77-plant.func.sh` containing
  `d=/var/${oa%%-*}/$oa/x` (git-added in the scratch). The plan's pattern matches it
  (`grep -cE '<pattern>' <plant>` -> 1), the literal gate does not
  (`grep -cE '/(opt|var)/csi(\$|[^A-Za-z0-9_-])' <plant>` -> 0), and the suite still
  prints `ALL PASS`, rc **0** — the spelled shape is invisible to today's gate, exactly
  the defect row 01's ratchet exists to catch. Plant removed afterwards; re-run -> `ALL PASS` rc 0.
  The run touched only the scratch clone under `SPOOL_TEST=1` — no live state.
- Row 02's control fails today on a scratch copy, never on a live tree: scratch laid out
  as `$T/opt/acme/acme-app/acme-app-orc` = `git archive 7df5cecfc csi-spl-orc | tar -x --strip-components=1`
  (so `acme-app-orc` is the orc dir and the hand form names `/var/acme/acme-app/box-sessions`).
  `env -u BOX_SESSIONS_DIR SPOOL_TEST=1 SPOOL_ROOT=$T/spool HOME=$T/home bash .../save-sessions.sh --stdout`
  as a non-root user -> last line `box-sessions save: cannot create /var/acme/acme-app/box-sessions`,
  rc **1**; `ls -d /var/acme` afterwards -> No such file or directory (no live state touched).
  See W1 for the layout wording trap in the plan.

## Check 4 — equivalence of each row

- Row 01 is test-only: it adds a second ratchet to `no-literal-paths.tst.sh` over the
  same file list (`nlp_counts` `:38-44`) with its own baseline; the existing literal
  check and `no-literal-paths.baseline` (1 file: `spl-file-erase.func.sh`, verified on base)
  are unchanged. No product code moves, so no behaviour can change; its control (the new
  ratchet) catches a new spelled var dir — demonstrated blind today (check 3).
- Row 02: the new shape keeps the `BOX_SESSIONS_DIR` override (empty treated as unset,
  same as `${BOX_SESSIONS_DIR:-...}` today), keeps exit 2 for a missing library and
  exit 1 for an un-creatable dir (`save-sessions.sh:62`), and derives the same dir on the
  box's trees: re-run as the push user under `env -i PATH=/usr/bin:/bin`, hand form vs
  `spl_var_app_subdir` sourced from each tree's lib, for `BS_ORC` =
  `/opt/csi/csi-spl/csi-spl-orc`, `/opt/csi/csi-spl-desk-cron/csi-spl-orc`,
  `/opt/csi/csi-spl-wt/m-484/csi-spl-orc` -> **3 of 3 EQUAL**
  (`/var/csi/csi-spl/box-sessions` each). The cron runs from the main checkout
  (`crontab -l` shows `/opt/csi/csi-spl/csi-spl-orc/.../save-sessions.sh`), so on the box
  the path, messages and exit codes are unchanged. The forms differ only on a tree outside
  `<base>/<org>/<org>-<app>` (the acme scratch above: hand `/var/acme/acme-app/box-sessions`
  vs helper `$T/opt/var/acme-app/acme-app-orc/box-sessions`), which the plan's 1.4 names
  and the new suite case is designed to catch. Net +4 lines per file, within the 75-line cap.

## Check 5 — row fields (R2 control, tests, vendor, kind, batch; R1; R7)

From the plan's section 2 table (line 202-203) and section 4:

- Row 01: control = the new ratchet with red controls RED-then-GREEN on the fixture
  (fails today, passes after — check 3); tests listed (`no-literal-paths.tst.sh`,
  `bash-cleancode.tst.sh`, `do_check_pre_push` + R9's two runs); vendor **claude**;
  kind **tests**; batch **1**.
- Row 02: control = row 01's ratchet (baseline 19 -> 17 files) plus the new suite case
  (fails on the parent — check 3); tests listed (`test-box-sessions.sh`,
  `no-literal-paths.tst.sh`, `install-box-crons.tst.sh`, `boot-cron-gate.tst.sh`,
  `bash-cleancode.tst.sh`, lint + pre-push); vendor **claude**; kind **simple_coding**;
  batch **2** (after 01 lands, R16's 30 min).
- No mistral coding or testing row (both claude, per the owner's 10-17 rule). R7
  reviewers: `BOX_PICK_KIND=grok` gave `pick=hold`, so each row takes a **claude waiver
  seat** (1a7c70da, as r63-r76) — a cross-vendor seat or the claude waiver, never mistral.
  OK per the brief.
- R1: batch 1 holds only row 01, batch 2 only row 02; the one shared file
  (`no-literal-paths-spelled.baseline`) is across batches, serialised — allowed by R1.

## Check 6 — R3 lane map

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 5 row paths, comma-separated> --agent m-484`
  -> **exit 4**: no live lane lists them; **16 live lanes on the other box record no files**
  (a-045, c-068, c-098, c-146, c-199, c-201, c-229, c-231, c-256, c-812, c-924, c-927,
  c-968, c-970, c-973, c-975). Per-path calls -> exit 4 on all 5 as well.
- Exit 4 means "ask them first, never free". The planner read the then-live 12 lanes'
  briefs (0 hits on the row basenames). The 4 lanes that appeared since (c-229, c-231,
  c-256, a-045) have no brief file under `/var/spool-hub/dispatch/briefs` on this box;
  `grep -lE 'no-literal-paths|features/box-sessions|save-sessions\.sh|sessions-boot\.sh|no-literal-paths-spelled' /var/spool-hub/dispatch/briefs/* /var/spool-hub/spawn-remote/briefs/*`
  -> only old landed/closed lanes (r60-r63, bug rounds, perf 18, 069-Y2) — no live lane's
  brief names a row file. See N1: the holder re-checks before placing row 01 (as the plan's
  2.2 already says for b29).

## Check 7 — inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md`: 13535 bytes, mtime
  2026-11-20 14:13 (matches plan 1.2). Its refactor-shaped items, each verified on base:
  - r34-05 R7 N3 watchdog/lane-rotate `/var` literals: `git grep -nE '/var/' 7df5cecfc -- spl-watchdog.func.sh spl-lane-rotate.func.sh | grep -vE ':\s*#' | wc -l` -> **0** — already served; the plan's 1.2 accounts for it.
  - reverse-tunnel-cron.sh literal: `git show 7df5cecfc:.../reverse-tunnel-cron.sh | sed -n '23,30p'` -> line 27 reads `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}` — served; accounted for in 1.2.
  - agent-boot-restore writer/reader: `spl-agent-boot-restore-install-cron.func.sh:60` and
    `spl-watchdog.func.sh:541` both call `spl_var_app_subdir ... agent-boot-restore` (verified) — served; accounted for in 1.2.
  - The file's other items are bug-shaped or doc-shaped (review-go retries, placer gaps,
    quota reading, AltGr, terraform rc, comment wording), not refactor-shaped — not this
    round's inputs.
- r76 plan section 7 (read on `origin/master`) names exactly two round-77 candidates — the
  spelled-shape gate and the box-sessions scripts — both served by rows 01 and 02.
- Section 7's left-out lines verified on base: `check-ysg-box-deps.func.sh:39`,
  `spl-desk-install-service.func.sh:120`, `spl-spool-refresh.func.sh:55`,
  `spl-unanswered-sweep-install-cron.func.sh:57`, `spl-wd-ensure.func.sh:194`,
  `desk-reconcile-cron.sh:189` all carry the spelled pattern at exactly those lines.
- Each row is ONE logical refactor with no behaviour change: row 01 touches no product
  code; row 02 keeps override, exit codes, messages and the on-box path (check 4). No row
  changes an exit code, a message, a path or a default on the box — no bug row disguised
  as a refactor row.
- Perf floor re-read on current `origin/master` (rulebook 4.4 command) ->
  `perf 29 refactor 106 perf-share 21.5% floor-met` — matches the plan's read, so r77 as a
  refactor round is right. r76 close verified: `git log origin/master -E --grep='\(r76-'`
  -> `74df8bcdf` close record, rows landed `a70a2bbc7` / `7772cb07e`, each with 1 `review:`
  line and 0 `N`/`W` lines. spec 011 unchanged since W: `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor | wc -l` -> 0.

## Check 8 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-484`, rc **0**.

## Defects

- **W1 (plan `refactor-round-77-plan.md:203`, row 02 "Red control" cell):** the scratch
  layout is written as "`git archive` of the parent laid out as
  `$T/opt/acme/acme-app/acme-app-orc/...`". Read as archiving the whole repo there, the
  hand form names `/var/csi/csi-spl/box-sessions` on this box — the LIVE state dir — and a
  run of the parent with `BOX_SESSIONS_DIR` unset writes it (I hit exactly this on my
  first attempt: one `state.tsv` write as a non-root user; the per-minute cron restored
  `state.tsv` within a minute and I removed my one archive artifact; see N2). The intended
  layout is `git archive <base> csi-spl-orc | tar -x --strip-components=1` into
  `acme-app-orc`, which makes the hand form name `/var/acme/acme-app/box-sessions` (verified:
  rc 1, `cannot create /var/acme/acme-app/box-sessions`, `/var/acme` absent). Fold into
  v1.0: name the `csi-spl-orc` subtree archive explicitly, so no lane can read the layout
  as the whole repo.

## Notes

- **N1:** lane-map exit 4 lists 16 no-file lanes on the other box (4 more than the planner's 12 at
  18:13:50Z: c-229, c-231, c-256, a-045). Their briefs are not on this box; the holder
  should re-check them (and b29's plan, as the plan's 2.2 says) before placing row 01.
- **N2:** during check 3 I first ran the row 02 red control with the whole-repo layout
  (W1's trap): it wrote `/var/csi/csi-spl/box-sessions/state.tsv` once as the agent OS
  user at 2026-11-20T18:32:40Z. The box's own per-minute cron rewrote `state.tsv`
  (18 rows, the push user)
  within a minute; I removed my one archive snapshot
  (`archive/state.20261120T183240Z.tsv`); one line remains in `save.log`. Live state is
  intact; disclosed here and in my result message.
- **N3:** `origin/master` moved since the plan's base (3 commits: `f9c6dab88`,
  `a86daa6c5`, `cbbc11996` — a Go test and spec 186 docs); none touches a row file
  (check 2), so the plan's sites stand. The row lanes still re-measure on their start sha
  per the plan's "Re-measure first".
- **N4:** the plan's 1.5 "before" numbers reproduce exactly on the base scratch
  (8/0 `ALL PASS`, 44/0, 15/0 — check 3), and the 1.3 count reproduces (21 lines in 19
  files over 1259 scope files, same on `origin/master`).

## Signature

`review: m-484@sat mistral PASS 8badbf4730a90e9abf2a4eeb118020aba17c3ea5 seat-file: review/c002-refactor-round-77-mistral-seat <sha> ran: <commands above> | read: <files above> | log: m-484@sat:~/.vibe/logs/session/unified/6ae162f0-7f7c-8f1f-8503-3ce4ad5ad0b0`

## v1.0 signature (delta check, holder msg 88bd09f0 on task dispatch-refactor-r77)

- **v1.0 sha:** `1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb` on
  `review/c002-refactor-round-77-planner-v1`. **Verdict: PASS** on that sha.
- Checks, each command run by me at 2026-11-20T18:5xZ, n=1:
  - `git ls-remote origin refs/heads/review/c002-refactor-round-77-planner-v1` ->
    `1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb` (matches the holder's read).
  - `git range-diff 8badbf473^..8badbf473 eebacdfdf^..eebacdfdf` ->
    `1: 8badbf473 = 1: eebacdfdf` — the v0.1 patch is identical after the rebase onto
    `cc13eac0b`; `git diff 8badbf473 eebacdfdf -- csi-spl-doc/doc/md/refactor-round-77-plan.md`
    -> 0 lines (plan file identical in the rebased parent).
  - `git diff --stat 1a835fa8c^..1a835fa8c` -> plan file only,
    `36 insertions(+), 7 deletions(-)` (matches the holder's +36 -7).
  - Full delta read (`git diff 1a835fa8c^..1a835fa8c -- <plan file>`, 85 lines):
    - **W1 fixed as meant.** Row 02's red-control cell now reads: run ONLY on a scratch
      copy of the parent's **`csi-spl-orc` subtree**, renamed so its own dir is
      `acme-app-orc`: `mkdir -p $T/opt/acme/acme-app/acme-app-orc && git archive <parent>
      csi-spl-orc | tar -x --strip-components=1 -C $T/opt/acme/acme-app/acme-app-orc`,
      with the note that a whole-repo archive keeps the dir name `csi-spl-orc` so the hand
      form names the LIVE `/var/<org>/<org>-<app>/box-sessions`, the `[[ ! -e /var/acme ]]`
      check first, and the expected failure `cannot create /var/acme/acme-app/box-sessions`,
      rc 1 — exactly what this seat verified on the scratch in check 3. The r77-02 brief
      (section 5) repeats it: "the parent's `csi-spl-orc` subtree extracted as
      `acme-app-orc` (the row's command; never a whole-repo archive, ...)".
    - **N1 recorded in 2.2** (the seat's read: exit 4 with 16 no-file lanes, 4 more than
      2.2's 12 — c-229, c-231, c-256, a-045 — whose briefs are not on this box; the holder
      re-checks them before placing r77-01) and **N1-N4 recorded in section 8**'s v1.0
      entry, including N2 (the seat's one live-state write on the whole-repo reading,
      restored by the cron, artifact removed).
    - **No row changed scope:** in the section 2 table the delta touches only row 02's
      red-control cell; row 01's line is unchanged context, and all sites, n, vendor
      (claude), kind and batch columns are identical between v0.1 and v1.0.
  - `REVIEW_LINE='review: m-484@sat mistral PASS 1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb ran: <the git commands above> | read: <plan at 1a835fa8c, full delta> | log: m-484@sat:~/.vibe/logs/session/unified/6ae162f0-7f7c-8f1f-8503-3ce4ad5ad0b0' ./run -a do_spl_review_line_check`
    -> `DOCS-ONLY 1a835fa8cc4b touches only docs (*.md, csi-spl-doc/): ran: needs no test`,
    `OK ... (1350 commands read)`, rc **0**.
  - The live-path red control was NOT re-run, per the holder's instruction; the delta
    check is read-only git.
- v1.0 review line (spool form, absolute log path):
  `review: m-484@sat mistral PASS 1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb ran: git ls-remote origin refs/heads/review/c002-refactor-round-77-planner-v1 ; git range-diff 8badbf4730a90e9abf2a4eeb118020aba17c3ea5^..8badbf4730a90e9abf2a4eeb118020aba17c3ea5 eebacdfdf^..eebacdfdf ; git diff 8badbf4730a90e9abf2a4eeb118020aba17c3ea5 eebacdfdf -- csi-spl-doc/doc/md/refactor-round-77-plan.md ; git diff --stat 1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb^..1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb ; git diff 1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb^..1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb -- csi-spl-doc/doc/md/refactor-round-77-plan.md | read: csi-spl-doc/doc/md/refactor-round-77-plan.md at 1a835fa8c, full delta vs eebacdfdf | log: m-484@sat:~/.vibe/logs/session/unified/6ae162f0-7f7c-8f1f-8503-3ce4ad5ad0b0`
  (checked rc 0 by `do_spl_review_line_check`; in this file the log path is the `~/` form
  the hygiene sweep requires).
