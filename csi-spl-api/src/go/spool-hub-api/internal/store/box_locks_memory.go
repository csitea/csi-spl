package store

import (
	"context"
	"sort"
	"time"
)

// Memory side of box_locks.go (rdb 0213, spec 025 box owner lock, row B1).
// No cache: every load verifies the stored row.

// memBoxLocks is box_locks and box_lock_audit, guarded by Memory.mu.
type memBoxLocks struct {
	locks map[[2]string]BoxLock
	audit []BoxLockAudit
}

// boxLocksLocked answers the tables, made on first use; s.mu is held.
func (s *Memory) boxLocksLocked() *memBoxLocks {
	if s.boxLocks == nil {
		s.boxLocks = &memBoxLocks{locks: map[[2]string]BoxLock{}}
	}
	return s.boxLocks
}

// BoxLock implements BoxLockStore.
func (s *Memory) BoxLock(_ context.Context, tenant, box string) (*BoxLock, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	row, ok := s.boxLocksLocked().locks[[2]string{tenant, box}]
	if !ok {
		return nil, nil
	}
	l := row.clone()
	if verifyLoaded(l) {
		s.recordBoxLockAuditLocked(tamperAudit(l), s.now().UTC())
	}
	return l, nil
}

// CreateBoxLock implements BoxLockStore.
func (s *Memory) CreateBoxLock(_ context.Context, l BoxLock, by string, now time.Time) error {
	if err := checkTenant(l.TenantID); err != nil {
		return err
	}
	if err := VerifyBoxLock(l); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[l.TenantID]; !ok {
		return ErrNotFound
	}
	t := s.boxLocksLocked()
	k := [2]string{l.TenantID, l.BoxID}
	if _, ok := t.locks[k]; ok {
		return ErrBoxLockExists
	}
	now = now.UTC()
	l.CreatedAt, l.UpdatedAt, l.Tampered = now, now, false
	t.locks[k] = *l.clone()
	s.recordBoxLockAuditLocked(BoxLockAudit{TenantID: l.TenantID, BoxID: l.BoxID, HumanID: by,
		Path: "create", Verdict: BoxLockCreated}, now)
	return nil
}

// ChangeBoxLock implements BoxLockStore.
func (s *Memory) ChangeBoxLock(_ context.Context, l BoxLock, by string, now time.Time) error {
	if err := checkTenant(l.TenantID); err != nil {
		return err
	}
	if err := VerifyBoxLock(l); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.boxLocksLocked()
	k := [2]string{l.TenantID, l.BoxID}
	prev, ok := t.locks[k]
	if !ok {
		return ErrNotFound
	}
	if err := checkBoxLockChange(prev, l); err != nil {
		return err
	}
	now = now.UTC()
	l.CreatedAt, l.UpdatedAt, l.Tampered = prev.CreatedAt, now, false
	t.locks[k] = *l.clone()
	s.recordBoxLockAuditLocked(BoxLockAudit{TenantID: l.TenantID, BoxID: l.BoxID, HumanID: by,
		Path: "change", Verdict: BoxLockChanged}, now)
	return nil
}

// LiftBoxLock implements BoxLockStore.
func (s *Memory) LiftBoxLock(_ context.Context, tenant, box, by string, now time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.boxLocksLocked()
	k := [2]string{tenant, box}
	if _, ok := t.locks[k]; !ok {
		return ErrNotFound
	}
	delete(t.locks, k)
	s.recordBoxLockAuditLocked(BoxLockAudit{TenantID: tenant, BoxID: box, HumanID: by,
		Path: "lift", Verdict: BoxLockLifted}, now.UTC())
	return nil
}

// RecordBoxLockAudit implements BoxLockStore.
func (s *Memory) RecordBoxLockAudit(_ context.Context, a BoxLockAudit, now time.Time) error {
	if err := checkBoxLockAudit(a); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[a.TenantID]; !ok {
		return ErrNotFound
	}
	s.recordBoxLockAuditLocked(a, now.UTC())
	return nil
}

// recordBoxLockAuditLocked bumps the row of a's key written within the
// window, else appends one; s.mu is held.
func (s *Memory) recordBoxLockAuditLocked(a BoxLockAudit, now time.Time) {
	t := s.boxLocksLocked()
	for i := range t.audit {
		if sameAuditKey(t.audit[i], a, now) {
			t.audit[i].Count++
			t.audit[i].LastAt = now
			return
		}
	}
	a.FirstAt, a.LastAt, a.Count = now, now, 1
	t.audit = append(t.audit, a)
}

// BoxLockAudits implements BoxLockStore.
func (s *Memory) BoxLockAudits(_ context.Context, tenant, box string, limit int) ([]BoxLockAudit, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []BoxLockAudit
	for _, a := range s.boxLocksLocked().audit {
		if a.TenantID == tenant && a.BoxID == box {
			out = append(out, a)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].LastAt.After(out[j].LastAt) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
