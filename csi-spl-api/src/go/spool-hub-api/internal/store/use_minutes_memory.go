package store

import (
	"context"
	"sort"
	"time"
)

// Memory side of use_minutes.go (rdb 0289, SPL-5709), guarded by Memory.mu.

// memUseRow is one counter row: minutes and the last counted minute.
type memUseRow struct {
	minutes int64
	last    time.Time
}

// memUse is workspace_use_minutes (tenant, human, day) and hub_use_minutes
// (human, day).
type memUse struct {
	ws  map[[3]string]*memUseRow
	hub map[[2]string]*memUseRow
}

// useLocked answers the tables, made on first use; s.mu is held.
func (s *Memory) useLocked() *memUse {
	if s.use == nil {
		s.use = &memUse{ws: map[[3]string]*memUseRow{}, hub: map[[2]string]*memUseRow{}}
	}
	return s.use
}

// countUseRow adds the minute m to *row unless it was counted.
func countUseRow(row **memUseRow, m time.Time) bool {
	if *row == nil {
		*row = &memUseRow{minutes: 1, last: m}
		return true
	}
	if !(*row).last.Before(m) {
		return false
	}
	(*row).minutes++
	(*row).last = m
	return true
}

// RecordUseMinute implements UseMinutes.
func (s *Memory) RecordUseMinute(_ context.Context, tenant, hum string, at time.Time) (UseCounted, error) {
	if err := checkTenant(tenant); err != nil {
		return UseCounted{}, err
	}
	m, day := useMinute(at)
	s.mu.Lock()
	defer s.mu.Unlock()
	u := s.useLocked()
	wk, hk := [3]string{tenant, hum, day}, [2]string{hum, day}
	w, h := u.ws[wk], u.hub[hk]
	c := UseCounted{Workspace: countUseRow(&w, m), Hub: countUseRow(&h, m)}
	u.ws[wk], u.hub[hk] = w, h
	return c, nil
}

func inUseRange(day, from, to string) bool { return day >= from && day <= to }

// WorkspaceUseMinutes implements UseMinutes.
func (s *Memory) WorkspaceUseMinutes(_ context.Context, tenant, from, to string) (map[string]int64, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]int64{}
	for k, r := range s.useLocked().ws {
		if k[0] == tenant && inUseRange(k[2], from, to) {
			out[k[1]] += r.minutes
		}
	}
	return out, nil
}

// HubUseMinutesOf implements UseMinutes.
func (s *Memory) HubUseMinutesOf(_ context.Context, humans []string, from, to string) (map[string]int64, error) {
	want := map[string]bool{}
	for _, h := range humans {
		want[h] = true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]int64{}
	for k, r := range s.useLocked().hub {
		if want[k[0]] && inUseRange(k[1], from, to) {
			out[k[0]] += r.minutes
		}
	}
	return out, nil
}

// HubUseTotal implements UseMinutes.
func (s *Memory) HubUseTotal(_ context.Context, from, to string) (UseTotal, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u := s.useLocked()
	t := UseTotal{Days: []UseDay{}, Workspaces: []UseWorkspace{}}
	people, days := map[string]bool{}, map[string]*UseDay{}
	for k, r := range u.hub {
		if !inUseRange(k[1], from, to) {
			continue
		}
		t.Minutes += r.minutes
		people[k[0]] = true
		if days[k[1]] == nil {
			days[k[1]] = &UseDay{Day: k[1]}
		}
		days[k[1]].Minutes += r.minutes
		days[k[1]].People++
	}
	t.People = len(people)
	for _, d := range days {
		t.Days = append(t.Days, *d)
	}
	sort.Slice(t.Days, func(i, j int) bool { return t.Days[i].Day < t.Days[j].Day })
	t.Workspaces = memUseWorkspaces(u, from, to)
	return t, nil
}

// memUseWorkspaces is HubUseTotal's per-workspace rows, most minutes first.
func memUseWorkspaces(u *memUse, from, to string) []UseWorkspace {
	by, ppl := map[string]*UseWorkspace{}, map[[2]string]bool{}
	for k, r := range u.ws {
		if !inUseRange(k[2], from, to) {
			continue
		}
		if by[k[0]] == nil {
			by[k[0]] = &UseWorkspace{TenantID: k[0]}
		}
		by[k[0]].Minutes += r.minutes
		if p := [2]string{k[0], k[1]}; !ppl[p] {
			ppl[p] = true
			by[k[0]].People++
		}
	}
	out := []UseWorkspace{}
	for _, w := range by {
		out = append(out, *w)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Minutes != out[j].Minutes {
			return out[i].Minutes > out[j].Minutes
		}
		return out[i].TenantID < out[j].TenantID
	})
	return out
}

// SweepUseMinutes implements UseMinutes.
func (s *Memory) SweepUseMinutes(_ context.Context, before string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, n := s.useLocked(), 0
	for k := range u.ws {
		if k[2] < before {
			delete(u.ws, k)
			n++
		}
	}
	for k := range u.hub {
		if k[1] < before {
			delete(u.hub, k)
			n++
		}
	}
	return n, nil
}
