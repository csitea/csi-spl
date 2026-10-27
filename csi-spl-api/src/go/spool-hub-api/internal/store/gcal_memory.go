package store

import (
	"context"
	"maps"
	"sort"
	"time"
)

// memGcal is the Memory store's Gcal (rdb 0217, spec 149 B2), for hub tests
// and a hub without Postgres. Same rules as the Postgres one, under s.mu.
type memGcal struct {
	conns map[string]*GcalConnection         // connection id -> connection
	toks  map[string]GcalTokens              // connection id -> sealed tokens
	maps  map[string]map[string]GcalEventMap // connection id -> event id -> row
}

// gcalLocked returns the lazily made Google Calendar state; s.mu must be held.
func (s *Memory) gcalLocked() *memGcal {
	if s.gcal == nil {
		s.gcal = &memGcal{conns: map[string]*GcalConnection{}, toks: map[string]GcalTokens{},
			maps: map[string]map[string]GcalEventMap{}}
	}
	return s.gcal
}

// member is (tenant, human)'s connection, or nil.
func (g *memGcal) member(tenant, human string) *GcalConnection {
	for _, c := range g.conns {
		if c.Tenant == tenant && c.Human == human {
			return c
		}
	}
	return nil
}

// fenced is the connection that still holds lease l, or nil.
func (g *memGcal) fenced(l GcalLease) *GcalConnection {
	c, ok := g.conns[l.ConnectionID]
	if !ok || c.Tenant != l.Tenant || c.Human != l.Human || c.SyncLeaseUntil == nil || !c.SyncLeaseUntil.Equal(l.Until) {
		return nil
	}
	return c
}

func memTime(t time.Time) *time.Time { return &t }

// ConnectGcal implements Gcal on the Memory store (rdb 0217).
func (s *Memory) ConnectGcal(_ context.Context, c GcalConnection, tok GcalTokens, now time.Time) (GcalConnection, error) {
	if !gcalConnectOK(c, tok) {
		return GcalConnection{}, ErrInvalidGcal
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[c.Tenant]; !ok {
		return GcalConnection{}, ErrNotFound
	}
	g := s.gcalLocked()
	cur := g.member(c.Tenant, c.Human)
	if cur == nil {
		cur = &GcalConnection{ID: memUUID(), Tenant: c.Tenant, Human: c.Human, GoogleEmail: c.GoogleEmail, CreatedAt: now}
		g.conns[cur.ID] = cur
	}
	if cur.GoogleEmail != c.GoogleEmail {
		cur.CalendarID, cur.SyncToken, cur.OutCursor, cur.SourceSync = "", "", nil, nil
		cur.WatchChannelID, cur.WatchResourceID, cur.WatchExpiry = "", "", nil
		delete(g.maps, cur.ID)
	}
	cur.GoogleEmail, cur.Status, cur.StatusDetail = c.GoogleEmail, GcalConnected, ""
	cur.KMSKeyID, cur.AccessExpiry = tok.KMSKeyID, tok.AccessExpiry
	cur.DueAt, cur.SyncLeaseUntil, cur.UpdatedAt = now, nil, now
	g.toks[cur.ID] = tok
	return *cur, nil
}

// GcalConnection implements Gcal on the Memory store (rdb 0217).
func (s *Memory) GcalConnection(_ context.Context, tenant, human string) (GcalConnection, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.gcalLocked().member(tenant, human); c != nil {
		return *c, nil
	}
	return GcalConnection{}, ErrNotFound
}

// GcalTokens implements Gcal on the Memory store (rdb 0217).
func (s *Memory) GcalTokens(_ context.Context, tenant, human string) (GcalTokens, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := s.gcalLocked()
	if c := g.member(tenant, human); c != nil {
		return g.toks[c.ID], nil
	}
	return GcalTokens{}, ErrNotFound
}

// DeleteGcalConnection implements Gcal on the Memory store (rdb 0217).
func (s *Memory) DeleteGcalConnection(_ context.Context, tenant, human string) (GcalConnection, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := s.gcalLocked()
	c := g.member(tenant, human)
	if c == nil {
		return GcalConnection{}, ErrNotFound
	}
	delete(g.conns, c.ID)
	delete(g.toks, c.ID)
	delete(g.maps, c.ID)
	return *c, nil
}

// MarkGcalDue implements Gcal on the Memory store (rdb 0217).
func (s *Memory) MarkGcalDue(_ context.Context, tenant, human string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.gcalLocked().member(tenant, human)
	if c == nil {
		return ErrNotFound
	}
	c.DueAt, c.UpdatedAt = now, now
	return nil
}

// GcalEventMaps implements Gcal on the Memory store (rdb 0217).
func (s *Memory) GcalEventMaps(_ context.Context, tenant, human string) ([]GcalEventMap, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := s.gcalLocked()
	out := []GcalEventMap{}
	if c := g.member(tenant, human); c != nil {
		for _, m := range g.maps[c.ID] {
			out = append(out, m)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].EventID < out[j].EventID })
	return out, nil
}

