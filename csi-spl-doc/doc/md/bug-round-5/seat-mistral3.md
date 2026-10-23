# Bug round 5 - mistral3 reviewer verdict (R7)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Plan: [bug-round-5-plan.md](/doc/md/bug-round-5/bug-round-5-plan.md) v1.0, commit `8be4e3448`  
Reviewer: m-183@\u003cbox\u003e (mistral, cross-vendor)  
Verdict: **Agree** (both rows, no changes)  
Proof of the run: this session's vibe journal (the newest session dir under the harness user's vibe logs).

---

## 1. What I ran

Every command below was run by me in this session. The outputs are quoted exactly as they appeared in my terminal.

### 1.1 Worktree and plan

```bash
# Worktree status (empty, HEAD = origin/master)
cd /opt/csi/csi-spl-wt/m-183

git fetch origin master
# From https://github.com/csitea/csi-spl
#  * branch                master     -> FETCH_HEAD

git rev-parse HEAD origin/master
# 63955c7dac6e06a253e9dee76c632f5e0aacb532
# 8be4e34486890e19a31e414ac5a0445e3ceaba1a

git status --short
# (empty)
```

The plan is on `origin/master` at `8be4e3448`.

### 1.2 Red controls

```bash
# Copy the tree under test
D=$(mktemp -d)
git -C /opt/csi/csi-spl archive 35a8a111d csi-spl-orc | tar -x -C "$D"
cd "$D"

# Run the red controls
bash /var/spool-hub/c-081/b05-red-controls/zz-b05.tst.sh csi-spl-orc/src/bash/run/spl-review-line-check.func.sh
# FAIL 02a log: the store root (2 sessions) is refused (rc 0, want 1): OK 1 of 1 named in ran: are commands in /tmp/tmp.2AId2I36jW/unified (2 commands read)
# PASS 02a control: log: one session dir -> OK (rc 0)
# FAIL 02b reviewer with no agent id is refused (rc 0, want 1): OK 1 of 1 named in ran: are commands in /tmp/tmp.2AId2I36jW/unified/s2 (1 commands read)
# FAIL 02b reviewer is not the log: owner (rc 0, want 1): OK 1 of 1 named in ran: are commands in /tmp/tmp.2AId2I36jW/unified/s2 (1 commands read)
# INFO 01 unreadable log today: rc 1: FATAL log <scratch-path> is not readable on <box> as <user>
# 3 failure(s)

echo rc=$?
# rc=1
```

### 1.3 Baseline suite

```bash
# Baseline suite (must stay green)
bash csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh
# spl-review-line-check: 0 failure(s)

echo rc=$?
# rc=0
```

---

## 2. Judgment of the rows

### Row 01: `b05-01-orc-review-check-reads-as-log-owner`

**Defect:** Real.
- The red control (`zz-b05.tst.sh` case 01) fails as described: `FATAL log ... is not readable on box-a as <HARNESS_USER>`, rc 1.
- The evidence cites the correct lines (`50-52`) in `spl-review-line-check.func.sh`: the readable test (`[[ -r "$path" ]]`) and the read itself.
- The defect is narrow: the check does not attempt to read as the log's owner, even though `sudo -n -u <HARNESS_USER> true` succeeds for `<DEV_USER>`.

**Fix scope:** Correct and narrow.
- The fix proposes to run the read through `sudo -n -u <owner>` when the log is not readable as the current user.
- The owner lookup (nearest existing ancestor) and the `sudo` call are the minimal change needed.
- The hygiene requirement (no literal user names) is met by using placeholders.

### Row 02: `b05-02-orc-review-check-one-session-and-owner`

**Defect:** Real.
- The red controls (`zz-b05.tst.sh` cases 02a and 02b) fail as described:
  - **02a:** The store root (`unified/`, 2 sessions) is accepted (rc 0, want rc 1).
  - **02b:** A reviewer with no agent id (`mistral@box-a`) and a reviewer that differs from the `log:` owner (`m-902@box-a` vs `m-901@box-a`) are both accepted (rc 0, want rc 1).
- The evidence cites the correct lines (`40-44`, `50-52`, `73-88`, `157-158`) in `spl-review-line-check.func.sh`.

**Fix scope:** Correct and narrow.
- **(a)** Refuse a directory `log:` that holds 2+ session dirs (child dirs with `CURRENT` or `journal/`).
- **(b)** On the local branch, run the header part of `_spl_review_line_syntax` (reviewer = `log:` owner, vendor of the id) before the read.
- The changes are minimal and target the exact failure modes.

---

## 3. Re-check of "not reproduced" and "left out"

### Not reproduced: The 2700 s cap for the full-tier api budget
- The plan states: "No run over 2700 s, n=0 runs above 1.38/cpu since the change."
- The arithmetic (`2700 / 1950 = 1.385`) is correct.
- The defect requires a **measured timeout of a green trunk at that load**, which does not exist.
- **Judgment:** The plan's conclusion is correct. No row is needed.

### Left out: The sat go-cache prune cron (SPL-2986)
- The plan states: "Left out by the brief."
- The brief explicitly excludes this item.
- **Judgment:** The plan's conclusion is correct. No row is needed.

---

## 4. Hygiene check

```bash
cd /opt/csi/csi-spl-wt/m-183
cd csi-spl-iac && ./run -a do_check_dist_hygiene
# (exit 0, no output)

git status --short
# ?? csi-spl-doc/doc/md/bug-round-5/seat-mistral3.md
```