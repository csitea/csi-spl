package store

import (
	"context"
	"math"
	"regexp"
	"sort"
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
}

// BoxDisk is one mounted filesystem of a sample: its size, free space and,
// from the boxes that send it, df's used (c-542: total - avail also counts
// the root-reserved blocks, so only used / (used + avail) is df's Use%).
// 0 = not sent (older boxes); the readers then fall back to total - avail.
type BoxDisk struct {
	Mount   string `json:"mount"`
	TotalKB int64  `json:"total_kb"`
	AvailKB int64  `json:"avail_kb"`
	UsedKB  int64  `json:"used_kb,omitempty"`
}

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
	seen := map[string]bool{}
	for _, d := range b.Disks {
		if !boxMountRe.MatchString(d.Mount) || seen[d.Mount] {
			return "each disk needs a distinct mount, an absolute path of up to 256 bytes"
		}
		if d.TotalKB < 0 || d.AvailKB < 0 || d.UsedKB < 0 {
			return "disk total_kb / avail_kb / used_kb must be >= 0"
		}
		seen[d.Mount] = true
	}
	return ""
}

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
	return n, nil
}