// ClaimGcalConnection implements Gcal on the Memory store (rdb 0217).
func (s *Memory) ClaimGcalConnection(_ context.Context, now time.Time, lease time.Duration) (GcalConnection, GcalLease, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best *GcalConnection
	for _, c := range s.gcalLocked().conns {
		if c.Status != GcalConnected || c.DueAt.After(now) || (c.SyncLeaseUntil != nil && !c.SyncLeaseUntil.Before(now)) {
			continue
		}
		if best == nil || c.DueAt.Before(best.DueAt) || (c.DueAt.Equal(best.DueAt) && c.ID < best.ID) {
			best = c
		}
	}
	if best == nil {
		return GcalConnection{}, GcalLease{}, ErrNotFound
	}
	best.SyncLeaseUntil = memTime(gcalLeaseUntil(now, lease))
	return *best, GcalLease{Tenant: best.Tenant, Human: best.Human, ConnectionID: best.ID, Until: *best.SyncLeaseUntil}, nil
}

// ClaimGcalMember implements Gcal on the Memory store (rdb 0217).
func (s *Memory) ClaimGcalMember(_ context.Context, tenant, human string, now time.Time, lease time.Duration) (GcalConnection, GcalLease, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.gcalLocked().member(tenant, human)
	if c == nil || c.Status == GcalRevoked || (c.SyncLeaseUntil != nil && !c.SyncLeaseUntil.Before(now)) {
		return GcalConnection{}, GcalLease{}, ErrNotFound
	}
	c.SyncLeaseUntil = memTime(gcalLeaseUntil(now, lease))
	return *c, GcalLease{Tenant: c.Tenant, Human: c.Human, ConnectionID: c.ID, Until: *c.SyncLeaseUntil}, nil
}

// GcalConnectionByWatch implements Gcal on the Memory store (rdb 0217).
func (s *Memory) GcalConnectionByWatch(_ context.Context, watchChannelID string) (GcalConnection, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.gcalLocked().conns {
		if watchChannelID != "" && c.WatchChannelID == watchChannelID {
			return *c, nil
		}
	}
	return GcalConnection{}, ErrNotFound
}

// gcalSet runs set on the connection that still holds lease l.
func (s *Memory) gcalSet(l GcalLease, set func(g *memGcal, c *GcalConnection) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := s.gcalLocked()
	c := g.fenced(l)
	if c == nil {
		return ErrGcalLeaseLost
	}
	return set(g, c)
}

// RenewGcalLease implements Gcal on the Memory store (rdb 0217).
func (s *Memory) RenewGcalLease(_ context.Context, l GcalLease, now time.Time, lease time.Duration) (GcalLease, error) {
	next := l
	next.Until = gcalLeaseUntil(now, lease)
	return next, s.gcalSet(l, func(_ *memGcal, c *GcalConnection) error {
		c.SyncLeaseUntil = memTime(next.Until)
		return nil
	})
}

