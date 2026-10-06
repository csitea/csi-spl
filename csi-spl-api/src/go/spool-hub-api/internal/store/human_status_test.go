package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// rdb 0141 human_status (spec 096 L1), Postgres only. The table holds a
// member's manual status per workspace: workspace B reads none of A's rows,
// the CHECKs refuse what the hub must never store, and the row goes with
// the membership. CONTROL: A reads its own row.
func TestHumanStatusTable(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	a, b := seedTenantAll(t, pg), seedTenantAll(t, pg)

	count := func(tenant, human string) int {
		var n int
		if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM human_status WHERE human_id = $1`, human).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := count(a.tenant, a.humanID); n != 1 {
		t.Fatalf("CONTROL: workspace A reads %d of its own status rows, want 1", n)
	}
	if n := count(b.tenant, a.humanID); n != 0 {
		t.Fatalf("workspace B reads %d of A's status rows, want 0", n)
	}

	put := func(tenant, human, status string, note any) error {
		return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO human_status (tenant_id, human_id, status, note, until_at, set_by)
				VALUES ($1, $2, $3, $4, $5, $2)
				ON CONFLICT (tenant_id, human_id) DO UPDATE SET status = EXCLUDED.status, note = EXCLUDED.note`,
				tenant, human, status, note, now.Add(time.Hour))
			return err
		})
	}
	for name, err := range map[string]error{
		"available is no row": put(a.tenant, a.humanID, "available", nil),
		"unknown state":       put(a.tenant, a.humanID, "away", nil),
		"note over 80":        put(a.tenant, a.humanID, "busy", strings.Repeat("x", 81)),
		"not a member":        put(a.tenant, "HUM-999999999", "busy", nil),
		"A's member from B":   put(b.tenant, a.humanID, "busy", nil),
	} {
		if err == nil {
			t.Errorf("%s: the insert was accepted", name)
		}
	}
	if err := put(a.tenant, a.humanID, "busy", strings.Repeat("x", 80)); err != nil {
		t.Fatalf("CONTROL: busy with an 80-character note: %v", err)
	}

	// Leaving the workspace removes the status (FK on the membership).
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`, a.tenant, a.humanID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if n := count(a.tenant, a.humanID); n != 0 {
		t.Fatalf("after the membership went: %d status rows, want 0", n)
	}
}
