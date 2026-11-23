package store

import (
	"context"
	"encoding/json"
	"math"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// The hardware history of the fleet's boxes (rdb 0117, owner t1 8c4fcc46):
// the lane map's BOX-0@<box> row is overwritten every 300 s, so the same tick
// also appends one sample here, and the hub answers a window of them with a
// per-hour avg / peak. Append-only; the hub's retention sweep prunes rows
// older than BoxStatsRetention.

// Box stat limits.
const (
	// BoxStatsRetention is how long a sample lives. The ONE place the
	// number lives (the brief: 30 days, ~8.6k rows per box).
	BoxStatsRetention = 30 * 24 * time.Hour
	// BoxStatsMax is the most rows one list returns: 30 days of one box at
	// one row per 5 min is 8640, so two boxes fit a full window.
	BoxStatsMax    = 20000
	boxStatLoadMax = 100000 // rdb 0117 CHECKs
	// BoxDisksMax is the most mounts one sample carries (rdb 0121 CHECK).
	BoxDisksMax     = 16
	boxStatCountMax = 100000
	boxStatPIDMax   = 4194304 // Linux PID_MAX_LIMIT; rdb 0317 tasks CHECKs
)

// BoxStat is one row of box_stats.
type BoxStat struct {
	Box        string    `json:"box"`
	WriterBox  string    `json:"writer_box,omitempty"`
	At         time.Time `json:"at"`
	Load1      float64   `json:"load1"`
	Load5      float64   `json:"load5"`
	Load15     float64   `json:"load15"`
	CPUs       int       `json:"cpus"`
	MemTotalKB int64     `json:"mem_total_kb"`
	MemAvailKB int64     `json:"mem_avail_kb"`
	SwapUsedKB int64     `json:"swap_used_kb"`
	AgentsLive int       `json:"agents_live"`
	Disks      []BoxDisk `json:"disks"` // rdb 0121; [] before it
	// The htop header scalars (rdb 0317, spec 071 8.3.3); nil = an older
	// box that does not send them, NULL in the row.
	CPUPct       *float64 `json:"cpu_pct,omitempty"`
	SwapTotalKB  *int64   `json:"swap_total_kb,omitempty"`
	MemBuffersKB *int64   `json:"mem_buffers_kb,omitempty"`
	MemCachedKB  *int64   `json:"mem_cached_kb,omitempty"`
	TasksTotal   *int     `json:"tasks_total,omitempty"`
	TasksRunning *int     `json:"tasks_running,omitempty"`
	UptimeS      *int64   `json:"uptime_s,omitempty"`
}

// BoxDisk is one mounted filesystem of a sample: its size, free space and,
// from the boxes that send it, df's used (c-542: total - avail also counts
// the root-reserved blocks, so only used / (used + avail) is df's Use%).
// 0 = not sent (older boxes); the readers then fall back to total - avail.
//
// FSType is df's Type column (spec 071 8.3.1, row T11); "" = not sent.
type BoxDisk struct {
	Mount   string `json:"mount"`
	TotalKB int64  `json:"total_kb"`
	AvailKB int64  `json:"avail_kb"`
	UsedKB  int64  `json:"used_kb,omitempty"`
	FSType  string `json:"fstype,omitempty"`
}

// BoxFSTypeRe is a filesystem type (spec 071 8.3.1): [a-z0-9._-], 1..24.
var BoxFSTypeRe = regexp.MustCompile(`^[a-z0-9._-]{1,24}$`)

// boxMountRe is a mount point: an absolute path, printable, up to 256 bytes.
var boxMountRe = regexp.MustCompile(`^/[^\x00-\x1f\x7f]{0,255}$`)

// CheckBoxStat names the first field a sample may not carry ("" = fine): the
// Go side of rdb 0117's CHECKs, so a refusal is a 400, not a 500.
func CheckBoxStat(b BoxStat) string {
	bad := func(f float64) bool { return math.IsNaN(f) || f < 0 || f > boxStatLoadMax }
	switch {
	case !FleetNameRe.MatchString(b.Box):
		return "box must be the box's desk id ([a-z0-9-], up to 32)"
	case bad(b.Load1) || bad(b.Load5) || bad(b.Load15):
		return "load1 / load5 / load15 must be 0..100000"
	case b.CPUs < 1 || b.CPUs > boxStatCountMax:
		return "cpus must be 1..100000"
	case b.MemTotalKB < 0 || b.MemAvailKB < 0 || b.SwapUsedKB < 0:
		return "mem_total_kb / mem_avail_kb / swap_used_kb must be >= 0"
	case b.AgentsLive < 0 || b.AgentsLive > boxStatCountMax:
		return "agents_live must be 0..100000"
	case len(b.Disks) > BoxDisksMax:
		return "disks lists at most 16 mounts"
	}
	if why := checkBoxStatHeader(b); why != "" {
		return why
	}
	seen := map[string]bool{}
	for _, d := range b.Disks {
		if !boxMountRe.MatchString(d.Mount) || seen[d.Mount] {
			return "each disk needs a distinct mount, an absolute path of up to 256 bytes"
		}
		if d.TotalKB < 0 || d.AvailKB < 0 || d.UsedKB < 0 {
			return "disk total_kb / avail_kb / used_kb must be >= 0"
		}
		if d.FSType != "" && !BoxFSTypeRe.MatchString(d.FSType) {
			return "disk fstype must be [a-z0-9._-], up to 24 bytes"
		}
		seen[d.Mount] = true
	}
	return ""
}

// checkBoxStatHeader is CheckBoxStat for the htop header scalars (rdb 0317).
func checkBoxStatHeader(b BoxStat) string {
	neg := func(p *int64) bool { return p != nil && *p < 0 }
	tasks := func(p *int) bool { return p != nil && (*p < 0 || *p > boxStatPIDMax) }
	switch {
	case b.CPUPct != nil && !isPct(*b.CPUPct):
		return "cpu_pct must be 0..100"
	case neg(b.SwapTotalKB) || neg(b.MemBuffersKB) || neg(b.MemCachedKB) || neg(b.UptimeS):
		return "swap_total_kb / mem_buffers_kb / mem_cached_kb / uptime_s must be >= 0"
	case tasks(b.TasksTotal) || tasks(b.TasksRunning):
		return "tasks_total / tasks_running must be 0..4194304"
	}
	return ""
}

// isPct is a percentage: 0..100, not NaN.
func isPct(f float64) bool { return !math.IsNaN(f) && f >= 0 && f <= 100 }

// BoxStatHour is one box's hour of samples: n, the load1 and the used memory
// (mem_total - mem_avail) as avg and peak, the live agents, and per mount
// the size and the least free space of the hour.
type BoxStatHour struct {
	Box           string        `json:"box"`
	Hour          time.Time     `json:"hour"`
	N             int           `json:"n"`
	CPUs          int           `json:"cpus"`
	Load1Avg      float64       `json:"load1_avg"`
	Load1Peak     float64       `json:"load1_peak"`
	MemUsedAvgKB  int64         `json:"mem_used_avg_kb"`
	MemUsedPeakKB int64         `json:"mem_used_peak_kb"`
	MemAvailMinKB int64         `json:"mem_avail_min_kb"`
	AgentsAvg     float64       `json:"agents_avg"`
	AgentsPeak    int           `json:"agents_peak"`
	Disks         []BoxDiskHour `json:"disks"`
}

// BoxDiskHour is one mount over an hour: its largest size, least free and
// most used (0 = no sample of the hour sent used_kb).
type BoxDiskHour struct {
	Mount      string `json:"mount"`
	TotalKB    int64  `json:"total_kb"`
	AvailMinKB int64  `json:"avail_min_kb"`
	UsedMaxKB  int64  `json:"used_max_kb,omitempty"`
}

// BoxStatHours folds samples into one row per (box, UTC hour), ordered by
// box, then hour. Both drivers and every reader share it.
func BoxStatHours(rows []BoxStat) []BoxStatHour {
	type key struct {
		box  string
		hour int64
	}
	type acc struct {
		h                 BoxStatHour
		load, used, agent float64
		disks             map[string]*BoxDiskHour
	}
	m := map[key]*acc{}
	for _, r := range rows {
		hr := r.At.UTC().Truncate(time.Hour)
		k := key{r.Box, hr.Unix()}
		a := m[k]
		if a == nil {
			a = &acc{h: BoxStatHour{Box: r.Box, Hour: hr, MemAvailMinKB: r.MemAvailKB}, disks: map[string]*BoxDiskHour{}}
			m[k] = a
		}
		used := r.MemTotalKB - r.MemAvailKB
		if used < 0 {
			used = 0
		}
		a.h.N++
		a.load += r.Load1
		a.used += float64(used)
		a.agent += float64(r.AgentsLive)
		a.h.CPUs = max(a.h.CPUs, r.CPUs)
		a.h.Load1Peak = max(a.h.Load1Peak, r.Load1)
		a.h.MemUsedPeakKB = max(a.h.MemUsedPeakKB, used)
		a.h.MemAvailMinKB = min(a.h.MemAvailMinKB, r.MemAvailKB)
		a.h.AgentsPeak = max(a.h.AgentsPeak, r.AgentsLive)
		for _, d := range r.Disks {
			if dh := a.disks[d.Mount]; dh == nil {
				a.disks[d.Mount] = &BoxDiskHour{Mount: d.Mount, TotalKB: d.TotalKB, AvailMinKB: d.AvailKB, UsedMaxKB: d.UsedKB}
			} else {
				dh.TotalKB = max(dh.TotalKB, d.TotalKB)
				dh.AvailMinKB = min(dh.AvailMinKB, d.AvailKB)
				dh.UsedMaxKB = max(dh.UsedMaxKB, d.UsedKB)
			}
		}
	}
	out := make([]BoxStatHour, 0, len(m))
	for _, a := range m {
		n := float64(a.h.N)
		a.h.Load1Avg = math.Round(a.load/n*100) / 100
		a.h.MemUsedAvgKB = int64(math.Round(a.used / n))
		a.h.AgentsAvg = math.Round(a.agent/n*10) / 10
		a.h.Disks = make([]BoxDiskHour, 0, len(a.disks))
		for _, d := range a.disks {
			a.h.Disks = append(a.h.Disks, *d)
		}
		sort.Slice(a.h.Disks, func(i, j int) bool { return a.h.Disks[i].Mount < a.h.Disks[j].Mount })
		out = append(out, a.h)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Box != out[j].Box {
			return out[i].Box < out[j].Box
		}
		return out[i].Hour.Before(out[j].Hour)
	})
	return out
}

