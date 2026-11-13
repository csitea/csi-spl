# Perf round 7: editor seat (c-660@sat, claude)

The raw measurements behind [perf-round-7-plan.md](../perf-round-7-plan.md). All on
`origin/master` `ccef654f0` (`ccef654f0329231cce02f9ec7a8f418c03dd62f0`), the lane
worktree at that sha, satellite box, 16 vCPU, 2026-11-13. The probe scripts lived in
the seat's scratch dir and are quoted here whole; none was committed. Load is the
1-minute `/proc/loadavg` value read beside the run.

## 1. Seat

- Role: planner and editor (rulebook 1.4, 4.2), issue SPL-5424, topic
  `f6cc015c-97b8-4ada-ab61-2f8aa125e793`.
- The panel seats write their files beside this one: `perf-round-7/<seat id>.md`,
  each naming the plan sha it signs.

## 2. Measurements

### 2.1 Row 01: channel frame fan-out (Go bench, n=5 per arm)

Scratch file `internal/hub/zz_p7_scratch_bench_test.go` (removed after the run;
`git status --short` clean):

```go
func p7Frame() map[string]any {
	return map[string]any{"type": "channel", "channel": "c-0123456789", "name": "general-discussion",
		"description": "a channel description of typical length for the sidebar", "created_by": "HUM-10", "created_at": "2026-11-13T09:00:00Z"}
}
func BenchmarkP7ChannelFramePerSocket(b *testing.B) { // today's path
	s, done := fanoutRig(b, 10, nil); defer done()
	ctx, f := context.Background(), p7Frame(); b.ReportAllocs(); b.ResetTimer()
	for i := 0; i < b.N; i++ { s.fanoutChannelFrame(ctx, "t1", nil, f) }
}
func BenchmarkP7ChannelFrameEncodeOnce(b *testing.B) { // the encode-once path
	s, done := fanoutRig(b, 10, nil); defer done()
	ctx, f := context.Background(), p7Frame(); b.ReportAllocs(); b.ResetTimer()
	for i := 0; i < b.N; i++ { s.fanoutIssue(ctx, "t1", f) }
}
```

`go test ./internal/hub -bench 'BenchmarkP7' -benchmem -run '^$' -count=5` (09:31Z, load 25):

| arm | ns/op | B/op | allocs/op |
|---|---|---|---|
| per socket | 337351, 361911, 334734, 322043, 292877 | 20933, 20932, 20931, 20928, 20910 | 342, 342, 342, 342, 341 |
| encode once | 297366, 289994, 249846, 215148, 218633 | 16962, 16971, 16972, 16961, 16950 | 216, 217, 217, 216, 216 |

For reference, the existing `BenchmarkFanoutWUI` (message frames, already encoded
once) on the same tree: `200257, 191261, 194737, 195748, 192152 ns/op`, `287` allocs.

### 2.2 Row 02: lane-map local rows (n=5 per arm)

Whole call: `lane-map.sh --check csi-spl-doc/doc/md/perf-round-7-plan.md --agent c-660`,
`time` (wall, user, sys in s), 09:34Z, load 29:
`21.127 3.079 4.230`, `8.440 2.742 4.233`, `9.629 2.896 4.096`, `8.971 2.790 3.965`,
`7.008 2.570 4.297`.

The rows pass alone (`lr.sh`), and the probe (`lr2.sh`) on the same repo:

```bash
O=<lane worktree>/csi-spl-orc
source $O/src/bash/features/spawn-agents/lib/spool-env.inc.sh
source $O/src/bash/run/spl-lane-map.func.sh
LANE_BOX=sat
spl_lane_repo_tops() { echo <the box's main checkout>; }
p7_rows() {
  local top wt br line
  for top in $(spl_lane_repo_tops); do
    wt="" br=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt="${line#worktree }" br="" ;;
        "branch "*) br="${line#branch refs/heads/}" ;;
        "") if [[ -n "$wt" && "${wt%/*}" == "${top}-wt" && "${wt##*/}" =~ ^${SPOOL_PARTICIPANT_RX}$ ]]; then
              printf '%s\t%s\t%s\n' "${wt##*/}" "${top##*/}" "$br"; fi; wt="" ;;
      esac
    done < <(git -C "$top" worktree list --porcelain 2>/dev/null; echo)
  done | jq -R -s -c --arg b "$LANE_BOX" 'split("\n") | map(select(length>0) | split("\t") | {agent_id: .[0], agent_box: $b, repo: .[1], branch: .[2], scope: "", files: [], topic: "", state: "live", age_s: -1, src: "local"})'
}
a="$(spl_lane_local_rows)"
t0=$EPOCHREALTIME; b="$(p7_rows)"; t1=$EPOCHREALTIME
echo "after_ms=$(( (${t1/./}-${t0/./})/1000 )) same=$([ "$(jq -S . <<<"$a")" = "$(jq -S . <<<"$b")" ] && echo yes || echo no)"
```

