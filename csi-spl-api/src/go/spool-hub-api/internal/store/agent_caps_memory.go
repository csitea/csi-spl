package store

import (
	"context"
	"time"
)

// Memory side of agent_caps.go (rdb 0212, spec 147).

// memCap is one tenant_agent_caps row.
type memCap struct {
	maxLive int
	at      time.Time
	by      string
}

// capRosterLocked is the tenant's roster pairs with their box's presence at
// now; s.mu is held.
func (s *Memory) capRosterLocked(tenant string, now time.Time) []capRosterRow {
	var out []capRosterRow
	for k, agents := range s.roster {
		if k[0] != tenant {
			continue
		}
		live := boxLive(s.boxes[k], now)
		for _, a := range agents {
			out = append(out, capRosterRow{box: k[1], agent: a, live: live})
		}
	}
	return out
}

// vendorCapGateLocked is Postgres.vendorCapGate; s.mu is held.
func (s *Memory) vendorCapGateLocked(tenant, box string, agents []string, now time.Time) error {
	rows := s.agentCaps[tenant]
	if len(rows) == 0 || len(agents) == 0 {
		return nil
	}
	caps := map[string]int{}
	for v, c := range rows {
		caps[v] = c.maxLive
	}
	return overVendorCap(tenant, box, caps, s.capRosterLocked(tenant, now), agents)
}

func (s *Memory) agentCapsLocked(tenant string) AgentCaps {
	c := AgentCaps{TenantID: tenant, Caps: map[string]int{}}
	for v, r := range s.agentCaps[tenant] {
		c.Caps[v] = r.maxLive
		if r.at.After(c.UpdatedAt) {
			c.UpdatedAt, c.UpdatedBy = r.at, r.by
		}
	}
	return c
}

// AgentCaps implements AgentCapStore.
func (s *Memory) AgentCaps(_ context.Context, tenant string) (AgentCaps, error) {
	if err := checkTenant(tenant); err != nil {
		return AgentCaps{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.agentCapsLocked(tenant), nil
}

// LiveAgents implements AgentCapStore.
func (s *Memory) LiveAgents(_ context.Context, tenant string, now time.Time) (map[string]int, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return liveByVendor(s.capRosterLocked(tenant, now)), nil
}

// SetAgentCaps implements AgentCapStore.
func (s *Memory) SetAgentCaps(_ context.Context, tenant string, caps map[string]*int, by AgentCapActor, now time.Time) (AgentCaps, error) {
	if err := checkTenant(tenant); err != nil {
		return AgentCaps{}, err
	}
	if err := checkAgentCaps(caps); err != nil {
		return AgentCaps{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return AgentCaps{}, ErrNotFound
	}
	now = now.UTC()
	for _, c := range agentCapChanges(tenant, s.agentCapsLocked(tenant).Caps, caps, by, now) {
		if c.n == nil {
			delete(s.agentCaps[tenant], c.vendor)
		} else {
			if s.agentCaps[tenant] == nil {
				s.agentCaps[tenant] = map[string]memCap{}
			}
			s.agentCaps[tenant][c.vendor] = memCap{maxLive: *c.n, at: now, by: by.Hum}
		}
		s.opAudit = append(s.opAudit, c.audit)
	}
	return s.agentCapsLocked(tenant), nil
}
