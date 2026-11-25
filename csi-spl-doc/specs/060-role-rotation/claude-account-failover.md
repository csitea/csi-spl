# 060 add-on: cross-box Claude login failover (design, SPL-5695)

Status: **built, step 2 of 2, default-off** (holder c-002 build GO, msg
d8c3c9e7). It runs only once cnf `env.box.claude_login_pool.enabled` is true,
after the owner's step 0 (section 6). What the build changed from this design:
section 8. Issue SPL-5695, epic SPL-2364, topic 64ca0e0c.
This is an add-on to [spec 060](spec.md): it reuses the second login folder
of section 5.3 (SPL-2943 / SPL-3023, `claude2`) for a new trigger.

## 1. What the owner decided

Owner HUM-10, t1 64ca0e0c, msg 1147c760 (2026-11-16 05:5xZ). It replaces
msgs a1dabc14 and 428630ce:

> "there will be one active on DNK and one active on SAT boxes, but the SAT
> box account will act as the backup/failover for the DNK account. Whenever
> there is a problem with the limit of the [box 1] account, the SAT account will
> take over, and vice versa. Because I have four logins, which seem to be
> okay for now, what will happen is that only once a week I will switch the
> SAT account, and three times a week I will switch the [box 1] account."

("DNK" and "[box 1]" are voice-typed names of box 1, the home box; the bracket replaces a box name the hygiene sweep keeps out of the repo.) So:

| # | rule |
|---|---|
| D1 | each box runs ONE account of its own in the agent user's main Claude folder (`~/.claude`) |
| D2 | each box's backup is the OTHER box's current account, kept in the agent user's second folder (`CLAUDE2_CONFIG_DIR`, default `~/.claude-2`) |
| D3 | a box whose own account nears its weekly limit starts new claude work under the backup; it comes back when its own account has quota again |
| D4 | the owner swaps the accounts by hand (sat weekly, box 1 three times a week). The code never signs in, never logs out and never changes an account |

## 2. What is there today (origin/master 28fdd8879, measured 2026-11-16)

