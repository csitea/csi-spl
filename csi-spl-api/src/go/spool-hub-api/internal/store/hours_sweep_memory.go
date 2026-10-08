package store

import (
	"context"
	"sort"
	"time"
)

// The Memory side of hours_sweep.go.

func (s *Memory) SweepHours(ctx context.Context, now time.Time, open HoursOpenSuggestions, tenants ...string) (HoursSweepResult, error) {
	return sweepHours(ctx, s, now, open, tenants)
}

func (s *Memory) hoursSweepTenants(_ context.Context) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.tenants))
	for id := range s.tenants {
		out = append(out, id)
	}
	sort.Strings(out)
	return out, nil
}

func (s *Memory) hoursActiveMembers(_ context.Context, tenant, from, to string) (map[string]bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hrs.init()
	s.hum.init()
	out := map[string]bool{}
	add := func(id string) {
		if s.hum.humans[id] != nil {
			out[id] = true // a human; an agent id never is one
		}
	}
	for k, rows := range s.hrs.entries {
		for _, e := range rows {
			if k[0] == tenant && from <= e.Day && e.Day <= to {
				add(k[1])
				break
			}
		}
	}
	for k, rows := range s.hrs.minutes {
		for _, m := range rows {
			if d := hoursMinuteDay(m); k[0] == tenant && from <= d && d <= to {
				add(k[1])
				break
			}
		}
	}
	return out, nil
}

func (s *Memory) freezeHoursPeriod(_ context.Context, tenant string, p HoursPeriod, es []HoursEntry) (created bool, pruned int, err error) {
	if err := checkHoursPeriod(&p); err != nil {
		return false, 0, err
	}
	if err := checkSweepEntries(p, es); err != nil {
		return false, 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.hoursTenantLocked(tenant); err != nil {
		return false, 0, err
	}
	k := [2]string{tenant, p.Member}
	if _, dup := s.hrs.periods[k][p.Start]; !dup {
		if err := s.memSweepEntriesLocked(k, p, es); err != nil {
			return false, 0, err
		}
		p.Minutes = 0
		for _, e := range s.hrs.entries[k] {
			if p.Start <= e.Day && e.Day <= p.End {
				p.Minutes += hoursEntryCounts(e)
			}
		}
		if s.hrs.periods[k] == nil {
			s.hrs.periods[k] = map[string]HoursPeriod{}
		}
		p.DecidedAt = p.DecidedAt.UTC()
		s.hrs.periods[k][p.Start] = p
		created = true
	}
	for at, m := range s.hrs.minutes[k] {
		if d := hoursMinuteDay(m); p.Start <= d && d <= p.End {
			delete(s.hrs.minutes[k], at)
			pruned++
		}
	}
	return created, pruned, nil
}

func (s *Memory) pruneAgedHoursMinutes(_ context.Context, before time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, rows := range s.hrs.minutes {
		for at, m := range rows {
			if m.At.Before(before) {
				delete(rows, at)
				n++
			}
		}
	}
	return n, nil
}

// memSweepEntriesLocked adds es where no entry is, all or none (the cap).
func (s *Memory) memSweepEntriesLocked(k [2]string, p HoursPeriod, es []HoursEntry) error {
	next := map[[2]string]HoursEntry{}
	for dk, e := range s.hrs.entries[k] {
		next[dk] = e
	}
	var days []string
	for _, e := range es {
		dk := [2]string{e.Day, e.Target}
		if _, ok := next[dk]; ok {
			continue // the worker's own decision stays
		}
		e.UpdatedAt, e.UpdatedBy = p.DecidedAt.UTC(), HoursSweepBy
		next[dk] = e
		days = append(days, e.Day)
	}
	if err := memHoursCap(next, days); err != nil {
		return err
	}
	s.hrs.entries[k] = next
	return nil
}