| arm | ms (5 runs) | rows | load |
|---|---|---|---|
| `spl_lane_local_rows` today | 4098, 3008, 4369, 4365, 4650 | 113 | 48 |
| probe | 79, 77, 99, 101, 61; `same=yes` x5 | 113 | 43 |

A `bash -x` trace of one `do_spl_lane_map` (timing inflated by the trace, used only
to rank): `spl_lane_local_row` ran 145 times, one `jq -n` each.

### 2.3 Rows 03 and 04: `./run` startup

Startup, `./run -a do_p7_no_such_action` (loads everything, then refuses), `time`
wall / user / sys in s, n=5, 09:31Z, load 22:

| module | wall | user | sys |
|---|---|---|---|
| orc | 0.898, 0.961, 0.919, 0.989, 0.950 | 0.549..0.652 | 0.362..0.413 |
| iac | 0.231, 0.259, 0.242, 0.240, 0.247 | 0.143..0.189 | 0.073..0.116 |
| utl | 0.157, 0.117, 0.140, 0.163, 0.158 | 0.068..0.117 | 0.051..0.096 |

Phase probe (`phase.sh <module dir>`), n=5 orc, n=3 iac and utl, 09:32Z, load 19:

```bash
cd "$1"
AWK="$(sed -n "/<<'EOF_RUN_INDEX_AWK'/,/^EOF_RUN_INDEX_AWK/p" src/bash/run/run.sh | sed '1d;$d')"
t0=$EPOCHREALTIME
out="$(find lib/bash/funcs src/bash/run -type f -name '*.func.sh' -print0 2>/dev/null | sort -z | xargs -0 -r awk "$AWK")"
t1=$EPOCHREALTIME
declare -gA _func_to_file; declare -ga _rl_files=() _rl_done=(); _rl_eager=(); _rl_cand=()
eval "$out"
t2=$EPOCHREALTIME
for f in "${_rl_eager[@]}"; do source "$f" >/dev/null 2>&1; done
t3=$EPOCHREALTIME
echo "awk_ms=$(( (${t1/./}-${t0/./})/1000 )) eval_ms=$(( (${t2/./}-${t1/./})/1000 )) eager_ms=$(( (${t3/./}-${t2/./})/1000 )) eager_n=${#_rl_eager[@]}"
```

| module | awk ms | eval ms | eager ms | eager files |
|---|---|---|---|---|
| orc | 169, 160, 163, 177, 165 | 46, 43, 36, 59, 45 | 478, 494, 510, 516, 479 | 98 of 600 |
| iac | 21, 21, 23 | 5, 4, 7 | 45, 39, 40 | 36 of 148 |
| utl | 9, 9, 9 | 0, 0, 0 | 20, 15, 15 | 14 of 15 |

