package store

import (
	"context"
	"sort"
	"strings"
	"time"
)

// Memory's contacts (personal_contacts.go), the same contract as the
// Postgres side, under s.mu. memContacts is the one Memory field of spec 154
// (memory.go); it holds the list here and the bindings of contacts_sync_memory.go.

// memContact is one personal.contacts row, its soft delete included.
type memContact struct {
	Contact
	deletedAt *time.Time
	deletedBy string
	etag      string // google_etag
	syncHash  string // sync_hash, "" = NULL
}

// memContacts is rdb 0226 on Memory.
type memContacts struct {
	byPerson map[string]map[string]*memContact // person -> contact id -> row
	binds    map[string]*ContactsSync          // human -> its binding (contacts_sync_memory.go)
}

// contactsLocked returns the lazily made contacts state; s.mu must be held.
func (s *Memory) contactsLocked() *memContacts {
	if s.contacts == nil {
		s.contacts = &memContacts{byPerson: map[string]map[string]*memContact{}, binds: map[string]*ContactsSync{}}
	}
	return s.contacts
}

// liveContactLocked is the person's live contact, or ErrNotFound; s.mu is held.
func (s *Memory) liveContactLocked(person, contactID string) (*memContact, error) {
	if err := checkContactIDs(person, contactID); err != nil {
		return nil, err
	}
	c, ok := s.contactsLocked().byPerson[person][strings.ToLower(contactID)]
	if !ok || c.deletedAt != nil {
		return nil, ErrNotFound
	}
	return c, nil
}

