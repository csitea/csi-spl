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
	"tenant_hosts", "tenant_seat_periods", "rbac_roles",
	"workspace_events", // rdb 0240, spec 162 B3
	// rdb 0244, spec 163 B1
	"marketing_metric_samples", "marketing_metric_definitions",
	// rdb 0249, spec 169 T2
	"channel_move_journal", "channel_move_steps",
	// rdb 0255, spec 125 B4: owner human only (netvisor_test.go)
	"netvisor_settings", "netvisor_snapshots", "netvisor_forecast_items", "netvisor_card_cost_lines",
	// rdb 0266, spec 143 releases-projects row B-1
	"software_projects", "workspace_repos",
	// rdb 0274, spec 090 section 22 (SPL-5240)
	"marketing_drafts",
}

// spl4808ExpandTables carry a tenant_id but no tenant row security yet: rdb
// 0267 (spec 171 Step A) expands them while the running hub still reads them
// with no scope. Time-boxed: SPL-4808's Lane 2b (row B-3) forces both, moves
// them to rlsTables and removes this map.
var spl4808ExpandTables = map[string]bool{
	"release_notes":  true, // SPL-4808 Lane 2b: no row security until the contract
	"estate_deploys": true, // SPL-4808 Lane 2b: its read policy stays USING (true) until the contract
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
		if spl4808ExpandTables[name] {
			continue
		}
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

// TestRLSFleetDeskBoxesOperatorOnly (rdb 0230, spec 158 T4): the fleet desk
// list is the estate's, not a workspace's. Only the operator scope reads or
// writes it; a tenant scope and no scope see no row and insert none. A new
// workspace starts with fleet_seating true (CreateTenant, SPL-4295).
func TestRLSFleetDeskBoxesOperatorOnly(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	box := "fdb-" + a
	if len(box) > 32 {
		box = box[:32]
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO fleet_desk_boxes (box_id, added_by) VALUES ($1, 'HUM-10')`, box)
		return err
	}); err != nil {
		t.Fatalf("operator listing a fleet desk box: %v", err)
	}
	t.Cleanup(func() {
		_ = pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `DELETE FROM fleet_desk_boxes WHERE box_id = $1`, box)
			return err
		})
	})
	var seen int
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM fleet_desk_boxes WHERE box_id = $1`, box).Scan(&seen)
	}); err != nil || seen != 1 {
		t.Fatalf("operator scope sees %d of its 1 fleet desk box (%v)", seen, err)
	}
	err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM fleet_desk_boxes`).Scan(&n); err != nil {
			return err
		}
		if n != 0 {
			t.Errorf("tenant %s sees %d fleet desk box(es), want 0", a, n)
		}
		var on bool
		if err := tx.QueryRow(ctx, `SELECT fleet_seating FROM tenants WHERE tenant_id = $1`, a).Scan(&on); err != nil {
			return err
		}
		if !on {
			t.Errorf("new tenant %s has fleet_seating false, want true (CreateTenant's default)", a)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	err = pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO fleet_desk_boxes (box_id, added_by) VALUES ('fdb-tenant-x', 'HUM-10')`)
		return err
	})
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Fatalf("a tenant listing a fleet desk box: want 42501 row-level security violation, got %v", err)
	}
	var none int
	if err := pg.pool.QueryRow(ctx, `SELECT count(*) FROM fleet_desk_boxes`).Scan(&none); err != nil {
		t.Fatal(err)
	}
	if none != 0 {
		t.Fatalf("a statement with no scope sees %d fleet desk box(es), want 0", none)
	}
	var on, force bool
	if err := pg.pool.QueryRow(ctx, `SELECT relrowsecurity, relforcerowsecurity FROM pg_class
		WHERE oid = 'fleet_desk_boxes'::regclass`).Scan(&on, &force); err != nil || !on || !force {
		t.Fatalf("fleet_desk_boxes row security enable=%v force=%v (%v)", on, force, err)
	}
}

