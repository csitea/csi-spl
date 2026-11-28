# Refactoring round 13 (2026-11-27) - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6710  
Topic: a2ab3779-df44-4d8f-993b-3065178ee601  
Discussion: a2ab3779-df44-4d8f-993b-3065178ee601 (t1 #refactoring, "Refactor round 13", opened by c-002)  
Window: W=2026-11-27T20:38:00+02:00  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, after 99 comes 01 (rulebook 5.3). The older cycle already created
  `refactor-round-13-plan.md`, `refactor-round-13-retro.md` and `refactor-round-13/` on
  `origin/master`, so this round carries its open date (rulebook 5.3): plan
  `refactor-round-13-20261127-plan.md`, retro `refactor-round-13-20261127-retro.md`,
  seat dir `refactor-round-13-20261127/`, Qto doc title the same, rows `r13-<NN>`,
  commit scope `docs(r13-plan, SPL-6710)`.
- owner 10-17 (t1 b61851fb, msg 91bf8278): no mistral coding or testing rows; mistral
  sits on no review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 12
([refactor-round-12-20261127-plan.md](refactor-round-12-20261127-plan.md), SPL-6696)
has served both rows on `origin/master`: `r12-01` `99923867a` (SPL-6704, follow-up
`545713768` for its R7 notes N1 and N3) and `r12-02` `c978c467e` (SPL-6705). Its close
record (`Closes: SPL-6696`) has not landed: `git log origin/master --oneline
--grep='SPL-6696'` prints only the r12 plan `bbef68498`. The perf floor (rulebook 4.4),
re-measured on `d03028967`: `perf 35 refactor 116 perf-share 23.2% floor-met`
(5 x 35 = 175 >= 151), so this is a refactor round (the brief's read at 23:2xZ on
`545713768` was `perf 35 refactor 117 perf-share 23.0%`; the 14-day window moved).

Both rows are **one fact, one copy** (developer guide 2.2.4), non-secret, zero-PG, with
zero behaviour change:
- **Row 01 (the external API probe uses the uplink probe's ms clock, ISO stamp and 7-day
  trim, 2 `csi-spl-utl` files):** `utl:src/bash/run/external-api-health.func.sh` carries
  byte-identical copies of `spl_uplink_ms` (`ext_api_ms`, `:109`) and `spl_uplink_trim`
  (`ext_api_trim`, `:142-152`), and two inline copies of the `spl_uplink_iso` body
  (`:72`, `:98`), although it already sources `orc:src/bash/run/spl-uplink-probe.func.sh`
  (`:65`, only when `EXTERNAL_API_DIR` is unset). The row sources it on every run and
  deletes the copies. Guarded by case `13` of `utl:src/bash/tests/external-api-health.tst.sh`.
- **Row 03 (`_spl_channel_agent_ids`, the operator channel seat actions' box and agent id
  checks, 3 `csi-spl-orc` files):** `orc:src/bash/run/spl-channel-agent-add-op.func.sh:67-76`
  and `orc:src/bash/run/spl-channel-agent-remove-op.func.sh:39-48` carry the same 10
  lines (AGENT_BOX check, empty AGENTS check, lazy source of `spool-env.inc.sh`, the
  `spl_is_agent_id` + dedupe loop). The row hosts them once as `_spl_channel_agent_ids`
  in the add-op file; remove-op lazy-sources it. Guarded by section `5` of
  `orc:src/bash/tests/channel-agent-remove-op.tst.sh`.

The two rows share no file: both are **Batch 1**.

**Status: v1.0, signed by the panel (c-867 PASS on `0d794aa4c`).** Editor: **c-851** (claude, the specs_and_docs backup:
agy is out of quota on both boxes until about 2026-12-03T07:02Z). Panel: the claude seat
`hand-sat-c002-refactor-round-13-claude-panel-seat` (queued as ask `bd0f6ac8`, position
73/109 at 2026-11-27T23:44:38Z), a same-vendor panel under waiver `1a7c70da` (section 9).

**One sha:** every count is measured on **`d03028967`**
(`d030289673d10a4ad4caad945382d05e0f474c27`, `origin/master` at 2026-11-27T23:43:47Z),
n=1 per command unless stated. The tests of 1.5 ran in scratch clones of `d03028967`
(not committed): "base" unmodified, "head1" = base + row 01 as in 1.3, "head2" = base +
row 03 as in 1.4; each red control and mutation ran on its tree and was restored after.
1.3 and 1.4 print each head as a unified diff against `d03028967`, so any panel or R7
seat can rebuild head1 and head2 with `git apply` and check the sha256 values. Queue,
lane map, brief and branch reads are live state and carry their own times.

## 1. Baseline

### 1.1 Window, slug proof and old-cycle leftovers (rulebook 5.3)

2026-11-27T23:43:47Z-23:43:55Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-27T20:38:00+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r12-(plan|close)'`:
  `bbef684985632e26c022c50af4b4f81d665640f6`
  (`docs(r12-plan, SPL-6696): refactor round 12 plan v1.0 (fold panel W1, W2, N1-N7; signed by c-999 PASS on 05594587a)`).
  r12's close record has not landed, so W is the r12 plan v1.0 commit. Read once; every
  later R4, R6, 2.7.5 and `PRUNE_SINCE` read for r13 uses this W.
- **Perf floor (rulebook 4.4):** the 4.4 command on `d03028967` ->
  `perf 35 refactor 116 perf-share 23.2% floor-met`.
- **Slug proof since W:**
  `git log origin/master --since="2026-11-27T20:38:00+02:00" --oneline -E --grep='\(r13-' | wc -l`
  -> **0**.
- **Remote heads:**
  `git ls-remote origin 'refs/heads/review/r13-*' 'refs/heads/wip/*r13*' 'refs/heads/*-r13-*' 'refs/heads/*refactor-round-13*'`
  -> **2**, both from the old cycle and older than W (tip commit dates):
  `review/r13-02` `6cc7f2cbb` (2026-10-16T04:45:03+03:00) and
  `wip/c-596-c002-r13-01-wui-decompose-message-card` `90887bc0c`
  (2026-10-16T05:12:00+03:00). The W-scoped DRY prune (2026-11-28T00:15:35Z) keeps both:
  `KEEP review/r13-02 before-window 2026-11-27T20:38:00+02:00`,
  `KEEP wip/c-596-c002-r13-01-wui-decompose-message-card before-window ...`,
  `nothing deleted`. This plan's own review branch is
  `review/c002-refactor-round-13-planner` (not matched by `review/r13-*`). The
  `review/r13-02` head is why the second row is numbered **r13-03**, not r13-02 (holder
  ruling on the panel's W1, section 5): no row of this round uses the id `r13-02`.
- **Old-cycle files:** `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep refactor-round-13`
  -> 3: `refactor-round-13-plan.md`, `refactor-round-13-retro.md`, `refactor-round-13/`.
  The dated names of this round match 0 entries.
- **Briefs on the planner box** (`ls -la /var/spool-hub/dispatch/briefs`, filtered on
  `r13-[0-9]{2}|r13-retro|r13-seat|r12-retro-r13|refactor-round-13|r13-plan|-r13-`):
  besides this planner's brief and the panel seat's
  (`hand-sat-c002-refactor-round-13-claude-panel-seat.md`, both 2026-11-28T01:31:18 box
  time), 21 old-cycle leftovers, all before W (mtimes 2026-11-18, one 2026-10-18): the
  brief's 4 (`c001-r13-r7-reviewer-agy.md`, `c002-r12-retro-r13-plan.md`,
  `c002-refactor-r13-retro-r14-plan.md` and the `c002-r13-*` row briefs), namely
  `c002-r13-01-wui-decompose-message-card.md`, `c002-r13-02-wui-test-sfc-script-ratchet.md`,
  `c002-r13-03-restart.md`, `c002-r13-04-wui-decompose-channel-sidebar.md`,
  `c002-r13-05-restart.md`, `c002-r13-05-restart2.md`, `c002-r13-06-restart2.md`,
  `c002-r13-07-restart2.md`, `c002-r13-08-restart2.md`, `c002-r13-09-restart.md`,
  `c002-r13-10-restart.md`, `c002-r13-10-restart2.md`; and, beyond the brief's list but
  of the same old cycle, `c002-r13-r7-reviewer-agy.md`, the 3 seat briefs
  `c002-r13-seat-{claude,grok,mistral}.md` and one hidden backup
  `.c002-r13-07-restart2.md.bak-2125` (2026-10-18). No other r13 head, file or brief
  exists for this cycle.

### 1.2 The brief's inputs, re-measured on `d03028967`

- **(a) r12 section 7, the two items deferred to r13 by name:**
  1. `orc:src/bash/run/spl-uplink-probe.func.sh` / `utl:src/bash/run/external-api-health.func.sh`:
     `diff` of `spl-uplink-probe.func.sh:184-194` against `external-api-health.func.sh:142-152`
     with the function names masked -> rc 0 (11 identical lines); `:95` against `:109`
     -> rc 0. A third copy, found now: `external-api-health.func.sh:72,98` inline the
     body of `spl_uplink_iso` (`spl-uplink-probe.func.sh:89`). -> **row 01** (1.3).
  2. `spl_peer_pids` (`orc:src/bash/run/spl-peer-restart.func.sh:102-120`) and
     `spl_rotate_pids` (`orc:src/bash/run/spl-rotate-lib.func.sh:832-850`): still the
     same 19-line `/proc` scan with a different matcher (`spl_peer_harness_comm "$comm"`
     against `spl_rotate_cli "$d" "$comm"`). **Still deferred:** queued ask `aa377e76`
     (`c001-s179-b5-paused-seats-free`, `HELD` behind `c001-s179-b4-spawn-pause-hold` in
     `do_spl_spawn_queue` at 23:44:38Z) names `spl-rotate-lib.func.sh` in its brief
     (`:20`, the `Open takes`), and 8 more briefs modified in the last 48 h name it
     (`c002-s184-l5-rotation-restart-rekind.md`, which also names `spl-peer-restart`,
     `c002-spl6615-rotate-login-race-respawn.md` and 6 reviewer seat briefs). Section 7.
- **(a') The rest of r12 section 7:** unchanged on `d03028967` with r12's reasons;
  carried into section 7.
- **(b) R7 notes of r12-01 and r12-02:**
  - r12-01's N1 (c-806) and N3 landed as `545713768`. Its R7 (c-838 PASS on `39bef48ae`)
    left a new N1: `check-hub-deploy.tst.sh:316` pins the describe-failure return through
    the FATAL wording at `check-hub-image-regress.func.sh:46` (c-838's mutation M3, `:43`
    dropped plus `:46` reworded, stays green). A test-strength row, not a refactor:
    section 7 (it is also in the candidates file, below).
  - r12-02 (`c978c467e`): its body records one deviation from the plan (the
    `lint-sigpipe` part refused `awk ... | grep -q`) and no follow-up note. This plan's
    test hunks pipe into no early-exit consumer (`sigpipe-lint.sh` rc 0, 1.5).
  - r12 panel notes: all folded into r12 v1.0 (`bbef68498`).
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  on the planner box, 183 lines, mtime 2026-11-28T01:28:11 box time; re-read for v1.0 at
  2026-11-28T01:04:26Z: 196 lines, mtime 02:04:06 box time, the 13 new lines 184-196 are
  the SPL-6698 L4 and SPL-6699 H2 review notes, test and bug shaped, none a refactor), its
  refactor-shaped items:
  - line 1 (literal `/var` paths in `spl-watchdog.func.sh` and `spl-lane-rotate.func.sh`):
    served, `git grep -nE '/var/\$|/var/csi|LOGIN_STATE_DIR:-' d03028967 -- <both files>`
    -> 0 hits.
  - lines 25, 48, 76, 104, 115: served on `3308d118f` (r12 1.2 (c)).
  - line 113 (`_ppe_keys`, gate design), line 125 (WUI entry-chunk headroom, perf), the
    r12-01 R7 N1 line and the SPL-6661 N1 / N2 lines added 2026-11-27 (test gaps, code
    order in a live lane's lib): not refactor rows; section 7.
- **(d) spec 011 tasks:** `git log 3308d118f..d03028967 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> 0; its 15 open tasks (`T001`-`T008` owner-deferred, `T018`-`T021`, `T023`, `T027`,
  `T034`) are each wider than one row or wait on the owner.
- **(e) A duplicate scan of its own** (scripts in the planner's scratch dir, on a
  `git archive` of `d03028967`'s `csi-spl-{orc,iac,utl}/src/bash/run`,
  `csi-spl-orc/lib/bash` and `spawn-agents/{lib,scripts}`): identical function bodies (6
  lines or more, own function names masked) and identical 6- and 8-line windows across
  files, with the `run.sh` and `print-help.func.sh` twins left out (byte-identical by
  design, developer guide 2.4.2). Outcome:
  - `ext_api_trim` = `spl_uplink_trim`: with the gcp apis enable/disable pair, the only
    cross-file function twin -> row 01.
  - `spl-channel-agent-add-op.func.sh:67-76` = `spl-channel-agent-remove-op.func.sh:39-48`
    (plus the dry-run gate line) -> **row 03** (1.4).
  - Every other hit is secret-class, PG-bound, a guard or already folded: section 7.

### 1.3 Row 01's site: the external API probe reuses the uplink probe's helpers

`orc:` = `csi-spl-orc/`, `utl:` = `csi-spl-utl/`. On `d03028967`:

- `utl:src/bash/run/external-api-health.func.sh` (157 lines, last changed `b36b20577`
  2026-11-18) writes its samples next to the uplink probe's, "in its format" (its
  header, `:16-18`), and already sources `orc:src/bash/run/spl-uplink-probe.func.sh`
  (`:65`) for the default dir. It keeps its own copies of three uplink probe helpers:
  1. `ext_api_ms` (`:108-109`) = `spl_uplink_ms` (`spl-uplink-probe.func.sh:94-95`),
     byte for byte; 8 calls (`:74`, `:80`, `:124-135`).
  2. `ext_api_trim` (`:140-152`) = `spl_uplink_trim` (`spl-uplink-probe.func.sh:182-194`),
     byte for byte in its 11-line body (the comment wraps differently); 1 call (`:99`).
  3. `TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T'` inline at `:72` and `:98` = the body of
     `spl_uplink_iso` (`spl-uplink-probe.func.sh:89`). `git grep -nF` of that format
     over every `src/bash/run` and `lib` of orc, iac and utl -> these 3 lines only.
- The source at `:65` runs only when `EXTERNAL_API_DIR` is unset. The row moves it ahead
  of the dir block so it runs on every call (guard: `declare -F spl_uplink_trim`), and
  calls `spl_uplink_ms`, `spl_uplink_iso` and `spl_uplink_trim`. The host
  `spl-uplink-probe.func.sh` is **not edited**; sourcing it defines functions only (no
  top-level command besides the header comment), and it was already sourced on the
  default-dir path.
- **CI cost:** `ci-doc-only.sh d03028967 HEAD` on head1 prints
  `parts=all - csi-spl-utl/src/bash/run/external-api-health.func.sh needs the full gate`
  (a `csi-spl-utl/` path maps to `all`). The one full-gate row of the round; r12 deferred
  it for that reason, and of r12's two named deferrals it is the one no other lane holds
  (2.2).
- Non-secret: the probe reads no key or credential (getent, a TCP connect and a TLS
  handshake, payload-free); the test stubs all three.
- Line cap (`bash-cleancode.tst.sh`, 75): `do_net_external_api_check` 60 -> 61 lines,
  `ext_api_probe` 26 (unchanged), `ext_api_trim` 11 -> gone. Neither edited file has an
  entry in `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt` or `param-required-baseline.txt`.

Shape (head1, `git diff --numstat d03028967 head1`):
`external-api-health.func.sh` +13 -29 (157 -> 141 lines),
`external-api-health.tst.sh` +11 -0 (207 -> 218). sha256 (12 chars):
`external-api-health.func.sh` `ffff32c79361`, `external-api-health.tst.sh` `d28b6e398393`.

head1 as a diff against `d03028967` (`git apply` it there; `index` lines dropped):

```diff
diff --git a/csi-spl-utl/src/bash/run/external-api-health.func.sh b/csi-spl-utl/src/bash/run/external-api-health.func.sh
--- a/csi-spl-utl/src/bash/run/external-api-health.func.sh
+++ b/csi-spl-utl/src/bash/run/external-api-health.func.sh
@@ -60,24 +60,25 @@ do_net_external_api_check() {
   for ep in "${list[@]}"; do
     [[ "$ep" =~ ^[a-z0-9-]+=[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || { do_log "FATAL endpoint '$ep' is not name=host:port"; return 1; }
   done
+  # the ms clock, the ISO stamp, the 7-day trim and the default dir are the uplink probe's
+  declare -F spl_uplink_trim >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/src/bash/run/spl-uplink-probe.func.sh"
   dir="${EXTERNAL_API_DIR:-}"
   if [[ -z "$dir" ]]; then
-    declare -F spl_uplink_probe_dir >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/src/bash/run/spl-uplink-probe.func.sh"
     spl_uplink_probe_dir dir || return 1
   fi
   box="${EXTERNAL_API_BOX:-${UPLINK_PROBE_BOX:-$(spl_box_name)}}"
   [[ "$box" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL the box id '$box' is not a plain name (set EXTERNAL_API_BOX)"; return 1; }
   file="$dir/$box.external-api.tsv"
   now="${EXTERNAL_API_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
-  ts="$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' "$now")"
+  ts="$(spl_uplink_iso "$now")"
   tmp="$(mktemp -d)" || { do_log "WARN cannot make a temp dir: no sample"; return 0; }
-  t0="$(ext_api_ms)"
+  t0="$(spl_uplink_ms)"
   for i in "${!list[@]}"; do
     ext_api_probe "${list[$i]}" "$tmo" >"$tmp/$i" &
     pids+=($!)
   done
   wait "${pids[@]}" 2>/dev/null
-  t1="$(ext_api_ms)"
+  t1="$(spl_uplink_ms)"
   mkdir -p "$dir" 2>/dev/null || do_log "WARN cannot create $dir: samples not kept"
   for i in "${!list[@]}"; do
     IFS=$'\t' read -r name host port dnsok dnsms tcpok tcpms tlsok tlsms <"$tmp/$i" || continue
@@ -95,8 +96,8 @@ do_net_external_api_check() {
   done
   rm -rf "$tmp"
   if [[ -f "$file" ]]; then
-    cut="$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' $((now - 7 * 86400)))"
-    ext_api_trim "$file" "$cut"
+    cut="$(spl_uplink_iso $((now - 7 * 86400)))"
+    spl_uplink_trim "$file" "$cut"
   fi
   echo "external-api $ts box=$box endpoints=$n down=$down wall=$((t1 - t0))ms file=$file"
   return 0
@@ -105,9 +106,6 @@ do_net_external_api_check() {
 # do_external_api_health - the file-name alias run.sh derives for this file
 do_external_api_health() { do_net_external_api_check "$@"; }
 
-# ext_api_ms - a millisecond wall clock (no fork)
-ext_api_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }
-
 # ext_api_probe <name=host:port> <timeout> - prints one TSV row:
 # name host port dns_ok dns_ms tcp_ok tcp_ms tls_ok tls_ms
 ext_api_probe() {
@@ -121,36 +119,22 @@ ext_api_probe() {
   ((${#tcp[@]})) || tcp=(bash -c 'exec 3<>"/dev/tcp/$1/$2"' _)
   # shellcheck disable=SC2016 # $1 and $2 expand in the child bash
   ((${#tls[@]})) || tls=(bash -c 'openssl s_client -connect "$1:$2" -servername "$1" -verify_return_error -brief </dev/null' _)
-  t0="$(ext_api_ms)"
+  t0="$(spl_uplink_ms)"
   timeout "$tmo" "${getent[@]}" hosts "$host" >/dev/null 2>&1 && dnsok=1
-  dnsms=$(( $(ext_api_ms) - t0 ))
+  dnsms=$(( $(spl_uplink_ms) - t0 ))
   if [[ "$dnsok" == 1 ]]; then
-    tcpok=0; t0="$(ext_api_ms)"
+    tcpok=0; t0="$(spl_uplink_ms)"
     timeout "$tmo" "${tcp[@]}" "$host" "$port" >/dev/null 2>&1 && tcpok=1
-    tcpms=$(( $(ext_api_ms) - t0 ))
+    tcpms=$(( $(spl_uplink_ms) - t0 ))
   fi
   if [[ "$tcpok" == 1 ]]; then
-    tlsok=0; t0="$(ext_api_ms)"
+    tlsok=0; t0="$(spl_uplink_ms)"
     timeout "$tmo" "${tls[@]}" "$host" "$port" >/dev/null 2>&1 && tlsok=1
-    tlsms=$(( $(ext_api_ms) - t0 ))
+    tlsms=$(( $(spl_uplink_ms) - t0 ))
   fi
   printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host" "$port" "$dnsok" "$dnsms" "$tcpok" "$tcpms" "$tlsok" "$tlsms"
 }
 
-# ext_api_trim <file> <cutoff-iso> - drops the samples older than the cutoff,
-# only when the first line is older
-ext_api_trim() {
-  local file="$1" cut="$2" first=""
-  IFS=$'\t' read -r first _ <"$file" || return 0
-  [[ "$first" < "$cut" ]] || return 0
-  if awk -F'\t' -v cut="$cut" '$1 >= cut' "$file" >"$file.tmp.$$"; then
-    mv -f "$file.tmp.$$" "$file" || do_log "WARN cannot trim $file"
-  else
-    rm -f "$file.tmp.$$"; do_log "WARN cannot trim $file"
-  fi
-  return 0
-}
-
 # Register the row's action name with run.sh's function map when sourced
 if declare -p _func_to_file &>/dev/null; then
   _func_to_file["do_net_external_api_check"]="${BASH_SOURCE[0]}"
diff --git a/csi-spl-utl/src/bash/tests/external-api-health.tst.sh b/csi-spl-utl/src/bash/tests/external-api-health.tst.sh
--- a/csi-spl-utl/src/bash/tests/external-api-health.tst.sh
+++ b/csi-spl-utl/src/bash/tests/external-api-health.tst.sh
@@ -14,6 +14,8 @@
 #  10. Samples older than 7 days are trimmed
 #  11. Report-only: an unwritable dir still exits 0 with a WARN
 #  12. ./run -a do_net_external_api_check through the csi-spl-utl harness
+#  13. One copy (r13-01): the ms clock, the ISO stamp and the 7-day trim are
+#      the uplink probe's (spl_uplink_ms, spl_uplink_iso, spl_uplink_trim)
 #------------------------------------------------------------------------------
 set -uo pipefail
 
@@ -201,6 +203,15 @@ else
   fail "12. ./run harness (rc=$rc out=$out)"
 fi
 
+# 13 ------------------------------------------------------------------------
+own=$(grep -nE '^[a-z_]+_(ms|iso|trim)\(\)|TZ=UTC printf|-v cut="\$cut"' "$FUNC_SH" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
+if [[ -z "$own" ]] && grep -qF 'spl_uplink_trim "$file" "$cut"' "$FUNC_SH" && grep -qF 'ts="$(spl_uplink_iso "$now")"' "$FUNC_SH" \
+   && grep -qF 't0="$(spl_uplink_ms)"' "$FUNC_SH"; then
+  pass "13. one copy: ms clock, ISO stamp and trim come from spl-uplink-probe.func.sh"
+else
+  fail "13. one copy (own=[$own])"
+fi
+
 echo "=========================================="
 echo "external-api-health: $fails failure(s)"
 echo "=========================================="
```

**Behaviour:** none changes: the same TSV line (ISO stamp, 1/0/- fields, ms), the same
stdout and WARN lines, the same trim (only when the first line is older than 7 days),
the same exit codes. Existing cases 1 (row format with the ISO stamp), 3
(`tcp_ms >= 4900` at the 5 s timeout: the ms clock), 10 (the trim, and the stamp
`2033-05-18T03:33:20Z` of `EXTERNAL_API_NOW=2000000000`) and 12 (the `./run` harness) run
with `EXTERNAL_API_DIR` set, the path where base never sourced the uplink probe, and pass
on base and head1 alike (1.5).

### 1.4 Row 03's site: `_spl_channel_agent_ids` (add-op, remove-op)

On `d03028967`:

- `orc:src/bash/run/spl-channel-agent-remove-op.func.sh` (145 lines) is "the operator
  mirror of do_spl_channel_agent_add_op" (its header, `:3-4`);
  `orc:src/bash/run/spl-channel-agent-add-op.func.sh` has 268 lines. Both last changed in
  `5467bfffc` (2026-11-15). Their entry functions share 10 identical lines and the
  dry-run gate after them:
  - `add-op:67-76` = `remove-op:39-48`: the AGENT_BOX check (`^[a-z0-9][a-z0-9-]{0,31}$`,
    not `box-wui`), the empty AGENTS check, the lazy source of
    `spawn-agents/lib/spool-env.inc.sh`, the `spl_is_agent_id` loop with first-seen
    dedupe, `agents="${ids[*]}"`;
  - with their declarations `local -a ids=()` / `declare -A seen=()` (`add-op:44-45`,
    `remove-op:31-32`) and the loop variable `a` (`add-op:41`, `remove-op:30`).
- Why only these two: `git grep -nF 'is not a box id (box-wui is reserved)' d03028967`
  -> 14 files. The other 12 check other variables (`DESK_BOX`, `PROBE_BOX`, a loop `$b`)
  in desk and probe actions, several secret-class, and their next lines differ.
  `spl-channel-agent-add.func.sh:32-37` (the member path) has the box and id checks
  without the dedupe and reads a member password file: out (section 7).
- The helper `_spl_channel_agent_ids <var name> <box>` lives in the add-op file (zero
  new files, zero eager loads). Remove-op lazy-sources the add-op file inside
  `do_spl_channel_agent_remove_op`, only when the helper is not yet defined (the r12-02
  form). The add-op file has no top-level command besides its functions and their SQL
  heredocs. `spool-env.inc.sh` assigns its globals with plain assignments (0 top-level
  `declare` / `local` / `typeset` in its 1217 lines), so sourcing it one call deeper
  keeps them global, as before.
- `_spl_channel_agent_remove_op_run` loops `for a in $4` only to count. With `$a` read
  nowhere else in the file, shellcheck 0.10.0 reports `SC2034 (warning): a appears
  unused` at `:54` on the head (base: rc 0 on all 3 files). The row writes that loop
  `for _ in $4` and drops `a` from its `local` line: the same count, the same word
  splitting and pathname expansion.
- Non-secret and zero-PG for the change: the helper is input validation that runs before
  `do_gcp_pin_account` and `spl_via_proxy`; both test files stub `gcloud`, `psql`,
  `cloud-sql-proxy` and `docker`.
- **Narrow CI:** `ci-doc-only.sh d03028967 HEAD` on head2 -> `parts=cnf hub iac orc`.
- Line cap: `do_spl_channel_agent_add_op` 48 -> 37 lines, `do_spl_channel_agent_remove_op`
  31 -> 22, `_spl_channel_agent_ids` 16 (new), `_spl_channel_agent_remove_op_run` 33
  (unchanged). None of the 3 edited files has an entry in the 4 baselines of 1.3.
- Naming: no `apply` in the helper or the row slug (`do_spl_review_go` reads an owner-go
  keyword in a brief that names `*_apply` helpers).

Shape (head2, `git diff --numstat d03028967 head2`):
`spl-channel-agent-add-op.func.sh` +24 -13 (268 -> 279),
`spl-channel-agent-remove-op.func.sh` +6 -15 (145 -> 136),
`channel-agent-remove-op.tst.sh` +41 -0 (137 -> 178). sha256 (12 chars):
`spl-channel-agent-add-op.func.sh` `0886cb641acc`,
`spl-channel-agent-remove-op.func.sh` `76627571f91b`,
`channel-agent-remove-op.tst.sh` `a070c581fec9` (v1.0: the two `(r13-02)` labels of the
v0.1 head read `(r13-03)`, a comment-only change; v0.1's value was `a34c5a00909b`).

head2 as a diff against `d03028967` (`index` lines dropped):

```diff
diff --git a/csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh b/csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh
--- a/csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh
+++ b/csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh
@@ -38,11 +38,9 @@
 do_spl_channel_agent_add_op() {
   do_require_bin yq psql || return 1
   do_spl_cloud_cnf || return 1
-  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" box="${AGENT_BOX:-$(spl_desk_box_default)}" agents="${AGENTS:-}" dry=1 raw a
+  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" box="${AGENT_BOX:-$(spl_desk_box_default)}" agents="${AGENTS:-}" dry=1 raw
   local allowdef="${ALLOW_DEFAULT_CHANNEL:-0}"
   [[ "$allowdef" == 0 || "$allowdef" == 1 ]] || { do_log "FATAL ALLOW_DEFAULT_CHANNEL must be 0 or 1, got: '$allowdef'"; return 1; }
-  local -a ids=()
-  declare -A seen=()
   spl_require_tenant_slug "$tenant" || return 1
   [[ "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
   raw="$ch"
@@ -64,16 +62,7 @@ do_spl_channel_agent_add_op() {
         return 1
       fi ;;
   esac
-  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL AGENT_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
-  [[ -n "$agents" ]] || { do_log "FATAL AGENTS must name at least one agent id"; return 1; }
-  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
-  for a in $agents; do
-    spl_is_agent_id "$a" || { do_log "FATAL AGENTS entry '$a' is not an agent id"; return 1; }
-    [[ -n "${seen[$a]:-}" ]] && continue
-    seen[$a]=1
-    ids+=("$a")
-  done
-  agents="${ids[*]}"
+  _spl_channel_agent_ids agents "$box" || return 1
   if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
   if (( dry )); then
     do_log "OK DRY_RUN would add $agents on $box to #$ch in $tenant (origin=invite) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
@@ -84,6 +73,28 @@ do_spl_channel_agent_add_op() {
   spl_via_proxy _spl_channel_agent_add_op_run "$tenant" "$ch" "$box" "$agents" "$allowdef"
 }
 
+# _spl_channel_agent_ids <var name> <box>: the AGENT_BOX and AGENTS checks of
+# the operator channel seat actions (add_op, remove_op). Refuses a box that is
+# not a box id (box-wui is reserved), an empty list and an entry that is not an
+# agent id; then writes the named var's space-separated ids back deduped, in
+# first-seen order. 1 with the FATAL on the first bad value.
+_spl_channel_agent_ids() {
+  local -n _cai_ids="$1"
+  local box="$2" a
+  local -a ids=()
+  local -A seen=()
+  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL AGENT_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
+  [[ -n "$_cai_ids" ]] || { do_log "FATAL AGENTS must name at least one agent id"; return 1; }
+  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
+  for a in $_cai_ids; do
+    spl_is_agent_id "$a" || { do_log "FATAL AGENTS entry '$a' is not an agent id"; return 1; }
+    [[ -n "${seen[$a]:-}" ]] && continue
+    seen[$a]=1
+    ids+=("$a")
+  done
+  _cai_ids="${ids[*]}"
+}
+
 # _spl_channel_agent_add_op_run <tenant> <channel> <box> <agents> [allowdef]
 # [system]: system=1 is the desk reconcile's add, which a humans-only channel
 # skips (OK, nothing written); 0 (by hand) adds and clears the mark.
diff --git a/csi-spl-orc/src/bash/run/spl-channel-agent-remove-op.func.sh b/csi-spl-orc/src/bash/run/spl-channel-agent-remove-op.func.sh
--- a/csi-spl-orc/src/bash/run/spl-channel-agent-remove-op.func.sh
+++ b/csi-spl-orc/src/bash/run/spl-channel-agent-remove-op.func.sh
@@ -27,25 +27,16 @@
 do_spl_channel_agent_remove_op() {
   do_require_bin yq psql || return 1
   do_spl_cloud_cnf || return 1
-  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" box="${AGENT_BOX:-$(spl_desk_box_default)}" agents="${AGENTS:-}" dry=1 a
-  local -a ids=()
-  declare -A seen=()
+  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" box="${AGENT_BOX:-$(spl_desk_box_default)}" agents="${AGENTS:-}" dry=1
   spl_require_tenant_slug "$tenant" || return 1
   [[ "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
   [[ "$ch" == general ]] && ch=lobby
   case "$ch" in
     issues|tasks) do_log "FATAL #$ch is not a channel an agent sits in (reserved / retired)"; return 1 ;;
   esac
-  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL AGENT_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
-  [[ -n "$agents" ]] || { do_log "FATAL AGENTS must name at least one agent id"; return 1; }
-  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
-  for a in $agents; do
-    spl_is_agent_id "$a" || { do_log "FATAL AGENTS entry '$a' is not an agent id"; return 1; }
-    [[ -n "${seen[$a]:-}" ]] && continue
-    seen[$a]=1
-    ids+=("$a")
-  done
-  agents="${ids[*]}"
+  # shellcheck source=spl-channel-agent-add-op.func.sh
+  declare -F _spl_channel_agent_ids >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-channel-agent-add-op.func.sh" || return 1
+  _spl_channel_agent_ids agents "$box" || return 1
   if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
   if (( dry )); then
     do_log "OK DRY_RUN would remove $agents on $box from #$ch in $tenant (origin=removed) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
@@ -59,8 +50,8 @@ do_spl_channel_agent_remove_op() {
 # _spl_channel_agent_remove_op_run <tenant> <channel> <box> <agents>, with
 # SPL_PROXY_DSN set (inside spl_via_proxy).
 _spl_channel_agent_remove_op_run() {
-  local out rc=0 n_removed n_absent n_want=0 a ids
-  for a in $4; do n_want=$((n_want + 1)); done
+  local out rc=0 n_removed n_absent n_want=0 ids
+  for _ in $4; do n_want=$((n_want + 1)); done
   out="$(_spl_channel_agent_remove_op_sql |
     spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
       -v tenant="$1" -v channel="$2" -v box="$3" -v agents="$4")" || rc=$?
diff --git a/csi-spl-orc/src/bash/tests/channel-agent-remove-op.tst.sh b/csi-spl-orc/src/bash/tests/channel-agent-remove-op.tst.sh
--- a/csi-spl-orc/src/bash/tests/channel-agent-remove-op.tst.sh
+++ b/csi-spl-orc/src/bash/tests/channel-agent-remove-op.tst.sh
@@ -11,6 +11,9 @@
 #   3. DRY_RUN=0: one transaction, UPDATE ... origin='removed' only (no DELETE,
 #      no INSERT), app.tenant_id set, values as -v, as the env SA
 #   4. runner: removed / absent reported; a count mismatch or psql failure is FATAL
+#   5. one copy (r13-03): _spl_channel_agent_ids in spl-channel-agent-add-op.func.sh
+#      checks AGENT_BOX and AGENTS for both operator actions; remove_op sourced
+#      alone loads it and keeps its plan, dedupe and refusals
 #------------------------------------------------------------------------------
 set -uo pipefail
 TEST_DIR=$(cd "$(dirname "$0")" && pwd)
@@ -133,5 +136,43 @@ in_orc 'do_spl_channel_agent_remove_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT=''
 in_orc 'do_spl_channel_agent_remove_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_RC=2 STUB_PSQL_OUT='boom'; rc=$?
 [[ $rc -ne 0 ]] && grep -q 'failed: boom' "$T/out" && pass "4. a psql failure is FATAL" || fail "4. psql rc: $(cat "$T/out")"
 
+# --- 5. _spl_channel_agent_ids, one copy, remove_op alone (r13-03) -------------------
+ADD="$PROJ_ROOT/src/bash/run/spl-channel-agent-add-op.func.sh"
+ids_of() {
+  env PROJ_PATH="$PROJ_ROOT" BOX_ARG="$1" IDS_ARG="$2" bash -c '
+    set -uo pipefail; do_log() { echo "$*"; }
+    source "$1"; v="$IDS_ARG"; _spl_channel_agent_ids v "$BOX_ARG" || exit $?
+    printf "IDS=[%s]\n" "$v"' _ "$ADD" 2>&1
+}
+out=$(ids_of box-desk 'c-002 c-001 c-002'); rc=$?
+[[ $rc -eq 0 && "$out" == "IDS=[c-002 c-001]" ]] && pass "5. _spl_channel_agent_ids dedupes in first-seen order" || fail "5. dedupe ($rc: $out)"
+out=$(ids_of box-wui c-001); rc=$?
+[[ $rc -eq 1 && "$out" == *"FATAL AGENT_BOX 'box-wui' is not a box id (box-wui is reserved)"* ]] && pass "5. _spl_channel_agent_ids refuses box-wui" || fail "5. box-wui ($rc: $out)"
+out=$(ids_of box-desk ''); rc=$?
+[[ $rc -eq 1 && "$out" == *"FATAL AGENTS must name at least one agent id"* ]] && pass "5. _spl_channel_agent_ids refuses an empty list" || fail "5. empty ($rc: $out)"
+out=$(ids_of box-desk 'c-001 HUM-4'); rc=$?
+[[ $rc -eq 1 && "$out" == *"FATAL AGENTS entry 'HUM-4' is not an agent id"* ]] && pass "5. _spl_channel_agent_ids refuses a non-agent id" || fail "5. human ($rc: $out)"
+alone() {
+  : >"$T/calls.log"
+  env -u DRY_RUN -u AGENT_BOX -u SPOOL_DESK_BOX HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
+    SPOOL_BOX_ENV="$T/box.env" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
+    set -uo pipefail; do_log() { echo "$*"; }
+    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
+    source "$PROJ_PATH/src/bash/run/spl-channel-agent-remove-op.func.sh"
+    do_spl_channel_agent_remove_op' >"$T/out" 2>&1 </dev/null
+}
+alone TENANT_ID=t1 CHANNEL=spool-hub-devel AGENTS='c-001 c-001'; rc=$?
+[[ $rc -eq 0 && ! -s "$T/calls.log" && $(grep -o 'c-001' "$T/out" | wc -l) -eq 1 ]] \
+  && grep -q 'DRY_RUN would remove c-001 on box-desk from #spool-hub-devel in t1 (origin=removed)' "$T/out" \
+  && pass "5. remove_op alone loads the helper: plan, deduped, no cloud" || fail "5. alone dry: rc=$rc $(cat "$T/out")"
+alone TENANT_ID=t1 CHANNEL=x AGENTS=c-001 AGENT_BOX=box-wui DRY_RUN=0; rc=$?
+[[ $rc -eq 1 && ! -s "$T/calls.log" ]] && grep -q "FATAL AGENT_BOX 'box-wui' is not a box id (box-wui is reserved)" "$T/out" \
+  && pass "5. remove_op alone refuses box-wui before any call" || fail "5. alone box-wui: rc=$rc $(cat "$T/out")"
+[[ $(grep -c '^_spl_channel_agent_ids()' "$ADD") -eq 1 ]] && grep -q '_spl_channel_agent_ids agents "$box" || return 1' "$ADD" \
+  && pass "5. one copy: spl-channel-agent-add-op.func.sh hosts and calls _spl_channel_agent_ids" || fail "5. host"
+own=$(grep -nE 'is not a box id|AGENTS entry|seen\[\$a\]|spl_is_agent_id' "$FUNC" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
+[[ -z "$own" ]] && grep -q '_spl_channel_agent_ids agents "$box" || return 1' "$FUNC" \
+  && pass "5. one copy: remove_op delegates to _spl_channel_agent_ids" || fail "5. remove_op own=[$own]"
+
 [[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
 echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
```

**Behaviour:** none changes: the same FATAL texts in the same order (tenant, channel,
default or reserved channel, box, empty list, id), the same dedupe in first-seen order,
the same dry-run plan line, the same exit codes. Both standalone remove-op checks of
section `5` (`5. remove_op alone ...`) pass on base too (1.5, red control), which shows
base and head2 behave the same.

### 1.5 Before and on the rows' heads

Base (2026-11-27T23:5xZ-00:1xZ) and final heads (2026-11-28T00:14:09Z on), n=1, as the
planner's user in the scratch clones, `SPOOL_TEST=1` with `SPOOL_BOX_TAG` and
`SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'` (a suite's own
`PASS: all ...` / `FAIL: N assertion(s)` footer counts as one line). "=" means equal to
base; "-" means that head does not touch the suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `utl:src/bash/tests/external-api-health.tst.sh` | 01 | 0 / 13 / 0 | 0 / 14 / 0 (+1, case 13) | - |
| `orc:src/bash/tests/spl-uplink-probe.tst.sh` | 01 | 0 / 22 / 0 | = | - |
| `orc:src/bash/tests/reliability-checks-cron.tst.sh` | 01 | 0 / 9 / 0 | = | - |
| `orc:src/bash/features/spawn-agents/tests/test-spawn-hub-dns.sh` | 01 | 0 / 21 / 0 | = | - |
| `orc:src/bash/tests/channel-agent-remove-op.tst.sh` | 03 | 0 / 21 / 0 | - | 0 / 29 / 0 (+8, section 5) |
| `orc:src/bash/tests/channel-agent-add-op.tst.sh` | 03 | 0 / 42 / 0 | - | = |
| `orc:src/bash/tests/dispatch-subscribe.tst.sh` | 03 | 0 / 31 / 0 | - | = |
| `orc:src/bash/tests/dispatch-tick.tst.sh` | 03 | 0 / 29 / 0 | - | = |
| `orc:src/bash/tests/tests-hermetic.tst.sh` | 03 | 0 / 9 / 0 | - | = |
| `orc:src/bash/tests/dispatch-inbound-pg.tst.sh` | 03 | 0 / 20 / 0 | - | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 03 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 03 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 03 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 03 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 03 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 03 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 03 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 03 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 03 | 0 / 48 / 0 | = | = |
| `utl:src/bash/tests/param-required.tst.sh` | 01, 03 | 0 / 17 / 0 | = | = |
| `utl:src/bash/tests/print-help.tst.sh` | 01, 03 | 0 / 4 / 0 | = | = |

Not run by the planner nor by the panel seat (panel N5): `cd csi-spl-iac && ./run -a do_check_pre_push`
on either head; each row lane runs it in its worktree before its push (section 5); `gcloud-account-pinned.tst.sh` counts are
box-dependent (48 here, equal on base and heads).

`shellcheck 0.10.0 -S warning -x` on the 5 edited files: rc 0 (base rc 0 too; head2 first
read `SC2034` at `remove-op:54`, fixed as 1.4 says). `csi-spl-iac/src/bash/scripts/sigpipe-lint.sh`
on each head's files: rc 0.

**Red controls** (each head's test file copied onto base, n=1):
- `rc1` (head1's `external-api-health.tst.sh` on base): rc 1, 13 pass, 1 fail
  (`FAIL: 13. one copy (own=[72:  ts="$(TZ=UTC printf ...`, naming base's `:72`); head1:
  rc 0, 14 pass, 0 fail.
- `rc2` (head2's `channel-agent-remove-op.tst.sh` on base): rc 1, 22 pass, 7 fail lines
  (`FAIL: 6 assertion(s)`: 4 `_spl_channel_agent_ids: command not found`, `5. host`,
  `5. remove_op own=[39: ...`); both `5. remove_op alone` checks PASS on base (behaviour
  equal). head2: rc 0, 29 pass, 0 fail.

**Mutations** (one defect planted in the final head, then restored, n=1; columns:
row 01 = `external-api-health` + `spl-uplink-probe`, row 03 = `channel-agent-remove-op`
+ `channel-agent-add-op`):
- `m1a` (drop the source of `spl-uplink-probe.func.sh`): ext-api rc 1, 10 / 4
  (cases 1, 3, 5b, 10); uplink 0 / 22 / 0.
- `m1b` (`spl_uplink_trim` returns at once): ext-api rc 1, 13 / 1 (case 10); uplink rc 1,
  21 / 1 (case 7).
- `m1c` (an own `ext_api_ms` copy is back): ext-api rc 1, 13 / 1 (case 13).
- `m1d` (`spl_uplink_iso` without `TZ=UTC`): ext-api rc 1, 13 / 1 (case 10); uplink rc 1,
  19 / 3. Box-dependent: red only where the box's local zone is not UTC (here it is not).
- `m2a` (the helper drops the dedupe): remove-op rc 1, 27 / 4 (`1. dry`, `5. dedupe`,
  `5. alone dry`); add-op rc 1, 41 / 2 (`1. dedupe`).
- `m2b` (remove-op drops the lazy source): remove-op rc 1, 26 / 3 (`5. alone dry`,
  `5. alone box-wui`); add-op 0 / 42 / 0.
- `m2c` (the helper accepts `box-wui`): remove-op rc 1, 26 / 4 (`2. box-wui`,
  `5. box-wui`, `5. alone box-wui`); add-op rc 1, 41 / 2 (`2. box-wui`).
- `m2d` (remove-op gets back its own box check): remove-op rc 1, 27 / 2
  (`5. remove_op own=[...]`); add-op 0 / 42 / 0.

The tests that name the sites (R2), `git grep -lE` over `*/tests/*` on `d03028967`:
- Row 01 (`external-api-health|do_net_external_api_check|do_external_api_health|ext_api_|spl-uplink-probe|do_spl_uplink_probe|spl_uplink_(ms|iso|trim)`)
  -> **`utl:.../external-api-health.tst.sh`** (edited), `orc:.../spl-uplink-probe.tst.sh`,
  `orc:.../reliability-checks-cron.tst.sh`, `orc:.../spawn-agents/tests/test-spawn-hub-dns.sh`
  (and `orc-shard-weights.txt`, a table).
- Row 03 (`spl-channel-agent-(add|remove)-op|do_spl_channel_agent_(add|remove)_op|_spl_channel_agent_(add|remove)_op`)
  -> **`orc:.../channel-agent-remove-op.tst.sh`** (edited), `orc:.../channel-agent-add-op.tst.sh`,
  `dispatch-inbound-pg.tst.sh`, `dispatch-subscribe.tst.sh`, `dispatch-tick.tst.sh`,
  `tests-hermetic.tst.sh`.
- No new test file, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r13-01-utl-ext-api-uplink-helpers)` | one fact, one copy (developer guide 2.2.4) | `external-api-health.func.sh` keeps byte-identical copies of the uplink probe's ms clock (`:109` = `spl-uplink-probe.func.sh:95`) and 7-day trim (`:142-152` = `:184-194`) and inlines its ISO stamp twice (`:72`, `:98` = `:89`), though it already sources that file (`:65`) for the default dir (1.3) | `utl:src/bash/run/external-api-health.func.sh:63-67,72,98-99,108-109,140-152`<br>`utl:src/bash/tests/external-api-health.tst.sh:16,204` | copies of `spl_uplink_ms` and `spl_uplink_trim` 2 -> 1 each; inline copies of the `spl_uplink_iso` body 2 -> 0 (1.3) | 1.3's shape (head1 diff in 1.3). **Red control:** head1's `external-api-health.tst.sh` on base: rc 1, 13 pass, 1 fail (`13. one copy`), then GREEN on head1 (`0/14/0`). Mutations `m1a` (drop the source: 4 fail), `m1b` (trim no-op: 1 + uplink 1), `m1c` (own `ext_api_ms` back: 1), `m1d` (no `TZ=UTC`: 1 + uplink 3, box-dependent) (1.5); outputs in the body. **Behaviour:** none changes (1.3). Tests: **`utl:.../external-api-health.tst.sh`**, `orc:.../spl-uplink-probe.tst.sh`, `orc:.../reliability-checks-cron.tst.sh`, `orc:.../spawn-agents/tests/test-spawn-hub-dns.sh`, the 11 guard suites of 1.5, `shellcheck -S warning -x` and `sigpipe-lint.sh` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 03 `refactor(r13-03-orc-channel-agent-ids)` | one fact, one copy (developer guide 2.2.4) | `spl-channel-agent-add-op.func.sh:67-76` and `spl-channel-agent-remove-op.func.sh:39-48` carry the same 10-line AGENT_BOX + AGENTS check and first-seen dedupe; remove-op is the add-op's documented mirror (1.4) | `orc:src/bash/run/spl-channel-agent-add-op.func.sh:41,44-45,67-76,86`<br>`orc:src/bash/run/spl-channel-agent-remove-op.func.sh:30-32,39-48,62-63`<br>`orc:src/bash/tests/channel-agent-remove-op.tst.sh:13,136` | copies of the box and agent id check + dedupe 2 -> 1 (hosted once as `_spl_channel_agent_ids` in the add-op file) | 1.4's shape (head2 diff in 1.4). **Red control:** head2's `channel-agent-remove-op.tst.sh` on base: rc 1, 22 pass, 7 fail lines (`FAILED: 6`; both standalone checks pass on base), then GREEN on head2 (`0/29/0`). Mutations `m2a` (no dedupe: 3 + add-op 1), `m2b` (no lazy source: 2), `m2c` (accept `box-wui`: 3 + add-op 1), `m2d` (own box check back: 1) (1.5); outputs in the body. **Behaviour:** none changes (1.4). Tests: **`orc:.../channel-agent-remove-op.tst.sh`**, `orc:.../channel-agent-add-op.tst.sh`, `orc:.../dispatch-subscribe.tst.sh`, `orc:.../dispatch-tick.tst.sh`, `orc:.../tests-hermetic.tst.sh`, `orc:.../dispatch-inbound-pg.tst.sh`, the 11 guard suites of 1.5, `shellcheck -S warning -x` and `sigpipe-lint.sh` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`orc:` = `csi-spl-orc/`, `utl:` = `csi-spl-utl/`, `iac:` = `csi-spl-iac/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `refactor(r13-NN-<slug>, SPL-<row issue>): ...`; review
branch `review/r13-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows fold internal shell helper copies with zero change to any output,
exit code, env var, path or file a caller sees ->
`Docs: none (internal helper consolidation; no behaviour changes)`. The developer guide
2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 03**, at once: disjoint file sets (row 01: the 2 `utl:` files;
  row 03: the 3 `orc:` files).
- Neither row edits `orc:src/bash/run/spl-uplink-probe.func.sh`,
  `orc:src/bash/tests/spl-uplink-probe.tst.sh`, `orc:src/bash/run/spl-channel-agent-add.func.sh`,
  `orc:src/bash/tests/channel-agent-add-op.tst.sh`, `spool-env.inc.sh`,
  `spl-rotate-lib.func.sh`, `spl-peer-restart.func.sh`, `.shellcheck-warning-baseline.txt`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/`,
  `csi-spl-iac/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths checked (5 edited + 4 read-or-run siblings = 9):
`utl:src/bash/run/external-api-health.func.sh`, `utl:src/bash/tests/external-api-health.tst.sh`,
`orc:src/bash/run/spl-uplink-probe.func.sh`, `orc:src/bash/tests/spl-uplink-probe.tst.sh`,
`orc:src/bash/run/spl-channel-agent-add-op.func.sh`,
`orc:src/bash/run/spl-channel-agent-remove-op.func.sh`,
`orc:src/bash/tests/channel-agent-remove-op.tst.sh` (edited by row 03),
`orc:src/bash/tests/channel-agent-add-op.tst.sh`, plus `spl-channel-agent-add-op`'s
callers' tests (`dispatch-subscribe`, `dispatch-tick`).

- **Lane map, every machine:** `lane-map.sh --check <6 paths: the 4 action files and the 2
  probe tests> --agent c-851`, n=1, at 2026-11-27T23:47:57Z: **exit 4**, 0 owned, "29
  live lane(s) record no files". Of the 29 `unknown:` lanes (all on the other box), 22
  are `-rotate` role or channel seats; the other 7 are `c-023` (SPL-6699 spool
  agent-models report verb), `c-050` (SPL-6675 WUI search strip), `c-107` (r12-01 N1 N3,
  landed as `545713768`), `c-982` (SPL-6692 spec 187 move rewrites scope query: its brief
  `c002-s187-fu-move-rewrites-scope-query.md` names Go and spec files only), `c-985`
  (SPL-6694 spec 184 L2 launch passes model), `c-995` (blog draft) and `c-264` (spec 158
  P2 pin sweep). None of their briefs names any of the 9 paths (grep below).
- **Live lanes on this box** (`do_spl_lane_map` at 2026-11-28T00:10:03Z, 17 lanes):
  `git diff --name-only $(merge-base) HEAD` plus `git status --porcelain` in the
  worktrees of `c-815` (SPL-6692 channel move), `c-842`, `c-804`, `c-838`, `c-651`,
  `c-738`, `c-795`, `c-846`, `c-787`, `c-746` and `m-674`, grepped for
  `channel-agent|uplink|external-api` -> **none** in each. The others are role seats
  (`c-001`, `c-002`, `c-003`), this lane, and the r12 row seats `c-806` / `c-808`
  (rows landed).
- **Spawn queue** (`./run -a do_spl_spawn_queue`, at 2026-11-27T23:44:38Z): 109 queued.
  Rows with `channel` in their placement: `03bd8d31` (s150 B18, Go files only, its
  `Files` line), `fe8cde81` (s167 B2 channel move git, `spl-channel-move.func.sh` and
  `channel-move*.inc.sh`), `7261f813` (WUI dialog), `2f880751`
  (`c002-bug-retire-drops-channel-invites`: a hub route and `agent-id-retire.sh`; its
  brief names neither op file). None touches the 9 paths.
- **Briefs** (`/var/spool-hub/dispatch/briefs`, all `*.md`, grep for
  `spl-channel-agent-(add|remove)-op|channel-agent-(add|remove)-op\.tst|_spl_channel_agent`):
  16 hits, all of them seats or lanes that **run** `do_spl_channel_agent_add_op`
  (channel seat briefs that ask c-001 to seat them with it) or
  older than 2026-11-19; none edits the files. For the last 48 h
  (`-newermt 2026-11-25T23:46:00Z`, 402 briefs): `spl-uplink-probe` and
  `external-api-health` are named by this brief only.
- **Remote branches committed in the last 48 h** (157, `git for-each-ref` at 23:48Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths>` ->
  **0 hits**.
- **Commits in the last 48 h** on the paths (`git log origin/master --since='48 hours ago'`)
  -> **0**. Last changes: add-op and remove-op `5467bfffc` (2026-11-15),
  `spl-uplink-probe.func.sh` `dfe7fd9a1` (2026-11-18), `external-api-health.func.sh`
  `b36b20577` (2026-11-18).
- A running `do_spl_channel_agent_add_op` / `_remove_op` (an orchestrator prune, a desk
  seat) is not affected: the actions behave the same (1.4).

## 3. Per row: what the lane does

- **r13-01:** applies 1.3's head1 diff on its `origin/master`:
  `utl:src/bash/run/external-api-health.func.sh` sources
  `orc:src/bash/run/spl-uplink-probe.func.sh` ahead of the dir block on every call,
  calls `spl_uplink_iso`, `spl_uplink_ms` and `spl_uplink_trim`, and deletes
  `ext_api_ms`, `ext_api_trim` and the 2 inline ISO formats;
  `utl:src/bash/tests/external-api-health.tst.sh` adds case `13` (one copy) to the
  header (`:16`) and before the footer (`:204`).
- **r13-03:** applies 1.4's head2 diff: `orc:src/bash/run/spl-channel-agent-add-op.func.sh`
  hosts `_spl_channel_agent_ids` and calls it; `orc:src/bash/run/spl-channel-agent-remove-op.func.sh`
  lazy-sources the add-op file and calls it, and counts with `for _ in $4`;
  `orc:src/bash/tests/channel-agent-remove-op.tst.sh` adds section `5` to the header
  (`:13`) and before the footer (`:136`): 4 direct helper checks, 2 standalone remove-op
  checks, 2 one-copy checks.

## 4. Reviewers (R7)

- Editor: **c-851** (claude). The panel seat signs the plan sha (rulebook 3.2,
  section 9).
- **Row reviewers (code R7), cross-vendor first (2.7.2):**
  `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix` at 2026-11-28T00:11:43Z:
  `agy paused in instance settings until 2026-11-28T05:24:23Z: usage limit` (and agy's
  weekly quota is out until about 2026-12-03T07:02Z per the brief), grok and qwen off,
  mistral sits on no review, codex not signed in -> `pick=claude`. So each claude row's
  R7 is the **claude waiver seat** (waiver `1a7c70da`), until agy can sit; the holder
  re-checks at placement and moves R7 to an agy seat once agy is back. Never mistral.
- Row vendor: `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 00:11:43Z ->
  `pick=claude` (main claude; agy skipped on its limit). Both rows: **claude** (R14).
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries its plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites of 1.3 / 1.4, its R7 seat, "re-measure first", and the plan's
`Window: W=2026-11-27T20:38:00+02:00` for its R4 slug check.

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r13-01 | `c002-r13-01-utl-ext-api-uplink-helpers` | `refactor(r13-01-utl-ext-api-uplink-helpers, SPL-<row issue>): ...` | `review/r13-01` | 1 |
| r13-03 | `c002-r13-03-orc-channel-agent-ids` | `refactor(r13-03-orc-channel-agent-ids, SPL-<row issue>): ...` | `review/r13-03` (id free: below) | 1 |

Before placing either: R4's slug check reads since W, for both rows at once (panel N2,
the form of 1.1):
`git log origin/master --since="2026-11-27T20:38:00+02:00" --oneline -E --grep='\(r13-' | wc -l`
must print 0 (it printed 0 at 2026-11-28T01:04:26Z, `origin/master` `d49322617`).

**Row ids 01 and 03 (holder ruling on the panel's W1, c-002 msg ee9cc9eb):** `review/r13-02`
exists on origin from the old cycle (`6cc7f2cbb`, 2026-10-16, 1.1) and the W-scoped prune
keeps it (`ROUND=13 PRUNE_SINCE="2026-11-27T20:38:00+02:00" DRY_RUN=1 ./run -a do_git_prune_round_branches`
at 2026-11-28T00:15:35Z: `KEEP review/r13-02 before-window ...`, `nothing deleted`), so the
id `r13-02` fails rulebook 5.3's id-free test and a row push to that name would not be a
fast-forward. The second row is therefore **r13-03**, in its slug, subject, review branch,
brief name and R4 grep; no remote branch is deleted. Id-free proof at
2026-11-28T01:04:26Z:
`git ls-remote origin 'refs/heads/review/r13-01*' 'refs/heads/review/r13-03*' 'refs/heads/*-r13-03-*' 'refs/heads/wip/*r13-03*' | wc -l`
-> 0, and `git log origin/master --since="2026-11-27T20:38:00+02:00" --oneline -E --grep='r13-03' | wc -l`
-> 0. The old-cycle brief `c002-r13-03-restart.md` (1.1) is a different file name from this
row's `c002-r13-03-orc-channel-agent-ids.md`. The `wip/c-596-c002-r13-01-...` head (1.1)
matches neither `review/r13-01*` nor this round's slugs. Rulebook 5.3's whole-id test
(`refs/heads/review/r13-*` and friends) still prints these 2 old-cycle heads; the
W-scoped prune keeps both, as 1.1 shows.

**r13-01 brief, Files: ONLY**
`csi-spl-utl/src/bash/run/external-api-health.func.sh` and
`csi-spl-utl/src/bash/tests/external-api-health.tst.sh` (1.3's head1 diff). NOT
`csi-spl-orc/src/bash/run/spl-uplink-probe.func.sh` (the host stays as it is), NOT
`spl-uplink-probe.tst.sh`, NOT any other file. Do: plan section 2 row 01 verbatim, 1.3's
shape; red control (head1's test on its parent: rc 1, 13 pass, 1 fail (`13. one copy`)) RED then GREEN in the body;
the 4 mutations `m1a`-`m1d` of 1.5 shown RED in the body. Gates: the row's tests (section
2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` and
`csi-spl-iac/src/bash/scripts/sigpipe-lint.sh` on the 2 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. Full CI gate (`parts=all`, 1.3): watch
every job of workflow 10 on the sha (R11).
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind
`simple_coding`, vendor claude; R7 the claude waiver seat under waiver `1a7c70da` while
agy cannot sit (re-checked at placement); never mistral. `m1d` is box-dependent (panel
N4, 1.5): it is RED only where the box's local zone is not UTC; on a UTC box the lane
writes `m1d: n/a (box zone UTC)` with `date +%Z` instead of a RED line. The new lazy
source line has no failure branch (panel N1), like the file's existing lazy source at
`:42`: a missing `spl-uplink-probe.func.sh` gives `command not found` and an empty stamp.
Unreachable in the mono-repo (both files ship in the one tree), so the row keeps the
file's shape; the lane may add `|| { do_log "FATAL ..."; return 1; }` and then shows
`m1a` RED again.

**r13-03 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh`,
`csi-spl-orc/src/bash/run/spl-channel-agent-remove-op.func.sh` and
`csi-spl-orc/src/bash/tests/channel-agent-remove-op.tst.sh` (1.4's head2 diff). NOT
`channel-agent-add-op.tst.sh`, NOT `spl-channel-agent-add.func.sh` (the member path),
NOT `spool-env.inc.sh`, NOT any other file. Do: plan section 2 row 03 verbatim, 1.4's
shape; red control (head2's test on its parent: rc 1, 22 pass, 7 fail lines (`FAILED: 6`; both standalone checks pass on base)) RED then GREEN in the body; the
4 mutations `m2a`-`m2d` of 1.5 shown RED in the body. Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` and `sigpipe-lint.sh` on
the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind
`simple_coding`, vendor claude; R7 the claude waiver seat under waiver `1a7c70da` while
agy cannot sit (re-checked at placement); never mistral.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 03 |
| copies of `spl_uplink_ms` / `spl_uplink_trim` (row 01) | 2 / 2 on `d03028967` -> 1 / 1 |
| inline copies of the `spl_uplink_iso` body outside its home (row 01) | 2 -> 0 |
| copies of the operator channel seat box + agent id check and dedupe (row 03) | 2 -> 1 (`_spl_channel_agent_ids`) |
| lines (`git diff --numstat` of each head) | row 01: `external-api-health.func.sh` +13 -29, `external-api-health.tst.sh` +11 -0; row 03: `spl-channel-agent-add-op.func.sh` +24 -13, `spl-channel-agent-remove-op.func.sh` +6 -15, `channel-agent-remove-op.tst.sh` +41 -0 |
| CI parts (`ci-doc-only.sh` on each head's range) | row 01 `all`; row 03 `cnf hub iac orc` |
| measured on | `d03028967`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-peer-restart.func.sh:102-120` (`spl_peer_pids`) and `orc:src/bash/run/spl-rotate-lib.func.sh:832-850` (`spl_rotate_pids`) | the same 19-line `/proc` scan (the matcher differs: `spl_peer_harness_comm "$comm"` against `spl_rotate_cli "$d" "$comm"`); still deferred (R3): queued ask `aa377e76` (held) and 8 briefs of the last 48 h name `spl-rotate-lib.func.sh`, one of them also `spl-peer-restart.func.sh` (1.2 (a)) | `git show d03028967:<both files>`; `do_spl_spawn_queue` 23:44:38Z; brief grep (n=1) |
| r12-01 R7 N1 (c-838): `check-hub-deploy.tst.sh:316` is string-coupled to the FATAL wording at `check-hub-image-regress.func.sh:46` | a test-strength row (assert no parse error, or a second describe-failure case), not a refactor; next bug or test round (candidates file, 2026-11-27 23:1xZ) | `545713768` body (c-838's M3) |
| SPL-6661 R7 N1 / N2 (agy fallback deadline and cache order) | test gaps and a code-order note in a live lane's files (`lib/agy-fallback.inc.sh`, SPL-6661 follow-up c-842 / c-738) | candidates file, 2026-11-27 23:3xZ |
| `spawn-agents/scripts/force-push-guard-hook.sh:99-110` and `owner-order-guard-hook.sh:49-60` (the same payload parser), `force-push-guard.inc.sh` / `kill-target-guard.inc.sh` (10 lines) | fail-closed command guards with a rust implementation beside them (`spl-cmd-guard`): a guard change is a gate row with its own red control, not a pure refactor | 8-line window scan (1.2 (e)) |
| `spl-reply-probe` / `spl-reply-count-probe` / `spl-topic-reply-probe`, `spl-backfill-probe` / `spl-fallback-probe`, `set-mistral-key` / `set-nano-banana-key`, `box-copy-gcp-key` / `gcp-key-copy-local-user`, `spl-wait-for-firebase-domain` / `spl-wait-for-mapping-cert` (access token), `spl-tenant-member-add` / `-remove` | secret-class (desk keys, member passwords, API keys, access tokens) | window scan (1.2 (e)) |
| `spl-db-health` / `spl-db-message-show`, `spl-msg-dedup` / `spl-msg-wipe` | PG-bound (and the wipe is destructive) | window scan |
| `iac:src/bash/run/gcp-project-apis-disable.func.sh` / `gcp-modify-project-apis-disable.func.sh` (12-line twin) and the enable / lb pairs | destructive `gcp-*` actions (repo CLAUDE.md: never run without the owner's go); a refactor would need their live proof | function-body scan |
| `spl-channel-agent-add.func.sh:32-37` (the member path) | the same box and id checks without the dedupe, and it reads a member password file; folding it changes its list (dedupe) | `git show d03028967:...` (1.4) |
| the other 12 `is not a box id (box-wui is reserved)` sites | other variables (`DESK_BOX`, `PROBE_BOX`, `$b`) in desk and probe actions, several secret-class; their next lines differ | `git grep -nF` (1.4) |
| `setup-box-stats-cron` / `check-disk-headroom-install-cron` / `setup-go-cache-prune-cron` / `spl-agent-boot-restore-install-cron` (6-7 line preambles) | already folded into `_spl_simple_cron_apply`; the rest is per-cron wording; and a brief naming `*_apply` trips `do_spl_review_go`'s owner-go keyword | window scan |
| r12 section 7's other items (`utl` sender families, the 4 `*_SEND_CMD` actions with `SC2071` / `SC2155`, the NM keyfile writers, `provision-firebase-dns`, spec 011 tasks, candidates-file items) | unchanged on `d03028967`, with r12's reasons | r12 plan section 7; `git log 3308d118f..d03028967 -- <files>` (n=1) |

## 8. Changes

- v0.1 (c-851): the rows and every read on `d03028967`; both heads built in scratch
  clones; the column of 1.5 run on base and each head; shellcheck 0.10.0 and
  `sigpipe-lint.sh` rc 0 on the 5 edited files; both red controls and the 8 mutations
  RED. Pushed to `review/c002-refactor-round-13-planner`.
- v1.0 (c-851), the panel's FAIL (c-867@sat, msg 8aeb5df2, on `2d15031a0`) and the
  holder's ruling (c-002, msg ee9cc9eb): W1 the second row is **r13-03** (slug, subject,
  review branch, brief, R4 grep, head2's two test-comment labels; head2's test sha256
  re-measured), section 5; N2 the R4 slug check reads `-E --grep='\(r13-'` for both rows;
  N1 and N4 written into the r13-01 brief; N3 the candidates file re-read (196 lines,
  no new refactor item), 1.2 (c); N5 `do_check_pre_push` on the heads stays not run by the
  planner (1.5), each lane runs it. Rows, sites, other counts unchanged (`d03028967`).
  Re-run on the v1.0 head2 (2026-11-28T01:1x-01:2xZ, n=1): the 17 row 03 and guard
  suites of 1.5 equal v0.1's counts; red control rc 1, 22 / 7; `m2a` 27 / 4 + 41 / 2,
  `m2b` 26 / 3 + 0 / 42 / 0, `m2c` 26 / 4 + 41 / 2, as 1.5.
- v1.0 signed: the claude panel seat c-867@sat PASS on `0d794aa4c` (msg 841851fc), the
  holder's line check rc 0 and GO to land (c-002, msg 5a86c835); section 9 records it. The
  plan differs from the signed `0d794aa4c` only in this entry, the status line and the
  two section 9 cells.

## 9. Consensus

Same-vendor panel, waiver 1a7c70da (c-001 ruling on 21e079a5): agy, the cross-vendor
reviewer of a claude plan, is out of quota on both boxes until about
2026-12-03T07:02Z (and paused on this box until 2026-11-28T05:24:23Z,
`do_spl_lane_mix` at 00:11:43Z), so the panel seat is claude. The r13 retro names this.

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `c-851` | claude | editor | v1.0 `0d794aa4c` | author | section 8 |
| claude panel seat (`hand-sat-c002-refactor-round-13-claude-panel-seat`, ask `bd0f6ac8`) | claude | panel | v0.1 `2d15031a0` FAIL (W1, N1-N5); v1.0 `0d794aa4c` | **PASS** (c-867@sat, msg 841851fc; W none; signed in `seat-claude.md` `f6a76bf3b`) | same-vendor panel, waiver 1a7c70da (c-001 ruling on 21e079a5); `do_spl_review_line_check` on its line rc 0 (`OK 1 of 1 named in ran: are commands`, 177 commands read), confirmed by the holder c-002 (msg 5a86c835) |

No row lane starts before the panel signs the plan sha and its review line passes
`do_spl_review_line_check` (rc 0), confirmed by the dispatch lease holder.