// sortedLiveContacts is the person's live contacts in created order; s.mu is held.
func (s *Memory) sortedLiveContacts(person string) []Contact {
	out := []Contact{}
	for _, c := range s.contactsLocked().byPerson[person] {
		if c.deletedAt == nil {
			out = append(out, c.Contact)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.Before(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// ListContacts is PersonalContacts.ListContacts.
func (s *Memory) ListContacts(_ context.Context, person string, q ContactQuery) (ContactPage, error) {
	if err := checkPerson(person); err != nil {
		return ContactPage{}, err
	}
	at, after, err := parseContactCursor(q.After)
	if err != nil {
		return ContactPage{}, err
	}
	words, limit := contactWords(q.Q), contactPageLimit(q)
	s.mu.Lock()
	defer s.mu.Unlock()
	var rows []Contact
	for _, c := range s.sortedLiveContacts(person) {
		if (after == "" || contactAfter(c, at, strings.ToLower(after))) && contactMatches(c, words) {
			rows = append(rows, c)
			if len(rows) > limit {
				break
			}
		}
	}
	return contactPageOf(rows, limit), nil
}

// ContactOf is PersonalContacts.ContactOf.
func (s *Memory) ContactOf(_ context.Context, person, contactID string) (Contact, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, err := s.liveContactLocked(person, contactID)
	if err != nil {
		return Contact{}, err
	}
	return c.Contact, nil
}

// CreateContact is PersonalContacts.CreateContact.
func (s *Memory) CreateContact(_ context.Context, person string, c Contact, now time.Time) (Contact, error) {
	if err := checkPerson(person); err != nil {
		return Contact{}, err
	}
	c, err := cleanContact(c)
	if err != nil {
		return Contact{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, true); err != nil {
		return Contact{}, err
	}
	now = contactTime(now)
	row := &memContact{Contact: Contact{ID: memUUID(), FirstName: c.FirstName, LastName: c.LastName,
		Email: c.Email, Phone: c.Phone, CreatedAt: now, UpdatedAt: now}}
	cs := s.contactsLocked()
	if cs.byPerson[person] == nil {
		cs.byPerson[person] = map[string]*memContact{}
	}
	cs.byPerson[person][row.ID] = row
	return row.Contact, nil
}

// PatchContact is PersonalContacts.PatchContact.
func (s *Memory) PatchContact(_ context.Context, person, contactID string, p ContactPatch, now time.Time) (Contact, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, err := s.liveContactLocked(person, contactID)
	if err != nil {
		return Contact{}, err
	}
	next, err := patchedContact(c.Contact, p)
	if err != nil {
		return Contact{}, err
	}
	next.UpdatedAt = contactTime(now)
	c.Contact = next
	return next, nil
}

// DeleteContact is PersonalContacts.DeleteContact.
func (s *Memory) DeleteContact(_ context.Context, person, contactID, by string, now time.Time) error {
	if err := checkContactDeleter(by); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, err := s.liveContactLocked(person, contactID)
	if err != nil {
		return err
	}
	if by == "" {
		delete(s.contactsLocked().byPerson[person], c.ID)
		return nil
	}
	at := contactTime(now)
	c.deletedAt, c.deletedBy = &at, by
	return nil
}

// ExportContacts is PersonalContacts.ExportContacts.
func (s *Memory) ExportContacts(_ context.Context, person string) ([]Contact, error) {
	if err := checkPerson(person); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sortedLiveContacts(person), nil
}

// EraseContacts is PersonalContacts.EraseContacts.
func (s *Memory) EraseContacts(_ context.Context, person string) (int, error) {
	if err := checkPerson(person); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cs := s.contactsLocked()
	n := len(cs.byPerson[person])
	delete(cs.byPerson, person)
	return n, nil
}

// PurgeDeletedContacts is PersonalContacts.PurgeDeletedContacts, the twin
// of rdb 0226's door: each person once, in person order.
func (s *Memory) PurgeDeletedContacts(_ context.Context, before time.Time) ([]ContactPurged, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pending := map[string]bool{}
	for person, rows := range s.contactsLocked().byPerson {
		for id, c := range rows {
			if c.deletedAt == nil || !c.deletedAt.Before(before) {
				continue
			}
			pending[person] = pending[person] || (c.deletedBy == ContactDeletedByMember && c.GoogleResource != "")
			delete(rows, id)
		}
	}
	out := []ContactPurged{}
	for person, p := range pending {
		out = append(out, ContactPurged{Person: person, PendingGoogle: p})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Person < out[j].Person })
	return out, nil
}

// changedAt is GREATEST(updated_at, COALESCE(deleted_at, updated_at)).
func (c *memContact) changedAt() time.Time {
	if c.deletedAt != nil && c.deletedAt.After(c.UpdatedAt) {
		return *c.deletedAt
	}
	return c.UpdatedAt
}

// ContactsChangedSince is ContactsCycle.ContactsChangedSince.
func (s *Memory) ContactsChangedSince(_ context.Context, person string, since *time.Time) ([]ContactOut, error) {
	if err := checkPerson(person); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []ContactOut{}
	for _, c := range s.contactsLocked().byPerson[person] {
		if (c.deletedAt != nil && c.deletedBy != ContactDeletedByMember) || (since != nil && !c.changedAt().After(*since)) {
			continue
		}
		out = append(out, ContactOut{Contact: c.Contact, GoogleETag: c.etag, SyncHash: c.syncHash,
			DeletedAt: c.deletedAt, ChangedAt: c.changedAt()})
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].ChangedAt.Equal(out[j].ChangedAt) {
			return out[i].ChangedAt.Before(out[j].ChangedAt)
		}
		return out[i].ID < out[j].ID
	})
	if len(out) > ContactsCycleMax {
		out = out[:ContactsCycleMax]
	}
	return out, nil
}

// LinkContact is ContactsCycle.LinkContact.
func (s *Memory) LinkContact(_ context.Context, person, contactID string, l ContactLink) (Contact, error) {
	l, err := cleanContactLink(l)
	if err != nil {
		return Contact{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, err := s.liveContactLocked(person, contactID)
	if err != nil {
		return Contact{}, err
	}
	if l.Resource != "" {
		for _, o := range s.contactsLocked().byPerson[person] {
			if o != c && o.GoogleAccount == l.Account && o.GoogleResource == l.Resource {
				return Contact{}, ErrConflict
			}
		}
	}
	c.GoogleAccount, c.GoogleResource, c.etag, c.syncHash = l.Account, l.Resource, l.ETag, l.SyncHash
	return c.Contact, nil
}

// DropDeletedContact is ContactsCycle.DropDeletedContact.
func (s *Memory) DropDeletedContact(_ context.Context, person, contactID string) error {
	if err := checkContactIDs(person, contactID); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rows := s.contactsLocked().byPerson[person]
	c, ok := rows[strings.ToLower(contactID)]
	if !ok || c.deletedAt == nil {
		return ErrNotFound
	}
	delete(rows, c.ID)
	return nil
}
