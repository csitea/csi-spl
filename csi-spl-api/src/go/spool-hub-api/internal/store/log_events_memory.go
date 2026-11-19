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
	cursors   map[string]EvlogCursor // env -> the reader cursor (rdb 0298)
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

// AddWorkspaceEvent is LogEvents.AddWorkspaceEvent.
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

// WorkspaceEventsPage is LogEvents.WorkspaceEventsPage.
func (s *Memory) WorkspaceEventsPage(_ context.Context, tenant string, before int64, limit int) ([]LogEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return logEventsPage(s.logEventsLocked().workspace[tenant], before, limit), nil
}

// DeleteWorkspaceEvents is LogEvents.DeleteWorkspaceEvents.
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

// AddSystemEvent is LogEvents.AddSystemEvent.
func (s *Memory) AddSystemEvent(_ context.Context, e LogEvent, now time.Time) (LogEvent, error) {
	e, err := normLogEvent(e)
	if err != nil {
		return LogEvent{}, err
	}
	e = plainSystemEvent(e)
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.logEventsLocked()
	m.system, e = m.add(m.system, e, now, SystemEventsKeep)
	return e, nil
}

// SystemEventsPage is LogEvents.SystemEventsPage.
func (s *Memory) SystemEventsPage(_ context.Context, before int64, limit int) ([]LogEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return logEventsPage(s.logEventsLocked().system, before, limit), nil
}

// DeleteSystemEvents is LogEvents.DeleteSystemEvents.
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
		rows, _ = m.add(rows, plainSystemEvent(logDeletedEvent(n, actor)), now, SystemEventsKeep)
	}
	m.system = rows
	return n, nil
}

// upsertGroup is UpsertSystemErrorGroup on the system slice (no trim): the
// rdb 0298 ON CONFLICT rule, the known row taken out and appended again
// under a new id; m is held.
func (m *memLogEvents) upsertGroup(e LogEvent) LogEvent {
	i := slices.IndexFunc(m.system, func(r LogEvent) bool { return r.Fingerprint == e.Fingerprint })
	if i >= 0 {
		old := m.system[i]
		m.system = slices.Delete(m.system, i, i+1)
		if old.At.After(e.At) {
			e.At = old.At
		}
		if old.FirstAt.Before(e.FirstAt) {
			e.FirstAt = old.FirstAt
		}
		e.Kind, e.Level, e.Actor, e.OriginKind, e.OriginRef = old.Kind, old.Level, old.Actor, old.OriginKind, old.OriginRef
		e.N += old.N
		e.IssueKey, e.IssueN = old.IssueKey, old.IssueN
		if e.HumanID == "" {
			e.HumanID = old.HumanID
		}
	}
	m.seq++
	e.ID = m.seq
	m.system = append(m.system, e)
	return e
}

// trimSystem keeps the newest SystemEventsKeep system rows; m is held.
func (m *memLogEvents) trimSystem() {
	if len(m.system) > SystemEventsKeep {
		m.system = slices.Clone(m.system[len(m.system)-SystemEventsKeep:])
	}
}

// UpsertSystemErrorGroup is LogEvents.UpsertSystemErrorGroup.
func (s *Memory) UpsertSystemErrorGroup(_ context.Context, e LogEvent) (LogEvent, error) {
	e, err := normErrorGroup(e)
	if err != nil {
		return LogEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.logEventsLocked()
	e = m.upsertGroup(e)
	m.trimSystem()
	return e, nil
}

// SystemEventsCursor is LogEvents.SystemEventsCursor.
func (s *Memory) SystemEventsCursor(_ context.Context, env string) (EvlogCursor, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c, ok := s.logEventsLocked().cursors[env]; ok {
		return c, nil
	}
	return EvlogCursor{Env: env}, nil
}

// PutSystemErrorGroups is LogEvents.PutSystemErrorGroups.
func (s *Memory) PutSystemErrorGroups(_ context.Context, p EvlogPut) (EvlogCursor, error) {
	groups, err := checkEvlogPut(p)
	if err != nil {
		return EvlogCursor{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.logEventsLocked()
	cur, ok := m.cursors[p.Env]
	if (!ok && p.Gen != 0) || (ok && (cur.Gen != p.Gen || !cur.ReadUntil.Equal(p.From))) {
		return EvlogCursor{}, ErrEvlogCursorMoved
	}
	cur = EvlogCursor{Env: p.Env, ReadUntil: p.To.UTC().Truncate(time.Microsecond), Gen: cur.Gen + 1, ByActor: p.Actor}
	if m.cursors == nil {
		m.cursors = map[string]EvlogCursor{}
	}
	m.cursors[p.Env] = cur
	for _, g := range groups {
		m.upsertGroup(g)
	}
	m.trimSystem()
	return cur, nil
}

// LinkSystemErrorGroup is LogEvents.LinkSystemErrorGroup.
func (s *Memory) LinkSystemErrorGroup(_ context.Context, fingerprint, issueKey string) (LogEvent, error) {
	if err := checkEvlogLink(fingerprint, issueKey); err != nil {
		return LogEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.logEventsLocked()
	i := slices.IndexFunc(m.system, func(r LogEvent) bool { return r.Fingerprint == fingerprint })
	if i < 0 {
		return LogEvent{}, ErrNotFound
	}
	m.system[i].IssueKey, m.system[i].IssueN = issueKey, m.system[i].N
	return m.system[i], nil
}
