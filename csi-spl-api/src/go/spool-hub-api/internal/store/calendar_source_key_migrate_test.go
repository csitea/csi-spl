package store

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// rdb 0156 (specs/112 RDB-1, spec section 4.2): calendar_events.source_key,
// unique per workspace when set, and the kinds goal and milestone. Postgres
// only: the memory store does not carry the index.
//
// Pair, n=8 inserts on one fresh database:
//   - refused (n=2): a second row with the same (tenant_id, source_key) is
//     23505 on calendar_events_source_key; a kind outside the nine is 23514
//     on calendar_events_kind_check.
//   - control (n=6): the first keyed row; two rows with a NULL key; the same
//     key in another workspace; kind goal; kind milestone.
func TestCalendarSourceKey0156(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)

	insert := func(tenant, kind string, key any) error {
		return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO calendar_events
				(tenant_id, title, kind, starts_at, ends_at, creator_type, creator_id, source_key)
				VALUES ($1, 'rdb 0156', $2, now(), now(), 'system', 'roadmap-sync', $3)`, tenant, kind, key)
			return err
		})
	}
	stored := func(what, tenant, kind string, key any) {
		t.Helper()
		if err := insert(tenant, kind, key); err != nil {
			t.Fatalf("control, %s: %v", what, err)
		}
	}
	refused := func(what, tenant, kind string, key any, code, constraint string) {
		t.Helper()
		var pe *pgconn.PgError
		if err := insert(tenant, kind, key); !errors.As(err, &pe) || pe.Code != code || pe.ConstraintName != constraint {
			t.Fatalf("%s: %v, want %s on %s", what, err, code, constraint)
		}
	}

	stored("first keyed row", a, "release", "release:v1.3.0")
	refused("same key twice in one workspace", a, "release", "release:v1.3.0", "23505", "calendar_events_source_key")
	stored("first NULL key", a, "other", nil)
	stored("second NULL key", a, "other", nil)
	stored("same key in another workspace", b, "release", "release:v1.3.0")
	stored("kind goal", a, "goal", "goal:G01:deadline")
	stored("kind milestone", a, "milestone", "goal:G01:m:first")
	refused("kind outside the nine", a, "roadmap", nil, "23514", "calendar_events_kind_check")
}
