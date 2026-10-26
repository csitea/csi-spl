package store

import (
	"context"
	"time"
)

// Memory's contacts binding (contacts_sync.go), the same contract as the
// Postgres side, under s.mu. The bindings live in memContacts.binds
// (personal_contacts_memory.go), keyed by human: one binding per person,
// as rdb 0226's primary key.

// bindingInLocked is the human's binding in tenant, or nil; s.mu is held.
func (s *Memory) bindingInLocked(tenant, human string) *ContactsSync {
	b := s.contactsLocked().binds[human]
	if b == nil || b.Tenant != tenant {
		return nil
	}
	return b
}

// dropContactsSyncLocked removes the human's binding in tenant, never the
// contacts: rdb 0226's ON DELETE CASCADE from tenant_memberships and
// gcal_connections. Spec 154 B4 calls it where the memory store deletes a
// membership; s.mu is held.
func (s *Memory) dropContactsSyncLocked(tenant, human string) {
	if s.bindingInLocked(tenant, human) != nil {
		delete(s.contactsLocked().binds, human)
	}
}

// ContactsSyncIn is ContactsSyncs.ContactsSyncIn.
func (s *Memory) ContactsSyncIn(_ context.Context, tenant, human string) (ContactsSync, error) {
	if err := checkPerson(human); err != nil {
		return ContactsSync{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bindingInLocked(tenant, human)
	if b == nil {
		return ContactsSync{}, ErrNotFound
	}
	return *b, nil
}

// SetContactsSync is ContactsSyncs.SetContactsSync.
func (s *Memory) SetContactsSync(_ context.Context, tenant, human string, enabled bool, now time.Time) (ContactsSync, error) {
	if err := checkPerson(human); err != nil {
		return ContactsSync{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if b := s.bindingInLocked(tenant, human); b != nil {
		b.Enabled, b.UpdatedAt = enabled, now
		if enabled {
			b.DueAt = now
		}
		return *b, nil
	}
	if !enabled {
		return ContactsSync{}, ErrNotFound
	}
	// Postgres raises the unique violation before the foreign keys.
	binds := s.contactsLocked().binds
	if binds[human] != nil {
		return ContactsSync{}, ErrContactsSyncElsewhere
	}
	s.hum.init()
	if _, seat := s.hum.members[[2]string{tenant, human}]; !seat || s.gcalLocked().member(tenant, human) == nil {
		return ContactsSync{}, ErrNotFound
	}
	b := &ContactsSync{Human: human, Tenant: tenant, Enabled: true, DueAt: now, CreatedAt: now, UpdatedAt: now}
	binds[human] = b
	return *b, nil
}

// MarkContactsSyncDue is ContactsSyncs.MarkContactsSyncDue.
func (s *Memory) MarkContactsSyncDue(_ context.Context, tenant, human string, now time.Time) error {
	if err := checkPerson(human); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bindingInLocked(tenant, human)
	if b == nil || !b.Enabled {
		return ErrNotFound
	}
	if b.SyncLeaseUntil != nil && b.SyncLeaseUntil.After(now) {
		return ErrContactsSyncBusy
	}
	b.DueAt, b.UpdatedAt = now, now
	return nil
}

// ContactsSyncOf is ContactsSyncs.ContactsSyncOf.
func (s *Memory) ContactsSyncOf(_ context.Context, human string) (ContactsSync, error) {
	if err := checkPerson(human); err != nil {
		return ContactsSync{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.contactsLocked().binds[human]
	if b == nil {
		return ContactsSync{}, ErrNotFound
	}
	return *b, nil
}

// MarkContactsPurgePending is ContactsSyncs.MarkContactsPurgePending.
func (s *Memory) MarkContactsPurgePending(_ context.Context, persons []string, now time.Time) (int, error) {
	if err := checkContactsSyncPersons(persons); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	marked := map[string]bool{}
	for _, p := range persons {
		if b := s.contactsLocked().binds[p]; b != nil && !marked[p] {
			b.StatusDetail, b.UpdatedAt = ContactsPurgePendingDetail, now
			marked[p] = true
		}
	}
	return len(marked), nil
}

// ClaimContactsSync is ContactsSyncs.ClaimContactsSync: the binding due
// longest (then the lowest human id, as Postgres's ORDER BY) of every
// workspace whose Google connection is connected.
func (s *Memory) ClaimContactsSync(_ context.Context, now time.Time, lease time.Duration) (ContactsSync, ContactsLease, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best *ContactsSync
	for _, b := range s.contactsLocked().binds {
		if !s.contactsClaimableLocked(b, now) {
			continue
		}
		if best == nil || b.DueAt.Before(best.DueAt) || (b.DueAt.Equal(best.DueAt) && b.Human < best.Human) {
			best = b
		}
	}
	if best == nil {
		return ContactsSync{}, ContactsLease{}, ErrNotFound
	}
	best.SyncLeaseUntil = memTime(gcalLeaseUntil(now, lease))
	return *best, ContactsLease{Tenant: best.Tenant, Human: best.Human, Until: *best.SyncLeaseUntil}, nil
}

// contactsClaimableLocked is the claim's WHERE on one binding; s.mu is held.
func (s *Memory) contactsClaimableLocked(b *ContactsSync, now time.Time) bool {
	if !b.Enabled || b.DueAt.After(now) || (b.SyncLeaseUntil != nil && !b.SyncLeaseUntil.Before(now)) ||
		(b.BackoffUntil != nil && b.BackoffUntil.After(now)) {
		return false
	}
	c := s.gcalLocked().member(b.Tenant, b.Human)
	return c != nil && c.Status == GcalConnected
}

// contactsFencedSet runs set on the binding that still holds lease l, or is
// ErrContactsLeaseLost.
func (s *Memory) contactsFencedSet(l ContactsLease, set func(b *ContactsSync)) error {
	if !contactsLeaseOK(l) {
		return ErrContactsLeaseLost
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bindingInLocked(l.Tenant, l.Human)
	if b == nil || b.SyncLeaseUntil == nil || !b.SyncLeaseUntil.Equal(l.Until) {
		return ErrContactsLeaseLost
	}
	set(b)
	return nil
}

// RenewContactsLease is ContactsSyncs.RenewContactsLease.
func (s *Memory) RenewContactsLease(_ context.Context, l ContactsLease, now time.Time, lease time.Duration) (ContactsLease, error) {
	next := l
	next.Until = gcalLeaseUntil(now, lease)
	return next, s.contactsFencedSet(l, func(b *ContactsSync) { b.SyncLeaseUntil = memTime(next.Until) })
}

// SetContactsBackoff is ContactsSyncs.SetContactsBackoff.
func (s *Memory) SetContactsBackoff(_ context.Context, l ContactsLease, until *time.Time, detail string, now time.Time) error {
	if !contactsDetailOK(detail) {
		return ErrContactsSyncBad
	}
	return s.contactsFencedSet(l, func(b *ContactsSync) {
		b.BackoffUntil = nil
		if until != nil {
			b.BackoffUntil = memTime(contactTime(*until))
		}
		b.StatusDetail, b.UpdatedAt = detail, now
	})
}

// FinishContactsSync is ContactsSyncs.FinishContactsSync.
func (s *Memory) FinishContactsSync(_ context.Context, l ContactsLease, d ContactsSyncDone, now time.Time) error {
	return s.contactsFencedSet(l, func(b *ContactsSync) {
		b.SyncToken = d.SyncToken
		if d.OutCursor != nil {
			b.OutCursor = memTime(contactTime(*d.OutCursor))
		}
		b.LastSyncedAt, b.DueAt, b.SyncLeaseUntil, b.UpdatedAt = memTime(now), d.NextDue, nil, now
	})
}
