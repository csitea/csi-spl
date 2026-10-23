package store

import (
	"context"
	"sort"
	"time"
)

// memHours is Memory's rdb 0151, 0176 and 0218 tables, guarded by Memory.mu,
// each keyed by (tenant, member).
type memHours struct {
	minutes map[[2]string]map[int64]HoursMinute        // unix minute -> row
	entries map[[2]string]map[hoursEntryKey]HoursEntry // (day, target, kind) -> row
	periods map[[2]string]map[string]HoursPeriod       // period start -> row
	spans   map[[2]string][]HoursEntrySpan             // by start
}

func (h *memHours) init() {
	if h.minutes == nil {
		h.minutes = map[[2]string]map[int64]HoursMinute{}
		h.entries = map[[2]string]map[hoursEntryKey]HoursEntry{}
		h.periods = map[[2]string]map[string]HoursPeriod{}
		h.spans = map[[2]string][]HoursEntrySpan{}
	}
}

// hoursTenantLocked is ErrNotFound for an unknown tenant (the FK of rdb 0151).
func (s *Memory) hoursTenantLocked(tenant string) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	s.hrs.init()
	return nil
}

func (s *Memory) UpsertHoursMinutes(_ context.Context, tenant, member string, ms []HoursMinute) error {
	ms, err := normalizeHoursMinutes(member, ms)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.hoursTenantLocked(tenant); err != nil {
		return err
	}
	k := [2]string{tenant, member}
	if s.hrs.minutes[k] == nil {
		s.hrs.minutes[k] = map[int64]HoursMinute{}
	}
	for _, m := range ms {
		if old, ok := s.hrs.minutes[k][m.At.Unix()]; ok && old.Src != HoursSrcTab {
			continue // a post minute stays (spec 1.3)
		}
		s.hrs.minutes[k][m.At.Unix()] = m
	}
	return nil
}