// TestRLSChannelMoveRedirects (rdb 0249, spec 169 T2, Q2 = A): the
// redirect table is hub-wide, ids only. The operator writes it; the <SRC>
// tenant scope reads only the rows of its own src_tenant_id; <DST>, any
// other tenant and no scope read none; no tenant scope writes one. A row
// expires 30 days after it is written unless the writer says otherwise.
func TestRLSChannelMoveRedirects(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	src, dst, other := newTenant(t, pg), newTenant(t, pg), newTenant(t, pg)
	task := uuid4()
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO channel_move_redirects (src_tenant_id, kind, old_ref, dst_tenant_id, new_ref, move_id)
			VALUES ($1, 'task', $2, $3, $2, $4)`, src, task, dst, uuid4())
		return err
	}); err != nil {
		t.Fatalf("operator writing a redirect: %v", err)
	}
	var days float64
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT extract(epoch FROM expires_at - created_at) / 86400 FROM channel_move_redirects
			WHERE src_tenant_id = $1 AND kind = 'task' AND old_ref = $2`, src, task).Scan(&days)
	}); err != nil || days != 30 {
		t.Fatalf("the redirect lives %v day(s), want 30 (Q2) (%v)", days, err)
	}
	seen := func(tenant string) int {
		t.Helper()
		var n int
		if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM channel_move_redirects WHERE old_ref = $1`, task).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := seen(src); n != 1 {
		t.Errorf("<SRC> scope reads %d of its 1 redirect (control)", n)
	}
	for name, tenant := range map[string]string{"<DST>": dst, "another tenant": other} {
		if n := seen(tenant); n != 0 {
			t.Errorf("%s scope reads %d redirect(s) of <SRC>, want 0", name, n)
		}
	}
	var none int
	if err := pg.pool.QueryRow(ctx, `SELECT count(*) FROM channel_move_redirects`).Scan(&none); err != nil || none != 0 {
		t.Fatalf("a statement with no scope sees %d redirect(s), want 0 (%v)", none, err)
	}
	var reached int64
	err := pg.inTenant(ctx, src, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE channel_move_redirects SET expires_at = expires_at + interval '1 day'`)
		reached = tag.RowsAffected()
		if err != nil {
			return err
		}
		tag, err = tx.Exec(ctx, `DELETE FROM channel_move_redirects`)
		reached += tag.RowsAffected()
		return err
	})
	if err != nil || reached != 0 {
		t.Errorf("<SRC> scope UPDATE / DELETE reached %d redirect(s), want 0 (operator-written) (%v)", reached, err)
	}
	err = pg.inTenant(ctx, src, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO channel_move_redirects (src_tenant_id, kind, old_ref, dst_tenant_id, new_ref, move_id)
			VALUES ($1, 'issue', 'SPL-1', $2, 'NEW-1', $3)`, src, dst, uuid4())
		return err
	})
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Fatalf("<SRC> scope writing a redirect: want 42501 row-level security violation, got %v", err)
	}
	var on, force bool
	if err := pg.pool.QueryRow(ctx, `SELECT relrowsecurity, relforcerowsecurity FROM pg_class
		WHERE oid = 'channel_move_redirects'::regclass`).Scan(&on, &force); err != nil || !on || !force {
		t.Fatalf("channel_move_redirects row security enable=%v force=%v (%v)", on, force, err)
	}
}

// TestMessagesCopiedFrom (rdb 0250, spec 169 T3): messages.copied_from is a
// nullable uuid with no default, so adding it rewrote no row (catalog-only)
// and every existing post reads NULL: only a copy (T11) sets it.
func TestMessagesCopiedFrom(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	var typ, nullable string
	var def *string
	if err := pg.pool.QueryRow(ctx, `SELECT data_type, is_nullable, column_default FROM information_schema.columns
		WHERE table_schema = current_schema() AND table_name = 'messages' AND column_name = 'copied_from'`).Scan(&typ, &nullable, &def); err != nil {
		t.Fatalf("messages.copied_from: %v", err)
	}
	if typ != "uuid" || nullable != "YES" || def != nil {
		shown := "none"
		if def != nil {
			shown = *def
		}
		t.Fatalf("messages.copied_from is %s nullable=%s default=%s, want uuid, nullable, no default", typ, nullable, shown)
	}
	tenant, msgID := rlsTenant(t, pg)
	var from *string
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT copied_from::text FROM messages WHERE msg_id = $1`, msgID).Scan(&from)
	}); err != nil || from != nil {
		t.Fatalf("a post that is not a copy has copied_from %v, want NULL (%v)", from, err)
	}
}