// SetGcalTokens implements Gcal on the Memory store (rdb 0217).
func (s *Memory) SetGcalTokens(_ context.Context, l GcalLease, tok GcalTokens, now time.Time) error {
	if !gcalTokensOK(tok) {
		return ErrInvalidGcal
	}
	return s.gcalSet(l, func(g *memGcal, c *GcalConnection) error {
		g.toks[c.ID] = tok
		c.KMSKeyID, c.AccessExpiry, c.UpdatedAt = tok.KMSKeyID, tok.AccessExpiry, now
		return nil
	})
}

// SetGcalCalendar implements Gcal on the Memory store (rdb 0217).
func (s *Memory) SetGcalCalendar(_ context.Context, l GcalLease, calendarID string, now time.Time) error {
	if len(calendarID) > 255 {
		return ErrInvalidGcal
	}
	return s.gcalSet(l, func(_ *memGcal, c *GcalConnection) error {
		c.CalendarID, c.UpdatedAt = calendarID, now
		return nil
	})
}

// SetGcalStatus implements Gcal on the Memory store (rdb 0217).
func (s *Memory) SetGcalStatus(_ context.Context, l GcalLease, status, detail string, now time.Time) error {
	if !gcalStatusOK(status, detail) {
		return ErrInvalidGcal
	}
	return s.gcalSet(l, func(_ *memGcal, c *GcalConnection) error {
		c.Status, c.StatusDetail, c.UpdatedAt = status, detail, now
		return nil
	})
}

// SetGcalWatch implements Gcal on the Memory store (rdb 0217).
func (s *Memory) SetGcalWatch(_ context.Context, l GcalLease, w GcalWatch, now time.Time) error {
	if w.ChannelID != "" && !calendarIDRe.MatchString(w.ChannelID) {
		return ErrInvalidGcal
	}
	return s.gcalSet(l, func(g *memGcal, c *GcalConnection) error {
		if w.ChannelID != "" {
			for _, o := range g.conns {
				if o.ID != c.ID && o.WatchChannelID == w.ChannelID {
					return ErrConflict // rdb 0217 gcal_connections_watch
				}
			}
		} else {
			w = GcalWatch{Expiry: w.Expiry}
		}
		c.WatchChannelID, c.WatchResourceID, c.WatchExpiry, c.UpdatedAt = w.ChannelID, w.ResourceID, w.Expiry, now
		return nil
	})
}

// PutGcalEventMap implements Gcal on the Memory store (rdb 0217).
func (s *Memory) PutGcalEventMap(_ context.Context, l GcalLease, m GcalEventMap, now time.Time) error {
	if !gcalMapOK(m) {
		return ErrInvalidGcal
	}
	return s.gcalSet(l, func(g *memGcal, c *GcalConnection) error {
		rows := g.maps[c.ID]
		if rows == nil {
			rows = map[string]GcalEventMap{}
			g.maps[c.ID] = rows
		}
		for id, o := range rows {
			if id != m.EventID && o.GoogleID == m.GoogleID {
				return ErrConflict
			}
		}
		m.SyncedAt = now
		rows[m.EventID] = m
		return nil
	})
}

// DeleteGcalEventMap implements Gcal on the Memory store (rdb 0217).
func (s *Memory) DeleteGcalEventMap(_ context.Context, l GcalLease, eventID string) error {
	if !calendarIDRe.MatchString(eventID) {
		return ErrInvalidGcal
	}
	return s.gcalSet(l, func(g *memGcal, c *GcalConnection) error {
		delete(g.maps[c.ID], eventID)
		return nil
	})
}

// FinishGcalSync implements Gcal on the Memory store (rdb 0217).
func (s *Memory) FinishGcalSync(_ context.Context, l GcalLease, d GcalSyncDone, now time.Time) error {
	return s.gcalSet(l, func(_ *memGcal, c *GcalConnection) error {
		c.SyncToken = d.SyncToken
		if d.OutCursor != nil {
			c.OutCursor = memTime(*d.OutCursor)
		}
		if d.SourceSync != nil {
			c.SourceSync = maps.Clone(d.SourceSync)
		}
		c.LastSyncedAt, c.DueAt, c.SyncLeaseUntil, c.UpdatedAt = memTime(now), d.NextDue, nil, now
		return nil
	})
}
