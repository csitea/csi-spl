package hubclient

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The htop header of a box sample (spec 071 8.3.3, SPL-6318 row T11): CPU %
// (total, per core, user / sys / iowait) from two /proc/stat reads 250 ms
// apart, the memory meter's buffers and cache plus the swap total from
// /proc/meminfo, the tasks from /proc/loadavg field 4 and the numeric
// entries of /proc, and the uptime from /proc/uptime. No subprocess and no
// per-process read. The breakdown, where 8.3.3 names no formula (recorded
// in spec 8.6.3): user = user + nice, sys = system + irq + softirq, as
// htop's non-detailed meter groups them; the guest columns are left out,
// the kernel already counts them in user and nice.

// boxSampleCPUWindow is the time between the two /proc/stat reads.
const boxSampleCPUWindow = 250 * time.Millisecond

// boxCPUTimes is one /proc/stat cpu line: user, nice, system, idle, iowait,
// irq, softirq, steal (a missing trailing column reads 0).
type boxCPUTimes [8]uint64

// boxCPUStat is one read of /proc/stat: the aggregate line and the per-core
// lines in file order.
type boxCPUStat struct {
	all   boxCPUTimes
	cores []string
	core  map[string]boxCPUTimes
}

// boxCPU is the CPU part of the header.
type boxCPU struct {
	pct, user, sys, iowait float64
	cores                  []float64
}

// header fills the htop header scalars of out.Stat and out.Snapshot. A part
// it cannot read stays nil (the hub then stores NULL, as for an older box);
// with no CPU reading there is no snapshot. Only a cancelled ctx is an
// error.
func (s BoxSampler) header(ctx context.Context, out *BoxSample, mem boxMemInfo, sched string) error {
	cpu, err := s.cpu(ctx)
	if ctx.Err() != nil {
		return fmt.Errorf("box sample: %w", ctx.Err())
	}
	st := &out.Stat
	st.SwapTotalKB = &mem.swapTotal
	st.MemBuffersKB, st.MemCachedKB = mem.buffers, mem.cached
	running, threads, schedOK := boxSched(sched)
	if schedOK {
		st.TasksRunning = &running
	}
	if n, ok := boxProcCount(orDefault(s.Proc, "/proc")); ok {
		st.TasksTotal = &n
	}
	if up, ok := boxUptime(orDefault(s.Uptime, "/proc/uptime")); ok {
		st.UptimeS = &up
	}
	if err != nil {
		return nil
	}
	st.CPUPct = &cpu.pct
	out.Snapshot = &store.BoxSnapshot{CPUCoresPct: cpu.cores, CPUUserPct: cpu.user, CPUSysPct: cpu.sys,
		CPUIOWaitPct: cpu.iowait, TasksThreads: threads}
	return nil
}

// cpu reads /proc/stat, waits the window, reads it again and turns the
// deltas into percentages: the aggregate line, and each core found in both
// reads, at most store.BoxCPUCoresMax.
func (s BoxSampler) cpu(ctx context.Context) (boxCPU, error) {
	path := orDefault(s.Stat, "/proc/stat")
	a, err := readBoxCPUStat(path)
	if err != nil {
		return boxCPU{}, err
	}
	window := s.CPUWindow
	if window <= 0 {
		window = boxSampleCPUWindow
	}
	wait := s.CPUWait
	if wait == nil {
		wait = boxSleep
	}
	if err := wait(ctx, window); err != nil {
		return boxCPU{}, err
	}
	b, err := readBoxCPUStat(path)
	if err != nil {
		return boxCPU{}, err
	}
	out := boxCPU{cores: []float64{}}
	out.pct, out.user, out.sys, out.iowait = boxCPUPct(a.all, b.all)
	for _, name := range b.cores {
		prev, ok := a.core[name]
		if !ok || len(out.cores) == store.BoxCPUCoresMax {
			continue
		}
		pct, _, _, _ := boxCPUPct(prev, b.core[name])
		out.cores = append(out.cores, pct)
	}
	return out, nil
}

// boxSleep waits d, or until ctx ends.
func boxSleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// readBoxCPUStat reads the cpu lines of a /proc/stat; it needs the
// aggregate line.
func readBoxCPUStat(path string) (boxCPUStat, error) {
	raw, err := os.ReadFile(path) // #nosec G304 -- /proc/stat or a test fixture
	if err != nil {
		return boxCPUStat{}, fmt.Errorf("box sample: %w", err)
	}
	out := boxCPUStat{core: map[string]boxCPUTimes{}}
	found := false
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) < 5 || !strings.HasPrefix(f[0], "cpu") {
			continue
		}
		var t boxCPUTimes
		for i := 0; i < len(t) && i+1 < len(f); i++ {
			if t[i], err = strconv.ParseUint(f[i+1], 10, 64); err != nil {
				return boxCPUStat{}, fmt.Errorf("box sample: /proc/stat %s: %w", f[0], err)
			}
		}
		switch name := f[0]; {
		case name == "cpu":
			out.all, found = t, true
		case boxDigitsRe.MatchString(name[3:]):
			out.cores = append(out.cores, name)
			out.core[name] = t
		}
	}
	if !found {
		return boxCPUStat{}, errors.New("box sample: /proc/stat has no cpu line")
	}
	return out, nil
}

// boxCPUPct is spec 8.3.3's arithmetic on two reads of one cpu line: the
// total delta of the eight columns, active = total - (idle + iowait); then
// user (user + nice), sys (system + irq + softirq) and iowait, each a
// percentage of the total delta, 1 decimal, 0..100. A counter that went
// back (a core that went offline and came back) counts 0.
func boxCPUPct(a, b boxCPUTimes) (pct, user, sys, iowait float64) {
	var d boxCPUTimes
	var total uint64
	for i := range d {
		if b[i] > a[i] {
			d[i] = b[i] - a[i]
		}
		total += d[i]
	}
	if total == 0 {
		return 0, 0, 0, 0
	}
	share := func(n uint64) float64 {
		return math.Min(100, math.Round(float64(n)*1000/float64(total))/10)
	}
	return share(total - d[3] - d[4]), share(d[0] + d[1]), share(d[2] + d[5] + d[6]), share(d[4])
}

// boxSched reads /proc/loadavg field 4, "<running>/<threads>".
func boxSched(field string) (running, threads int, ok bool) {
	r, t, found := strings.Cut(field, "/")
	if !found || !boxDigitsRe.MatchString(r) || !boxDigitsRe.MatchString(t) {
		return 0, 0, false
	}
	running, err1 := strconv.Atoi(r)
	threads, err2 := strconv.Atoi(t)
	return running, threads, err1 == nil && err2 == nil
}

// boxProcCount counts the numeric entries of /proc: the processes.
func boxProcCount(dir string) (int, bool) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return 0, false
	}
	n := 0
	for _, e := range ents {
		if boxDigitsRe.MatchString(e.Name()) {
			n++
		}
	}
	return n, true
}

// boxUptime reads /proc/uptime field 1 as whole seconds.
func boxUptime(path string) (int64, bool) {
	raw, err := os.ReadFile(path) // #nosec G304 -- /proc/uptime or a test fixture
	if err != nil {
		return 0, false
	}
	f := strings.Fields(string(raw))
	if len(f) == 0 {
		return 0, false
	}
	up, err := strconv.ParseFloat(f[0], 64)
	if err != nil || math.IsNaN(up) || up < 0 || up > 1e15 {
		return 0, false
	}
	return int64(up), true
}
