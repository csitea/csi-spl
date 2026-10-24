package store

import (
	"context"
	"sort"
	"time"
)

// Memory side of dedicated.go (rdb 0219, spec 144 T002), guarded by s.mu.
// The memory Message has no is_private_scope field, so a topic's flag is
// kept per (tenant, task): every message of a flagged topic reads private,
// a message inserted after the flag included.
type memDedicated struct {
	bindings map[[3]string]DedicatedBinding // (tenant, agent, box)
	privCh   map[[2]string]time.Time        // (tenant, channel) -> private_scope_at
	privTask map[[2]string]bool             // (tenant, task)
}

// dedicatedLocked returns the lazily made state; s.mu must be held.
func (s *Memory) dedicatedLocked() *memDedicated {
	if s.dedicated == nil {
		s.dedicated = &memDedicated{bindings: map[[3]string]DedicatedBinding{},
			privCh: map[[2]string]time.Time{}, privTask: map[[2]string]bool{}}
	}
	return s.dedicated
}

// GetDedicatedBinding implements DedicatedStore.
func (s *Memory) GetDedicatedBinding(_ context.Context, tenant, agent, box string) (DedicatedBinding, error) {
	if err := checkTenant(tenant); err != nil {
		return DedicatedBinding{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.dedicatedLocked().bindings[[3]string{tenant, agent, box}]
	if !ok {
		return DedicatedBinding{}, ErrNotFound
	}
	return b, nil
}

// SetDedicatedBinding implements DedicatedStore.
func (s *Memory) SetDedicatedBinding(_ context.Context, b DedicatedBinding) (DedicatedBinding, error) {
	if err := checkBinding(&b, s.now()); err != nil {
		return DedicatedBinding{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[b.TenantID]; !ok {
		return DedicatedBinding{}, ErrNotFound // fk_dedicated_agents_tenant
	}
	d := s.dedicatedLocked()
	k := [3]string{b.TenantID, b.AgentID, b.BoxID}
	if got, ok := d.bindings[k]; ok {
		if got.ScopeType != b.ScopeType || got.ScopeID != b.ScopeID {
			return got, ErrDedicatedRebind
		}
		return got, nil
	}
	d.bindings[k] = b
	return b, nil
}

// RemoveDedicatedBinding implements DedicatedStore.
func (s *Memory) RemoveDedicatedBinding(_ context.Context, tenant, agent, box string) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d, k := s.dedicatedLocked(), [3]string{tenant, agent, box}
	if _, ok := d.bindings[k]; !ok {
		return ErrNotFound
	}
	delete(d.bindings, k)
	return nil
}

// ListDedicatedAgentsByScope implements DedicatedStore.
func (s *Memory) ListDedicatedAgentsByScope(_ context.Context, tenant, scopeType, scopeID string) ([]DedicatedBinding, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if err := checkScope(scopeType, scopeID); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []DedicatedBinding{}
	for k, b := range s.dedicatedLocked().bindings {
		if k[0] == tenant && b.ScopeType == scopeType && b.ScopeID == scopeID {
			out = append(out, b)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].AgentID != out[j].AgentID {
			return out[i].AgentID < out[j].AgentID
		}
		return out[i].BoxID < out[j].BoxID
	})
	return out, nil
}

// privateMsgLocked: m is flagged (its topic) or lives in a private channel.
func (s *Memory) privateMsgLocked(tenant string, m *Message) bool {
	d := s.dedicatedLocked()
	if d.privTask[[2]string{tenant, m.TaskID}] {
		return true
	}
	_, ok := d.privCh[[2]string{tenant, m.Channel}]
	return ok && m.Channel != ""
}

// IsPrivateScope implements DedicatedStore.
func (s *Memory) IsPrivateScope(_ context.Context, tenant, scopeType, scopeID string) (bool, error) {
	if err := checkTenant(tenant); err != nil {
		return false, err
	}
	if err := checkScope(scopeType, scopeID); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if scopeType == ScopeChannel {
		_, ok := s.dedicatedLocked().privCh[[2]string{tenant, scopeID}]
		return ok, nil
	}
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == scopeID && s.privateMsgLocked(tenant, m) {
			return true, nil
		}
	}
	return false, nil
}

// SetPrivateScope implements DedicatedStore.
func (s *Memory) SetPrivateScope(_ context.Context, tenant, scopeType, scopeID string, private bool, now time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if err := checkScope(scopeType, scopeID); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.dedicatedLocked()
	if scopeType == ScopeChannel {
		k := [2]string{tenant, scopeID}
		_, live := s.ch.rows[k]
		_, arch := s.ch.archived[k]
		if !live && !arch {
			return ErrNotFound
		}
		if private {
			d.privCh[k] = now.UTC()
		} else {
			delete(d.privCh, k)
		}
		return nil
	}
	found := false
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == scopeID {
			found = true
			break
		}
	}
	if !found {
		return ErrNotFound
	}
	if private {
		d.privTask[[2]string{tenant, scopeID}] = true
	} else {
		delete(d.privTask, [2]string{tenant, scopeID})
	}
	return nil
}

// dedicatedTailOKLocked is boxTaskDedicatedSQL for one message: agent on
// box reads m. s.mu must be held.
func (s *Memory) dedicatedTailOKLocked(tenant, box, agent string, m *Message) bool {
	b, ok := s.dedicatedLocked().bindings[[3]string{tenant, agent, box}]
	return dedicatedTailOK(b, ok, m.Channel, m.TaskID, s.privateMsgLocked(tenant, m))
}