// BoxStats is the store half of rdb 0117. Optional: the hub skips the sweep,
// and its routes answer unsupported, on a store without it.
type BoxStats interface {
	// AppendBoxStat appends one sample (the caller has checked it).
	AppendBoxStat(ctx context.Context, tenantID string, b BoxStat) error
	// ListBoxStats is the tenant's samples of box ("" = every box) at or
	// after since, oldest first, at most BoxStatsMax (the newest of them).
	ListBoxStats(ctx context.Context, tenantID, box string, since time.Time) ([]BoxStat, error)
	// PruneBoxStats deletes every tenant's samples older than before and
	// returns how many (the retention sweep).
	PruneBoxStats(ctx context.Context, before time.Time) (int, error)
}

// The Memory driver keeps its samples beside the store rather than in it
// (memory.go is shared by every lane), like memLifecycle.
var (
	memBoxStatsMu sync.Mutex
	memBoxStats   = map[*Memory]map[string][]BoxStat{} // per tenant, in append order
)

func (s *Memory) AppendBoxStat(_ context.Context, tenant string, b BoxStat) error {
	memBoxStatsMu.Lock()
	defer memBoxStatsMu.Unlock()
	if memBoxStats[s] == nil {
		memBoxStats[s] = map[string][]BoxStat{}
	}
	b.At = b.At.UTC()
	b.Disks = append([]BoxDisk{}, b.Disks...)
	memBoxStats[s][tenant] = append(memBoxStats[s][tenant], b)
	return nil
}

