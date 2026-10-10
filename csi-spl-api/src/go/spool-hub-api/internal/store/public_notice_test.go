package store

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

const publicChannelFile = "0173_default_channel_public.sql"

// rdb 0173 on Postgres: the tenant trigger seeds #public, the file applies a
// second time and changes nothing (one #public per tenant, every tenant has
// one), and spool_public_notice_id is store.PublicNoticeID.
// CONTROL: drop 'public' from the trigger's VALUES and the first check is red.
func TestDefaultChannelPublic0173(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)

	count := func(sql string, args ...any) int {
		t.Helper()
		var n int
		if err := pg.asOperatorQuery(ctx, sql, args, func(r pgx.Rows) error { return r.Scan(&n) }); err != nil {
			t.Fatal(err)
		}
		return n
	}
	const onePublic = `SELECT count(*) FROM channels WHERE tenant_id = $1 AND channel_id = 'public' AND created_by = 'hub'`
	const lacking = `SELECT count(*) FROM tenants t WHERE NOT EXISTS (SELECT 1 FROM channels c
		WHERE c.tenant_id = t.tenant_id AND c.channel_id = 'public')`
	const doubled = `SELECT count(*) FROM (SELECT tenant_id FROM channels WHERE channel_id = 'public'
		GROUP BY tenant_id HAVING count(*) > 1) x`
	if n := count(onePublic, tid); n != 1 {
		t.Fatalf("a new tenant has %d #public rows, want 1 (the tenant trigger)", n)
	}

	// Apply #2 through Migrate: forget the ledger row, the runner re-runs it.
	if _, err := pg.pool.Exec(ctx, `DELETE FROM spool_schema_migrations WHERE filename = $1`, publicChannelFile); err != nil {
		t.Fatal(err)
	}
	applied, err := Migrate(ctx, pg.Pool(), sqlDir(t))
	if err != nil {
		t.Fatalf("second apply of %s: %v", publicChannelFile, err)
	}
	again := false
	for _, a := range applied {
		again = again || (a.File == publicChannelFile && !a.Skipped)
	}
	if !again {
		t.Fatalf("%s was not re-applied: %+v", publicChannelFile, applied)
	}
	if n := count(onePublic, tid); n != 1 {
		t.Fatalf("after a second apply: %d #public rows, want 1", n)
	}
	if n := count(lacking); n != 0 {
		t.Fatalf("%d tenants have no #public after the backfill", n)
	}
	if n := count(doubled); n != 0 {
		t.Fatalf("%d tenants have more than one #public", n)
	}

	var id string
	if err := pg.pool.QueryRow(ctx, `SELECT spool_public_notice_id($1)::text`, tid).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if id != PublicNoticeID(tid) {
		t.Fatalf("spool_public_notice_id %s, store.PublicNoticeID %s", id, PublicNoticeID(tid))
	}
}
