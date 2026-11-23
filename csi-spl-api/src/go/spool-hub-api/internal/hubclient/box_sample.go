package hubclient

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The box side of "Refresh now" (spec 071 section 7.6.3, SPL-6239 row T2):
// the same hardware sample the 5-minute box-stats cron sends
// (csi-spl-orc spl-lane-map.func.sh, spl_lane_box_sample and
// spl_lane_box_disks), collected in Go by `spool hub-run`, so a box_sample
// frame can be answered on the open socket with no new dial. The same
// sources and the same arithmetic: /proc/loadavg, the process's CPU count
// (nproc counts the CPU affinity, as runtime.NumCPU does), /proc/meminfo, and
// POSIX df minus the memory, image and EFI-variable mounts, at most 16.
//
// Two differences from the tick, both named in the spec:
//   - df runs under a 3 s timeout (the tick allows 10 s); a timeout gives
//     disks [], as the tick does on an unreadable df;
//   - agents_live counts the roster agents the AgentRunReport says run, not
//     the live tmux panes (which the desk sidecar's user may not read). With
//     no fresh report the sample says so (AgentsReported false) and the hub
//     copies agents_live from the box's newest tick sample.
//
// The frame handler in readLoop, the 60 s box-side guard (spec 8.7.1) and
// the hello feature are row T3: box_sample_frame.go.
//
// Row T11 (spec 071 8.3.1, 8.3.3, SPL-6318) adds the htop header
// (box_header.go) and replaces the tick's df argv with `df -kPT` and the
// mount rule of 8.3.1 (box_df.go): an agent-root tmpfs or overlay is kept,
// every other one is dropped.

// boxSampleDFTimeout bounds the df run: a hung network mount must not hold
// the answer past the hub's wait (spec 7.3, step 5).
const boxSampleDFTimeout = 3 * time.Second

// boxSampleDFArgv is spec 8.3.1's df: POSIX, KiB, with the type column, so
// the mount rule (box_df.go) can keep an agent-root tmpfs.
var boxSampleDFArgv = []string{"df", "-kPT"}

// boxDigitsRe is a whole number as the tick's awk and bash checks read one.
var boxDigitsRe = regexp.MustCompile(`^[0-9]+$`)

// boxLoadRe is one load average as spl_lane_box_sample accepts it.
var boxLoadRe = regexp.MustCompile(`^[0-9.]+$`)

// BoxSampler collects one box sample. The zero value reads the live box;
// the tests point the paths and the df run at fixtures.
type BoxSampler struct {
	Box       string                                    // the sample's box (the hub rewrites it from the session)
	Loadavg   string                                    // default /proc/loadavg
	Meminfo   string                                    // default /proc/meminfo
	CPUs      func() int                                // default runtime.NumCPU
	DF        func(ctx context.Context) ([]byte, error) // default: boxSampleDFArgv
	DFTimeout time.Duration                             // default boxSampleDFTimeout
	AgentRun  func() map[string]bool                    // the roster's run report; nil, or a nil map = no fresh report

	// The htop header (row T11, box_header.go).
	Stat      string                                           // default /proc/stat
	Uptime    string                                           // default /proc/uptime
	Proc      string                                           // default /proc (its numeric entries are the tasks)
	CPUWindow time.Duration                                    // default boxSampleCPUWindow
	CPUWait   func(ctx context.Context, d time.Duration) error // default: a timer; tests rewrite Stat here

	// The df mount rule (row T11, box_df.go).
	AgentRoots []string                         // default $SPOOL_ROOT, $SPL_WT_ROOT, $SPL_VAR_APP_DIR
	TmpDir     string                           // default /tmp
	Dev        func(path string) (uint64, bool) // default: stat(path).st_dev
}

// BoxSample is one collected sample and whether its agents_live is measured.
// Snapshot is the htop detail of spec 8.4.2 (per-core CPU, user / sys /
// iowait, threads); nil when /proc/stat could not be read twice. Row T14
// sends it; the row T3 handler sends Stat only.
type BoxSample struct {
	Stat           store.BoxStat
	Snapshot       *store.BoxSnapshot
	AgentsReported bool // false: no fresh AgentRunReport, the hub fills agents_live
}

