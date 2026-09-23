package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Cross-tenant suite, store half (specs/017 FR-SEC-015, CLE-3416). Postgres
// only (hub-pg.tst.sh, 10 ci hub job). Two tenants hold data in EVERY table
// that carries tenant_id - the list comes from the catalogue, and a table the
// seed does not fill fails the suite, so a new tenant table (RBAC, search,
// keys, M2/M4, ...) must be seeded here before it can ship. The hub half,
// the HTTP / WS / files / search paths, is internal/hub crosstenant_test.go.

// crossSeed is what seedTenantAll wrote for one tenant.
type crossSeed struct {
	tenant, marker, msgID, taskID, channelID, humanID, checkoutID string
}

// seedTenantAll fills every tenant table for a fresh tenant, through the
// store API where one exists (so through inTenant) and as the operator only
// for the rows the paid webhook writes.
func seedTenantAll(t *testing.T, pg *Postgres) crossSeed {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	s := crossSeed{tenant: uid("t-")}
	co := testCheckout(t, s.tenant) // payment_checkouts: a hold comes before its tenant
	co.Email = "buyer-" + s.tenant + "@example.com"
	if err := pg.HoldCheckout(ctx, co, now, time.Hour); err != nil {
		t.Fatal(err)
	}
	s.checkoutID = co.ID
	if err := pg.CreateTenant(ctx, Tenant{ID: s.tenant, RootPubKey: pubkey()}); err != nil { // tenants + tenant_hosts (0015 trigger)
		t.Fatal(err)
	}
	s.marker = "secret" + strings.ReplaceAll(s.tenant, "-", "")
	s.taskID = uuid4()
	s.channelID = uid("ch-")
	if err := pg.PutPin(ctx, s.tenant, "box-a", pubkey(), false, now, now); err != nil { // pins
		t.Fatal(err)
	}
	if err := pg.PutPin(ctx, s.tenant, "box-old", pubkey(), false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.RevokePin(ctx, s.tenant, "box-old", now.Add(time.Second), now.Add(time.Second)); err != nil { // pins_history
		t.Fatal(err)
	}
	if err := pg.TouchBox(ctx, s.tenant, "box-a", now); err != nil { // boxes
		t.Fatal(err)
	}
	if err := pg.SetRoster(ctx, s.tenant, "box-a", []string{"CLE-01"}, now); err != nil { // roster
		t.Fatal(err)
	}
	m := msgFor(s.tenant, s.taskID, "box-a", now, now, "env-"+s.tenant) // messages
	m.Body = "the " + s.marker + " plan"
	if _, err := pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	s.msgID = m.MsgID
	if err := pg.Enqueue(ctx, s.tenant, m.MsgID, "box-a", now, now.Add(time.Hour), 0); err != nil { // deliveries
		t.Fatal(err)
	}
	// message_revisions (rdb 0026): one edit writes revisions 1 and 2, so the
	// register holds rows for both tenants. The marker stays in the body, so
	// the search leak checks below are unaffected by the rewrite.
	if _, err := pg.ApplyEdit(ctx, s.tenant, m.MsgID, Edit{Body: "the " + s.marker + " plan, revised",
		Msg: m.Msg, Env: m.Env, EditedBy: "CLE-01", EditedAt: now.Add(time.Second)}); err != nil {
		t.Fatal(err)
	}
	if err := pg.CreateChannel(ctx, Channel{TenantID: s.tenant, ChannelID: s.channelID, Name: "c" + s.marker[:12], CreatedBy: "CLE-01", CreatedAt: now}); err != nil { // channels
		t.Fatal(err)
	}
	if err := pg.SetSubscriptions(ctx, s.tenant, "box-a", []string{"CLE-01"}, []string{s.channelID}, now); err != nil { // channel_subscriptions
		t.Fatal(err)
	}
	hum, err := pg.Admit(ctx, Identity{Provider: "google", Subject: "sub-" + s.tenant, Email: s.tenant + "@example.com", Name: "FirstName LastName"},
		s.tenant, AdmitPolicy{BootstrapOwner: true}, now) // tenant_memberships
	if err != nil {
		t.Fatal(err)
	}
	s.humanID = hum
	if err := pg.AddChannelHumans(ctx, s.tenant, s.channelID, []string{hum}, hum, now); err != nil { // channel_humans
		t.Fatal(err)
	}
	if err := pg.PutInvite(ctx, Invite{TenantID: s.tenant, Email: "inv-" + s.tenant + "@example.com", Role: "developer", InvitedBy: hum,
		ExpiresAt: now.Add(24 * time.Hour)}, now); err != nil { // tenant_invites
		t.Fatal(err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error { // tenant_seat_periods: the paid webhook's row
		_, err := tx.Exec(ctx, `INSERT INTO tenant_seat_periods (tenant_id, period_start, seats_users, seats_bots, checkout_id, amount_cents, paid_at)
			VALUES ($1, date_trunc('month', now())::date, 1, 1, $2, 100, now())`, s.tenant, co.ID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error { // rbac_roles: a tenant's own role (025 phase 2 shape)
		_, err := tx.Exec(ctx, `INSERT INTO rbac_roles (role_id, tenant_id, description) VALUES ($1, $2, 'cross-tenant seed')`,
			"r_"+strings.ReplaceAll(s.tenant, "-", "_"), s.tenant)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return s
}

// tenantTables lists every table with a tenant_id column, from the catalogue.
func tenantTables(t *testing.T, pg *Postgres) []string {
	t.Helper()
	var out []string
	rows, err := pg.pool.Query(context.Background(), `SELECT c.relname FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
		WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	if err := scanRows(rows, func(r pgx.Rows) error {
		var n string
		out = append(out, n)
		return r.Scan(&out[len(out)-1])
	}); err != nil {
		t.Fatal(err)
	}
	if len(out) == 0 {
		t.Fatal("no tenant_id table in the catalogue")
	}
	return out
}

// countOf counts tenant's rows in tb as the operator (the ground truth).
func countOf(t *testing.T, pg *Postgres, tb, tenant string) int {
	t.Helper()
	var n int
	if err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT count(*) FROM `+pgx.Identifier{tb}.Sanitize()+` WHERE tenant_id = $1`, tenant).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

// TestCrossTenantEveryTable: with A and B seeded in every tenant table, A's
// scope sees none of B's rows in any of them, and A's unscoped UPDATE /
// DELETE / a B-stamped INSERT change none of them. CONTROL: B's rows are
// there (counted as the operator), and A sees its own.
func TestCrossTenantEveryTable(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := seedTenantAll(t, pg)
	b := seedTenantAll(t, pg)
	tables := tenantTables(t, pg)
	before := map[string]int{}
	for _, tb := range tables {
		before[tb] = countOf(t, pg, tb, b.tenant)
		if before[tb] == 0 {
			t.Errorf("%s: seedTenantAll wrote no row for tenant B - a new tenant table must be seeded in crosstenant_test.go", tb)
		}
		if countOf(t, pg, tb, a.tenant) == 0 {
			t.Errorf("%s: no row for tenant A", tb)
		}
	}
	if t.Failed() {
		t.FailNow()
	}
	for _, tb := range tables {
		id := pgx.Identifier{tb}.Sanitize()
		err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
			var other, own int
			if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE tenant_id <> $1), count(*) FILTER (WHERE tenant_id = $1) FROM `+id, a.tenant).Scan(&other, &own); err != nil {
				return err
			}
			if other != 0 {
				t.Errorf("%s: A's scope reads %d row(s) of other tenants", tb, other)
			}
			if own == 0 {
				t.Errorf("%s: A's scope reads none of its own rows (control)", tb)
			}
			return nil
		})
		if err != nil {
			t.Fatalf("%s read: %v", tb, err)
		}
		// Writes that forget WHERE tenant_id touch only A's rows: RETURNING
		// names every row the statement reached. Each runs in a transaction
		// that is rolled back, so A's seed stays for the next table.
		for _, w := range []string{
			`UPDATE ` + id + ` SET tenant_id = tenant_id RETURNING tenant_id`,
			`DELETE FROM ` + id + ` RETURNING tenant_id`,
		} {
			var reached, foreign int
			rolledBack := errors.New("rollback")
			err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
				if err := tx.QueryRow(ctx, `WITH w AS (`+w+`) SELECT count(*), count(*) FILTER (WHERE tenant_id IS DISTINCT FROM $1) FROM w`, a.tenant).Scan(&reached, &foreign); err != nil {
					return err
				}
				return rolledBack
			})
			if !errors.Is(err, rolledBack) {
				t.Errorf("%s: %s: %v", tb, w, err)
				continue
			}
			if foreign != 0 || reached == 0 {
				t.Errorf("%s: %s from A's scope reached %d row(s), %d not A's (want >0 and 0)", tb, w, reached, foreign)
			}
		}
		if n := countOf(t, pg, tb, b.tenant); n != before[tb] {
			t.Errorf("%s: B had %d row(s), now %d", tb, before[tb], n)
		}
		// A B-stamped row from A's scope: refused by WITH CHECK.
		err = pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE `+id+` SET tenant_id = $1 WHERE tenant_id = $2`, b.tenant, a.tenant)
			return err
		})
		if err == nil {
			t.Errorf("%s: A re-stamped its own row(s) as B's", tb)
		}
	}
}

// TestCrossTenantStoreAPI: every tenant-scoped store read called with A's
// tenant and B's ids returns nothing of B's. CONTROL: B's own call finds it.
func TestCrossTenantStoreAPI(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a := seedTenantAll(t, pg)
	b := seedTenantAll(t, pg)

	if ok, err := pg.HasMessage(ctx, b.tenant, b.msgID); err != nil || !ok {
		t.Fatalf("control: B's own message: %v %v", ok, err)
	}
	if ok, err := pg.HasMessage(ctx, a.tenant, b.msgID); err != nil || ok {
		t.Errorf("HasMessage(A, B's msg) = %v %v", ok, err)
	}
	if env, err := pg.TaskEnvelopes(ctx, a.tenant, b.taskID); err != nil || len(env) != 0 {
		t.Errorf("TaskEnvelopes(A, B's task) = %d %v", len(env), err)
	}
	if msgs, err := pg.ViewTopic(ctx, a.tenant, TopicMsgQuery{TaskID: b.taskID, Limit: 50, Now: now}); err != nil || len(msgs) != 0 {
		t.Errorf("ViewTopic(A, B's task) = %d %v", len(msgs), err)
	}
	if st, err := pg.DeliveryState(ctx, a.tenant, b.msgID, "box-a"); err == nil && st != "" {
		t.Errorf("DeliveryState(A, B's msg) = %q", st)
	}
	if ok, err := pg.ClaimSent(ctx, a.tenant, b.msgID, "box-a", now); err == nil && ok {
		t.Error("ClaimSent(A, B's msg) claimed B's delivery")
	}
	if st, _ := pg.DeliveryState(ctx, b.tenant, b.msgID, "box-a"); st != "queued" {
		t.Errorf("B's delivery after A's claim attempt: %q", st)
	}
	if ok, err := pg.ChannelKnown(ctx, a.tenant, b.channelID); err != nil || ok {
		t.Errorf("ChannelKnown(A, B's channel) = %v %v", ok, err)
	}
	if mem, err := pg.ChannelMembers(ctx, a.tenant, b.channelID); err != nil || len(mem) != 0 {
		t.Errorf("ChannelMembers(A, B's channel) = %v %v", mem, err)
	}
	if role, err := pg.MemberRole(ctx, b.humanID, a.tenant); err == nil && role != "" {
		t.Errorf("MemberRole(B's human, A) = %q", role)
	}
	if hs, err := pg.TenantHumans(ctx, a.tenant); err != nil {
		t.Fatal(err)
	} else {
		for _, h := range hs {
			if h.HumanID == b.humanID {
				t.Errorf("TenantHumans(A) lists B's human %s", b.humanID)
			}
		}
	}
	rs, err := pg.SearchMessages(ctx, a.tenant, sq(t, b.marker, now))
	if err != nil || len(rs) != 0 {
		t.Errorf("SearchMessages(A, B's marker) = %d %v", len(rs), err)
	}
	if rs, err := pg.SearchMessages(ctx, b.tenant, sq(t, b.marker, now)); err != nil || len(rs) != 1 {
		t.Errorf("control: SearchMessages(B, B's marker) = %d %v", len(rs), err)
	}
	if ps, err := pg.SeatPeriods(ctx, a.tenant); err != nil || len(ps) != 1 {
		t.Errorf("SeatPeriods(A) = %d %v, want A's own 1", len(ps), err)
	}
	if pins, err := pg.ListPins(ctx, a.tenant); err != nil {
		t.Fatal(err)
	} else if len(pins) != 1 {
		t.Errorf("ListPins(A) = %d pins, want A's own 1", len(pins))
	}
	if r, err := pg.Roster(ctx, a.tenant); err != nil || len(r) != 1 {
		t.Errorf("Roster(A) = %v %v", r, err)
	}
	if n, err := pg.CountMembers(ctx, a.tenant); err != nil || n != 1 {
		t.Errorf("CountMembers(A) = %d %v, want 1", n, err)
	}
	// Writes through the API with A's tenant and B's ids change nothing of B.
	if err := pg.RevokePin(ctx, a.tenant, "box-a", now.Add(time.Minute), now.Add(time.Minute)); err != nil {
		t.Fatal(err) // A revokes its OWN box-a; B's box-a must survive
	}
	if _, err := pg.GetPin(ctx, b.tenant, "box-a"); err != nil {
		t.Errorf("B's box-a pin after A revoked its own box-a: %v", err)
	}
	if err := pg.Unclaim(ctx, a.tenant, b.msgID, "box-a"); err != nil && !errors.Is(err, ErrNotFound) {
		t.Errorf("Unclaim(A, B's msg): %v", err)
	}
}
