# Refactor round 63 (r63): mistral panel seat (m-582)

Seat: m-582@sat, placement `c003-refactor-round-63-mistral-panel-seat` (mistral;
docs and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c003-refactor-round-63-mistral-panel-seat.md`
(Issue SPL-5912, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `675dfea3-7648-47e2-b751-08eb68160a53`).

Review target: plan v0.1 `621788d9b2f9ce68b53b6c36074d2755e000a2fa`, named by
c-915 msg c2a6cc15 and in the brief. Provenance: `git ls-remote origin | grep -E
'r63-[0-9]{2}|refactor-round-63'` -> `621788d9b2f9ce68b53b6c36074d2755e000a2fa
refs/heads/review/c002-refactor-round-63-planner` (only that branch);
`git show 621788d9b --stat` -> 1 file, +268,
`csi-spl-doc/doc/md/refactor-round-63-plan.md` (268 lines, read in full at that
sha). `git merge-base --is-ancestor e7ff0e347 origin/master` -> exit 0 (the
plan's measuring sha is on trunk). origin/master at my read: `232902108`.

## Verdict

**PASS on `621788d9b2f9ce68b53b6c36074d2755e000a2fa`** (plan v0.1, 2 rows). All
eight checks of the brief re-run by me, commands and outputs below. Defects:
none. Notes: N1..N4 below.

## Checks (each with the command run and what it printed, 2026-11-18 17:2x-17:5xZ)

### 1. Slug r63 unused

- `git log origin/master --oneline -E --grep='\(r63-' | wc -l` -> **0**.
- `git ls-remote origin | grep -E 'r63-[0-9]{2}|refactor-round-63'` ->
  `621788d9b2f9ce68b53b6c36074d2755e000a2fa  refs/heads/review/c002-refactor-round-63-planner`
  only — the planner's branch, expected; my own review branch does not exist on
  origin yet. Nothing else named.
- `git ls-tree -r --name-only e7ff0e347 csi-spl-doc/doc/md/ | grep -c 'round-63'`
  -> **0** (no `refactor-round-63*` file on the measuring sha, so the plain plan
  name is free, rulebook 5.3 "Files").

### 2. R15: round 35's signed rows 05/06 and the sha mapping

- `git log origin/master --oneline --grep='round 35' -i | head` -> includes
  `08efd6484 docs(refactor-round-35-plan, SPL-5831): refactor round 35 plan v1.0, panel m-392 mistral PASS on v0.2 a73b73d47`.
- `git log -1 --format='%H %cI %s' e563bf623` ->
  `e563bf623248e1eb442ec54abfaa45dfdb5af985 2026-11-18T10:17:09+02:00 docs(refactor-round-35-plan, SPL-5831): refactor round 35 plan v1.0, panel m-392 mistral PASS on v0.2 a73b73d47`;
  same command on `08efd6484` ->
  `08efd648496cfd305e66383dd9b81c89e1f6e8f0 2026-11-18T10:17:09+02:00 <same subject>`.
  `git rev-parse e563bf623:csi-spl-doc/doc/md/refactor-round-35-plan.md 08efd6484:csi-spl-doc/doc/md/refactor-round-35-plan.md`
  -> both `81f00cbfce87d65d630c217fffa3f9869aba0818` (same plan blob). The
  e563bf623 -> 08efd6484 mapping holds (subject match per R15).
- Rows 05/06 in the signed plan:
  `git show 08efd6484:csi-spl-doc/doc/md/refactor-round-35-plan.md | grep -n 'r61-0[56]'`
  -> line 142 `05 refactor(r61-05-orc-feature-state-dirs)` with sites
  `spl-workspace-docs-purge.func.sh:36,48,135`, `prune-docker-images-install-cron.func.sh:8,27`,
  `setup-reverse-tunnel.func.sh:30,40`, vendor claude, kind simple_coding;
  line 143 `06 refactor(r61-06-orc-key-path-examples)` with
  `spl-desk-up.func.sh:66`, `spl-m3-e2e.func.sh:85`, `spl-desk-install-service.func.sh:327,329`,
  claude, simple_coding. Signed: same file lines 38 and 288
  ("panel seat m-392@sat (mistral) PASS on v0.2 a73b73d47").
- The 6 row files unchanged since then:
  `git log --oneline f284b4148..e7ff0e347 -- <6 files> | wc -l` -> **0**;
  `git log --oneline 08efd6484..origin/master -- <6 files> | wc -l` -> **0**.

### 3. Every site file:line of both rows on `e7ff0e347` and on origin/master

`git show <sha>:csi-spl-orc/src/bash/run/<file> | sed -n <N>p` for each site, on
both shas — identical on the two, and matching the plan's section 2 wording:

- `spl-workspace-docs-purge.func.sh:36` -> `# @param PURGE_EXPORT_DIR (optional) - default /var/csi/csi-spl/workspace-docs-purge/<env>/<tenant>/<utc ts>`
- `:48` -> `  dir="${PURGE_EXPORT_DIR:-/var/csi/csi-spl/workspace-docs-purge/$ENV/$tenant/$(date -u +%Y%m%dT%H%M%SZ)}"`
- `:135` -> `  # the default ACL of the parent (/var/csi carries one) would give.`
- `prune-docker-images-install-cron.func.sh:8` -> `# @description /var/csi/csi-spl/docker-prune/cron.out. Tagged`
- `:27` -> `  local ct="${PRUNE_CRONTAB:-crontab}" logdir="${PRUNE_CRON_LOG_DIR:-/var/csi/csi-spl/docker-prune}"`
- `setup-reverse-tunnel.func.sh:30` -> `# @param REVERSE_TUNNEL_STATE_DIR (optional) - default /var/csi/csi-spl/reverse-tunnel`
- `:40` -> `  local dir="${REVERSE_TUNNEL_STATE_DIR:-/var/csi/csi-spl/reverse-tunnel}" dry=1 k s dest`
- `spl-desk-up.func.sh:66` -> `# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ROOT_KEY_JSON=/var/csi/csi-spl/tenants/dev/t1.<ts>.json DRY_RUN=0 ./run -a do_spl_desk_up`
- `spl-m3-e2e.func.sh:85` -> `# @example ENV=dev TENANT_ID=t1 ROOT_KEY_JSON=/var/csi/csi-spl/tenants/dev/t1.<ts>.json ./run -a do_spl_m3_e2e`
- `spl-desk-install-service.func.sh:327` -> `# @reboot jobs at 18:38:48Z while /opt, /var/csi and /var/spool-hub (nofail`
- `:329` -> `# `>> /var/csi/...` redirect failed ("Directory nonexistent"), so no job ran,`

The plan's literal grep, re-run per file on both shas
(`git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' <sha> -- csi-spl-orc/src/bash/run/<file>`):
row 01 -> exactly 7 lines (36,48,135 / 8,27 / 30,40); row 02 -> exactly 4 lines
(66 / 85 / 327,329). No drift between `e7ff0e347` and origin/master.

### 4. Each row: practice, R2 control/test, test list, vendor, kind, batch; R7 reviewer

- Plan section 3 table: both rows carry practice (no literal box path, developer
  guide 2.3.1), why, sites, n, test + red control, box, **vendor claude**,
  **kind simple_coding**, batch (01: batch 1 after r62-02; 02: batch 2 after 01).
  No mistral coding or testing row (owner 10-17, t1 b61851fb msg 91bf8278).
- Test lists re-run with the plan's own command on both shas: row 01 NAMES
  (`spl-workspace-docs-purge prune-docker-images-install-cron setup-reverse-tunnel`)
  -> **4** files on `e7ff0e347` and on origin/master
  (`orc-shard-weights.txt`, `prune-docker-images.tst.sh`, `reverse-tunnel.tst.sh`,
  `spl-workspace-docs-purge.tst.sh`); row 02 NAMES (`spl-desk-up spl-m3-e2e
  spl-desk-install-service`) -> **60** files on both. Matches the plan.
- Row 02's named subset exists on `e7ff0e347` (`git cat-file -e` OK x5):
  `iac:tests/action-header-tags.tst.sh`, `orc:tests/m3-e2e-none.tst.sh`,
  `orc:tests/desk-install-service-envs.tst.sh`, `orc:tests/desk-install-service-user.tst.sh`,
  `orc:tests/boot-cron-gate.tst.sh`.
- R2 bullet 2, the 30-character strings, `git grep -lF '<string>' e7ff0e347 -- 'csi-spl-*/**/tests/*'`
  -> **0** files each for `DESK_AGENT=CLE-00 ROOT_KEY_JSON`,
  `ROOT_KEY_JSON=/var/csi/csi-spl/tenants`, `jobs at 18:38:48Z while /opt`,
  `redirect failed ("Directory nonexistent")`.
- Red control exists: `git show e7ff0e347:csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh | grep -n STALE`
  -> lines 50, 51 (`STALE baseline: ... drop its line`, `bad = 1`) and 77 (red
  control assertion). Gates named for row 01 exist (`git cat-file -e` OK):
  `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh`, `run-eager-files.tst.sh`.
- R7 (plan section 5): row reviewers are an agy seat per row, else the holder's
  claude-waiver call; the plan says "Not a mistral code R7" — compliant with
  rulebook 2.7.2. The mistral panel seat reviews this doc only, allowed by
  91bf8278 (docs and reviews only).

### 5. Section 7 baseline counts, re-counted on origin/master

- `git show origin/master:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
  -> **`11 23`** (same on `e7ff0e347`). Matches section 7's 11/23.
- Per-file entries on origin/master: `3 spl-workspace-docs-purge.func.sh`,
  `2 prune-docker-images-install-cron.func.sh`, `2 setup-reverse-tunnel.func.sh`
  (row 01: 3 entries, 7 lines), `1 spl-desk-up.func.sh`, `1 spl-m3-e2e.func.sh`,
  `2 spl-desk-install-service.func.sh` (row 02: 3 entries, 4 lines),
  `2 spl-spawn-place.func.sh` (r62-02's entry, still present).
- Arithmetic of section 7: 11/23 -> r62-02 drops 1 file/2 lines -> 10/21 ->
  r63-01 drops 3 files/7 lines -> 7/14 -> r63-02 drops 3 files/4 lines -> 4/10.
  The 4 files left are `spl-reflection-gather` 2, `spl-cmd-guard-mode` 3,
  `fleet-logrotate-install` 3, `spl-file-erase` 2 = 4 files / 10 lines, exactly
  section 7's list.
- Cross-check of the r62 step: `git show 04ca1d897:...baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
  -> `14 30`; `git diff b36b20577^..b36b20577 -- csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -E '^[-+][0-9]'`
  -> `-2 install-box-crons.func.sh`, `-3 spl-box-state-backup.func.sh`,
  `-2 external-api-health.func.sh` (r62-01 took 3 files / 7 lines).

### 6. R3: lane-map over the 7 written paths, and the 3.1 judgment

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-workspace-docs-purge.func.sh,csi-spl-orc/src/bash/run/prune-docker-images-install-cron.func.sh,csi-spl-orc/src/bash/run/setup-reverse-tunnel.func.sh,csi-spl-orc/src/bash/run/spl-desk-up.func.sh,csi-spl-orc/src/bash/run/spl-m3-e2e.func.sh,csi-spl-orc/src/bash/run/spl-desk-install-service.func.sh,csi-spl-orc/src/bash/tests/no-literal-paths.baseline --agent m-582`
  -> **exit 4**: no live lane lists any of the 7 paths, but 15 live lanes record
  no files (scope unknown, not free): c-054, c-060, c-390, c-714, c-812, c-866,
  c-885, c-902, c-908, c-915, c-917, c-924, c-927, c-933, c-936 (15 lanes, all
  on the other fleet box).
  The plan's own 17:12:20Z read got exit 3 naming c-908 as owner of the baseline.
- Live worktrees on this box: `for d in /opt/csi/csi-spl-wt/*/; do git -C "$d" diff --name-only origin/master...HEAD; git -C "$d" status --porcelain; done`
  matched against the 7 basenames -> **0 hits** (241 dirs scanned).
- r62-02 (c-908, SPL-5910): `git ls-remote origin | grep r62-02` ->
  `91b450be9a4aec43e1c3e8f5fd62d1dccb69aedd refs/heads/review/c002-r62-02-orc-spawn-place-token-burn-dir`;
  after fetch, `git log --oneline origin/master..FETCH_HEAD` -> 1 commit
  `91b450be9 refactor(r62-02-orc-spawn-place-token-burn-dir, SPL-5910): ...`;
  `git diff --name-only origin/master...FETCH_HEAD` -> `spl-spawn-place.func.sh`
  + `no-literal-paths.baseline`; `git log origin/master --oneline -E --grep='\(r62-02' | wc -l`
  -> **0** (not landed).
- **Judgment on 3.1:** the only contested path is the baseline, and 3.1
  serializes it — row 01 carries `SPAWN_AFTER=c002-r62-02-orc-spawn-place-token-burn-dir`
  and row 02 spawns after row 01, so all three baseline edits are ordered.
  The mechanism exists: `git ls-tree --name-only origin/master csi-spl-orc/src/bash/run/ | grep spawn-after`
  -> `spl-spawn-after.func.sh`; `git show origin/master:csi-spl-orc/src/bash/run/spl-spawn-after.func.sh | grep -c SPAWN_AFTER`
  -> 25. **3.1 handles the r62-02 collision.**

### 7. R1 across rounds: no live perf/bug round row names these files

- Newest plans on origin/master: `perf-round-18-plan.md`, `bug-round-18-plan.md`
  (from `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -oE '(perf|bug)-round-[0-9]+-plan\.md' | sort -t- -k3 -n | tail`).
- `git show origin/master:csi-spl-doc/doc/md/<plan> | grep -cE 'spl-workspace-docs-purge\.func\.sh|prune-docker-images-install-cron\.func\.sh|setup-reverse-tunnel\.func\.sh|spl-desk-up\.func\.sh|spl-m3-e2e\.func\.sh|spl-desk-install-service\.func\.sh'`
  -> perf-round-18: **0**, bug-round-18: **0**. (bug-round-18's one hit for the
  wider pattern is `no-literal-paths.baseline` inside r62's off-limits list,
  line 49 — not a code file.)
- Over all perf/bug plans on origin/master, only bug-round-15 (line 85, a
  measurement site `spl-desk-up.func.sh:358`) and bug-round-16 (line 55, r35's
  row files listed as off limits) name any of the 6 — context, not rows.

### 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-582`,
  exit 0.

## Defects

None. W1..: none.

## Notes

- N1: plan 3.2 cites r62-02's branch commit as `70732f2a5`; at my read the branch
  head is `91b450be9` (still 1 commit not on master, same 2 files). Stale sha
  only; the holder's R3 re-check before each row's spawn governs, as the plan
  itself says.
- N2: my lane-map read returned exit 4, not the exit 3 the plan recorded at
  17:12:20Z — 15 live lanes record no files, so their scope is unknown, not
  free (ask-first). None of them owns any of the 7 paths; the only known
  contested path is the baseline via r62-02, serialized by 3.1 (check 6).
- N3: rulebook 3.1's "file:line sites (at most 5)" vs row 01's 7 line sites —
  the same shape as the signed r35 row 05 (its line 142) and r62's rows; read
  as per-file / signed precedent, not treated as a defect.
- N4: the plan measures on `e7ff0e347`; origin/master has since moved to
  `232902108`. I re-read every site line and the baseline on origin/master too
  (checks 3 and 5): identical, so no drift between the measuring sha and trunk.
