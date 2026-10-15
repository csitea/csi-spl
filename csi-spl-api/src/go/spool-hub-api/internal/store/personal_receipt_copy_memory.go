package store

import (
	"context"
)

// appendRealmReceipts is Memory's step 2 of the receipt copy, as
// personal_receipt_copy_postgres.go: a row already held for its (workspace,
// day, label, kind, rev) is kept, an open receipt_due row stays open.
func (s *Memory) appendRealmReceipts(_ context.Context, person, workspaceID string, rows []RealmReceipt, due RealmReceiptDue) (int, error) {
	if err := checkRealmWorkspace(workspaceID); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, true); err != nil {
		return 0, err
	}
	held := map[[5]string]bool{}
	for _, r := range s.realm.receipts[person] {
		held[realmMemKey(r)] = true
	}
	written := 0
	for _, r := range rows {
		r.WorkspaceID, r.Rev, r.CopiedAt = workspaceID, 0, due.DueAt.UTC()
		if k := realmMemKey(r); !held[k] {
			held[k] = true
			s.realm.receipts[person] = append(s.realm.receipts[person], r)
			written++
		}
	}
	if s.realm.due[person] == nil {
		s.realm.due[person] = map[string]RealmReceiptDue{}
	}
	if old, ok := s.realm.due[person][workspaceID]; ok && old.DoneAt == nil {
		if old.LastOpenFrom != "" && (due.LastOpenFrom == "" || old.LastOpenFrom < due.LastOpenFrom) {
			due.LastOpenFrom = old.LastOpenFrom
		}
		due.DoneAt = nil
	}
	s.realm.due[person][workspaceID] = due
	return written, nil
}

// realmMemKey is hours_receipts' key past person_id.
func realmMemKey(r RealmReceipt) [5]string {
	return [5]string{r.WorkspaceID, r.Day, r.Label, r.Kind, string(rune('0' + r.Rev))}
}
