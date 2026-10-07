// SPDX-License-Identifier: AGPL-3.0-only

// Package hours is the suggestion engine of spec 107 (sections 1.1, 1.3,
// 1.4, 1.6): a member's recorded minutes and accepted meetings become per-day,
// per-target suggested rows. It is pure: no store, no clock of its own, no
// network. The member route GET /v1/me/hours (T006) reads hours_minutes and
// the member's meetings, keeps only the meetings 1.4 counts (timed,
// confirmed, the counted kinds, the member created it or answered yes) and
// calls Suggest; it also keeps only the days it asked for, since a block
// near the range's edge may reach a day outside it.
//
// The rules, in the order of spec 1.1 item 6:
//
//  1. Each wall-clock minute has at most one owner, by precedence meeting >
//     post > tab (1.3). A minute in two meetings goes to the one that started
//     first (1.4), so overlapping meetings never exceed the wall-clock time
//     they cover. A meeting with a topic suggests against t:<topic_id>, else
//     against cal:<event_id>.
//  2. Blocks: owned minutes whose gap is at most N idle minutes join one
//     block; the gap counts and goes to the target of the minute before it.
//     A longer gap ends the block at the end of its last owned minute: no
//     idle tail.
//  3. The floor: a block shorter than 3 minutes holding only tab minutes is
//     dropped. A block with a post or a meeting minute is never dropped.
//  4. Each minute of a kept block goes to the member's local day (the zone
//     given), so a block over midnight splits there and a DST day holds 23 or
//     25 hours of minutes; then per-target sums per day.
//  5. The fold: a target under 5 minutes in a day joins the day's ws row
//     ("other"). A dropped block is never folded back in.
package hours

import (
	"errors"
	"fmt"
	"sort"
	"time"
)

// Sources of a recorded minute (hours_minutes.src, spec 3.2).
const (
	SrcPost = "post"
	SrcTab  = "tab"
)

const (
	// TargetWS is the workspace target, also the folded "other" row.
	TargetWS = "ws"
	// DefaultIdleMinutes is N when hours.idle_minutes is unset (spec 1.1).
	DefaultIdleMinutes = 10
	// FloorMinutes: a tab-only block shorter than this is dropped (1.1 item 4).
	FloorMinutes = 3
	// FoldMinutes: a target under this many minutes in a day folds into ws (1.3).
	FoldMinutes = 5
)

// Minute is one hours_minutes row: an active minute, its target and source.
// At is truncated to its minute.
type Minute struct {
	At     time.Time
	Target string
	Src    string
}

// Meeting is one counted calendar event (1.4) over [Start, End). A partial
// first or last minute counts as a whole one.
type Meeting struct {
	EventID string
	TopicID string
	Start   time.Time
	End     time.Time
}

// Input is everything one member's suggestions are made of.
type Input struct {
	Minutes     []Minute
	Meetings    []Meeting
	IdleMinutes int            // N, the idle cutoff; 0 bridges nothing
	Loc         *time.Location // the member's zone (1.6)
}

// Span is a run of minutes [Start, End) of one row: the "why" sheet (5.2).
type Span struct {
	Start time.Time
	End   time.Time
}

// Row is one suggested (day, target) row.
type Row struct {
	Target  string
	Minutes int
	Blocks  []Span
}

// Day is one local day's suggestion, rows sorted by minutes, most first.
type Day struct {
	Date    string // YYYY-MM-DD in Input.Loc
	Minutes int
	Rows    []Row
}

// Owner kinds, in precedence order: a higher kind wins the minute.
const (
	kindTab = iota + 1
	kindPost
	kindMeeting
)

type owner struct {
	target string
	kind   int
}

// Suggest turns a member's minutes and meetings into per-day rows, oldest
// day first. It returns an error for input the store could never hold.
func Suggest(in Input) ([]Day, error) {
	if in.Loc == nil {
		return nil, errors.New("hours: no time zone")
	}
	if in.IdleMinutes < 0 {
		return nil, fmt.Errorf("hours: idle minutes %d < 0", in.IdleMinutes)
	}
	owners, err := ownMinutes(in)
	if err != nil {
		return nil, err
	}
	keys := make([]int64, 0, len(owners))
	for k := range owners {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })

	// per day, per target: the minute numbers it holds
	days := map[string]map[string][]int64{}
	for start := 0; start < len(keys); {
		end := start + 1
		for end < len(keys) && keys[end]-keys[end-1]-1 <= int64(in.IdleMinutes) {
			end++
		}
		addBlock(days, owners, keys[start:end], in.Loc)
		start = end
	}
	return foldDays(days), nil
}

