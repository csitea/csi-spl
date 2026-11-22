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
// The frame handler in readLoop, the 30 s box-side guard and the hello
// feature are row T3, not this file.

// boxSampleDFTimeout bounds the df run: a hung network mount must not hold
// the answer past the hub's wait (spec 7.3, step 5).
const boxSampleDFTimeout = 3 * time.Second

// boxSampleDFArgv is the tick's df command (spl_lane_box_disks), word for word.
var boxSampleDFArgv = []string{"df", "-kP", "-x", "tmpfs", "-x", "devtmpfs", "-x", "overlay", "-x", "squashfs", "-x", "efivarfs"}

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
}

// BoxSample is one collected sample and whether its agents_live is measured.
type BoxSample struct {
	Stat           store.BoxStat
	AgentsReported bool // false: no fresh AgentRunReport, the hub fills agents_live
}

// Collect reads the sample. It fails when load, cpus or memory cannot be
// read, so nothing half-read is sent; unreadable disks are [].
func (s BoxSampler) Collect(ctx context.Context) (BoxSample, error) {
	l1, l5, l15, err := boxLoad(orDefault(s.Loadavg, "/proc/loadavg"))
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
	total, avail, swap, err := boxMem(orDefault(s.Meminfo, "/proc/meminfo"))
	if err != nil {
		return BoxSample{}, err
	}
	out := BoxSample{Stat: store.BoxStat{Box: s.Box, Load1: l1, Load5: l5, Load15: l15, CPUs: cpus,
		MemTotalKB: total, MemAvailKB: avail, SwapUsedKB: swap, Disks: s.disks(ctx)}}
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

// boxLoad reads the three load averages, as `read -r l1 l5 l15 _` does.
func boxLoad(path string) (l1, l5, l15 float64, err error) {
	raw, err := os.ReadFile(path) // #nosec G304 -- /proc/loadavg or a test fixture
	if err != nil {
		return 0, 0, 0, fmt.Errorf("box sample: %w", err)
	}
	f := strings.Fields(strings.SplitN(string(raw), "\n", 2)[0])
	if len(f) < 3 {
		return 0, 0, 0, errors.New("box sample: loadavg has no three load averages")
	}
	var v [3]float64
	for i := range v {
		if !boxLoadRe.MatchString(f[i]) {
			return 0, 0, 0, fmt.Errorf("box sample: load %q is not a number", f[i])
		}
		if v[i], err = strconv.ParseFloat(f[i], 64); err != nil {
			return 0, 0, 0, fmt.Errorf("box sample: load %q: %w", f[i], err)
		}
	}
	return v[0], v[1], v[2], nil
}

// boxMem reads MemTotal, MemAvailable and SwapTotal - SwapFree (kB) as the
// tick's awk does: the last line of a key wins, a missing swap key counts 0,
// a negative swap reads 0, and both memory keys must be whole numbers.
func boxMem(path string) (total, avail, swap int64, err error) {
	raw, err := os.ReadFile(path) // #nosec G304 -- /proc/meminfo or a test fixture
	if err != nil {
		return 0, 0, 0, fmt.Errorf("box sample: %w", err)
	}
	v := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "MemTotal:", "MemAvailable:", "SwapTotal:", "SwapFree:":
			v[f[0]] = f[1]
		}
	}
	t, a := v["MemTotal:"], v["MemAvailable:"]
	if !boxDigitsRe.MatchString(t) || !boxDigitsRe.MatchString(a) {
		return 0, 0, 0, errors.New("box sample: meminfo lacks a MemTotal or MemAvailable number")
	}
	total, _ = strconv.ParseInt(t, 10, 64)
	avail, _ = strconv.ParseInt(a, 10, 64)
	swapTotal, _ := strconv.ParseInt(v["SwapTotal:"], 10, 64)
	swapFree, _ := strconv.ParseInt(v["SwapFree:"], 10, 64)
	if swap = swapTotal - swapFree; swap < 0 {
		swap = 0
	}
	return total, avail, swap, nil
}

// disks runs df under the timeout and parses what it printed; a timeout
// gives [] (never nil: the JSON says "disks": []). The run is waited on in
// its own goroutine, so a df stuck in the kernel on a hung mount, which even
// a kill does not end at once, cannot hold Collect past the timeout.
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
	got := make(chan []byte, 1)
	go func() {
		out, _ := run(ctx) // a non-zero df (one unreadable mount) still prints the others
		got <- out
	}()
	select {
	case out := <-got:
		if ctx.Err() != nil {
			return []store.BoxDisk{}
		}
		return parseBoxDF(out)
	case <-ctx.Done():
		return []store.BoxDisk{}
	}
}

// runBoxDF runs argv, killed at ctx's end, its stderr dropped (`2>/dev/null`).
func runBoxDF(ctx context.Context, argv []string) ([]byte, error) {
	return exec.CommandContext(ctx, argv[0], argv[1:]...).Output() // #nosec G204 -- boxSampleDFArgv, or a test's stub
}

// parseBoxDF is spl_lane_box_disks' awk: after the header, a row whose
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
