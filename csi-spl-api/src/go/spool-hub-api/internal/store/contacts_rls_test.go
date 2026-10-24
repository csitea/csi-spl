package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/154 B1 (rdb 0225, SPL-3256): personal.contacts and contacts_sync at
// SQL level, as the runtime login, with raw set_config and no store code
// (B2 brings it). Cases C1, C2, C2b, C2c and C2d of the spec's section 5.
// Postgres only. The names start TestRLS, so hub-pg.tst.sh's RLS control
// counts them; no t.Run, since that control greps every "--- PASS: TestRLS".

// contactPersons inserts two humans P1 and P2 in the owner's transaction.
func contactPersons(t *testing.T, tx pgx.Tx) (p1, p2 string) {
	t.Helper()
	n := time.Now().UnixNano() % 1_000_000_000
	p1, p2 = fmt.Sprintf("HUM-8%d1", n), fmt.Sprintf("HUM-8%d2", n)
	for _, who := range []string{p1, p2} {
		if _, err := tx.Exec(context.Background(), `INSERT INTO humans (human_id, display_name) VALUES ($1, 'FirstName LastName')`, who); err != nil {
			t.Fatal(err)
		}
	}
	return p1, p2
}

// addContact inserts one contact of person in person's own scope (FORCE
// binds the owner too) and returns its id. age > 0 soft-deletes it that long
// ago by `by`; linked sets a Google link.
func addContact(t *testing.T, tx pgx.Tx, person string, age time.Duration, by string, linked bool) string {
	t.Helper()
	ctx := context.Background()
	if err := scope(ctx, tx, person, "", ""); err != nil {
		t.Fatal(err)
	}
	var deletedAt *time.Time
	var deletedBy *string
	if age > 0 {
		at := time.Now().Add(-age)
		deletedAt, deletedBy = &at, &by
	}
	var account, resource *string
	if linked {
		a, r := "first.last@example.com", "people/c"+uuid4()[:12]
		account, resource = &a, &r
	}
	var id string
	if err := tx.QueryRow(ctx, `INSERT INTO personal.contacts (person_id, first_name, last_name, email, google_account, google_resource, deleted_at, deleted_by)
		VALUES ($1, 'FirstName', 'LastName', 'first.last@example.com', $2, $3, $4, $5) RETURNING contact_id::text`,
		person, account, resource, deletedAt, deletedBy).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if err := scope(ctx, tx, "", "", ""); err != nil {
		t.Fatal(err)
	}
	return id
}

// countContacts counts who's contacts under the given settings, in a
// savepoint that is always rolled back.
func countContacts(ctx context.Context, tx pgx.Tx, person, tenant, rls, who string) (int, error) {
	var c int
	err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
		if err := scope(ctx, sp, person, tenant, rls); err != nil {
			return err
		}
		return sp.QueryRow(ctx, `SELECT count(*) FROM personal.contacts WHERE person_id = $1`, who).Scan(&c)
	})
	return c, err
}

// TestRLSContactsSchema is C1: the objects of section 3 exist after the
// migration (the catalogue checks of personal.contacts and its door are in
// TestRLSPersonalCatalogue). Each query returns a row only when it fails.
func TestRLSContactsSchema(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	for _, c := range []struct{ what, sql string }{
		{"gcal_connections.granted_scopes is text NOT NULL DEFAULT ''", `
			SELECT 'missing' WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
			  JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
			  WHERE a.attrelid = 'public.gcal_connections'::regclass AND a.attname = 'granted_scopes'
			    AND a.atttypid = 'text'::regtype AND a.attnotnull AND pg_get_expr(d.adbin, d.adrelid) = '''''::text')`},
		{"contacts_sync is ENABLE + FORCE with exactly tenant_scope and operator_scope", `
			SELECT format('enable=%s force=%s policies=%s', c.relrowsecurity, c.relforcerowsecurity,
			              (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'contacts_sync'))
			FROM pg_class c WHERE c.oid = 'public.contacts_sync'::regclass
			  AND NOT (c.relrowsecurity AND c.relforcerowsecurity
			       AND (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
			            WHERE schemaname = 'public' AND tablename = 'contacts_sync') = 'operator_scope,tenant_scope')`},
		{"contacts_sync's primary key is human_id alone", `
			SELECT 'pk' WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = 'public.contacts_sync'::regclass
			  AND k.contype = 'p' AND k.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = k.conrelid AND attname = 'human_id')])`},
		{"contacts_sync has the two (tenant_id, human_id) FKs, to gcal_connections and tenant_memberships, ON DELETE CASCADE", `
			SELECT COALESCE(string_agg(confrelid::regclass::text, ',' ORDER BY confrelid::regclass::text), 'none') FROM pg_constraint
			WHERE conrelid = 'public.contacts_sync'::regclass AND contype = 'f' AND array_length(conkey, 1) = 2 AND confdeltype = 'c'
			HAVING string_agg(confrelid::regclass::text, ',' ORDER BY confrelid::regclass::text) IS DISTINCT FROM 'gcal_connections,tenant_memberships'`},
		{"spool_realm_contacts_purger exists", `
			SELECT 'missing' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_realm_contacts_purger')`},
	} {
		var bad *string
		err := pg.pool.QueryRow(ctx, c.sql).Scan(&bad)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			t.Errorf("C1 %s: %v", c.what, err)
		default:
			t.Errorf("C1 %s: found %s", c.what, show(bad))
		}
	}
}