// ownMinutes gives each minute its one owner (rule 1).
func ownMinutes(in Input) (map[int64]owner, error) {
	owners := map[int64]owner{}
	for _, m := range in.Minutes {
		var kind int
		switch m.Src {
		case SrcTab:
			kind = kindTab
		case SrcPost:
			kind = kindPost
		default:
			return nil, fmt.Errorf("hours: minute src %q is not post or tab", m.Src)
		}
		if m.Target == "" {
			return nil, errors.New("hours: minute without a target")
		}
		k := minuteOf(m.At)
		if cur, ok := owners[k]; ok && cur.kind >= kind {
			continue
		}
		owners[k] = owner{m.Target, kind}
	}
	meetings := append([]Meeting(nil), in.Meetings...)
	sort.SliceStable(meetings, func(i, j int) bool {
		if !meetings[i].Start.Equal(meetings[j].Start) {
			return meetings[i].Start.Before(meetings[j].Start)
		}
		return meetings[i].EventID < meetings[j].EventID
	})
	for _, mt := range meetings {
		if mt.EventID == "" {
			return nil, errors.New("hours: meeting without an event id")
		}
		if !mt.End.After(mt.Start) {
			continue
		}
		target := "cal:" + mt.EventID
		if mt.TopicID != "" {
			target = "t:" + mt.TopicID
		}
		last := minuteOf(mt.End.Add(-time.Nanosecond))
		for k := minuteOf(mt.Start); k <= last; k++ {
			if owners[k].kind == kindMeeting {
				continue
			}
			owners[k] = owner{target, kindMeeting}
		}
	}
	return owners, nil
}

// addBlock applies the floor (rule 3) to one block, fills its gaps from the
// minute before them (rule 2) and puts each minute on its local day (rule 4).
func addBlock(days map[string]map[string][]int64, owners map[int64]owner, block []int64, loc *time.Location) {
	first, last := block[0], block[len(block)-1]
	tabOnly := true
	for _, k := range block {
		if owners[k].kind != kindTab {
			tabOnly = false
			break
		}
	}
	if tabOnly && last-first+1 < FloorMinutes {
		return
	}
	target := owners[first].target
	for k := first; k <= last; k++ {
		if o, ok := owners[k]; ok {
			target = o.target
		}
		date := timeOf(k).In(loc).Format("2006-01-02")
		if days[date] == nil {
			days[date] = map[string][]int64{}
		}
		days[date][target] = append(days[date][target], k)
	}
}

// foldDays sums each day per target and folds the small ones into ws (rule 5).
func foldDays(days map[string]map[string][]int64) []Day {
	out := make([]Day, 0, len(days))
	for date, targets := range days {
		for t, ks := range targets {
			if t != TargetWS && len(ks) < FoldMinutes {
				targets[TargetWS] = append(targets[TargetWS], ks...)
				delete(targets, t)
			}
		}
		d := Day{Date: date}
		for t, ks := range targets {
			sort.Slice(ks, func(i, j int) bool { return ks[i] < ks[j] })
			d.Rows = append(d.Rows, Row{Target: t, Minutes: len(ks), Blocks: spans(ks)})
			d.Minutes += len(ks)
		}
		sort.Slice(d.Rows, func(i, j int) bool {
			if d.Rows[i].Minutes != d.Rows[j].Minutes {
				return d.Rows[i].Minutes > d.Rows[j].Minutes
			}
			return d.Rows[i].Target < d.Rows[j].Target
		})
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Date < out[j].Date })
	return out
}

// spans turns sorted minute numbers into runs of consecutive minutes.
func spans(ks []int64) []Span {
	var out []Span
	for i := 0; i < len(ks); {
		j := i + 1
		for j < len(ks) && ks[j] == ks[j-1]+1 {
			j++
		}
		out = append(out, Span{Start: timeOf(ks[i]), End: timeOf(ks[j-1] + 1)})
		i = j
	}
	return out
}

// minuteOf is the minute number of t: Unix minutes, floored.
func minuteOf(t time.Time) int64 {
	s := t.Unix()
	if s < 0 && s%60 != 0 {
		return s/60 - 1
	}
	return s / 60
}

func timeOf(k int64) time.Time { return time.Unix(k*60, 0).UTC() }