func (s *Memory) HoursMinutes(_ context.Context, tenant, member string, from, to time.Time) ([]HoursMinute, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out := []HoursMinute{}
	for _, m := range s.hrs.minutes[[2]string{tenant, member}] {
		if !m.At.Before(from) && m.At.Before(to) {
			out = append(out, m)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, nil
}

func (s *Memory) HoursEntries(_ context.Context, tenant, member, from, to string) ([]HoursEntry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out := []HoursEntry{}
	for _, e := range s.hrs.entries[[2]string{tenant, member}] {
		if from <= e.Day && e.Day <= to {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Day != b.Day {
			return a.Day < b.Day
		}
		if a.Target != b.Target {
			return a.Target < b.Target
		}
		return a.Kind < b.Kind
	})
	return out, nil
}

func (s *Memory) PutHoursEntries(ctx context.Context, tenant, member string, es []HoursEntry, by string, now time.Time) error {
	es = append([]HoursEntry(nil), es...)
	days, err := normalizeHoursEntries(member, by, es)
	if err != nil {
		return err
	}
	if err := refuseFrozen(ctx, s, tenant, member, days, now); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.hoursTenantLocked(tenant); err != nil {
		return err
	}
	k := [2]string{tenant, member}
	next := map[hoursEntryKey]HoursEntry{}
	for dk, e := range s.hrs.entries[k] {
		next[dk] = e
	}
	for _, e := range es {
		e.UpdatedAt, e.UpdatedBy, e.Spans = now.UTC(), by, nil
		e.CategoryMinutes = copyCategoryMinutes(e.CategoryMinutes)
		next[e.key()] = e
	}
	if err := memHoursCap(next, days); err != nil {
		return err
	}
	spans, err := memHoursSpans(s.hrs.spans[k], es)
	if err != nil {
		return err
	}
	s.hrs.entries[k], s.hrs.spans[k] = next, spans
	return nil
}

// memHoursSpans is old after es's span writes, as Postgres putHoursSpans:
// the replaced activity spans dropped, the member's own times added
// (ErrHoursOverlap on an overlap), then the activity spans that overlap
// nothing.
func memHoursSpans(old []HoursEntrySpan, es []HoursEntry) ([]HoursEntrySpan, error) {
	drop := map[hoursEntryKey]bool{}
	for _, e := range es {
		if hoursReplacesActivity(e) {
			drop[e.key()] = true
		}
	}
	out := []HoursEntrySpan{}
	for _, sp := range old {
		if !(sp.Src == HoursSpanActivity && drop[hoursEntryKey{sp.Day, sp.Target, sp.Kind}]) {
			out = append(out, sp)
		}
	}
	var own, act []HoursEntrySpan
	for _, e := range es {
		for _, sp := range e.Spans {
			row := HoursEntrySpan{Day: e.Day, Target: e.Target, Kind: e.Kind, HoursSpan: sp}
			if sp.Src == HoursSpanActivity {
				act = append(act, row)
			} else {
				own = append(own, row)
			}
		}
	}
	for _, sp := range own {
		if memSpanOverlaps(out, sp.HoursSpan) {
			return nil, ErrHoursOverlap
		}
		out = append(out, sp)
	}
	for _, sp := range act {
		if !memSpanOverlaps(out, sp.HoursSpan) {
			out = append(out, sp)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Start.Before(out[j].Start) })
	return out, nil
}

// memSpanOverlaps says whether sp overlaps one of ss ([a,b) and [b,c) do not).
func memSpanOverlaps(ss []HoursEntrySpan, sp HoursSpan) bool {
	for _, o := range ss {
		if sp.Start.Before(o.End) && o.Start.Before(sp.End) {
			return true
		}
	}
	return false
}

func (s *Memory) HoursEntrySpans(_ context.Context, tenant, member, from, to string) ([]HoursEntrySpan, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out := []HoursEntrySpan{}
	for _, sp := range s.hrs.spans[[2]string{tenant, member}] {
		if from <= sp.Day && sp.Day <= to {
			out = append(out, sp)
		}
	}
	return out, nil
}

// copyCategoryMinutes keeps a stored row from sharing the caller's map.
func copyCategoryMinutes(c map[string]int) map[string]int {
	if c == nil {
		return nil
	}
	out := make(map[string]int, len(c))
	for k, v := range c {
		out[k] = v
	}
	return out
}

// memHoursCap is ErrHoursDayCap when one of days sums above the cap.
func memHoursCap(rows map[hoursEntryKey]HoursEntry, days []string) error {
	sum := map[string]int{}
	for _, e := range rows {
		sum[e.Day] += hoursEntryCounts(e)
	}
	for _, d := range days {
		if sum[d] > HoursDayCap {
			return ErrHoursDayCap
		}
	}
	return nil
}

func (s *Memory) DeleteHoursEntry(ctx context.Context, tenant, member, day, target string, now time.Time) error {
	if err := refuseFrozen(ctx, s, tenant, member, []string{day}, now); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k, dk := [2]string{tenant, member}, hoursEntryKey{day, target, HoursKindWork}
	if _, ok := s.hrs.entries[k][dk]; !ok {
		return ErrNotFound
	}
	delete(s.hrs.entries[k], dk)
	kept := []HoursEntrySpan{} // the FK's cascade
	for _, sp := range s.hrs.spans[k] {
		if sp.Day != day || sp.Target != target || sp.Kind != HoursKindWork {
			kept = append(kept, sp)
		}
	}
	s.hrs.spans[k] = kept
	return nil
}

func (s *Memory) CreateHoursPeriod(_ context.Context, tenant string, p HoursPeriod) (bool, error) {
	if err := checkHoursPeriod(&p); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.hoursTenantLocked(tenant); err != nil {
		return false, err
	}
	k := [2]string{tenant, p.Member}
	if _, dup := s.hrs.periods[k][p.Start]; dup {
		return false, nil
	}
	if s.hrs.periods[k] == nil {
		s.hrs.periods[k] = map[string]HoursPeriod{}
	}
	if p.DecidedAt.IsZero() {
		p.DecidedAt = time.Now()
	}
	p.DecidedAt = p.DecidedAt.UTC()
	s.hrs.periods[k][p.Start] = p
	return true, nil
}

func (s *Memory) SetHoursPeriodState(_ context.Context, tenant, member, start string, ch HoursPeriodChange) (HoursPeriod, error) {
	from, err := checkHoursPeriodChange(&ch)
	if err != nil {
		return HoursPeriod{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := checkTenant(tenant); err != nil {
		return HoursPeriod{}, err
	}
	k := [2]string{tenant, member}
	p, ok := s.hrs.periods[k][start]
	if !ok {
		return HoursPeriod{}, ErrNotFound
	}
	allowed := false
	for _, st := range from {
		allowed = allowed || p.State == st
	}
	if !allowed {
		return HoursPeriod{}, ErrHoursPeriodState
	}
	p = applyHoursPeriodChange(p, ch)
	s.hrs.periods[k][start] = p
	return p, nil
}

func (s *Memory) HoursPeriods(_ context.Context, tenant, member, from, to string) ([]HoursPeriod, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out := []HoursPeriod{}
	for k, rows := range s.hrs.periods {
		if k[0] != tenant || (member != "" && k[1] != member) {
			continue
		}
		for _, p := range rows {
			if p.Start <= to && p.End >= from {
				out = append(out, p)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Start < out[j].Start || (out[i].Start == out[j].Start && out[i].Member < out[j].Member)
	})
	return out, nil
}

func (s *Memory) HoursFrozenDays(ctx context.Context, tenant, member string, days []string, now time.Time) (map[string]bool, error) {
	return hoursFrozenDays(ctx, s, tenant, member, days, now)
}

func (s *Memory) HoursIdleMinutes(ctx context.Context, tenant, member string) (int, error) {
	return hoursIdleMinutes(ctx, s, tenant, member)
}