// TestRLSContactsPersonScope is C2 and C2b as the runtime: P2's contact is
// read under P2's own person scope alone (the twin), and under P1's person,
// P2's person with a workspace set, and the operator scope it reads 0 rows.
// A contact with all four values empty is a CHECK violation; one value set
// inserts (the twin).
func TestRLSContactsPersonScope(t *testing.T) {
	pg := rlsStore(t)
	_, rt := runtimeSession(t)
	ctx := context.Background()
	tx := ownerTx(t, pg)
	p1, p2 := contactPersons(t, tx)
	addContact(t, tx, p2, 0, "", false)
	becomeRuntime(t, tx, rt)
	for _, c := range []struct {
		name, person, tenant, rls string
		want                      int
	}{
		{"twin: P2 reads P2's own", p2, "", "", 1},
		{"P1 reads P2's", p1, "", "", 0},
		{"P2 with app.tenant_id set", p2, "ws-c2-" + uuid4(), "", 0},
		{"the operator scope", "", "", "operator", 0},
		{"P2 under the operator scope", p2, "", "operator", 0},
		{"a workspace scope alone", "", "ws-c2-" + uuid4(), "", 0},
		{"no scope", "", "", "", 0},
	} {
		n, err := countContacts(ctx, tx, c.person, c.tenant, c.rls, p2)
		if err != nil || n != c.want {
			t.Errorf("C2 %s: %d row(s) (%v), want %d", c.name, n, err, c.want)
		}
	}
	// A write stamped P2 from P1's scope is refused by WITH CHECK.
	err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
		if err := scope(ctx, sp, p1, "", ""); err != nil {
			return err
		}
		_, err := sp.Exec(ctx, `INSERT INTO personal.contacts (person_id, first_name) VALUES ($1, 'FirstName')`, p2)
		return err
	})
	if sqlState(err) != "42501" {
		t.Errorf("C2 P1 inserting a contact stamped P2: %v, want the policy's 42501", err)
	}
	// C2b
	for _, c := range []struct {
		name, cols, vals string
		state            string
	}{
		{"all four empty", "", "", "23514"},
		{"twin: first_name only", ", first_name", ", 'FirstName'", ""},
		{"twin: phone only", ", phone", ", '+1 555 010 0000'", ""},
	} {
		err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, p1, "", ""); err != nil {
				return err
			}
			_, err := sp.Exec(ctx, `INSERT INTO personal.contacts (person_id`+c.cols+`) VALUES ($1`+c.vals+`)`, p1)
			return err
		})
		if got := sqlState(err); got != c.state {
			t.Errorf("C2b %s: %v (state %q), want state %q", c.name, err, got, c.state)
		}
	}
}

// TestRLSContactsSyncOnePerPerson is C2c: a human's second contacts_sync row,
// in another workspace whose scope cannot see the first, is a unique
// violation; another human's row there inserts (the twin).
func TestRLSContactsSyncOnePerPerson(t *testing.T) {
	pg := rlsStore(t)
	_, rt := runtimeSession(t)
	ctx := context.Background()
	w1, w2 := uid("t-c2c-"), uid("t-c2c-")
	for _, w := range []string{w1, w2} {
		if err := pg.CreateTenant(ctx, Tenant{ID: w, RootPubKey: pubkey()}); err != nil {
			t.Fatal(err)
		}
	}
	// H holds a seat and a Google connection in both workspaces, the other
	// human in W2 only: the rows a binding's two FKs reference.
	h := seatMember(t, pg, w1, "developer")
	if err := pg.inTenant(ctx, w2, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
			VALUES ($1, $2, 'developer', 'operator')`, w2, h)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	other := seatMember(t, pg, w2, "developer")
	for _, c := range []struct{ tenant, human string }{{w1, h}, {w2, h}, {w2, other}} {
		if err := seedGcalConnection(ctx, pg, c.tenant, c.human); err != nil {
			t.Fatal(err)
		}
	}
	tx := ownerTx(t, pg)
	becomeRuntime(t, tx, rt)
	insert := func(tenant, human string) error {
		return inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, "", tenant, ""); err != nil {
				return err
			}
			_, err := sp.Exec(ctx, `INSERT INTO contacts_sync (human_id, tenant_id) VALUES ($1, $2)`, human, tenant)
			return err
		})
	}
	// H's binding in W1, committed to the outer (rolled-back) transaction.
	if err := scope(ctx, tx, "", w1, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO contacts_sync (human_id, tenant_id) VALUES ($1, $2)`, h, w1); err != nil {
		t.Fatalf("H's binding in W1: %v", err)
	}
	var seen int
	if err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
		if err := scope(ctx, sp, "", w2, ""); err != nil {
			return err
		}
		return sp.QueryRow(ctx, `SELECT count(*) FROM contacts_sync WHERE human_id = $1`, h).Scan(&seen)
	}); err != nil || seen != 0 {
		t.Errorf("C2c W2's scope sees %d of H's bindings (%v), want 0 (RLS hides W1's row)", seen, err)
	}
	if err := insert(w2, h); sqlState(err) != "23505" {
		t.Errorf("C2c H's second binding, in W2: %v, want the unique violation 23505", err)
	}
	if err := insert(w2, other); err != nil {
		t.Errorf("C2c twin: another human's binding in W2: %v, want it inserted", err)
	}
}

