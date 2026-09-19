package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// TestMessagePeriodCounts (027 T040, rdb 0023): the quota count read from the
// trigger-kept counters equals COUNT(*) over messages through every write
// that changes it: insert, duplicate insert, another tenant's insert, the
// retention sweep, an UPDATE that moves received_at, and a since that is not
// a period start (which still counts rows).
func TestMessagePeriodCounts(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	period := billing.PeriodStart(now)
	prev := billing.PeriodStart(period.Add(-time.Hour))
	a, b := newTenant(t, pg), newTenant(t, pg)

	rows := func(tenant string, since time.Time) int {
		t.Helper()
		var n int
		if err := pg.queryRowTenant(ctx, tenant, `SELECT COUNT(*) FROM messages WHERE tenant_id = $1 AND received_at >= $2`,
			[]any{tenant, since}, &n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	check := func(what string, tenant string, since time.Time, want int) {
		t.Helper()
		got, err := pg.CountMessagesSince(ctx, tenant, since)
		if err != nil {
			t.Fatal(err)
		}
		if got != want || got != rows(tenant, since) {
			t.Fatalf("%s: CountMessagesSince %d, COUNT(*) %d, want %d", what, got, rows(tenant, since), want)
		}
	}
	insert := func(tenant string, at time.Time, expires time.Time) Message {
		t.Helper()
		m := msgFor(tenant, uuid4(), "box-b", at, at, uuid4())
		m.ExpiresAt = expires
		if ins, err := pg.InsertMessage(ctx, m); err != nil || !ins {
			t.Fatalf("insert: %v %v", ins, err)
		}
		return m
	}

	check("empty", a, period, 0)
	keep := now.Add(24 * time.Hour)
	first := insert(a, now, keep)
	insert(a, now, keep)
	gone := insert(a, now, now.Add(-time.Second)) // expired: the sweep deletes it
	insert(a, prev.Add(time.Hour), keep)
	check("three this period", a, period, 3)
	check("four since the previous period", a, prev, 4)

	if ins, err := pg.InsertMessage(ctx, first); err != nil || ins {
		t.Fatalf("duplicate insert: %v %v", ins, err)
	}
	check("a duplicate is not counted", a, period, 3)

	insert(b, now, keep)
	check("tenant B does not count for A", a, period, 3)
	check("tenant B", b, period, 1)

	if _, err := pg.Sweep(ctx, now); err != nil {
		t.Fatal(err)
	}
	if _, _, err := pg.MessageTimes(ctx, a, gone.MsgID); err != ErrNotFound {
		t.Fatalf("sweep kept the expired message: %v", err)
	}
	check("a swept message is decremented", a, period, 2)

	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE messages SET received_at = $3 WHERE tenant_id = $1 AND msg_id = $2`,
			a, first.MsgID, prev.Add(2*time.Hour))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	check("moved to the previous period", a, period, 1)
	check("still counted since the previous period", a, prev, 3)

	mid := period.Add(time.Nanosecond * 1000)
	if got, err := pg.CountMessagesSince(ctx, a, mid); err != nil || got != rows(a, mid) {
		t.Fatalf("since not a period start: %d %v, COUNT(*) %d", got, err, rows(a, mid))
	}
}