The cache key cost (row 03's after arm), orc, n=5:
`find lib/bash/funcs src/bash/run -type f -name '*.func.sh' -printf '%T@ %s %p\0' | sort -z | md5sum`
-> `0.012, 0.012, 0.012, 0.015, 0.011` s.

Per-file source time of the eager orc files (the same probe, one `EPOCHREALTIME`
pair per file), n=3, the five largest (ms, runs 1/2/3):
`spl-agent-restart` 140/120/121, `spl-sender-audit` 35/35/31, `gh-runner-add`
33/28/34, `spl-box-restart-after` 28/25/24, `spl-agent-login-check` 31/22/20; the
next: `spl-watchdog` 25/19/18, `spl-rotate-lib` 19/16/17.

What runs at their top level (`awk` over lines outside a function body):

- `spl-agent-restart`: `source` of `spl-wd-takeover`, `spl-agent-handoff`,
  `spl-lane-wip-push` (each guarded by `declare -F`), `ARS_CAUSES=...`
- `spl-sender-audit`: `readlink`/`dirname` for a lib dir, then `source` of
  `spool-env.inc.sh`, `spool-caller.inc.sh`, `spl-desk-box.func.sh`
- `gh-runner-add`: `source` of `apply-gh-runner-cpu-budget`, `GH_RUNNER_PKGS=...`,
  a call of `ghr_docker_flavour` (it runs `dpkg -s docker-ce`)
- `spl-box-restart-after`: `source` of `spl-box-restart-run`,
  `spl-box-restart-check`, `check-gh-runner`; `SPL_BRX_AGENT_WIN_RE=...`
- `spl-agent-login-check`: `source` of `spool-env.inc.sh`, two regex constants

### 2.4 Row 05: `spool` CLI with one P (n=20 per arm, interleaved)

`spool recv --as c-660` (read only), each arm `time`d, user+sys = CPU, 09:33Z,
load 16:

| arm | wall median ms | CPU median ms |
|---|---|---|
| default | 67.5 | 51.0 |
| `GOMAXPROCS=1` | 53.0 | 35.5 |

### 2.5 Dropped: `_spool_bin_stale` (n=5)

`git log -1 --format=%ct -- csi-spl-api/src/go/spool-hub-api/{cmd,internal,go.mod}`:
`0.016, 0.011, 0.013, 0.014, 0.016` s; sourcing `spool-env.inc.sh`: `0.012, 0.008,
0.010, 0.011, 0.012` s.

### 2.6 Not a row yet: `spl_box_ws_cnf`

`yq` v4.43.1, in `csi-spl-cnf/csi-spl`, `all.env.yaml` (102,448 B) and
`prd.env.yaml` (27,047 B):

- `yq eval-all -r '. as $i ireduce ({}; . * $i) | .env.box.workspace_base // ""' all.env.yaml prd.env.yaml`:
  first reads `4.417, 1.852, 3.445` s (09:3xZ); re-measure `0.237, 0.132, 0.257,
  0.258, 0.250` s (load 46)
- two plain reads (`yq -r '.env.box.workspace_base // ""'` on each file):
  `0.039, 0.057, 0.050, 0.054, 0.100` s

### 2.7 Measuring: test Postgres `fsync=off`

Two copies of `csi-spl-api/src/bash/tests/hub-pg.tst.sh` with `HERE` pinned to the
lane worktree; arm B adds `-c fsync=off -c synchronous_commit=off -c
full_page_writes=off` to the local `pg_ctl -o` and to the `docker run` line. Run
interleaved A, B, A, B, A, B from 09:34Z; each run's wall time and exit code go
here when it ends.

Result: not finished. The editor seat's hourly rotation (10:58Z) stopped the run
during arm A's first pass; its log ends at `store group d: 243 s` (10:01Z) and no
B run started. No pair, no number: the candidate is carried (plan section 6).

### 2.8 Row 05 on `spool send` (v1.0, the grok seat's W3)

`spool send` (binary `1.1.3`, the agent user's `~/.local/bin/spool`) from `c-998` to
`c-999` on a scratch `SPOOL_ROOT` with those two dirs, `SPOOL_NOTIFY_CMD=off`, as
`spool-send.sh:533` runs it. Bash `TIMEFORMAT='%R %U %S'`, arms A (default) and B
(`GOMAXPROCS=1`) interleaved, n=20 each, 2026-11-13T11:27:33Z, load 23.0. 40
messages landed in the scratch inbox (plus 1 from the trial send).

| arm | wall ms (median, range) | user+sys ms (median) |
|---|---|---|
| default | 69.5 (60..106) | 75.0 |
| `GOMAXPROCS=1` | 64.0 (53..88) | 59.0 (-21%) |

## 3. Readings for R3

The lane map, queue and slug readings, with their times: the plan's section 3.2.
