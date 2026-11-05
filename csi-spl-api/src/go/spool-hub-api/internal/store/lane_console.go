package store

import (
	"context"
	"maps"
	"slices"
	"time"
)

// A lane's live console (spec 153 section 3.20, rdb 0263, SPL-4810): one
// row per (workspace, box, agent). The hub writes the demand when an allowed
// reader asks; the box pulls its live demands and pushes the captured
// screen, masked on the box. Tenant is the BOX's workspace: the box writes
// over its own session, so the row is in that box's scope.

// LaneConsoleKeep is how long a row stays after its demand ended; the next
// demand in the workspace deletes the older ones.
const LaneConsoleKeep = time.Hour

// LaneConsole is one lane's console row.
type LaneConsole struct {
	Tenant      string
	AgentBox    string
	AgentID     string
	DemandUntil time.Time
	DemandedBy  string
	Screen      string // masked on the box
	Lines       int
	Redactions  map[string]int64
	CapturedAt  *time.Time // nil until the box pushed once
}

// LaneConsoleShot is one capture the box pushes.
type LaneConsoleShot struct {
	AgentID    string
	Screen     string
	Lines      int
	Redactions map[string]int64
}

// LaneConsoleStore is the hub's console store.
type LaneConsoleStore interface {
	// DemandLaneConsole sets the demand of (tenant, box, agent) to until,
	// by reader, keeping the last screen, and deletes tenant's rows whose
	// demand ended before now - LaneConsoleKeep. It returns the row.
	DemandLaneConsole(ctx context.Context, tenant, box, agent, by string, until, now time.Time) (LaneConsole, error)
	// LaneConsoleOf is one row; ErrNotFound when there is none.
	LaneConsoleOf(ctx context.Context, tenant, box, agent string) (LaneConsole, error)
	// LaneConsoleDemands is the agents of (tenant, box) whose demand is on
	// at now, sorted.
	LaneConsoleDemands(ctx context.Context, tenant, box string, now time.Time) ([]string, error)
	// PutLaneConsole stores shot as (tenant, box, shot.AgentID)'s screen,
	// captured at now, only while its demand is on: ErrNotFound when none is.
	PutLaneConsole(ctx context.Context, tenant, box string, shot LaneConsoleShot, now time.Time) error
}

// laneConsoleKey is the memory map's key.
type laneConsoleKey struct{ tenant, box, agent string }

// DemandLaneConsole is LaneConsoleStore.DemandLaneConsole.
func (s *Memory) DemandLaneConsole(_ context.Context, tenant, box, agent, by string, until, now time.Time) (LaneConsole, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.laneConsole == nil {
		s.laneConsole = map[laneConsoleKey]*LaneConsole{}
	}
	for k, c := range s.laneConsole {
		if k.tenant == tenant && c.DemandUntil.Before(now.Add(-LaneConsoleKeep)) {
			delete(s.laneConsole, k)
		}
	}
	k := laneConsoleKey{tenant, box, agent}
	c := s.laneConsole[k]
	if c == nil {
		c = &LaneConsole{Tenant: tenant, AgentBox: box, AgentID: agent, Redactions: map[string]int64{}}
		s.laneConsole[k] = c
	}
	c.DemandUntil, c.DemandedBy = until.UTC(), by
	return laneConsoleCopy(c), nil
}

// LaneConsoleOf is LaneConsoleStore.LaneConsoleOf.
func (s *Memory) LaneConsoleOf(_ context.Context, tenant, box, agent string) (LaneConsole, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.laneConsole[laneConsoleKey{tenant, box, agent}]
	if c == nil {
		return LaneConsole{}, ErrNotFound
	}
	return laneConsoleCopy(c), nil
}

// LaneConsoleDemands is LaneConsoleStore.LaneConsoleDemands.
func (s *Memory) LaneConsoleDemands(_ context.Context, tenant, box string, now time.Time) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for k, c := range s.laneConsole {
		if k.tenant == tenant && k.box == box && c.DemandUntil.After(now) {
			out = append(out, k.agent)
		}
	}
	slices.Sort(out)
	return out, nil
}

// PutLaneConsole is LaneConsoleStore.PutLaneConsole.
func (s *Memory) PutLaneConsole(_ context.Context, tenant, box string, shot LaneConsoleShot, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.laneConsole[laneConsoleKey{tenant, box, shot.AgentID}]
	if c == nil || !c.DemandUntil.After(now) {
		return ErrNotFound
	}
	at := now.UTC()
	c.Screen, c.Lines, c.CapturedAt = shot.Screen, shot.Lines, &at
	c.Redactions = maps.Clone(shot.Redactions)
	if c.Redactions == nil {
		c.Redactions = map[string]int64{}
	}
	return nil
}

func laneConsoleCopy(c *LaneConsole) LaneConsole {
	out := *c
	out.Redactions = maps.Clone(c.Redactions)
	if c.CapturedAt != nil {
		at := *c.CapturedAt
		out.CapturedAt = &at
	}
	return out
}
