package store

import (
	"context"
	"sort"
	"time"
)

// memHours is Memory's rdb 0151 tables, guarded by Memory.mu, each keyed by
// (tenant, member).
type memHours struct {
	minutes map[[2]string]map[int64]HoursMinute    // unix minute -> row
	entries map[[2]string]map[[2]string]HoursEntry // (day, target) -> row
	periods map[[2]string]map[string]HoursPeriod   // period start -> row
}

func (h *memHours) init() {
	if h.minutes == nil {
		h.minutes = map[[2]string]map[int64]HoursMinute{}
		h.entries = map[[2]string]map[[2]string]HoursEntry{}
		h.periods = map[[2]string]map[string]HoursPeriod{}
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
		return out[i].Day < out[j].Day || (out[i].Day == out[j].Day && out[i].Target < out[j].Target)
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
	next := map[[2]string]HoursEntry{}
	for dk, e := range s.hrs.entries[k] {
		next[dk] = e
	}
	for _, e := range es {
		e.UpdatedAt, e.UpdatedBy = now.UTC(), by
		next[[2]string{e.Day, e.Target}] = e
	}
	if err := memHoursCap(next, days); err != nil {
		return err
	}
	s.hrs.entries[k] = next
	return nil
}

// memHoursCap is ErrHoursDayCap when one of days sums above the cap.
func memHoursCap(rows map[[2]string]HoursEntry, days []string) error {
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
	k, dk := [2]string{tenant, member}, [2]string{day, target}
	if _, ok := s.hrs.entries[k][dk]; !ok {
		return ErrNotFound
	}
	delete(s.hrs.entries[k], dk)
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
