# Refactoring round 14 (2026-11-28) - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6723  
Topic: 741dfb6c-23f5-45a9-9ba1-66a912a5753f  
Discussion: 741dfb6c-23f5-45a9-9ba1-66a912a5753f (t1 #refactoring, "Refactor round 14", opened by c-002)  
Window: W=2026-11-28T03:34:51+02:00  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, after 99 comes 01 (rulebook 5.3). The older cycle already created
  `refactor-round-14-plan.md`, `refactor-round-14-retro.md` and `refactor-round-14/` on
  `origin/master`, so this round carries its open date (rulebook 5.3): plan
  `refactor-round-14-20261128-plan.md`, retro `refactor-round-14-20261128-retro.md`,
  seat dir `refactor-round-14-20261128/`, Qto doc title the same, rows `r14-<NN>`,
  commit scope `docs(r14-plan, SPL-6723)`.
- owner 10-17 (t1 b61851fb, msg 91bf8278): no mistral coding or testing rows; mistral
  sits on no review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 13
([refactor-round-13-20261127-plan.md](refactor-round-13-20261127-plan.md), SPL-6710)
has served both rows on `origin/master`: `r13-01` `07b483e33` (SPL-6716) and `r13-03`
`899f03b1c` (SPL-6717); the holder closed it at 03:35Z (post 0f8243f2). Its planner seat
has ended and no r13 retro exists, so r13's section 7 is this plan's first input. The
perf floor (rulebook 4.4), re-measured on `774876d90`:
`perf 32 refactor 118 perf-share 21.3% floor-met` (5 x 32 = 160 >= 150), so this is a
refactor round (the brief's read on `899f03b1c` printed the same).

Both rows are **one fact, one copy** (developer guide 2.2.4), non-secret, zero-PG, with
zero behaviour change, and each lands with a grep-count test that is RED on its parent:
- **Row 01 (`desk_root` once, in a lib module, 4 `csi-spl-orc` files):**
  `spawn-agents/scripts/spool-mirror.py:497-509` and
  `spawn-agents/scripts/agent-mirror-check.py:137-149` carry the same 13-line
  `desk_root(home)`, the python call of `lib/desk-root.inc.sh`. spool-mirror already
  imports two modules of `spawn-agents/lib`; the row hosts the function once there as
  `lib/spool_desk_root.py` and both scripts import it. Guarded by `0c` (new) and
  sections 8 and 9 (existing, the function's behaviour in 3 sandboxes) of
  `orc:src/bash/tests/desk-root-readers.tst.sh`.
- **Row 02 (`agent-caps.mjs` takes its mock helpers from `operator-console.mjs`, 4
  `csi-spl-wui` files):** `agent-caps.mjs:94-108` carries byte-identical copies of
  `opError` (as `capsError`) and `browserStore` of `operator-console.mjs:121-136`, a file
  it already imports (`:16`). The row exports the two there and imports them: no new
  import edge, so no chunk moves. Guarded by 2 new checks in
  `wui:tests/unit/agent-caps.test.mjs`.

The two rows share no file: both are **Batch 1**.

**Status: closed.** Both rows landed on `origin/master` (`r14-01` `2de10856d` SPL-6733, `r14-02` `454bf1f6b` SPL-6734; section 8), each with a same-vendor claude R7 PASS under waiver `1a7c70da`; retro: [refactor-round-14-20261128-retro.md](refactor-round-14-20261128-retro.md). Plan v1.0, the panel's notes N1-N6 folded (c-917 PASS on v0.1, section 9). Editor: **c-915** (claude, the specs_and_docs backup:
agy is out of quota on both boxes until about 2026-12-03 and paused on this box until
2026-11-28T05:24:23Z). Panel: the claude seat
`hand-sat-c002-refactor-round-14-claude-panel-seat` (live as c-917@sat in
`do_spl_lane_map` at 04:02:30Z), a same-vendor panel under waiver `1a7c70da` (section 9).

**One sha:** every count is measured on **`774876d90`**
(`774876d909a611e5bb48776c65492920072ff9a2`, `origin/master` at 2026-11-28T03:47:19Z),
n=1 per command unless stated. The tests of 1.5 ran in scratch clones of `774876d90`
(not committed): "base" unmodified, "head1" = base + row 01 as in 1.3, "head2" = base +
row 02 as in 1.4; each red control and mutation ran on its own copy. 1.3 and 1.4 print
each head as a unified diff against `774876d90`, so a panel or R7 seat can rebuild head1
and head2 with `git apply` and check the sha256 values. Queue, lane map, brief and branch
reads are live state and carry their own times.

## 1. Baseline

### 1.1 Window, slug proof and old-cycle leftovers (rulebook 5.3)

2026-11-28T03:47:19Z-03:47:40Z, n=1, after a fresh fetch:

- **Window: W=2026-11-28T03:34:51+02:00**, from
  `git log origin/master --format='%H %cI %s' | grep -E '^[0-9a-f]+ \S+ docs\(r13-(plan|close)' | head -1`
  (subject filter: `--grep` also matches bodies, and `899f03b1c`'s body quotes
  `docs(r13-plan`): `1e730d6e237aa4c2abec4fcb0b565f919cd39b9e`
  (`docs(r13-plan, SPL-6710): refactor round 13 plan v1.0 as signed, panel PASS recorded`).
  No r13 close commit exists, so W is the r13 plan v1.0 commit (its two earlier plan
  commits `7fe900332` and `0d04a240b` carry the same committer date). Read once; every
  later R4, R6, 2.7.5 and `PRUNE_SINCE` read for r14 uses this W.
- **Perf floor (rulebook 4.4):** the 4.4 command on `774876d90` ->
  `perf 32 refactor 118 perf-share 21.3% floor-met`.
- **Slug proof since W:**
  `git log origin/master --since="2026-11-28T03:34:51+02:00" --oneline -E --grep='\(r14-' | wc -l`
  -> **0**.
- **Remote heads:**
  `git ls-remote origin 'refs/heads/review/r14-*' 'refs/heads/wip/*r14*' 'refs/heads/*-r14-*' 'refs/heads/*refactor-round-14*'`
  -> **0** lines. So the ids `r14-01` and `r14-02` are free (unlike r13, no old-cycle
  head blocks a number). This plan's own branch is
  `review/c002-refactor-round-14-planner` (not matched by `review/r14-*`).
- **Old-cycle files:** `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep refactor-round-14`
  -> 3: `refactor-round-14-plan.md`, `refactor-round-14-retro.md`, `refactor-round-14/`.
  The dated names of this round match 0 entries.
- **Briefs on the planner box** (`ls -la /var/spool-hub/dispatch/briefs | grep -E 'r14|round-14'`):
  besides this planner's brief and the panel seat's
  (`hand-sat-c002-refactor-round-14-claude-panel-seat.md`, 2026-11-28T05:36-05:37 box
  time), 18 old-cycle leftovers, all mtime 2026-11-18T12:51 (before W): the brief's
  `c002-r14-01`..`c002-r14-08` row briefs, `c003-r14-09-bash-small-run-do-log.md`,
  `c002-refactor-r13-retro-r14-plan.md`, `c003-refactor-r14-retro-r15-plan.md`,
  `c002-wui-err-r14-journal-coalesce.md` and the bug / perf round 14 briefs
  (`c001-perf-round-14-planner.md`, `c002-bug-round-14-planner.md`,
  `c002-bug-round-14-mistral-panel-seat.md`, `c002-perf-round-14-mistral-panel-seat.md`);
  and, beyond the brief's list but of the same old cycle, the 2 seat briefs
  `c002-r14-seat-claude.md` and `c002-r14-seat-mistral.md`. No hidden file matches. No
  other r14 head, file or brief exists for this cycle.

### 1.2 The brief's inputs, re-measured on `774876d90`

- **(a) r13 section 7:**
  1. `spl_peer_pids` (`orc:src/bash/run/spl-peer-restart.func.sh`) /
     `spl_rotate_pids` (`orc:src/bash/run/spl-rotate-lib.func.sh`), deferred twice for
     queued ask `aa377e76`: **still deferred.** `do_spl_spawn_queue` at
     2026-11-28T03:47:34Z: `aa377e76` (`claude:c001-s179-b5-paused-seats-free`) is still
     queued (39/102), and `cf5e8b46` (`claude:c002-s184-l5-rotation-restart-rekind`,
     priority 2, position 2/102), whose brief names both `spl-rotate-lib` and
     `spl-peer-restart`, sits ahead of it. **v1.0 re-read (panel N2):** `cf5e8b46` is
     now LIVE as `c-298` on the other box (`c-298-c002-s184-l5-rotation-restart-rekind`,
     `lane-map.sh --check` at 2026-11-28T04:46:04Z), its brief still names both files
     (`grep -oE 'spl-(peer-restart|rotate-lib)[a-z.-]*'` -> both); `aa377e76` is still
     queued (35/99) and HELD after `c001-s179-b4-spawn-pause-hold` (`do_spl_spawn_queue`
     at 04:44:31Z). The deferral holds. The window scan of 1.2 (e) still finds the twin
     (`spl-peer-restart.func.sh:110` / `spl-rotate-lib.func.sh`). Section 7.
  2. The rest of r13's section 7 (the r12-01 R7 N1 test-strength item, the SPL-6661 N1 /
     N2 notes, the command guard pair, the secret-class and PG-bound twins, the destructive
     `gcp-*` apis pair, `spl-channel-agent-add.func.sh`'s member path, the other 13
     `box-wui is reserved` sites, the cron preambles, r12's carried items): unchanged on
     `774876d90` with r13's reasons; the scan of 1.2 (e) re-finds each pair. Section 7.
- **(b) R7 notes of the r13 rows** (refactor-shaped ones only):
  - r13-03 (c-254 PASS msg 65cc7198 on `daaec1107`, read in full on this box,
    `c-003/archive`): N1 (the "one copy" check looks in remove-op only; a second copy
    back in add-op is caught by nothing) and N4 (14 vs 15 `box-wui` sites) are test /
    count notes; N2 (a missing add-op file logs no FATAL) is a behaviour change; N3 (the
    nameref collides with a caller variable named `ids`, `seen`, `box` or `a`) is a
    latent defect in a helper no caller trips. None is a refactor row; section 7.
  - r13-01 (c-241 PASS msg abf29eef on `bd482d3de`): **read in full in v1.0** (panel
    N1), relayed verbatim by c-001 from the other box (msg 5feeb039, ask 961a8f11, 5746
    chars). N1 (case 13 checks named copies only: an inline `EPOCHREALTIME` ms at
    `func.sh:81` stays green), N2 (case 10 depends on the box zone: a runner in UTC
    misses the `TZ=UTC` mutation) and N3 (the 7-day cut is not pinned: an 8-day cut stays
    green) are test-strength notes; N4 (the lazy source at `func.sh:64` has no failure
    branch: a missing host file writes rows with an empty stamp, rc 0) is a behaviour
    change. None is a refactor row; section 7.
  - r13 panel notes: all folded into r13 v1.0 (`1e730d6e2`).
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  on the planner box, 221 lines, mtime 2026-11-28T05:41:59 box time): its lines 184-221
  (new since r13's read of 196 lines) are the SPL-6698 L4 and SPL-6699 H2 notes, SPL-6703
  N1 (an e2e blur line), the SPL-6721 cross-box design note, r13-01's N1-N4 pointer and
  the b53-01, SPL-6721 and SPL-6720 R7 notes: each a bug, a test gap or a design item,
  none a refactor. Its older lines: as r13 1.2 (c).
- **(d) spec 011 tasks:** `git log d03028967..774876d90 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> 0; its open tasks are as r13 1.2 (d) says: each wider than one row or waiting on
  the owner.
- **(e) A duplicate scan of its own**, wider than r13's (scripts in the planner's scratch
  dir, on a `git archive` of `774876d90`): (1) identical function bodies (5 lines or
  more, own name masked) and identical 6-line windows across files, over
  `csi-spl-{orc,iac,utl}/src/bash/run`, `orc/lib/bash`, `spawn-agents/{lib,scripts}`
  (1062 `.sh` files, the `run.sh` / `print-help.func.sh` twins left out, as r13); (2) the
  same over `csi-spl-{orc,utl,iac}/src/bash/scripts` and `csi-spl-orc/src/bash/features`
  (471 `.sh`); (3) **new: python function bodies by AST** over those (88 `.py`);
  (4) **new: Go and WUI function bodies** (`csi-spl-api/src/go`, `csi-spl-wui/src`, tests
  left out). Outcome:
  - `desk_root` in `spool-mirror.py:497` = `agent-mirror-check.py:137` (12 statement
    lines) -> **row 01** (1.3).
  - `capsError` (`agent-caps.mjs:94`) = `opError` (`operator-console.mjs:121`) =
    `fleetError` (`fleet-load.mjs:330`) = `costsError` (`tenant-costs.mjs:528`), and
    `browserStore` in `agent-caps.mjs:103`, `operator-console.mjs:131`,
    `fleet-load.mjs:515`, `vendor-keys.mjs:101` (the last two marked "Byte-identical twin
    ... merging them is a later lane" in the source) -> **row 02** takes the edge-free
    part (1.4); the rest is section 7.
  - Every other hit is secret-class, PG-bound, destructive, deliberate (with a test that
    pins the copies), cross-package, or a standalone script by design: section 7.

### 1.3 Row 01's site: `desk_root` once, in `spawn-agents/lib/spool_desk_root.py`

`orc:` = `csi-spl-orc/`, `P` = `orc:src/bash/features/spawn-agents/`. On `774876d90`:

- `P/scripts/spool-mirror.py` (1318 lines, last changed `284b012de` 2026-11-11; the
  agents' mirror hook) and `P/scripts/agent-mirror-check.py` (273 lines, `ec95d0f96`
  2026-10-22) each define `desk_root(home)` (`:497-509`, `:137-149`), byte for byte: run
  `bash <here>/../lib/desk-root.inc.sh <home>` (timeout 20 s) and return its stripped
  stdout, else `""`. One call each (`spool-mirror.py:516` in `seat_glob`,
  `agent-mirror-check.py:155` in `seats_of`).
- `spool-mirror.py:89-92` already puts `P/lib` on `sys.path` and imports `spool_redact`
  and `spool_discussion` from it. `agent-mirror-check.py` imports nothing from `lib/`.
- The row adds `P/lib/spool_desk_root.py` (19 lines, mode 100644 like
  `spool_discussion.py`; named after the bash function `spool_desk_root` it calls),
  holding the one `desk_root`; it resolves `desk-root.inc.sh` next to itself, which is
  the same file `<script>/../lib/desk-root.inc.sh` resolves to. spool-mirror imports
  it after its two lib imports; agent-mirror-check gains the same `sys.path.insert` of
  `../lib` and the import. Both import the name (`from spool_desk_root import desk_root`),
  so each module keeps a module-level `desk_root`:
  `P/tests/test-spool-discussion-mirror.sh:419` stubs `m.desk_root` on spool-mirror, and
  that stub must keep working (mutation `m1d`, 1.5).
- Why not `spool_discussion.py`: its docstring says "The decisions only: no send, no hub
  call"; a subprocess helper does not belong there. `lib/__pycache__/` is git-ignored
  (`.gitignore:39`).
- Non-secret: `desk_root` reads a box config key (the desk user's name) through
  `desk-root.inc.sh`; no key, token or message text. The hook's privacy path
  (`redact`, the DM hold) is not touched.
- **CI cost:** `ci-doc-only.sh 774876d90 HEAD` on head1 -> `parts=cnf hub iac orc`.
- Lint: the pre-push `lint-py` subset (`ruff check --isolated --select E9,F,S102,S113,S301,S307,S506,S602,S604,S605`
  and `ruff format --isolated --check`, ruff 0.16.9) on the 3 python files: rc 0 / rc 0
  on head1 (base rc 0 / rc 0). `shellcheck 0.10.0 -S warning -x` and `sigpipe-lint.sh`
  on the test: rc 0. `py_compile`: rc 0.

Shape (head1, `git diff --numstat 774876d90 head1`):
`spool_desk_root.py` +19 -0 (new, 19 lines), `agent-mirror-check.py` +5 -15 (273 -> 263),
`spool-mirror.py` +1 -15 (1318 -> 1304), `desk-root-readers.tst.sh` +3 -0 (217 -> 220).
sha256 (12 chars): `spool_desk_root.py` `a7cdf5fcd894`, `agent-mirror-check.py` `7bb858044ecb`,
`spool-mirror.py` `0fe9bf7cf00b`, `desk-root-readers.tst.sh` `8d2c03ea4ac9`.

head1 as a diff against `774876d90` (`git apply` it there; `index` lines dropped):

```diff
diff --git a/csi-spl-orc/src/bash/features/spawn-agents/lib/spool_desk_root.py b/csi-spl-orc/src/bash/features/spawn-agents/lib/spool_desk_root.py
new file mode 100644
--- /dev/null
+++ b/csi-spl-orc/src/bash/features/spawn-agents/lib/spool_desk_root.py
@@ -0,0 +1,19 @@
+"""spool_desk_root.py - desk-root.inc.sh for the python desk readers
+(spool-mirror.py, agent-mirror-check.py): one copy of the call.
+"""
+
+import os
+import subprocess
+
+
+def desk_root(home):
+    """The cloud state root of this box's desks under desk-root.inc.sh (spec
+    069 row B4): the desk user's, else HOME's. "" when it cannot tell."""
+    lib = os.path.join(os.path.dirname(os.path.realpath(__file__)), "desk-root.inc.sh")
+    try:
+        r = subprocess.run(
+            ["bash", lib, home], capture_output=True, text=True, timeout=20
+        )
+    except (OSError, subprocess.SubprocessError):
+        return ""
+    return r.stdout.strip() if r.returncode == 0 else ""
diff --git a/csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-mirror-check.py b/csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-mirror-check.py
--- a/csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-mirror-check.py
+++ b/csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-mirror-check.py
@@ -35,6 +35,11 @@ import re
 import subprocess
 import sys
 
+sys.path.insert(
+    0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib")
+)
+from spool_desk_root import desk_root  # noqa: E402
+
 HOOK_RE = re.compile(r"""([^\s'"]*spool-mirror\.py)""")
 PROC = os.environ.get("AMC_PROC_ROOT") or "/proc"
 
@@ -134,21 +139,6 @@ def argv_of(pid):
     return [a.decode(errors="replace") for a in b.split(b"\0") if a] if b else []
 
 
-def desk_root(home):
-    """The cloud state root of this box's desks under desk-root.inc.sh (spec
-    069 row B4): the desk user's, else HOME's. "" when it cannot tell."""
-    lib = os.path.join(
-        os.path.dirname(os.path.realpath(__file__)), "..", "lib", "desk-root.inc.sh"
-    )
-    try:
-        r = subprocess.run(
-            ["bash", lib, home], capture_output=True, text=True, timeout=20
-        )
-    except (OSError, subprocess.SubprocessError):
-        return ""
-    return r.stdout.strip() if r.returncode == 0 else ""
-
-
 def seats_of(agent):
     pat = os.environ.get("AMC_SEATS")
     if not pat:
diff --git a/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py b/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py
--- a/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py
+++ b/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py
@@ -90,6 +90,7 @@ HERE = os.path.dirname(os.path.realpath(__file__))
 sys.path.insert(0, os.path.join(HERE, "..", "lib"))
 from spool_redact import redact  # noqa: E402
 import spool_discussion as sd  # noqa: E402
+from spool_desk_root import desk_root  # noqa: E402
 
 # A participant id, as lib/spool-env.inc.sh SPOOL_ID_RE (specs/061): c-004, and
 # the legacy CLE-07 that readers keep accepting.
@@ -494,21 +495,6 @@ def hook_main(agy="", vibe=False):
 
 
 # ── post half (box user) ────────────────────────────────────────────────────
-def desk_root(home):
-    """The cloud state root of this box's desks under desk-root.inc.sh (spec
-    069 row B4): the desk user's, else HOME's. "" when it cannot tell."""
-    lib = os.path.join(
-        os.path.dirname(os.path.realpath(__file__)), "..", "lib", "desk-root.inc.sh"
-    )
-    try:
-        r = subprocess.run(
-            ["bash", lib, home], capture_output=True, text=True, timeout=20
-        )
-    except (OSError, subprocess.SubprocessError):
-        return ""
-    return r.stdout.strip() if r.returncode == 0 else ""
-
-
 def seat_glob():
     """The pattern of every seat dir on this box; "" when it cannot tell."""
     pat = os.environ.get("SPOOL_MIRROR_SEATS")
diff --git a/csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh b/csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh
--- a/csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh
+++ b/csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh
@@ -9,6 +9,8 @@
 #  0b. spool_box_kv, the box-config read the three fleet desk readers share:
 #      quotes dropped, the last line wins, a value with a space or an
 #      unreadable file reads empty; one definition, in desk-root.inc.sh
+#  0c. desk_root, the python readers' call of it: one definition, in
+#      lib/spool_desk_root.py (r14-01)
 #   per reader, three runs in a sandbox (caller A, desk user B, getent stub):
 #   a. SPOOL_DESK_USER unset, the desk under A: found, as before the key
 #   b. SPOOL_DESK_USER=B, the desk under B only: found
@@ -82,6 +84,7 @@ eq "0b. spool_box_kv: quotes dropped, the last line wins" two "$(run a bash -c "
 eq "0b. spool_box_kv: a value with a space reads empty" "" "$(run a bash -c "$LIB; spool_box_kv '$T/kv.env' Q")"
 eq "0b. spool_box_kv: an unreadable file reads empty, rc 0" ":0" "$(run a bash -c "$LIB; spool_box_kv '$T/no-such.env' K; echo \":\$?\"")"
 eq "0b. spool_box_kv is defined once, in desk-root.inc.sh" "$FEAT/lib/desk-root.inc.sh" "$(grep -rlE '^(spool_box_kv|kv)\(\) *\{' "$FEAT/lib" "$S")"
+eq "0c. desk_root is defined once, in lib/spool_desk_root.py" "$FEAT/lib/spool_desk_root.py" "$(grep -rlE '^def desk_root\(' "$FEAT/lib" "$S")"
 
 # verdict NAME MODE FOUND(0|1): a/b must find, c must not.
 verdict() {
```

**Behaviour:** none changes: the same subprocess call (`bash`, the same
`desk-root.inc.sh`, the same argument and timeout), the same return on success, a
non-zero exit, an `OSError` or a timeout. The hook's module-level name `desk_root`
stays, so stubs and callers see the same function. Sections 8 and 9 of
`desk-root-readers.tst.sh` run `seats()` / `seats_of()` of both scripts through
`desk_root` in 3 sandboxes (caller's desk, desk user's desk, and the red control with
the key unset) and pass on base and head1 alike (1.5).

### 1.4 Row 02's site: `agent-caps.mjs` uses `operator-console.mjs`'s `opError` and `browserStore`

`wui:` = `csi-spl-wui/`. On `774876d90`:

- `wui:src/utils/agent-caps.mjs` (163 lines, last changed `213354932` 2026-11-15) holds
  the agent caps mock (spec 147). Its `capsError` (`:94-101`) is byte for byte
  `opError` of `wui:src/utils/operator-console.mjs:121-128` (216 lines, `1c5f8c4a3`
  2026-10-05), and its `browserStore` (`:103-108`) is byte for byte
  `operator-console.mjs:131-136`. 4 `capsError` calls (`:125`, `:126`, `:154`, `:156`).
- `agent-caps.mjs:16` already imports `OPERATOR_MOCK_KEY` and `OPERATOR_WS_ID_RE` from
  `./operator-console.mjs`. The row exports `opError` and `browserStore` there (each with
  the `/** */` doc `util-docs.test.mjs` asks of an export), adds them to that import,
  renames the 4 calls and deletes the 2 copies. **No new import edge**, so the module
  graph and every chunk boundary stay as they are; the agent caps chunk loses 2 functions.
- `wui:src/types/operator-console.d.ts` declares all 19 exports of `operator-console.mjs`
  today (checked: each export name is in it); the row adds the 2 new ones, so it stays
  complete.
- Nuxt auto-imports every `src/utils` export by name (the note at
  `spool-client-lazy.mjs:8-9`). `git grep -nE 'export (function|const) (opError|browserStore)\b' 774876d90 -- csi-spl-wui`
  -> 0, so the 2 new names collide with no export; the local
  `browserStore` of `fleet-load.mjs` and `vendor-keys.mjs` are not exported and shadow
  any auto-import in their files.
- Why only agent-caps: folding `fleet-load.mjs`, `tenant-costs.mjs` or `vendor-keys.mjs`
  too would add an import edge to `operator-console.mjs` (they import only `./prefs.mjs`,
  `vendor-keys.mjs` also `./act-as-mock.mjs`), and hosting the helpers in `prefs.mjs` puts them in the
  initial JS, whose gzip budget is measured only in CI's generate job. Both need a bundle
  measurement: section 7.
- Non-secret, zero-PG: mock-hub code only (`NUXT_PUBLIC_USE_MOCK`); the live client
  path (`spool-client-lazy.mjs`) is not touched.
- **CI parts:** `ci-doc-only.sh 774876d90 HEAD` on head2 -> `parts=iac orc wui`.
- **E2E the pre-push map selects** (`cd csi-spl-iac && WUI_E2E_RANGE=HEAD^..HEAD ./run -a do_check_pre_push_e2e`
  on head2 committed in a scratch clone, rc 0): `tests/e2e/monitoring-costs.test.mjs`,
  `operator-console.test.mjs`, `monitoring-takeover.test.mjs`, `connect-agent.test.mjs`,
  `rail-only-sidebar-unmounted.test.mjs`, `unread-sum.test.mjs` (147 more `CUT ... budget`).
  `do_spl_review_line_check` fails a review line whose `ran:` does not name each of them
  (rulebook 2.7.4): the row's R7 runs all 6.

Shape (head2, `git diff --numstat 774876d90 head2`):
`agent-caps.mjs` +5 -21 (163 -> 147), `operator-console.mjs` +11 -3 (216 -> 224),
`operator-console.d.ts` +2 -0 (41 -> 43), `agent-caps.test.mjs` +10 -0 (105 -> 115).
sha256 (12 chars): `agent-caps.mjs` `a4ea0ef4832c`, `operator-console.mjs` `34fa31013fe0` (v1.0, panel N5; v0.1 `f583065b1266`),
`operator-console.d.ts` `fcdbd02e5c0c`, `agent-caps.test.mjs` `5f34aefd973b`.

head2 as a diff against `774876d90` (`index` lines dropped):

```diff
diff --git a/csi-spl-wui/src/types/operator-console.d.ts b/csi-spl-wui/src/types/operator-console.d.ts
--- a/csi-spl-wui/src/types/operator-console.d.ts
+++ b/csi-spl-wui/src/types/operator-console.d.ts
@@ -33,6 +33,8 @@ declare module '~/utils/operator-console.mjs' {
   export function operatorCreateBody(draft?: OperatorDraft): { body?: Record<string, string>, error?: string }
   export function operatorRootKey(body: unknown): string
   export function replaceOperatorWorkspace(rows: OperatorWorkspace[], row: unknown): OperatorWorkspace[]
+  export function opError(status: number, token: string, detail?: string, permission?: string): Error & { status: number, token: string, detail: string, permission?: string }
+  export function browserStore(): Storage | null
   export function operatorMockSeed(): Array<Record<string, unknown>>
   export function mockOperatorList(store?: Storage | null): { workspaces: Array<Record<string, unknown>> }
   export function mockOperatorCreate(body?: Record<string, unknown>, store?: Storage | null, now?: string): Record<string, unknown>
diff --git a/csi-spl-wui/src/utils/agent-caps.mjs b/csi-spl-wui/src/utils/agent-caps.mjs
--- a/csi-spl-wui/src/utils/agent-caps.mjs
+++ b/csi-spl-wui/src/utils/agent-caps.mjs
@@ -13,7 +13,7 @@
  */
 
 import { storageGetJson } from './prefs.mjs'
-import { OPERATOR_MOCK_KEY, OPERATOR_WS_ID_RE } from './operator-console.mjs'
+import { OPERATOR_MOCK_KEY, OPERATOR_WS_ID_RE, browserStore, opError } from './operator-console.mjs'
 
 /** The five vendors, in the order the forms show them (spec 147 P1). */
 export const AGENT_CAP_VENDORS = Object.freeze(['claude', 'grok', 'agy', 'mistral', 'qwen', 'codex'])
@@ -91,22 +91,6 @@ export function agentCapsPutBody(draft) {
 
 /* ---- the mock hub (NUXT_PUBLIC_USE_MOCK) --------------------------------- */
 
-function capsError(status, token, detail, permission) {
-  const err = new Error(detail || token)
-  err.status = status
-  err.token = token
-  err.detail = detail || ''
-  if (permission) err.permission = permission
-  return err
-}
-
-function browserStore() {
-  try {
-    if (typeof globalThis.localStorage !== 'undefined') return globalThis.localStorage
-  } catch { /* private mode */ }
-  return null
-}
-
 function mockMap(store, key) {
   const m = store && typeof store.getItem === 'function' ? storageGetJson(key, null, store) : null
   return m && typeof m === 'object' && !Array.isArray(m) ? m : {}
@@ -122,8 +106,8 @@ function mockCapsOf(store, id) {
 function mockOperatorGate(store, id) {
   let on = ''
   try { on = store ? store.getItem(OPERATOR_MOCK_KEY) || '' : '' } catch { on = '' }
-  if (on !== '1') throw capsError(403, 'forbidden', 'only an admin of the operator workspace manages agent caps', 'operator.workspaces')
-  if (!OPERATOR_WS_ID_RE.test(String(id || ''))) throw capsError(404, 'not_found', `workspace '${id}' does not exist`)
+  if (on !== '1') throw opError(403, 'forbidden', 'only an admin of the operator workspace manages agent caps', 'operator.workspaces')
+  if (!OPERATOR_WS_ID_RE.test(String(id || ''))) throw opError(404, 'not_found', `workspace '${id}' does not exist`)
 }
 
 /** The mock's GET /v1/tenant/agent-caps (the mock tenant is AGENT_CAPS_MOCK_TENANT). */
@@ -151,9 +135,9 @@ export function mockOperatorPutAgentCaps(id, body = {}, store = browserStore())
   mockOperatorGate(store, id)
   const next = mockCapsOf(store, id)
   for (const [v, c] of Object.entries(body?.caps || {})) {
-    if (!AGENT_CAP_VENDORS.includes(v)) throw capsError(400, 'bad_vendor', `vendor '${v}' is not supported`)
+    if (!AGENT_CAP_VENDORS.includes(v)) throw opError(400, 'bad_vendor', `vendor '${v}' is not supported`)
     if (c === null) { delete next[v]; continue }
-    if (capOf(c) === null || typeof c !== 'number') throw capsError(400, 'bad_cap', 'max_live must be a non-negative integer')
+    if (capOf(c) === null || typeof c !== 'number') throw opError(400, 'bad_cap', 'max_live must be a non-negative integer')
     next[v] = c
   }
   const all = mockMap(store, AGENT_CAPS_MOCK_KEY)
diff --git a/csi-spl-wui/src/utils/operator-console.mjs b/csi-spl-wui/src/utils/operator-console.mjs
--- a/csi-spl-wui/src/utils/operator-console.mjs
+++ b/csi-spl-wui/src/utils/operator-console.mjs
@@ -118,7 +118,11 @@ export function replaceOperatorWorkspace(rows, row) {
 
 /* ---- the mock hub (NUXT_PUBLIC_USE_MOCK=1), the e2e's stand-in ---- */
 
-function opError(status, token, detail, permission) {
+/**
+ * The mock hub's refusal: an Error with the hub's status, token, detail and
+ * (when given) the missing permission: the same shape spool-client.mjs builds.
+ */
+export function opError(status, token, detail, permission) {
   const err = new Error(detail || token)
   err.status = status
   err.token = token
@@ -127,8 +131,12 @@ function opError(status, token, detail, permission) {
   return err
 }
 
-/* Byte-identical twin: browserStore() in fleet-load.mjs (merging them is a later lane). */
-function browserStore() {
+/**
+ * The browser's localStorage, or null (no window, or private mode denies it).
+ * agent-caps.mjs uses this copy; its byte-identical twins in fleet-load.mjs and
+ * vendor-keys.mjs are a later lane.
+ */
+export function browserStore() {
   try {
     if (typeof globalThis.localStorage !== 'undefined') return globalThis.localStorage
   } catch { /* private mode */ }
diff --git a/csi-spl-wui/tests/unit/agent-caps.test.mjs b/csi-spl-wui/tests/unit/agent-caps.test.mjs
--- a/csi-spl-wui/tests/unit/agent-caps.test.mjs
+++ b/csi-spl-wui/tests/unit/agent-caps.test.mjs
@@ -95,6 +95,16 @@ ok('the lazy half has agentCaps on the three routes', /async function agentCaps\
   lazy.includes("'/v1/tenant/agent-caps'") && lazy.includes("'/agent-caps'"))
 ok('…and the client names it a lazy method', /'agentCaps',/.test(client))
 
+/* one copy (r14-02): the mock's refusal and its localStorage read are
+   operator-console.mjs's opError and browserStore, which this file imports */
+const caps = readFileSync(new URL('../../src/utils/agent-caps.mjs', import.meta.url), 'utf8')
+const opc = readFileSync(new URL('../../src/utils/operator-console.mjs', import.meta.url), 'utf8')
+ok('one copy: agent-caps.mjs defines no error or store helper of its own',
+  !/^function (capsError|browserStore|\w*Error)\(/m.test(caps) && !/err\.permission = /.test(caps))
+ok('…and imports opError and browserStore from operator-console.mjs, which exports each once',
+  /^import \{[^}]*\bbrowserStore\b[^}]*\bopError\b[^}]*\} from '\.\/operator-console\.mjs'$/m.test(caps) &&
+  (opc.match(/^export function opError\(/gm) || []).length === 1 && (opc.match(/^export function browserStore\(/gm) || []).length === 1)
+
 const s = runsInUnitSuite(import.meta.url)
 ok('pnpm test runs this suite', s.ok, s.why)
 
```

**Behaviour:** none changes: the same Error objects (message, `status`, `token`,
`detail`, `permission`), the same thrown statuses and tokens, the same default store.
`agent-caps.test.mjs` (29 checks on base) and `operator-console.test.mjs` (40) pass on
base and head2 alike (1.5).

### 1.5 Before and on the rows' heads

Base and heads 2026-11-28T03:58Z-04:2xZ, n=1, as the planner's user in the scratch clones,
`SPOOL_TEST=1` with `SPOOL_BOX_TAG`, `SPOOL_AGENT_ID` and `AGENT_ID` unset, stdin from
`/dev/null`, `TMPDIR` a short path (a first run with the deep scratch `TMPDIR` failed 6
suites on base with tmux `File name too long`: a unix socket path is capped at 108
bytes; the lanes run from `/opt/...` worktrees and are not hit). Pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'` (a suite's own
footer counts as one line). "=" means equal to base.

**Row 01** (the 24 suites that name `spool-mirror.py`, `agent-mirror-check`, `desk_root`
or `desk-root.inc` under `*/tests/*`; `box-crons-desk-reach.py` is a helper, run through
`install-box-crons.tst.sh`):

| suite | base rc / pass / fail | head1 |
|---|---|---|
| `orc:src/bash/features/spawn-agents/tests/test-agent-hook.sh` | 0 / 225 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-agent-id.sh` | 0 / 87 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-agent-mirror-check.sh` | 0 / 14 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-enc-side-files.sh` | 0 / 19 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-lane-issue-remote-desk.sh` | 0 / 49 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-live-ack-shown.sh` | 0 / 49 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-spool-agent.sh` | 0 / 73 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-spool-discussion-mirror.sh` | 0 / 192 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-spool-harness.sh` | 0 / 85 / 0 | = |
| `orc:src/bash/features/spawn-agents/tests/test-spool-mirror.sh` | 0 / 118 / 0 | = |
| `orc:src/bash/features/spool-install/tests/test-claude-config.sh` | 0 / 45 / 0 | = |
| `orc:src/bash/features/spool-install/tests/test-install.sh` | 1 / 110 / 2 | = |
| `orc:src/bash/features/spool-install/tests/test-y12-vibe-push-guard.sh` | 0 / 35 / 0 | = |
| `orc:src/bash/tests/agent-mcp.tst.sh` | 1 / 70 / 11 | = |
| `orc:src/bash/tests/install-box-crons.tst.sh` | 0 / 40 / 0 | = |
| `orc:src/bash/tests/desk-dir-follows-desk-user.tst.sh` | 0 / 35 / 0 | = |
| `orc:src/bash/tests/desk-mirror-actions.tst.sh` | 0 / 19 / 0 | = |
| `orc:src/bash/tests/desk-move.tst.sh` | 0 / 166 / 0 | = |
| `orc:src/bash/tests/desk-root-readers.tst.sh` | 0 / 41 / 0 | 0 / 42 / 0 |
| `orc:src/bash/tests/dispatch-lease-moved-desk.tst.sh` | 0 / 117 / 0 | = |
| `orc:src/bash/tests/enc-dirs-untouched.tst.sh` | 0 / 18 / 0 | = |
| `orc:src/bash/tests/rotate-open-takes.tst.sh` | 0 / 16 / 0 | = |
| `orc:src/bash/tests/spl-archived-followup.tst.sh` | 0 / 82 / 0 | = |
| `orc:src/bash/tests/spl-archived-seats-free.tst.sh` | 0 / 65 / 0 | = |

`desk-root-readers.tst.sh` gains `0c` on head1 (0 / 42 / 0). Two suites are red on base
and head1 alike, by the planner's harness, not the tree: `test-install.sh` case `5`
("this checkout ... read as a misplaced clone": the scratch clone is outside the
checkout layout) and `agent-mcp.tst.sh` cases `3`, `4` (5 checks) and `8` (5 checks):
the same 11 check names on both (`diff` of the names -> equal), their paths show the
symlinked `TMPDIR`. Not re-run in a real worktree by the planner: the row lane runs them
there and shows both green in its real worktree, or the same check names red on its
parent (panel N6, a required result field of the r14-01 brief, section 5).

**Row 02** (`node tests/unit/<x>.test.mjs` in `csi-spl-wui`; OK lines `^ *(OK|ok)`):

| suite | base rc / OK / FAIL | head2 |
|---|---|---|
| `wui:tests/unit/agent-caps.test.mjs` | 0 / 29 / 0 | 0 / 31 / 0 (+2, one copy) |
| `wui:tests/unit/operator-console.test.mjs` | 0 / 40 / 0 | = |
| `wui:tests/unit/monitoring-tokens.test.mjs` | 0 / 29 / 0 | = |
| `wui:tests/unit/topic-loops.test.mjs` | 0 / 30 / 0 | = |
| `wui:tests/unit/util-docs.test.mjs` | 0 / 5 / 0 | = (the first head2 draft had `*/` on a text line: `operator-console.mjs 2 > 0: opError, browserStore`; fixed) |
| `wui:tests/unit/unused-exports.test.mjs` | 0 (`3612 exports ... 30 unused, all listed in ALLOW (33 <= cap 33)`) | 0 (`3614 exports ...`, the same 30 unused) |
| `wui:tests/unit/mjs-shims-exist.test.mjs` | 0 | 0 |
| `wui:tests/unit/swallow-reasons.test.mjs` | 0 / 20 / 0 | = |

**Not run by the planner** (no `node_modules` on any checkout of this box, and the
brief forbids installs): `cleancode.test.mjs` (`Cannot find package 'typescript'`),
`pnpm run typecheck`, the 6 e2e files of 1.4. The row lane and its R7 run them.
`cd csi-spl-iac && ./run -a do_check_pre_push` on either head: not run by the planner;
each lane runs it in its worktree.

**Red controls** (each head's test file copied onto base, n=1):
- `rc1` (head1's `desk-root-readers.tst.sh` on base): rc 1, 41 pass, 1 fail
  (`FAIL: 0c. desk_root is defined once, in lib/spool_desk_root.py`: the grep finds the
  2 script copies); head1: rc 0, 42 pass, 0 fail.
- `rc2` (head2's `agent-caps.test.mjs` on base): rc 1, 29 OK, 2 FAIL (`one copy:
  agent-caps.mjs defines no error or store helper of its own`, `…and imports opError and
  browserStore from operator-console.mjs, which exports each once`); head2: rc 0, 31 OK.

**Mutations** (one defect planted in a copy of the final head, n=1; row 01 columns:
`desk-root-readers` / `test-agent-mirror-check` / `test-spool-discussion-mirror`):
- `m1a` (`spool_desk_root.desk_root` returns `""` at once): rc 1, 38 / 4 (`8.` and `9.`
  a and b: neither script finds a desk) / 0 / 14 / 0 / 0 / 192 / 0.
- `m1b` (a second `def desk_root` back in agent-mirror-check): rc 1, 41 / 1 (`0c`); the
  other two green (behaviour equal, only the copy count catches it).
- `m1c` (agent-mirror-check drops its `sys.path.insert`): rc 1, 39 / 3 (`9.` a, b, c);
  `test-agent-mirror-check` rc 1, 1 / 13; spool-mirror's suite green.
- `m1d` (spool-mirror does `import spool_desk_root` and calls
  `spool_desk_root.desk_root(...)`): `desk-root-readers` and `test-agent-mirror-check`
  green, `test-spool-discussion-mirror` rc 1, 188 / 4 (`C17`, `C18`: the suite's stub of
  `m.desk_root` no longer reaches `seat_glob`). This is why the row imports the name.
- `m2a` (an own `capsError` copy back in agent-caps): rc 1, 30 / 1 (`one copy: ...`).
- `m2b` (`opError` drops `permission`): agent-caps rc 1, 29 / 2 (`mock: a workspace admin
  PUT is 403 operator.workspaces`, `…and so is the GET`); operator-console rc 1, 39 / 1.
- `m2c` (`browserStore` always returns `null`): agent-caps 0 / 31 / 0 and
  operator-console 0 / 40 / 0, **green**: the unit suites pass an explicit store, so only
  the mock-bundle e2e reaches the default store. The row lane says which e2e goes red on
  it, or that none does: a required result field of the r14-02 brief (panel N3).
- `m2d` (`browserStore` not exported): agent-caps rc 1, `SyntaxError: The requested module
  './operator-console.mjs' does not provide an export named 'browserStore'`.

The tests that name the sites (R2), `git grep -lE` over `*/tests/*` on `774876d90`:
- Row 01 (`spool-mirror\.py|agent-mirror-check|desk_root|desk-root\.inc`) -> the 24
  suites above (**`orc:src/bash/tests/desk-root-readers.tst.sh`** edited).
- Row 02 (`agent-caps|operator-console|capsError|opError|browserStore` under
  `csi-spl-wui/tests`) -> **`tests/unit/agent-caps.test.mjs`** (edited),
  `tests/unit/operator-console.test.mjs`, `monitoring-tokens.test.mjs`,
  `topic-loops.test.mjs`, and the e2e `operator-console.test.mjs`,
  `section-closes-pane.test.mjs`, `tenant-settings.test.mjs` (with the 6 the pre-push map
  selects, 1.4, the R7 runs the union).
- No new test file, so no shard-weights line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r14-01-orc-desk-root-py-once)` | one fact, one copy (developer guide 2.2.4) | `spool-mirror.py:497-509` and `agent-mirror-check.py:137-149` carry the same `desk_root`, the python call of `desk-root.inc.sh`; spool-mirror already imports `spawn-agents/lib` modules (1.3) | `P/lib/spool_desk_root.py` (new, 19 lines)<br>`P/scripts/spool-mirror.py:92,497-511`<br>`P/scripts/agent-mirror-check.py:36-38,137-151`<br>`orc:src/bash/tests/desk-root-readers.tst.sh:11,84` | copies of `desk_root` 2 -> 1 (`grep -rlE '^def desk_root\(' P/lib P/scripts` 2 -> 1) | 1.3's shape (head1 diff). **Red control:** head1's `desk-root-readers.tst.sh` on base: `0c` FAIL (1.5), then GREEN on head1. Mutations `m1a`-`m1d` (1.5); outputs in the body. **Behaviour:** none changes (1.3). Tests: **`orc:.../desk-root-readers.tst.sh`**, `P/tests/test-agent-mirror-check.sh`, `P/tests/test-spool-mirror.sh`, `P/tests/test-spool-discussion-mirror.sh` and the rest of 1.5's column, `ruff` (the `lint-py` subset and `format --check`) on the 3 python files, `shellcheck -S warning -x` and `sigpipe-lint.sh` on the test, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r14-02-wui-agent-caps-mock-helpers)` | one fact, one copy (developer guide 2.2.4) | `agent-caps.mjs:94-108` carries byte-identical copies of `opError` and `browserStore` of `operator-console.mjs:121-136`, a file it already imports (`:16`) (1.4) | `wui:src/utils/agent-caps.mjs:16,94-108,125-126,154,156`<br>`wui:src/utils/operator-console.mjs:121,130-131`<br>`wui:src/types/operator-console.d.ts:35`<br>`wui:tests/unit/agent-caps.test.mjs:97` | copies of the error constructor and of `browserStore` in the pair 2 -> 1 each | 1.4's shape (head2 diff). **Red control:** head2's `agent-caps.test.mjs` on base: rc 1, 29 OK, 2 FAIL (the 2 one-copy checks), then GREEN on head2 (rc 0, 31 OK). Mutations `m2a`-`m2d` (1.5); outputs in the body. **Behaviour:** none changes (1.4). Tests: **`wui:tests/unit/agent-caps.test.mjs`**, `operator-console.test.mjs`, `monitoring-tokens.test.mjs`, `topic-loops.test.mjs`, `unused-exports.test.mjs`, `util-docs.test.mjs`, `mjs-shims-exist.test.mjs`, `swallow-reasons.test.mjs`, `cleancode.test.mjs`, `pnpm run typecheck`, the 6 e2e files of 1.4 and the 3 e2e of 1.5's R2 list (`BASE_URL=<generated mock bundle> pnpm run test:e2e`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`P` = `orc:src/bash/features/spawn-agents/`, `orc:` = `csi-spl-orc/`, `wui:` = `csi-spl-wui/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `refactor(r14-NN-<slug>, SPL-<row issue>): ...`; review
branch `review/r14-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows fold internal helper copies with zero change to any output, exit
code, env var, path or page a caller sees ->
`Docs: none (internal helper consolidation; no behaviour changes)`. The developer guide
2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: disjoint file sets (row 01: 4 `orc:` files;
  row 02: 4 `wui:` files).
- Neither row edits `P/lib/desk-root.inc.sh`, `P/lib/spool_discussion.py`,
  `P/lib/spool_redact.py`, any other `spawn-agents` test, `fleet-load.mjs`,
  `vendor-keys.mjs`, `tenant-costs.mjs`, `prefs.mjs`, `spool-client*.mjs`, any `.vue`,
  a locale file, `csi-spl-api/`, `csi-spl-cnf/`, terraform or `csi-spl-iac/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths checked: the 8 edited files plus `P/lib/desk-root.inc.sh` (read by row 01).

- **Lane map, every machine:** `lane-map.sh --check <P/scripts/spool-mirror.py,
  P/scripts/agent-mirror-check.py, P/lib/desk-root.inc.sh, wui agent-caps.mjs,
  wui operator-console.mjs> --agent c-915`, n=1, at 2026-11-28T03:54:07Z: **exit 4**,
  0 owned, "23 live lane(s) record no files", all on the other box: 19 `-rotate` seats
  and `c-266` (SPL-6722 help page), `c-285` (SPL-6707 tf cold start), `c-287` (spec 184
  W1: its brief names `AgentSplitKinds.vue` / `AgentModels.vue` and `tenant-settings.mjs`),
  `c-995` (blog draft). None of their briefs names any row path (grep below).
- **v1.0 re-read (panel N2):** the same check on the 9 row paths at 2026-11-28T04:46:04Z:
  **exit 4**, 0 owned, 21 unknown, all on the other box. New since v0.1: `c-290`
  (`c001-bug-issue-archive-status-diss`, landed as `0e6f561e4`), `c-298` (s184 L5,
  `cf5e8b46`) and `c-303` (s184 H3 models report). Their briefs grep
  `agent-caps|operator-console|capsError|opError|browserStore|spool-mirror|agent-mirror|desk_root|desk-root`
  -> 0 each.
- **Live lanes on this box** (`do_spl_lane_map` at 2026-11-28T04:02:30Z, 46 lines):
  `git diff --name-only $(merge-base) HEAD` plus `git status --porcelain` in the
  worktrees of `c-001`, `c-002`, `c-003`, `c-865`, `c-869`, `c-872`, `c-887`, `c-904`,
  `c-917` (the panel seat) and `m-674`, grepped for
  `agent-caps|operator-console|spool-mirror|agent-mirror|spool_desk_root|desk-root` ->
  **none** in each (04:02:40Z).
- **Spawn queue** (`do_spl_spawn_queue`, 2026-11-28T03:47:34Z, 102 queued): no row's
  placement matches `mirror|agent-caps|operator-console|caps`. The one `operator`-named
  row, `e39c6568` (`c002-948dae2e-ws-lanes-same-as-operator`), names
  `pages/monitoring/lanes/index.vue` and the hub's `fleet_lanes_view.go`, neither a row
  file.
- **Briefs** (`/var/spool-hub/dispatch/briefs`, the 402 modified in the last 48 h, grep
  `agent-caps|operator-console|capsError|opError|spool-mirror\.py|agent-mirror-check|desk_root|desk-root`):
  5 hits. the two `hand-<box>-c002-gik-cinode-v5-sv-claude-review.md` (spec 147's name, no
  csi-spl change); `c002-bug-move-notice-mirrored-into-topic.md` and its reviewer brief
  (the lane landed as `b65306882`, SPL-6679: `git show --stat` -> `spool-notify.inc.sh`,
  `test-spool-mirror.sh` and spec 067, no row file); `hand-sat-c001-bug-round-53-planner.md` (item 6:
  `spool-mirror.py:795`). **Serialization note:** bug round 53's plan carries that item,
  `spool-mirror.py:795-807` (`first_sighting`, `.mirror/seen`), to round 54 as an input; it
  is no placed lane today. Should round 54 take it while row 01 is open, the second to
  land rebases over a disjoint hunk (row 01 touches `:92` and `:497-511` only).
- **Remote branches committed in the last 48 h** (146, at 03:54:48Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b> --` the row paths and
  `P/lib` -> 3 hits, all other `P/lib` files: `review/c-738-agy-fallback-n2-n4` and
  `review/c-738-agy-quota-model-fallback` (`agy-fallback.inc.sh`),
  `review/c002-bug-move-notice-mirrored-into-topic` (`spool-notify.inc.sh`). 0 on a row
  file.
- **Commits in the last 7 days** on the 4 existing source files
  (`git log origin/master --since='7 days ago' -- <files>`) -> **0**.

## 3. Per row: what the lane does

- **r14-01:** applies 1.3's head1 diff on its `origin/master`: adds
  `P/lib/spool_desk_root.py` (mode 100644), deletes `desk_root` from
  `P/scripts/spool-mirror.py` and `P/scripts/agent-mirror-check.py`, imports it in both
  (agent-mirror-check with its own `sys.path.insert` of `../lib`), and adds check `0c`
  to the header (`:11`) and after `0b` (`:84`) of
  `orc:src/bash/tests/desk-root-readers.tst.sh`.
- **r14-02:** applies 1.4's head2 diff: exports `opError` and `browserStore` from
  `wui:src/utils/operator-console.mjs` with a `/** */` doc each, declares them in
  `wui:src/types/operator-console.d.ts`, imports them in `wui:src/utils/agent-caps.mjs`,
  renames its 4 `capsError` calls and deletes its 2 copies, and adds the 2 one-copy
  checks to `wui:tests/unit/agent-caps.test.mjs` before its suite footer (`:97`).

## 4. Reviewers (R7)

- Editor: **c-915** (claude). The panel seat signs the plan sha (rulebook 3.2,
  section 9).
- **Row reviewers (code R7), cross-vendor first (2.7.2):**
  `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix` at 2026-11-28T04:03:04Z:
  `agy paused in instance settings until 2026-11-28T05:24:23Z: usage limit` (and agy's
  weekly quota is out until about 2026-12-03 per the brief), grok and qwen off, mistral
  sits on no review -> `pick=claude`. So each claude row's R7 is the **claude waiver
  seat** (waiver `1a7c70da`), until agy can sit; the holder re-checks at placement and
  moves R7 to an agy seat once agy is back. Never mistral.
- Row vendor: `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 04:03:04Z ->
  `pick=claude` (main claude; agy skipped on its pause, mistral writes no code). Both
  rows: **claude** (R14).
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries its plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites of 1.3 / 1.4, its R7 seat, "re-measure first", and the plan's
`Window: W=2026-11-28T03:34:51+02:00` for its R4 slug check.

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r14-01 | `c002-r14-01-orc-desk-root-py-once` | `refactor(r14-01-orc-desk-root-py-once, SPL-<row issue>): ...` | `review/r14-01` | 1 |
| r14-02 | `c002-r14-02-wui-agent-caps-mock-helpers` | `refactor(r14-02-wui-agent-caps-mock-helpers, SPL-<row issue>): ...` | `review/r14-02` | 1 |

Before placing either: R4's slug check reads since W, for both rows at once:
`git log origin/master --since="2026-11-28T03:34:51+02:00" --oneline -E --grep='\(r14-' | wc -l`
must print 0 (it printed 0 at 2026-11-28T03:47Z, `origin/master` `774876d90`), and
`git ls-remote origin 'refs/heads/review/r14-*' 'refs/heads/wip/*r14*' 'refs/heads/*-r14-*'`
must print nothing (it printed nothing then).

**r14-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/lib/spool_desk_root.py` (new),
`csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py`,
`csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-mirror-check.py` and
`csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh` (1.3's head1 diff). NOT
`desk-root.inc.sh`, NOT `spool_discussion.py`, NOT `spool_redact.py`, NOT any
`spawn-agents/tests/*`, NOT any other file. Do: plan section 2 row 01 verbatim, 1.3's
shape; the import keeps the form `from spool_desk_root import desk_root` (mutation
`m1d` shows why); red control (head1's test on its parent: `0c` FAIL) RED then GREEN in
the body; the 4 mutations `m1a`-`m1d` of 1.5 shown RED in the body. Gates: the row's
tests (section 2, `SPOOL_TEST=1`, in the worktree; a short `TMPDIR`, 1.5), the
`lint-py` ruff subset and `ruff format --check` on the 3 python files, `shellcheck -S
warning -x` and `csi-spl-iac/src/bash/scripts/sigpipe-lint.sh` on the test,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind
`simple_coding`, vendor claude; R7 the claude waiver seat under waiver `1a7c70da` while
agy cannot sit (re-checked at placement); never mistral. The mirror hook runs on every
agent turn: after the land, `python3 csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py --help`
has no `--help`: its no-op entry is a bare run, so the post-land smoke run is, from the
box checkout, `python3 csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py </dev/null`
-> rc 64 (usage, the import worked; an ImportError is rc 1) and
`python3 csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-mirror-check.py --bogus </dev/null`
-> rc 2 (usage; an ImportError is rc 1) (panel N4: head1's agent-mirror-check imports at
load time). Both rc values measured on `75d0f5fff`'s tree (base code) at 04:4xZ, n=1;
say both in the result. Required result field (panel N6): `test-install.sh` and
`agent-mcp.tst.sh` green in the row's real worktree, or the same check names red on its
parent (1.5).

**r14-02 brief, Files: ONLY**
`csi-spl-wui/src/utils/agent-caps.mjs`, `csi-spl-wui/src/utils/operator-console.mjs`,
`csi-spl-wui/src/types/operator-console.d.ts` and
`csi-spl-wui/tests/unit/agent-caps.test.mjs` (1.4's head2 diff). NOT `fleet-load.mjs`,
NOT `vendor-keys.mjs`, NOT `tenant-costs.mjs`, NOT `prefs.mjs`, NOT any `.vue`, NOT any
other file. Do: plan section 2 row 02 verbatim, 1.4's shape; red control (head2's test
on its parent: rc 1, 29 OK, 2 FAIL) RED then GREEN in the body; the 4 mutations
`m2a`-`m2d` of 1.5 shown RED in the body (`m2c` is green in the unit suites by design:
say which e2e catches it, or that none does: a required result field, panel N3). The
`opError` doc reads "the same shape spool-client.mjs builds" (panel N5;
`spool-client.mjs:261-264` sets `status`, `token`, `permission` on its Error). Gates:
`pnpm run typecheck` (the planner
could not run it, 1.5), the row's unit tests, `BASE_URL=<generated mock bundle> pnpm run test:e2e`
on the 6 e2e files of 1.4 (re-list them with `do_check_pre_push_e2e` on the row's own
sha), `cd csi-spl-iac && ./run -a do_check_pre_push`. The initial JS budget is CI's
(`ci_initial_gzip_kb`): the row adds no import edge, so the entry chunk should not move;
state the generate build's initial gzip KB before and after if you build it.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind
`simple_coding`, vendor claude; R7 the claude waiver seat under waiver `1a7c70da` while
agy cannot sit (re-checked at placement); never mistral.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of `desk_root` (row 01) | 2 on `774876d90` -> 1 (`spool_desk_root.py`) |
| copies of the error constructor / `browserStore` in `agent-caps.mjs` + `operator-console.mjs` (row 02) | 2 / 2 -> 1 / 1 (fleet-wide: 4 / 4 -> 3 / 3; section 7 has the rest) |
| lines (`git diff --numstat` of each head) | row 01: +28 -30 over 4 files; row 02: +28 -24 over 4 files (1.3, 1.4) |
| CI parts (`ci-doc-only.sh` on each head's range) | row 01 `cnf hub iac orc`; row 02 `iac orc wui` |
| measured on | `774876d90`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-peer-restart.func.sh` (`spl_peer_pids`) and `orc:src/bash/run/spl-rotate-lib.func.sh` (`spl_rotate_pids`) | the same `/proc` scan with a different matcher; deferred a third time (R3): queued ask `aa377e76` (35/99, HELD at 04:44:31Z) and `cf5e8b46` (s184 L5 rotation restart), live as `c-298` on the other box since v0.1, whose brief names both files | `do_spl_spawn_queue` 03:47:34Z and 04:44:31Z; `lane-map.sh --check` 04:46:04Z; window scan 1.2 (e) (n=1) |
| the other error-constructor copies: `fleetError` (`fleet-load.mjs:330`), `costsError` (`tenant-costs.mjs:528`); and `browserStore` in `fleet-load.mjs:515` and `vendor-keys.mjs:101` | each file imports only `./prefs.mjs` (`vendor-keys.mjs` also `./act-as-mock.mjs`): a fold into `operator-console.mjs` adds an import edge, into `prefs.mjs` it adds bytes to the initial JS, whose gzip budget only CI's generate job measures. A perf-round row (bundle measured first), or a refactor row with that measurement | WUI body scan 1.2 (e); `grep '^import'` of the 4 files |
| `issueQuery` (`spool-client-lazy.mjs:31` = `issues.mjs:201`, 14 lines) | deliberate: kept out of the lazy chunk, with `tests/unit/issues.test.mjs:226` checking the two agree; a fold moves a chunk boundary | WUI body scan |
| `_read_json` (`spool-mirror.py:668` = `lib/spool_discussion.py:106`) | 6 lines; spool-mirror would call a private name of another module (`sd._read_json`), or `spool_discussion` gains a public name for it: a naming change for 6 lines | python AST scan |
| r13-03 R7 N1-N4 (c-254 msg 65cc7198) | N1 / N4 test and count notes; N2 adds a FATAL line (a behaviour change); N3 a latent nameref collision no caller trips: a bug or test round, not a refactor | the message (`c-003/archive`) |
| r13-01 R7 N1-N4 (c-241 msg abf29eef) | N1-N3 test strength (inline `EPOCHREALTIME` not guarded, case 10 zone-dependent, 7-day cut not pinned); N4 a missing failure branch (behaviour change): a test or bug round, not a refactor | the message, relayed verbatim (msg 5feeb039), read in v1.0 |
| Go: `isASCII` (`internal/search/fold.go:47` = `internal/mail/mail.go:308`), `phoneDigits` (`store/personal_contacts.go` / `hub/search.go`), `firstOf` / `pick` (`hubclient/host.go` / `hub/release_notes_parse.go`) | cross-package: a fold needs one package to import the other or a new package for 6 lines; personal-contacts code is personal-data-adjacent | Go body scan |
| Go: the 7-9 line `*Preflight` route twins (14 groups of 2 to 11 functions in `internal/hub`) | a family, not a pair: wider than one row (5 sites max), and each is a route's auth gate: a gate row with its own red control | Go body scan |
| Go: `readPID` / `harden` (`internal/lockkey` = `internal/keyd`) and `checkNoteIDs` / `checkContactIDs` (`store/personal_*`) | secret-class (the key daemon) and personal-data stores | Go body scan |
| `spl-lane-handover{,-mistral,-agy}.func.sh` (the `pick_mode` tar / size / zstd / key-scan block, 8 shared windows) | parametric, not identical, and it packs agents' session transcripts for another box with a key-material scan: secret-class | window scan; `diff` of the two `pick_mode` |
| `gcp-list-{alert-incidents,monitoring,secrets}.func.sh`, `gcp-get-alert-incident.func.sh` (the per-env SA key loop) | each reads an env SA key file and activates it: secret-class | window scan |
| `spl-issue-{blocker-rca-close,owner-question-diss,discard-stale}.func.sh` (the apply loop and undo line) | prd issue mutations under an owner go, the loops differ in their skip rule; next to the diss-archive bug lane (`spl-issue-archive.func.sh`), which landed after v0.1 as `0e6f561e4` (SPL-6726); left for a round that measures on that tree | window scan |
| `spl-search-{calendar,doc}-probe.func.sh`, the `http` / `session_cookie` twins of 9 probe `.py`, `spl-release-note-bans-{check,seed}`, `build-push-{hub,pdf}-image` | sign a member in with a password file, or read a Secret Manager slot (secret-class); the image pair differs in its tag and registry logic | window and AST scans |
| the `*-cron.sh` shims' preamble (19 files) | standalone by design: a cron job reads no profile and sources nothing | `scripts/` window scan |
| r13 section 7's other items | unchanged on `774876d90`, with r13's reasons | r13 plan section 7; scans 1.2 (e) (n=1) |

## 8. Changes

- v0.1 (c-915): the rows and every read on `774876d90`; both heads built in scratch
  clones; the column of 1.5 run on base and each head; ruff, shellcheck 0.10.0 and
  `sigpipe-lint.sh` as 1.3 / 1.5 say; both red controls and the mutations as 1.5 says.
  Pushed to `review/c002-refactor-round-14-planner`.
- v1.0 (c-915): the panel's c-917 PASS on `75d0f5fff` (msg 6c6b6686, W none) folded:
  N1 the r13-01 R7 notes read in full (relay 5feeb039), 1.2 (b) and section 7; N2 the
  `/proc` twin re-read (`cf5e8b46` live as `c-298`, `aa377e76` HELD; `c-303` s184 H3 is
  new, its brief greps 0 for the row paths, as do `c-298`'s and `c-290`'s), 1.2 (a),
  2.2 and section 7; N3 `m2c`'s e2e a required r14-02 result field; N4 the r14-01
  post-land smoke run names both scripts' no-op entries and their rc; N5 the `opError`
  doc says "builds", head2's `operator-console.mjs` sha256 `34fa31013fe0`
  (agent-caps 0 / 31 / 0, operator-console 0 / 40 / 0 on it, n=1); N6 `test-install.sh`
  and `agent-mcp.tst.sh` a required r14-01 result field. `origin/master` moved to
  `0e6f561e4`: `git diff --name-only 774876d90 0e6f561e4 --` the 9 row paths -> 0
  (04:4xZ); every count stays on `774876d90`.

- Close (c-915, 2026-11-28T08:0xZ, on `origin/master` `454bf1f6b`, n=1): R6 since
  W -> the 3 plan commits and the 2 rows, `r14-01` `2de10856d` (SPL-6733, c-336,
  07:07:55Z) and `r14-02` `454bf1f6b` (SPL-6734, c-349, 07:43:31Z). R5: is-ancestor of
  `origin/master` and of the box checkout rc 0 for both; r14-02's wf 10 (46122612088)
  and wf 30 (46122612015) success, `do_check_deploy_lag` dev and prd: WUI serves
  `454bf1f6`, rc 0 (08:06Z); r14-01's wf 10 (46119874909), 16 and 67 success. C7: the
  reviewed sha's diff to the landed sha over each row's 4 files is empty, patch-ids
  equal (`fa4c1ca1c3f4`, `27ee23a6e8c2`). Review lines: r14-02 `do_spl_review_line_check`
  rc 0 on the reviewer's box (OK 18 of 18, c-375 msg ee406101); r14-01 SYNTAX OK here,
  the full check not quoted (its seat closed first). Detail: the retro.

## 9. Consensus

Same-vendor panel, waiver 1a7c70da (c-001 ruling on 21e079a5): agy, the cross-vendor
reviewer of a claude plan, is out of quota on both boxes until about 2026-12-03 (and
paused on this box until 2026-11-28T05:24:23Z, `do_spl_lane_mix` at 04:03:04Z), so the
panel seat is claude. The r14 retro names this.

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `c-915` | claude | editor | v1.0 | author | section 8 |
| claude panel seat (`hand-sat-c002-refactor-round-14-claude-panel-seat`, live as c-917@sat) | claude | panel | v1.0 `4891e4598` (v0.1 `75d0f5fff`) | PASS on both (v0.1 msg 6c6b6686, N1-N6 folded in v1.0; v1.0 msg fd10cc80), W none | seat file `refactor-round-14-20261128/seat-claude.md`; same-vendor panel, waiver 1a7c70da (c-001 ruling on 21e079a5) |
| row R7 `r14-01` | claude (c-351) | R7, author c-336 (claude) | `c6d406a82` -> landed `2de10856d` | PASS | same-vendor, waiver 1a7c70da; line check: SYNTAX OK here, full check not quoted (retro 4.2) |
| row R7 `r14-02` | claude (c-375) | R7, author c-349 (claude) | `0579fc04f` -> landed `454bf1f6b` | PASS, GO by hand (review-go held it) | same-vendor, waiver 1a7c70da; line check rc 0 on the reviewer's box, OK 18 of 18 |

No row lane starts before the panel signs the plan sha and its review line passes
`do_spl_review_line_check` (rc 0), confirmed by the dispatch lease holder.