// Collect reads the sample: the htop header first (its 250 ms window),
// then df. It fails when load, cpus or memory cannot be read, so nothing
// half-read is sent; an unreadable header part stays nil, unreadable disks
// are [].
func (s BoxSampler) Collect(ctx context.Context) (BoxSample, error) {
	load, err := boxLoad(orDefault(s.Loadavg, "/proc/loadavg"))
	if err != nil {
		return BoxSample{}, err
	}
	cpus := runtime.NumCPU()
	if s.CPUs != nil {
		cpus = s.CPUs()
	}
	if cpus < 1 {
		return BoxSample{}, fmt.Errorf("box sample: cpus %d", cpus)
	}
	mem, err := boxMem(orDefault(s.Meminfo, "/proc/meminfo"))
	if err != nil {
		return BoxSample{}, err
	}
	out := BoxSample{Stat: store.BoxStat{Box: s.Box, Load1: load.l1, Load5: load.l5, Load15: load.l15, CPUs: cpus,
		MemTotalKB: mem.total, MemAvailKB: mem.avail, SwapUsedKB: mem.swapUsed}}
	if err := s.header(ctx, &out, mem, load.sched); err != nil {
		return BoxSample{}, err
	}
	out.Stat.Disks = s.disks(ctx)
	out.Stat.AgentsLive, out.AgentsReported = s.agentsLive()
	return out, nil
}

// agentsLive counts the agents the run report says run; false = no report.
func (s BoxSampler) agentsLive() (int, bool) {
	if s.AgentRun == nil {
		return 0, false
	}
	run := s.AgentRun()
	if run == nil {
		return 0, false
	}
	n := 0
	for _, up := range run {
		if up {
			n++
		}
	}
	return n, true
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// boxLoadInfo is one read of /proc/loadavg: the three load averages and
// field 4, "<running>/<threads>" ("" when absent).
type boxLoadInfo struct {
	l1, l5, l15 float64
	sched       string
}

// boxLoad reads the three load averages, as `read -r l1 l5 l15 _` does,
// and keeps field 4 for the htop header.
func boxLoad(path string) (boxLoadInfo, error) {
	raw, err := os.ReadFile(path) // #nosec G304 -- /proc/loadavg or a test fixture
	if err != nil {
		return boxLoadInfo{}, fmt.Errorf("box sample: %w", err)
	}
	f := strings.Fields(strings.SplitN(string(raw), "\n", 2)[0])
	if len(f) < 3 {
		return boxLoadInfo{}, errors.New("box sample: loadavg has no three load averages")
	}
	var v [3]float64
	for i := range v {
		if !boxLoadRe.MatchString(f[i]) {
			return boxLoadInfo{}, fmt.Errorf("box sample: load %q is not a number", f[i])
		}
		if v[i], err = strconv.ParseFloat(f[i], 64); err != nil {
			return boxLoadInfo{}, fmt.Errorf("box sample: load %q: %w", f[i], err)
		}
	}
	out := boxLoadInfo{l1: v[0], l5: v[1], l15: v[2]}
	if len(f) > 3 {
		out.sched = f[3]
	}
	return out, nil
}

// boxMemInfo is one read of /proc/meminfo (kB). buffers and cached are
// nil when the file lacks Buffers or Cached.
type boxMemInfo struct {
	total, avail, swapUsed, swapTotal int64
	buffers, cached                   *int64
}

// boxMem reads MemTotal, MemAvailable and SwapTotal - SwapFree (kB) as the
// tick's awk does: the last line of a key wins, a missing swap key counts 0,
// a negative swap reads 0, and both memory keys must be whole numbers. For
// the htop header (spec 8.3.3) it also reads SwapTotal, Buffers and the
// cache, max(0, Cached + SReclaimable - Shmem), htop 3.x's meter.
func boxMem(path string) (boxMemInfo, error) {
	raw, err := os.ReadFile(path) // #nosec G304 -- /proc/meminfo or a test fixture
	if err != nil {
		return boxMemInfo{}, fmt.Errorf("box sample: %w", err)
	}
	v := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "MemTotal:", "MemAvailable:", "SwapTotal:", "SwapFree:", "Buffers:", "Cached:", "SReclaimable:", "Shmem:":
			v[f[0]] = f[1]
		}
	}
	t, a := v["MemTotal:"], v["MemAvailable:"]
	if !boxDigitsRe.MatchString(t) || !boxDigitsRe.MatchString(a) {
		return boxMemInfo{}, errors.New("box sample: meminfo lacks a MemTotal or MemAvailable number")
	}
	num := func(k string) int64 { n, _ := strconv.ParseInt(v[k], 10, 64); return max(n, 0) }
	m := boxMemInfo{total: num("MemTotal:"), avail: num("MemAvailable:"), swapTotal: num("SwapTotal:")}
	m.swapUsed = max(m.swapTotal-num("SwapFree:"), 0)
	if boxDigitsRe.MatchString(v["Buffers:"]) {
		b := num("Buffers:")
		m.buffers = &b
	}
	if boxDigitsRe.MatchString(v["Cached:"]) {
		c := max(num("Cached:")+num("SReclaimable:")-num("Shmem:"), 0)
		m.cached = &c
	}
	return m, nil
}

