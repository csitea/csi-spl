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