func (s *Memory) ListBoxStats(_ context.Context, tenant, box string, since time.Time) ([]BoxStat, error) {
	memBoxStatsMu.Lock()
	defer memBoxStatsMu.Unlock()
	out := []BoxStat{}
	for _, b := range memBoxStats[s][tenant] {
		if (box == "" || b.Box == box) && !b.At.Before(since) {
			b.Disks = append([]BoxDisk{}, b.Disks...)
			out = append(out, b)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	if len(out) > BoxStatsMax {
		out = out[len(out)-BoxStatsMax:]
	}
	return out, nil
}

func (s *Memory) PruneBoxStats(_ context.Context, before time.Time) (int, error) {
	memBoxStatsMu.Lock()
	defer memBoxStatsMu.Unlock()
	n := 0
	for tenant, rows := range memBoxStats[s] {
		keep := rows[:0]
		for _, b := range rows {
			if b.At.Before(before) {
				n++
				continue
			}
			keep = append(keep, b)
		}
		memBoxStats[s][tenant] = keep
	}
	return n + s.pruneMemBoxSnaps(before), nil
}

// The newest snapshot of a box (rdb 0317, spec 071 8.4.2 / 8.6): the detail
// of one htop / df / du reading that is too big for the 30-day history, one
// row per (tenant, box), upserted with its box_stats row under the same at.

// Box snapshot limits (spec 071 8.7.1).
const (
	// BoxTopDirsMax is the most directories one snapshot lists (du top 10).
	BoxTopDirsMax = 10
	// BoxCPUCoresMax is the most per-core CPU values one snapshot carries.
	BoxCPUCoresMax = 256
	// BoxSnapshotMaxBytes caps a snapshot's JSON (rdb 0317 CHECK).
	BoxSnapshotMaxBytes = 16384
)

// BoxSnapshot is one box's newest snapshot detail. At is the hub's clock,
// the same as its box_stats row's.
type BoxSnapshot struct {
	At                time.Time  `json:"at"`
	CPUCoresPct       []float64  `json:"cpu_cores_pct,omitempty"`
	CPUUserPct        float64    `json:"cpu_user_pct"`
	CPUSysPct         float64    `json:"cpu_sys_pct"`
	CPUIOWaitPct      float64    `json:"cpu_iowait_pct"`
	TasksThreads      int        `json:"tasks_threads"`
	TopDirs           []BoxDir   `json:"top_dirs,omitempty"`
	TopDirsAt         *time.Time `json:"top_dirs_at,omitempty"`
	TopDirsPartial    bool       `json:"top_dirs_partial,omitempty"`
	TopDirsUnvisited  int        `json:"top_dirs_unvisited,omitempty"`
	TopDirsUnreadable int        `json:"top_dirs_unreadable,omitempty"`
	DetailsRedacted   bool       `json:"details_redacted,omitempty"`
}

// BoxDir is one of a snapshot's biggest directories (du): its path, the
// mount it lies on, its allocated KiB and whether its scan hit the time cap
// (the size is then a lower bound).
type BoxDir struct {
	Path    string `json:"path"`
	Mount   string `json:"mount"`
	SizeKB  int64  `json:"size_kb"`
	Partial bool   `json:"partial,omitempty"`
}

// boxDirRe is a du path: absolute, printable ASCII, up to 256 bytes.
var boxDirRe = regexp.MustCompile(`^/[\x20-\x7e]{0,255}$`)

// CheckBoxSnapshot names the first field a snapshot may not carry ("" =
// fine), like CheckBoxStat: at most 10 directories, each an absolute path
// with no ".." segment, at most 256 cores, percentages 0..100, and at most
// BoxSnapshotMaxBytes of JSON.
func CheckBoxSnapshot(s BoxSnapshot) string {
	switch {
	case len(s.CPUCoresPct) > BoxCPUCoresMax:
		return "cpu_cores_pct lists at most 256 cores"
	case !isPct(s.CPUUserPct) || !isPct(s.CPUSysPct) || !isPct(s.CPUIOWaitPct):
		return "cpu_user_pct / cpu_sys_pct / cpu_iowait_pct must be 0..100"
	case s.TasksThreads < 0 || s.TasksThreads > boxStatPIDMax:
		return "tasks_threads must be 0..4194304"
	case s.TopDirsUnvisited < 0 || s.TopDirsUnreadable < 0:
		return "top_dirs_unvisited / top_dirs_unreadable must be >= 0"
	case len(s.TopDirs) > BoxTopDirsMax:
		return "top_dirs lists at most 10 directories"
	}
	for _, c := range s.CPUCoresPct {
		if !isPct(c) {
			return "each cpu_cores_pct value must be 0..100"
		}
	}
	for _, d := range s.TopDirs {
		if !boxDirRe.MatchString(d.Path) || dotDot(d.Path) {
			return "each top_dirs path must be absolute, printable ASCII, up to 256 bytes, with no .. segment"
		}
		if !boxMountRe.MatchString(d.Mount) || d.SizeKB < 0 {
			return "each top_dirs entry needs a mount (an absolute path) and size_kb >= 0"
		}
	}
	if raw, err := json.Marshal(s); err != nil || len(raw) > BoxSnapshotMaxBytes {
		return "snapshot must encode to at most 16384 bytes of JSON"
	}
	return ""
}

// dotDot reports a ".." segment in a slash path.
func dotDot(p string) bool {
	for _, seg := range strings.Split(p, "/") {
		if seg == ".." {
			return true
		}
	}
	return false
}

// storedBoxSnapshot is the form both drivers keep: at is the row's, and the
// percentages are the 1-decimal values of spec 071 8.3.3, so the stored JSON
// stays far below the rdb 0317 size CHECK (a float such as 1e-300 would
// print 300 digits in jsonb).
func storedBoxSnapshot(s BoxSnapshot, at time.Time) BoxSnapshot {
	r1 := func(f float64) float64 { return math.Round(f*10) / 10 }
	s.At = at.UTC()
	s.CPUUserPct, s.CPUSysPct, s.CPUIOWaitPct = r1(s.CPUUserPct), r1(s.CPUSysPct), r1(s.CPUIOWaitPct)
	if s.CPUCoresPct != nil {
		cores := make([]float64, len(s.CPUCoresPct))
		for i, c := range s.CPUCoresPct {
			cores[i] = r1(c)
		}
		s.CPUCoresPct = cores
	}
	s.TopDirs = append([]BoxDir(nil), s.TopDirs...)
	if s.TopDirsAt != nil {
		t := s.TopDirsAt.UTC()
		s.TopDirsAt = &t
	}
	return s
}

// BoxSnapshots is the store half of rdb 0317's box_snapshots, beside
// BoxStats. PruneBoxStats prunes its rows too.
type BoxSnapshots interface {
	// AppendBoxStatSnapshot appends b and, when snap is not nil, upserts
	// box b.Box's one snapshot row under b.At, in one transaction (the
	// caller has checked both).
	AppendBoxStatSnapshot(ctx context.Context, tenantID string, b BoxStat, snap *BoxSnapshot) error
	// ListBoxSnapshots is the tenant's newest snapshot per box ("" = every
	// box), keyed by box.
	ListBoxSnapshots(ctx context.Context, tenantID, box string) (map[string]BoxSnapshot, error)
}

var memBoxSnaps = map[*Memory]map[string]map[string]BoxSnapshot{} // per tenant, per box; under memBoxStatsMu

// AppendBoxStatSnapshot is BoxSnapshots.AppendBoxStatSnapshot on Memory.
func (s *Memory) AppendBoxStatSnapshot(ctx context.Context, tenant string, b BoxStat, snap *BoxSnapshot) error {
	if err := s.AppendBoxStat(ctx, tenant, b); err != nil || snap == nil {
		return err
	}
	memBoxStatsMu.Lock()
	defer memBoxStatsMu.Unlock()
	if memBoxSnaps[s] == nil {
		memBoxSnaps[s] = map[string]map[string]BoxSnapshot{}
	}
	if memBoxSnaps[s][tenant] == nil {
		memBoxSnaps[s][tenant] = map[string]BoxSnapshot{}
	}
	memBoxSnaps[s][tenant][b.Box] = storedBoxSnapshot(*snap, b.At)
	return nil
}

// ListBoxSnapshots is BoxSnapshots.ListBoxSnapshots on Memory.
func (s *Memory) ListBoxSnapshots(_ context.Context, tenant, box string) (map[string]BoxSnapshot, error) {
	memBoxStatsMu.Lock()
	defer memBoxStatsMu.Unlock()
	out := map[string]BoxSnapshot{}
	for name, r := range memBoxSnaps[s][tenant] {
		if box == "" || name == box {
			out[name] = storedBoxSnapshot(r, r.At)
		}
	}
	return out, nil
}

// pruneMemBoxSnaps drops every tenant's snapshot older than before (the
// caller holds memBoxStatsMu).
func (s *Memory) pruneMemBoxSnaps(before time.Time) int {
	n := 0
	for _, boxes := range memBoxSnaps[s] {
		for name, r := range boxes {
			if r.At.Before(before) {
				delete(boxes, name)
				n++
			}
		}
	}
	return n
}
