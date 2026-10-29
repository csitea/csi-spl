package store

import (
	"context"
	"slices"
	"time"
)

// Memory's Workspace and System logs (log_events.go), the same contract as
// the Postgres side, under s.mu: each log is a slice, oldest first, and the
// ids come from one counter, as one identity per table does in Postgres.

type memLogEvents struct {
	seq       int64
	workspace map[string][]LogEvent // tenant -> rows, oldest first
	system    []LogEvent
}

// logEventsLocked is the state, made on first use; s.mu is held.
func (s *Memory) logEventsLocked() *memLogEvents {
	if s.logEvents == nil {
		s.logEvents = &memLogEvents{workspace: map[string][]LogEvent{}}
	}
	return s.logEvents
}

// add appends e to rows, stamped, and trims rows to keep; m is held.
func (m *memLogEvents) add(rows []LogEvent, e LogEvent, now time.Time, keep int) ([]LogEvent, LogEvent) {
	m.seq++
	e.ID, e.At = m.seq, now
	rows = append(rows, e)
	if len(rows) > keep {
		rows = slices.Clone(rows[len(rows)-keep:])
	}
	return rows, e
}

// page is rows newest first, ids below before (> 0), at most limit.
func logEventsPage(rows []LogEvent, before int64, limit int) []LogEvent {
	out := []LogEvent{}
	for i := len(rows) - 1; i >= 0 && len(out) < limit; i-- {
		if before <= 0 || rows[i].ID < before {
			out = append(out, rows[i])
		}
	}
	return out
}

// drop removes the rows named in ids; it answers what is left and how many went.
func logEventsDrop(rows []LogEvent, ids []int64) ([]LogEvent, int) {
	n := len(rows)
	rows = slices.DeleteFunc(rows, func(e LogEvent) bool { return slices.Contains(ids, e.ID) })
	return rows, n - len(rows)
}

func (s *Memory) AddWorkspaceEvent(_ context.Context, tenant string, e LogEvent, now time.Time) (LogEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return LogEvent{}, err
	}
	e, err := normLogEvent(e)
	if err != nil {
		return LogEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return LogEvent{}, ErrNotFound
	}
	m := s.logEventsLocked()
	e.Tenant = tenant
	m.workspace[tenant], e = m.add(m.workspace[tenant], e, now, WorkspaceEventsKeep)
	return e, nil
}

func (s *Memory) WorkspaceEventsPage(_ context.Context, tenant string, before int64, limit int) ([]LogEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return logEventsPage(s.logEventsLocked().workspace[tenant], before, limit), nil
}

func (s *Memory) DeleteWorkspaceEvents(_ context.Context, tenant string, ids []int64, actor string, now time.Time) (int, error) {
	if err := checkTenant(tenant); err != nil {
		return 0, err
	}
	if err := checkLogEventIDs(ids); err != nil {
		return 0, err
	}
	trace, err := normLogEvent(logDeletedEvent(0, actor))
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.logEventsLocked()
	rows, n := logEventsDrop(m.workspace[tenant], ids)
	if n > 0 {
		trace = logDeletedEvent(n, actor)
		trace.Tenant = tenant
		rows, _ = m.add(rows, trace, now, WorkspaceEventsKeep)
	}
	m.workspace[tenant] = rows
	return n, nil
}

func (s *Memory) AddSystemEvent(_ context.Context, e LogEvent, now time.Time) (LogEvent, error) {
	e, err := normLogEvent(e)
	if err != nil {
		return LogEvent{}, err
	}
	e.Tenant = ""
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.logEventsLocked()
	m.system, e = m.add(m.system, e, now, SystemEventsKeep)
	return e, nil
}

func (s *Memory) SystemEventsPage(_ context.Context, before int64, limit int) ([]LogEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return logEventsPage(s.logEventsLocked().system, before, limit), nil
}

func (s *Memory) DeleteSystemEvents(_ context.Context, ids []int64, actor string, now time.Time) (int, error) {
	if err := checkLogEventIDs(ids); err != nil {
		return 0, err
	}
	if _, err := normLogEvent(logDeletedEvent(0, actor)); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.logEventsLocked()
	rows, n := logEventsDrop(m.system, ids)
	if n > 0 {
		rows, _ = m.add(rows, logDeletedEvent(n, actor), now, SystemEventsKeep)
	}
	m.system = rows
	return n, nil
}
