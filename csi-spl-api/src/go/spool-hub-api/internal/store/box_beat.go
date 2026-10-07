package store

import (
	"context"
	"sort"
	"sync"
	"time"
)

// The box beat of spec 102 section 10.2 (rdb 0147, task T017): one row per
// watchdog tick per box. The hub's answer to the write is the beat's ack; a
// box with no ack for box_down_min fences itself.

// BoxBeatsRetention is how long a beat row is kept (the hub's sweep).
const BoxBeatsRetention = 48 * time.Hour

// BoxBeatsMax caps one read.
const BoxBeatsMax = 500

// BoxBeat is one beat. Box is the writing box (the session's, never the
// frame's) and BeatAt the hub's clock.
type BoxBeat struct {
	Box    string    `json:"box"`
	BeatAt time.Time `json:"beat_at"`
	PID    int       `json:"pid"`
}

// CheckBoxBeat is the table's CHECKs, so a bad beat is a 400, never a 500.
func CheckBoxBeat(b BoxBeat) string {
	if !FleetNameRe.MatchString(b.Box) {
		return "box must be a box id ([a-z0-9-], up to 32)"
	}
	if b.PID < 1 {
		return "pid must be a process id (1 or more)"
	}
	return ""
}

// BoxBeats is the store half of rdb 0147. Optional: the hub answers the beat
// ops unsupported, and skips the sweep, on a store without it.
type BoxBeats interface {
	// AppendBoxBeat appends one beat (the caller has checked it).
	AppendBoxBeat(ctx context.Context, tenantID string, b BoxBeat) error
	// ListBoxBeats is the tenant's beats of box ("" = every box) at or after
	// since, newest first, at most BoxBeatsMax.
	ListBoxBeats(ctx context.Context, tenantID, box string, since time.Time) ([]BoxBeat, error)
	// PruneBoxBeats deletes every tenant's beats older than before and
	// returns how many (the retention sweep).
	PruneBoxBeats(ctx context.Context, before time.Time) (int, error)
}

// The Memory driver keeps its beats beside the store, like memBoxStats.
var (
	memBoxBeatsMu sync.Mutex
	memBoxBeats   = map[*Memory]map[string][]BoxBeat{} // per tenant, in append order
)

func (s *Memory) AppendBoxBeat(_ context.Context, tenant string, b BoxBeat) error {
	memBoxBeatsMu.Lock()
	defer memBoxBeatsMu.Unlock()
	if memBoxBeats[s] == nil {
		memBoxBeats[s] = map[string][]BoxBeat{}
	}
	b.BeatAt = b.BeatAt.UTC()
	memBoxBeats[s][tenant] = append(memBoxBeats[s][tenant], b)
	return nil
}

func (s *Memory) ListBoxBeats(_ context.Context, tenant, box string, since time.Time) ([]BoxBeat, error) {
	memBoxBeatsMu.Lock()
	defer memBoxBeatsMu.Unlock()
	out := []BoxBeat{}
	for _, b := range memBoxBeats[s][tenant] {
		if (box == "" || b.Box == box) && !b.BeatAt.Before(since) {
			out = append(out, b)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].BeatAt.After(out[j].BeatAt) })
	if len(out) > BoxBeatsMax {
		out = out[:BoxBeatsMax]
	}
	return out, nil
}

func (s *Memory) PruneBoxBeats(_ context.Context, before time.Time) (int, error) {
	memBoxBeatsMu.Lock()
	defer memBoxBeatsMu.Unlock()
	n := 0
	for tenant, rows := range memBoxBeats[s] {
		keep := rows[:0]
		for _, b := range rows {
			if b.BeatAt.Before(before) {
				n++
				continue
			}
			keep = append(keep, b)
		}
		memBoxBeats[s][tenant] = keep
	}
	return n, nil
}