| fact | the check |
|---|---|
| box 1 and sat run ONE shared login. box 1 is the refresher and pushes its main credential into sat's main folder over ssh | `grep -c '^SPOOL_LOGIN_PEERS=sat=' /var/spool-hub/box.env` -> 1 on box 1; `do_spl_agent_login_check` `_lc_peer_one` |
| box 1's second folder is filled from the box user's own Claude folder (owner choice B, SPL-3023), for the role failover only | `grep -c '^SPOOL_LOGIN2_SRC=' /var/spool-hub/box.env` -> 1 on box 1 |
| the existing cross-box path is box 1 -> sat ssh, run by the box user. sat cannot reach box 1 (NAT, `_lc_pull` comment) | `sudo -u <box user> ssh -o BatchMode=yes satellite true` -> exit 0 on box 1 |
| the claude weekly mark is the generic `env.box.quota.weekly_max_pct` (90). `vendor_weekly_max_pct` has only `grok: 95` and no claude row | `csi-spl-cnf/csi-spl/all.env.yaml:1561-1564` |
| the box reads the agent user's own claude weekly % from the CLI's cache in `~/.claude.json` (`cachedUsageUtilization.seven_day`, kept only when its `accountUuid` is the login's) | `spl_box_quota_cache_read`, `csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh:196` |
| task 8 (lane c002-64ca-t8-rotate-weekly-first: rotation and placement check the weekly % first) has not landed | `git log --oneline -40 origin/master \| grep -ci weekly` -> 1 (SPL-5604, not task 8) |

## 3. The risk: two boxes renewing one login (measured)

The alerts panel (`/var/spool-hub/dispatch/64ca0e0c-alerts-panel.md`, row F)
suspects a refresh race: 2 of 100 alerts, unproven. box 1's own login check
logs give a sharper number for the shared login of section 2.

- **Source**: `/var/csi/csi-spl/agent-login-check/{cred.log,cron.log}` on box 1,
  from 2026-11-01T00:00Z to 2026-11-16T07:27Z.
- **Renewals**: 56. Each is a `cred.log` line, meaning the sha changed. That
  is 3 to 5 a day, once per ~8 h access token.
- **Stuck-login episodes**: 19. An episode is a run of `stuck_login>0` ticks,
  split where the gap is over 600 s.
- **Episodes within 15 min of a renewal**: 19 of 19, so 0 lie far from one.
- **Warnings**: 2376 lines of "expires in N min, not renewed" since 11-01.
  The token is renewed only in its last minutes, then pushed to sat
  (`copied=1` once per renewal).

n = 19 episodes, one box, one sharing setup. This shows that login trouble
clusters at the renewal of a shared credential. It does not prove that a
second box's renewal invalidated the first. The incident of 2026-10-25 is the
direct case, n = 1: a peer's renewal killed the older copy here at its next
refresh, and 4 panes showed "Login expired" (`_lc_pull` comment in
`spl-agent-login-check.func.sh`).

D2 makes sharing unavoidable while a box is on its backup: the lender box's
own seats and the borrower's backup seats then run one account. The design
keeps that window short and the copies converged (section 4.3). It ends the
full-time sharing of section 2 (step 0 of section 6). The residual risk is
stated in section 4.3.

## 4. The design

### 4.1 Account labels, never content

Every account is named by a **label**: `acct-` followed by the first 8 hex
of the sha256 of `oauthAccount.accountUuid` from that folder's
`.claude.json`. No email, no token and no file path appears in a log, an
alert, a post or a commit. A credential moves only through a pipe, as the
existing `agent-login-cred.sh get | put` does. Output is a sha12 at most.

### 4.2 The login mode: own or backup (new action)

**`do_spl_claude_login_mode`** (new, `csi-spl-orc/src/bash/run/spl-claude-login-mode.func.sh`).
It runs on each box, every minute, inside the existing `agent-login-check`
tick, so there is no new cron row. It is a dry run unless `DRY_RUN=0`. It
writes one file, `<login-check state>/login-mode`:
`<epoch> <own|backup> <own label> <backup label> <own pct> <own reset> <backup pct> <second folder> <reason>`
(`-` for an unknown value; built: section 8).

| from | to | when |
|---|---|---|
| own | backup | the own account's weekly % is at or over the claude mark, AND the backup folder probes ok, AND the backup account's weekly % (the other box's `wk=claude:<pct>` in its BOX-0 row, the same reading the box pick uses) is under the mark |
| own | own (hold, one alert) | the own account is at the mark but the backup is unusable (not logged in, probe not ok, over the mark, or no reading). The existing placement hold then applies unchanged |
| backup | own | the own account's label changed (the owner swapped it), OR the own reading's reset has passed, OR a fresh own reading is under `back_below_pct` (85) |
| backup | own (forced) | the backup folder probes `expired` or `limited`, or the backup's label stops matching the other box's own label. That is a stale copy: never run on it |

- **The mark** is task 8's mark, read through the same function
  (`spl_box_quota_vendor_max claude`, else `weekly_max_pct`), so it is 90
  today. This action does not define a second cutoff.
- **The own reading** is `spl_box_quota_cache_read` of the MAIN folder's
  `.claude.json`. The pane banners are no longer used for it while on
  backup, because a backup seat's banner shows the backup account. Which
  login a pane runs comes from its process environ (`CLAUDE_CONFIG_DIR`), as
  the role failover already reads it.
- **Every mode change** is ONE alert to the dispatch lease holder, keyed on
  (mode, own label, backup label), so it is deduplicated:
  `login-mode@<box>: own -> backup (own acct-xxxxxxxx 91%, backup acct-yyyyyyyy 40%)`.

### 4.3 The backup folder kept fresh, over the existing path

**`do_spl_agent_login2_sync`** gets a second kind of source:
`LOGIN2_SYNC_SRC=peer:<tag>` (box.env `SPOOL_LOGIN2_PEER=<tag>=<ssh dest>`).
The `<ssh dest>` is the one `SPOOL_LOGIN_PEERS` names today. This is the
existing box 1 -> sat path and no new tunnel. sat cannot reach box 1, so box 1
drives both directions:

1. **sat's account -> box 1's second folder**: `get` from sat's main folder,
   `put` into box 1's second folder.
2. **box 1's account -> sat's second folder**: `get` from box 1's main folder,
   `put` into sat's second folder (a new `slot=2` argument of
   `agent-login-cred.sh`).
3. **Newest wins within ONE label, in both directions**: when a borrower's
   backup seats renewed the shared token first, the borrower's second-folder
   copy is newer than the lender's main folder. It is then copied BACK into
   the lender's main folder, only if it probes ok and has the same label.
   That is the `_lc_pull` rule of the login check, applied per label. It
   closes the 10-25 case: the older copy dies at its next refresh.
4. **Never across labels into a main folder.** A main folder is written only
   by a newer copy of its OWN label, so the owner's swap is never undone.
   A second folder whose label differs from the lender's current label is
   replaced at once, newer or not, because it is a stale account.
5. **Every tick** (60 s, inside `agent-login-check`, under its flock), not
   every 5 min: the window for the race is the time between one side's
   renewal and the copy reaching the other side.
6. Every file lands as the agent user, mode 600, through a temp file and
   `mv`, and the old one is kept as `.bak-login2-<UTC>` (the newest 5).
   The `.claude.json` of the second folder gets only `oauthAccount` and
   `hasCompletedOnboarding` from the lender: no token, no history.

**Residual risk, stated**: a stale copy that refreshes inside that window
(at most one tick, 60 s, after the other side's renewal) still fails. The
login check then restores the stuck seat (spec 132, section 6). So the race
is made shorter and rarer, not impossible. Sharing happens only while a box
is on backup, and no longer all the time. The step 2 proof counts it
(section 5, case L9).

**One copy for any vendor, on demand: `do_spl_agent_cred_sync`** (SPL-6487,
owner HUM-10 t1 2d0a9f79 msg 72a9aaee: answer A, a generic action with this
sync as its wrapper; answer N, on demand only, so no cron row). It copies
one agent CLI login (`CRED_VENDOR=agy|claude`) in ONE direction,
`CRED_SRC_BOX` -> `CRED_DST_BOX`: box tags, one of them this box, the other
a peer of box.env reached over ssh. The source is always the main login; the
target is `CRED_SLOT` (`main`, or `2` for claude's second folder). A login's
files, the jq path of its expiry, its account file and the CLI of its proof
are cnf (`env.box.agent_cred_sync.<vendor>.<slot>`), each under the agent
user's home as `getent` reads it on its own box. The guards are this
section's, through the same `agent-login-cred.sh` (its f-ops): newer only
(claude `claudeAiOauth.expiresAt`, agy `token.expiry`), a missing source
file, an expiry that cannot be read (at the source, or at an existing
target) and a target that cannot be read are refused (exit 2), a claude
main login is never written with another account label nor over a target
credential whose account is unknown, a stale second folder is replaced, temp file + `mv` as the agent
user, mode 600, the old file kept as `.bak-cred-<UTC>`, and only sha
prefixes, the label and the expiry printed. After the copy it runs one
headless prompt as the agent user on the target (`agy -p` / `claude -p`);
any answer but ok puts every file back from its `.bak` and exits 1.
`DRY_RUN=1` by default. `do_spl_agent_login2_sync` is now
`CRED_VENDOR=claude CRED_SLOT=2` of it with no box, which runs the sync of
this section unchanged. Test: `csi-spl-orc/src/bash/tests/spl-agent-cred-sync.tst.sh`.

### 4.4 New seats and rotations start under the backup

- **spawn**: when `login-mode` says `backup`, a claude spawn gets
  `SPAWN_CLAUDE_CONFIG_DIR=<second folder>` unless the caller set one.
  This is one function, `spl_claude_login_dir`, sourced by
  `spawn-core.inc.sh`, which already passes the folder through (line 831).
- **rotation**: a rotation spawns through spawn-core, so it gets the same
  folder (`spl-rotate-lib.func.sh` is unchanged, section 8). A running seat
  moves at its next rotation. **Nothing is killed** on a mode change.
- **back to own**: new spawns and the next rotation start on the main folder
  again. Backup seats finish their work and rotate home.
- **The box pick**: a box on backup publishes the ACTIVE login's % as
  `wk=claude:<pct>` in its BOX-0 row, so a box on backup with room still
  takes claude lanes. This touches `spl_lane_box_report`. Task 8's files are
  checked with `lane-map.sh --check` before step 2's first edit; if task 8
  owns them, the change goes to that lane through the orchestrator.

### 4.5 cnf and box.env

| key | default | means |
|---|---|---|
| cnf `env.box.claude_login_pool.enabled` | `false` | the mode action plans only (it logs what it would do) until the owner turns it on |
| cnf `env.box.claude_login_pool.back_below_pct` | `85` | back to own under this %, a 5-point hysteresis under the mark |
| box.env `SPOOL_LOGIN2_PEER` (box 1 only) | none | `<tag>=<ssh dest>`, the peer whose account is the backup. Set with `box-config.sh` |
| box.env `SPOOL_LOGIN_PEERS` (box 1) | `sat=satellite` | **emptied** in the owner's step 0: the main-to-main push would overwrite sat's own account |

The mark itself stays task 8's key. This design adds no cutoff.

## 5. Tests, the red control, the proof

The new cases come in step 2, in the same commits as the code, on a throwaway
`SPOOL_ROOT` with fake folders and `LOGIN_PEER_CMD` in place of ssh:

| case | file | asserts |
|---|---|---|
| L1 | `spl-agent-login2-sync.tst.sh` | `peer:sat` pulls sat's main into the second folder here and pushes here's main into sat's second folder |
| L2 | same | newest wins within one label: a newer borrower copy goes back into the lender's main folder, only when it probes ok |
| L3 | same | a different label never reaches a main folder; a stale-label second folder is replaced |
| L4 | same | a planted marker in the fake credential never appears in stdout, stderr or the log (the no-content gate) |
| M1 | `spl-claude-login-mode.tst.sh` (new) | own 91 %, backup 40 % -> `backup`, one alert |
| M2 | same | backup at 92 % -> stays `own`, hold alert once, not every tick |
| M3 | same | own label changes -> `own` at once; own reset passed -> `own`; own 84 % -> `own`; own 87 % -> stays `backup` |
| M4 | same | the backup probes expired -> forced `own` |
| M5 | same | `enabled: false` -> plan line only, `login-mode` unchanged |
| S1 | `spawn-agents/tests/` (new case) | `login-mode=backup` -> the spawned claude has `CLAUDE_CONFIG_DIR=<second folder>`; `own` -> none; a caller's own value wins |
| L9 | proof, after the owner's step 0 | 7 days: stuck-login episodes within 15 min of a renewal, against section 3's 19 in 56 |

**Red control (n = 1, to be quoted in the step 2 report)**: the new case
files run against origin/master's code fail on L1, M1 and S1 (no `peer:`
source, no mode action, no folder pick), and pass on the branch.

**Gates**: `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` (or the
touched files' tests), `cd csi-spl-iac && ./run -a do_check_pre_push`.

## 6. The owner's steps (no agent does these)

0. **Once, before turning it on**: sign sat's agent user into its own
   account (`claude /login` as the agent user on sat). In the SAME step, box 1's
   `SPOOL_LOGIN_PEERS` is emptied and `SPOOL_LOGIN2_PEER=sat=<ssh dest>` is
   set, or box 1's next tick overwrites sat's new account. Spec 132 section 4
   asks for the same single step.
1. **Turn it on**: cnf `claude_login_pool.enabled: true` (a normal commit
   with the owner's go).
2. **The swaps**: sat weekly, box 1 three times a week, by `/login` in the
   agent user's main folder. The code sees the new label on its next tick,
   comes back to `own` if it was on backup, and refreshes the other box's
   second folder.

## 7. Decided questions

All three are decided; none is open.

| # | question | decision | by |
|---|---|---|---|
| Q1 | box 1's second folder today holds the owner's own login, for the role failover (SPL-3023, owner choice B). This design fills it with sat's account instead, so the role failover's `claude2` step on box 1 then runs on sat's account | **A**: one second folder. It holds the other box's account for both uses (the role failover and this one), replacing the owner's own login there | owner HUM-10, t1 64ca0e0c, msg 5ff9dea1 (poll b82d89b2) |
| Q2 | the backup account's % comes from the other box's BOX-0 row (published every 300 s, 1 h max age). On no reading, should the box stay on own (hold)? | **A**: hold. Never move onto an account whose % is unknown | holder c-002@sat, msg f4ec1294 |
| Q3 | `.claude.json` of the second folder: carry only `oauthAccount` and `hasCompletedOnboarding`, or the whole file as SPL-3023 does locally? | **A**: the two fields only. Nothing else crosses boxes | holder c-002@sat, msg f4ec1294 |

## 8. As built (step 2)

| part | where | test |
|---|---|---|
| slot 2 and the account label in the credential helper: `stat`, `probe`, `get`, `put` take a slot (1 main, 2 the second folder); `acct` prints the label, `acctget` / `acctput` carry the two `.claude.json` fields | `csi-spl-orc/src/bash/scripts/agent-login-cred.sh` | L1-L4 |
| the peer source of the login2 sync, both directions, by label (4.3 rules 1-4, 6); refused while the same tag is in `SPOOL_LOGIN_PEERS` (step 0 not done) | `csi-spl-orc/src/bash/run/spl-agent-login2-sync.func.sh` | L1-L4 |
| every tick (4.3 rule 5): the login check runs the peer sync when box.env sets `SPOOL_LOGIN2_PEER`, then the mode when the pool is enabled. The 5 min `login2-sync` cron row takes the tick's lock, and skips while the tick holds it | `csi-spl-orc/src/bash/run/spl-agent-login-check.func.sh` (`_lc_pool`) | login check case 21, L1 (lock) |
| the mode (4.2) | `csi-spl-orc/src/bash/run/spl-claude-login-mode.func.sh` | M1-M6 |
| the readers of the mode line: the folder for a new seat, the active login's % for `wk=`, the row fields; a line over 180 s old reads as own | `csi-spl-orc/lib/bash/funcs/spl-claude-login.func.sh` | M6, S1 |
| new seats and rotations (4.4): spawn-core picks the folder when the caller names none. A rotation spawns through spawn-core, so `spl-rotate-lib.func.sh` is unchanged | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh` | S1 (`spawn-agents/tests/test-spawn-claude-login-dir.sh`) |
| the BOX-0 row (4.4): `wk=claude:` is the active login's %, plus `acct=<own label>` and, on backup, `lm=backup`, before `live=`; a change rewrites the row at once | `spl_lane_box_report`, `csi-spl-orc/src/bash/run/spl-lane-map.func.sh` | lane-map case 17 |
| the box pick reads this box's claude % the same way | `spl_box_pick_quota`, `csi-spl-orc/src/bash/run/spl-box-pick.func.sh` | box pick case 22 |

What the build changed from the design:

- **The backup's % is found by label, not by box name.** A box publishes
  `acct=<own label>`, and the mode reads the % of the row whose `acct=`
  equals its second folder's label. No setting names the peer box, and sat
  (which names no peer) finds its backup the same way. A row with
  `lm=backup` means that box's own account is at the mark, so it reads as
  unusable (hold).
- **On backup, reaching the mark returns the box to own** (the backup's %
  is at or over the mark). The placement hold then applies as before.
- **`max_copy_age_s` is dropped.** Only the box that drives the sync
  knows when it last ran, and sat drives nothing. A stale copy is caught
  instead by its label (no fresh peer row carries it: forced own) and by
  the probe (expired or limited: forced own).
- **The cnf has two keys**, `enabled` (false) and `back_below_pct` (85).

## 9. Change log

| version | date | change |
|---|---|---|
| 0.1 | 2026-11-16 | design for the holder's review (c-560, SPL-5695) |
| 0.2 | 2026-11-16 | section 7: Q1 decided by the owner (msg 5ff9dea1), Q2 and Q3 by the holder (msg f4ec1294) |
| 0.3 | 2026-11-16 | built, default-off (holder GO msg d8c3c9e7): section 8, the login-mode line format, `max_copy_age_s` dropped |
| 0.4 | 2026-11-25 | section 4.3: `do_spl_agent_cred_sync`, the box-to-box login copy of any vendor; the login2 sync is its wrapper (SPL-6487) |
| 0.5 | 2026-11-25 | section 4.3: R7 a-546 W1-W2: unreadable expiry, unreadable target and an unknown main label refused |

<!-- last-edit: 2026-11-16T10:30:00Z — c-560 SPL-5695 -->