// seedGcalConnection writes one Google connection of human in tenant, the
// row a contacts_sync binding references.
func seedGcalConnection(ctx context.Context, pg *Postgres, tenant, human string) error {
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO gcal_connections (tenant_id, human_id, google_email,
			access_sealed, refresh_sealed, kms_key_id, access_expiry)
			VALUES ($1, $2, 'first.last@example.com', 'sealed-a', 'sealed-r', 'fake-kms', now() + interval '1 hour')`, tenant, human)
		return err
	})
}

// TestRLSContactsPurgeDoor is C2d: personal.purge_deleted_contacts as the
// runtime login, with no app.* setting, deletes every person's rows
// soft-deleted more than 30 days ago and names each person once, with
// pending_google true only for a member's delete of a linked contact. Rows
// 29 days old and live rows stay. Twin: the runtime's own DELETE under the
// operator scope deletes 0 rows.
func TestRLSContactsPurgeDoor(t *testing.T) {
	pg := rlsStore(t)
	_, rt := runtimeSession(t)
	ctx := context.Background()
	day := 24 * time.Hour
	tx := ownerTx(t, pg)
	p1, p2 := contactPersons(t, tx)
	// P1: two old member deletes, one linked (an unsent Google delete).
	addContact(t, tx, p1, 31*day, "member", true)
	addContact(t, tx, p1, 31*day, "member", false)
	// P2: an old delete that came from Google (nothing to send).
	addContact(t, tx, p2, 31*day, "google-sync", true)
	for _, who := range []string{p1, p2} {
		addContact(t, tx, who, 29*day, "member", true)
		addContact(t, tx, who, 0, "", false)
	}
	becomeRuntime(t, tx, rt)

	var n int64
	err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
		if err := scope(ctx, sp, "", "", "operator"); err != nil {
			return err
		}
		tag, err := sp.Exec(ctx, `DELETE FROM personal.contacts WHERE deleted_at < now() - interval '30 days'`)
		n = tag.RowsAffected()
		return err
	})
	if err != nil || n != 0 {
		t.Errorf("C2d twin: the runtime's own DELETE under the operator scope: %d row(s) (%v), want 0", n, err)
	}

	got := map[string][]bool{}
	if err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
		if err := scope(ctx, sp, "", "", ""); err != nil {
			return err
		}
		rows, err := sp.Query(ctx, `SELECT person_id, pending_google FROM personal.purge_deleted_contacts(now() - interval '30 days')
			WHERE person_id IN ($1, $2)`, p1, p2)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var p string
			var pending bool
			if err := rows.Scan(&p, &pending); err != nil {
				return err
			}
			got[p] = append(got[p], pending)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		for _, c := range []struct {
			who  string
			want int
		}{{p1, 2}, {p2, 2}} {
			left, err := countContacts(ctx, sp, c.who, "", "", c.who)
			if err != nil || left != c.want {
				t.Errorf("C2d %s's contacts after the purge: %d (%v), want %d (the 29-day-old and the live row)", c.who, left, err, c.want)
			}
		}
		return nil
	}); err != nil {
		t.Fatalf("C2d purge_deleted_contacts as the runtime: %v", err)
	}
	if len(got) != 2 || len(got[p1]) != 1 || len(got[p2]) != 1 || !got[p1][0] || got[p2][0] {
		t.Errorf("C2d purge result: %v, want each person once: %s pending_google=true, %s false", got, p1, p2)
	}
}
