package store

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Row level security (rdb 0014, specs/017 FR-SEC-013, T021). Postgres only:
// hub-pg.tst.sh runs this package as a NON-superuser role that owns the
// tables, which is the Cloud SQL shape. A superuser skips every policy, so
// such a role is a hard failure here, not a skip.

func rlsStore(t *testing.T) *Postgres {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(t)); err != nil {
		t.Fatal(err)
	}
	by, err := pg.RLSBypassed(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if by {
		t.Fatal("SPOOL_TEST_PG_DSN role is superuser or BYPASSRLS: RLS is not exercised (hub-pg.tst.sh uses a plain owner role)")
	}
	return pg
}

// rlsTenant seeds one tenant with a pin, a roster row, a message and its
// delivery, all through the store (so through inTenant).
func rlsTenant(t *testing.T, pg *Postgres) (tenant, msgID string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC()
	tenant = newTenant(t, pg)
	if err := pg.PutPin(ctx, tenant, "box-a", pubkey(), false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetRoster(ctx, tenant, "box-a", []string{"CLE-01"}, now); err != nil {
		t.Fatal(err)
	}
	m := msgFor(tenant, uuid4(), "box-a", now, now, "env-"+tenant)
	if _, err := pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	if err := pg.Enqueue(ctx, tenant, m.MsgID, "box-a", now, now.Add(time.Hour), 0); err != nil {
		t.Fatal(err)
	}
	return tenant, m.MsgID
}

// rlsTables are the tables 0014 covers, with their tenant_id column.
var rlsTables = []string{
	"tenants", "boxes", "pins", "pins_history", "roster", "messages", "deliveries",
	"channels", "channel_subscriptions", "tenant_memberships", "tenant_invites", "payment_checkouts",
}

// TestRLSCoversEveryTenantTable: a table that gains a tenant_id column must
// also gain ENABLE + FORCE row level security, or this fails.
func TestRLSCoversEveryTenantTable(t *testing.T) {
	pg := rlsStore(t)
	rows, err := pg.pool.Query(context.Background(), `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
		FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
		WHERE n.nspname = current_schema() AND c.relkind = 'r'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	seen := map[string]bool{}
	for rows.Next() {
		var name string
		var on, force bool
		if err := rows.Scan(&name, &on, &force); err != nil {
			t.Fatal(err)
		}
		seen[name] = true
		if !on || !force {
			t.Errorf("%s carries tenant_id but row security is enable=%v force=%v (add it in a new rdb migration)", name, on, force)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	for _, tb := range rlsTables {
		if !seen[tb] {
			t.Errorf("%s: expected a tenant_id table", tb)
		}
	}
}

// TestRLSControl is the CONTROL: the same query that forgets WHERE tenant_id
// leaks tenant B's rows to tenant A without FORCE (the pre-0014 state, the
// table owner is exempt) and returns none of them with it.
func TestRLSControl(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, _ := rlsTenant(t, pg)
	b, msgB := rlsTenant(t, pg)

	// forgotWhere is the bug RLS defends against: no tenant predicate.
	const forgotWhere = `SELECT count(*) FROM messages WHERE tenant_id <> $1`

	// BEFORE: switch FORCE off inside a rolled-back transaction, and the
	// owner sees B's rows under A's scope.
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `ALTER TABLE messages NO FORCE ROW LEVEL SECURITY`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, pgScopeTenant, a); err != nil {
		t.Fatal(err)
	}
	var leaked int
	if err := tx.QueryRow(ctx, forgotWhere, a).Scan(&leaked); err != nil {
		t.Fatal(err)
	}
	tx.Rollback(ctx) //nolint:errcheck
	if leaked == 0 {
		t.Fatal("control is void: without FORCE the unscoped query should see other tenants' messages")
	}

	// AFTER: with 0014 in force, A's scope sees none of B's rows, in any table.
	err = pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		for _, tb := range rlsTables {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{tb}.Sanitize()+` WHERE tenant_id <> $1`, a).Scan(&n); err != nil {
				return err
			}
			if n != 0 {
				t.Errorf("%s: tenant %s sees %d row(s) of other tenants", tb, a, n)
			}
		}
		var own int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM messages`).Scan(&own); err != nil {
			return err
		}
		if own != 1 {
			t.Errorf("tenant %s sees %d message(s), want its own 1", a, own)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Writes: an UPDATE / DELETE without WHERE touches only A's rows, and a
	// row stamped with B's tenant_id is refused (42501).
	err = pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE messages SET body = 'overwritten'`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM deliveries`); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if st, err := pg.DeliveryState(ctx, b, msgB, "box-a"); err != nil || st != "queued" {
		t.Fatalf("B's delivery after A's unscoped DELETE: %q %v", st, err)
	}
	var bodyB string
	if err := pg.inTenant(ctx, b, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT body FROM messages WHERE msg_id = $1`, msgB).Scan(&bodyB)
	}); err != nil {
		t.Fatal(err)
	}
	if bodyB == "overwritten" {
		t.Fatal("A's unscoped UPDATE rewrote B's message")
	}
	err = pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO pins (tenant_id, box_id, pubkey) VALUES ($1, 'box-x', $2)`, b, []byte(pubkey()))
		return err
	})
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Fatalf("A inserting a pin for B: want 42501 row-level security violation, got %v", err)
	}

	// Fail closed: no scope at all sees nothing.
	var none int
	if err := pg.pool.QueryRow(ctx, `SELECT count(*) FROM messages`).Scan(&none); err != nil {
		t.Fatal(err)
	}
	if none != 0 {
		t.Fatalf("a statement with no scope sees %d message(s), want 0", none)
	}

	// The operator path sees both (the sweep's view).
	var both int
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(DISTINCT tenant_id) FROM messages WHERE tenant_id IN ($1, $2)`, a, b).Scan(&both)
	}); err != nil {
		t.Fatal(err)
	}
	if both != 2 {
		t.Fatalf("operator scope sees %d of the 2 tenants", both)
	}
}

// TestRLSScopeIsTransactionLocal: on a ONE-connection pool (so the next
// statement reuses the very connection), neither inTenant nor the one-round-
// trip batch path, nor a batch whose statement fails, leaves a scope behind.
func TestRLSScopeIsTransactionLocal(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, msgA := rlsTenant(t, pg)
	one, err := OpenPostgres(ctx, os.Getenv("SPOOL_TEST_PG_DSN")+"&pool_max_conns=1")
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	unscoped := func(step string) {
		t.Helper()
		var n int
		if err := one.pool.QueryRow(ctx, `SELECT count(*) FROM messages`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Fatalf("after %s the connection still sees %d message(s)", step, n)
		}
	}
	if ok, err := one.HasMessage(ctx, a, msgA); err != nil || !ok {
		t.Fatalf("batch path HasMessage: %v %v", ok, err)
	}
	unscoped("queryRowTenant")
	if _, err := one.execTenant(ctx, a, `UPDATE messages SET body = body WHERE tenant_id = $1`, a); err != nil {
		t.Fatal(err)
	}
	unscoped("execTenant")
	if _, err := one.Roster(ctx, a); err != nil {
		t.Fatal(err)
	}
	unscoped("queryTenant")
	if _, err := one.execTenant(ctx, a, `SELECT no_such_column FROM messages`); err == nil {
		t.Fatal("a broken statement succeeded")
	}
	unscoped("a failed batch")
	if err := one.inTenant(ctx, a, func(tx pgx.Tx) error { return nil }); err != nil {
		t.Fatal(err)
	}
	unscoped("inTenant")
	if _, err := one.Sweep(ctx, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	unscoped("asOperator")
}
