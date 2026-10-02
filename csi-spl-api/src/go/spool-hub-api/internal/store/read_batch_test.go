package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Perf round 4, G4: GetEditable and CardState read as one tenant batch, not
// in a BEGIN / COMMIT transaction. The batch keeps the RLS scope (another
// tenant's id is ErrNotFound) and the not-found mapping (an unknown or
// expired id is ErrNotFound).
func TestReadBatchKeepsScopeAndNotFound(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid, other := newTenant(t, s), newTenant(t, s)
			m := msgFor(tid, uuid4(), "box-b", now, now, `{"e":1}`)
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			if err := s.Enqueue(ctx, tid, m.MsgID, "box-b", now, m.ExpiresAt, 0); err != nil {
				t.Fatal(err)
			}
			e, err := s.GetEditable(ctx, tid, m.MsgID, now)
			if err != nil || e.MsgID != m.MsgID || e.TaskID != m.TaskID || e.Body != "hi" {
				t.Fatalf("GetEditable: %+v %v", e, err)
			}
			if len(e.Deliveries) != 1 || e.Deliveries[0].ToBox != "box-b" {
				t.Fatalf("GetEditable deliveries: %+v", e.Deliveries)
			}
			c, err := s.CardState(ctx, tid, m.MsgID, now)
			if err != nil || c.MsgID != m.MsgID || c.TaskID != m.TaskID || !c.ArchivedAt.IsZero() {
				t.Fatalf("CardState: %+v %v", c, err)
			}
			for _, miss := range []struct {
				name, tenant, id string
				at               time.Time
			}{
				{"another tenant", other, m.MsgID, now},
				{"unknown id", tid, uuid4(), now},
				{"expired", tid, m.MsgID, m.ExpiresAt.Add(time.Second)},
			} {
				if e, err := s.GetEditable(ctx, miss.tenant, miss.id, miss.at); !errors.Is(err, ErrNotFound) || e.MsgID != "" {
					t.Fatalf("GetEditable %s: %+v %v", miss.name, e, err)
				}
				if c, err := s.CardState(ctx, miss.tenant, miss.id, miss.at); !errors.Is(err, ErrNotFound) || c.MsgID != "" {
					t.Fatalf("CardState %s: %+v %v", miss.name, c, err)
				}
			}
		})
	}
}