// disks runs df under the timeout and parses what it printed; a timeout
// gives [] (never nil: the JSON says "disks": []). The run and the mount
// rule's stat calls are waited on in their own goroutine, so a df or a stat
// stuck in the kernel on a hung mount, which even a kill does not end at
// once, cannot hold Collect past the timeout.
func (s BoxSampler) disks(ctx context.Context) []store.BoxDisk {
	limit := s.DFTimeout
	if limit <= 0 {
		limit = boxSampleDFTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	run := s.DF
	if run == nil {
		run = func(ctx context.Context) ([]byte, error) { return runBoxDF(ctx, boxSampleDFArgv) }
	}
	got := make(chan []store.BoxDisk, 1)
	go func() {
		out, _ := run(ctx)    // a non-zero df (one unreadable mount) still prints the others
		got <- s.parseDF(out) // its stat calls run under the same cap
	}()
	select {
	case disks := <-got:
		if ctx.Err() != nil {
			return []store.BoxDisk{}
		}
		return disks
	case <-ctx.Done():
		return []store.BoxDisk{}
	}
}

// runBoxDF runs argv, killed at ctx's end, its stderr dropped (`2>/dev/null`).
func runBoxDF(ctx context.Context, argv []string) ([]byte, error) {
	return exec.CommandContext(ctx, argv[0], argv[1:]...).Output() // #nosec G204 -- boxSampleDFArgv, or a test's stub
}

// parseBoxDF parses the tick's own `df -kP` (no type column), as
// spl_lane_box_disks' awk does: after the header, a row whose
// 1024-blocks and Available are whole numbers; the mount is field 6 to the
// end, joined by one space; only an absolute mount, each once; used_kb only
// when Used is a number; at most store.BoxDisksMax rows.
func parseBoxDF(out []byte) []store.BoxDisk {
	disks := []store.BoxDisk{}
	seen := map[string]bool{}
	lines := strings.Split(string(out), "\n")
	for i := 1; i < len(lines) && len(disks) < store.BoxDisksMax; i++ {
		f := strings.Fields(lines[i])
		if len(f) < 6 || !boxDigitsRe.MatchString(f[1]) || !boxDigitsRe.MatchString(f[3]) {
			continue
		}
		mount := strings.Join(f[5:], " ")
		if !strings.HasPrefix(mount, "/") || seen[mount] {
			continue
		}
		seen[mount] = true
		d := store.BoxDisk{Mount: mount}
		d.TotalKB, _ = strconv.ParseInt(f[1], 10, 64)
		d.AvailKB, _ = strconv.ParseInt(f[3], 10, 64)
		if boxDigitsRe.MatchString(f[2]) {
			d.UsedKB, _ = strconv.ParseInt(f[2], 10, 64)
		}
		disks = append(disks, d)
	}
	return disks
}
