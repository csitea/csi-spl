package store

import (
	"context"
	"encoding/json"
	"sort"
	"time"
)

// memRealm is Memory's rdb 0168 personal schema, guarded by Memory.mu, each
// keyed by person. The receipt copy (T004) writes receipts and due.
type memRealm struct {
	profiles map[string]RealmProfile
	limits   map[string]map[string]RealmLimits // valid_from -> row
	receipts map[string][]RealmReceipt
	due      map[string]map[string]RealmReceiptDue // workspace_id -> receipt_due row
}

func (r *memRealm) init() {
	if r.profiles == nil {
		r.profiles = map[string]RealmProfile{}
		r.limits = map[string]map[string]RealmLimits{}
		r.receipts = map[string][]RealmReceipt{}
		r.due = map[string]map[string]RealmReceiptDue{}
	}
}

// realmLocked is checkPerson plus, for a write, the FK of rdb 0168 (no such
// human = ErrNotFound).
func (s *Memory) realmLocked(person string, write bool) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	s.realm.init()
	if write {
		s.hum.init()
		if _, ok := s.hum.humans[person]; !ok {
			return ErrNotFound
		}
	}
	return nil
}

// RealmProfileOf is Realm.RealmProfileOf.
func (s *Memory) RealmProfileOf(_ context.Context, person string) (RealmProfile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, false); err != nil {
		return RealmProfile{}, err
	}
	p, ok := s.realm.profiles[person]
	if !ok {
		return RealmProfile{CommPrefs: json.RawMessage(`{}`)}, nil
	}
	p.CommPrefs = append(json.RawMessage(nil), p.CommPrefs...)
	return p, nil
}

// PutRealmProfile is Realm.PutRealmProfile.
func (s *Memory) PutRealmProfile(_ context.Context, person string, p RealmProfile, now time.Time) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	p, err := normalizeRealmProfile(p)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, true); err != nil {
		return err
	}
	p.CommPrefs = append(json.RawMessage(nil), p.CommPrefs...)
	p.UpdatedAt = now.UTC()
	s.realm.profiles[person] = p
	return nil
}

// AppendRealmLimits is Realm.AppendRealmLimits.
func (s *Memory) AppendRealmLimits(_ context.Context, person string, l RealmLimits, now time.Time) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	if err := checkRealmLimits(l); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, true); err != nil {
		return err
	}
	if s.realm.limits[person] == nil {
		s.realm.limits[person] = map[string]RealmLimits{}
	}
	l.DayLimitMinutes, l.WeekLimitMinutes = copyInt(l.DayLimitMinutes), copyInt(l.WeekLimitMinutes)
	l.UpdatedAt = now.UTC()
	s.realm.limits[person][l.ValidFrom] = l
	return nil
}

func copyInt(p *int) *int {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

// realmLimitsLocked is the person's rows, oldest valid_from first.
func (s *Memory) realmLimitsLocked(person string) []RealmLimits {
	out := make([]RealmLimits, 0, len(s.realm.limits[person]))
	for _, l := range s.realm.limits[person] {
		l.DayLimitMinutes, l.WeekLimitMinutes = copyInt(l.DayLimitMinutes), copyInt(l.WeekLimitMinutes)
		out = append(out, l)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ValidFrom < out[j].ValidFrom })
	return out
}

// RealmLimitsHistory is Realm.RealmLimitsHistory.
func (s *Memory) RealmLimitsHistory(_ context.Context, person string) ([]RealmLimits, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, false); err != nil {
		return nil, err
	}
	out := s.realmLimitsLocked(person)
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

// RealmLimitsOn is Realm.RealmLimitsOn.
func (s *Memory) RealmLimitsOn(_ context.Context, person, day string) (RealmLimits, bool, error) {
	if err := checkPerson(person); err != nil {
		return RealmLimits{}, false, err
	}
	if err := checkRealmDay(day); err != nil {
		return RealmLimits{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, false); err != nil {
		return RealmLimits{}, false, err
	}
	rows := s.realmLimitsLocked(person)
	for i := len(rows) - 1; i >= 0; i-- {
		if rows[i].ValidFrom <= day {
			return rows[i], true, nil
		}
	}
	return RealmLimits{}, false, nil
}

// RealmReceipts is Realm.RealmReceipts.
func (s *Memory) RealmReceipts(_ context.Context, person string) ([]RealmReceipt, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, false); err != nil {
		return nil, err
	}
	newest := map[[4]string]RealmReceipt{}
	for _, r := range s.realm.receipts[person] {
		k := [4]string{r.WorkspaceID, r.Day, r.Label, r.Kind}
		if old, ok := newest[k]; !ok || r.Rev > old.Rev {
			newest[k] = r
		}
	}
	var out []RealmReceipt
	for _, r := range newest {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.WorkspaceID != b.WorkspaceID {
			return a.WorkspaceID < b.WorkspaceID
		}
		if a.Day != b.Day {
			return a.Day < b.Day
		}
		if a.Label != b.Label {
			return a.Label < b.Label
		}
		return a.Kind < b.Kind
	})
	return out, nil
}

// DeleteRealmReceipts is Realm.DeleteRealmReceipts.
func (s *Memory) DeleteRealmReceipts(_ context.Context, person, workspaceID string) (int, error) {
	if err := checkPerson(person); err != nil {
		return 0, err
	}
	if err := checkRealmWorkspace(workspaceID); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, false); err != nil {
		return 0, err
	}
	keep := s.realm.receipts[person][:0]
	n := 0
	for _, r := range s.realm.receipts[person] {
		if r.WorkspaceID == workspaceID {
			n++
			continue
		}
		keep = append(keep, r)
	}
	s.realm.receipts[person] = keep
	if d, ok := s.realm.due[person][workspaceID]; ok && d.DoneAt == nil {
		done := s.now().UTC()
		d.DoneAt = &done
		s.realm.due[person][workspaceID] = d
	}
	return n, nil
}
