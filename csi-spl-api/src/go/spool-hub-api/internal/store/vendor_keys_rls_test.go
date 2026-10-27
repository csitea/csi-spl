package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 127 D1 (sections 4.2, 7.2): rdb 0174's workspace_vendor_keys,
// workspace_vendor_key_boxes and workspace_vendor_key_audit under row level
// security, and usage_events.key_source. The key table follows the
// personal.profile shape (rdb 0168): tenant_scope ONLY, so the operator
// scope reads 0 rows; the catalogue test pins that and goes red on an
// operator_scope policy. rls_failclosed_test.go's gate covers the policies'
// fail-closed form and TestCrossTenantEveryTable the unscoped writes
// (crosstenant_test.go seeds all three through seedVendorKeys). Postgres
// only (SPOOL_TEST_PG_DSN). Every key here is the obvious fake sk-test-0000:
// the row holds made-up bytes, never a sealed real key.

// The fake key's row: opaque bytes for the sealed key and the wrapped DEK,
// last4 of sk-test-0000, a 64-hex fingerprint. $1 tenant, $2 kind.
const vendorKeyInsert = `INSERT INTO workspace_vendor_keys (tenant_id, kind, key_id, ciphertext, wrapped_dek,
	kms_key_version, last4, fingerprint, set_by)
	VALUES ($1, $2, gen_random_uuid(), '\x00fa4e'::bytea, '\x00dec0'::bytea, 'test-kms-version-1', '0000', repeat('0', 64), 'HUM-1')`

// vendorKeyTables are rdb 0174's three tables, the key table first.
var vendorKeyTables = []string{"workspace_vendor_keys", "workspace_vendor_key_boxes", "workspace_vendor_key_audit"}

// seedVendorKeys writes one key, one approved box and one audit row of
// tenant under the tenant's own scope (the runtime path: RLS WITH CHECK
// admits them).
func seedVendorKeys(ctx context.Context, pg *Postgres, tenant string) error {
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{vendorKeyInsert, []any{tenant, "claude"}},
		{`INSERT INTO workspace_vendor_key_boxes (tenant_id, box_id, approved_by) VALUES ($1, 'box-a', 'HUM-1')`, []any{tenant}},
		{`INSERT INTO workspace_vendor_key_audit (tenant_id, kind, action, actor, last4) VALUES ($1, 'claude', 'set', 'HUM-1', '0000')`, []any{tenant}},
	} {
		if _, err := pg.execTenant(ctx, tenant, q.sql, q.args...); err != nil {
			return fmt.Errorf("seed %s: %w", strings.Fields(q.sql)[2], err)
		}
	}
	return nil
}

// vendorKeysCatalogueGaps returns one line per violation of 4.2's RLS shape:
// ENABLE + FORCE on all three tables, and their policies exactly
// tenant_scope (keys) or operator_scope + tenant_scope (boxes, audit).
func vendorKeysCatalogueGaps(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}) []string {
	want := map[string]string{
		"workspace_vendor_keys":      "tenant_scope",
		"workspace_vendor_key_boxes": "operator_scope,tenant_scope",
		"workspace_vendor_key_audit": "operator_scope,tenant_scope",
	}
	var gaps []string
	for _, tb := range vendorKeyTables {
		var on, force bool
		var pols string
		err := q.QueryRow(ctx, `SELECT c.relrowsecurity, c.relforcerowsecurity,
				COALESCE((SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
				          WHERE schemaname = current_schema() AND tablename = c.relname), '')
			FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
			WHERE n.nspname = current_schema() AND c.relname = $1`, tb).Scan(&on, &force, &pols)
		if err != nil {
			gaps = append(gaps, fmt.Sprintf("%s: %v", tb, err))
			continue
		}
		if !on || !force {
			gaps = append(gaps, fmt.Sprintf("%s: ENABLE + FORCE row level security: enable=%v force=%v", tb, on, force))
		}
		if pols != want[tb] {
			gaps = append(gaps, fmt.Sprintf("%s: policies are exactly %q, found %q", tb, want[tb], pols))
		}
	}
	return gaps
}

// TestRLSVendorKeysCatalogue: the migrated schema matches 4.2. CONTROL: each
// plant, in a rolled-back transaction, turns its own check red and no other.
func TestRLSVendorKeysCatalogue(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	for _, g := range vendorKeysCatalogueGaps(ctx, pg.pool) {
		t.Error(g)
	}
	for _, p := range []struct{ name, sql, want string }{
		{"an operator_scope policy on the keys", `CREATE POLICY operator_scope ON workspace_vendor_keys
			USING (current_setting('app.rls_scope', true) = 'operator')`, "workspace_vendor_keys: policies are exactly"},
		{"a wide read policy on the keys", `CREATE POLICY wide ON workspace_vendor_keys FOR SELECT USING (true)`,
			"workspace_vendor_keys: policies are exactly"},
		{"the keys without FORCE", `ALTER TABLE workspace_vendor_keys NO FORCE ROW LEVEL SECURITY`,
			"workspace_vendor_keys: ENABLE + FORCE"},
		{"the audit without its operator policy", `DROP POLICY operator_scope ON workspace_vendor_key_audit`,
			"workspace_vendor_key_audit: policies are exactly"},
	} {
		func() {
			tx, err := pg.pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(ctx) //nolint:errcheck
			if _, err := tx.Exec(ctx, p.sql); err != nil {
				t.Fatalf("plant %s: %v", p.name, err)
			}
			gaps := vendorKeysCatalogueGaps(ctx, tx)
			if len(gaps) != 1 || !strings.HasPrefix(gaps[0], p.want) {
				t.Errorf("CONTROL %s: gaps %q, want exactly one starting %q", p.name, gaps, p.want)
			}
		}()
	}
}

// TestRLSVendorKeysScopes: workspace B, an empty scope and no scope read
// none of A's rows in any of the three tables; A reads its own; the operator
// reads A's box and audit rows and 0 of A's keys, and cannot write a key
// (no operator policy, 42501). B cannot write an A row (WITH CHECK, 42501).
// CONTROLS: with FORCE lifted (rolled back) B and the operator read A's key,
// and with an operator_scope policy planted (rolled back) the operator does,
// so the zeros are the policy's. A tenant delete takes all three with it,
// the append-only audit included.
func TestRLSVendorKeysScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	for _, tn := range []string{a, b} {
		if err := seedVendorKeys(ctx, pg, tn); err != nil {
			t.Fatal(err)
		}
	}
	for _, tb := range vendorKeyTables {
		op := 1
		if tb == "workspace_vendor_keys" {
			op = 0
		}
		for _, c := range []struct {
			scope string
			want  int
		}{{"tenant:" + b, 0}, {"empty", 0}, {"none", 0}, {"tenant:" + a, 1}, {"operator", op}} {
			if got := scopedTenantCount(t, pg, c.scope, tb, a, false); got != c.want {
				t.Errorf("%s: scope %s reads %d of A's rows, want %d", tb, c.scope, got, c.want)
			}
		}
		if got := scopedTenantCount(t, pg, "tenant:"+b, tb, a, true); got != 1 {
			t.Errorf("CONTROL %s: without FORCE B's scope reads %d of A's rows, want 1", tb, got)
		}
	}
	if got := scopedTenantCount(t, pg, "operator", "workspace_vendor_keys", a, true); got != 1 {
		t.Errorf("CONTROL: without FORCE the operator reads %d of A's keys, want 1", got)
	}
	n := -1
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `CREATE POLICY operator_scope ON workspace_vendor_keys
			USING (current_setting('app.rls_scope', true) = 'operator')`); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM workspace_vendor_keys WHERE tenant_id = $1`, a).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) || n != 1 {
		t.Errorf("CONTROL: with an operator_scope policy the operator reads %d of A's keys (%v), want 1", n, err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, vendorKeyInsert, a, "mistral")
		return err
	}); pgCode(err) != "42501" {
		t.Errorf("the operator wrote a key: %v (want 42501: no operator policy)", err)
	}
	tag, err := pg.asOperator2(ctx, `UPDATE workspace_vendor_keys SET last4 = 'xxxx' WHERE tenant_id = $1`, a)
	if err != nil || tag != 0 {
		t.Errorf("the operator reached %d of A's keys (%v), want 0", tag, err)
	}
	if _, err := pg.execTenant(ctx, b, vendorKeyInsert, a, "mistral"); pgCode(err) != "42501" {
		t.Errorf("an A key written under B's scope: %v (want WITH CHECK, 42501)", err)
	}
	if _, err := pg.execTenant(ctx, b, `INSERT INTO workspace_vendor_key_boxes (tenant_id, box_id, approved_by) VALUES ($1, 'box-b', 'HUM-2')`, a); pgCode(err) != "42501" {
		t.Errorf("an A box approval written under B's scope: %v (want WITH CHECK, 42501)", err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, a)
		return err
	}); err != nil {
		t.Fatalf("tenant delete with a key and an audit row: %v (the cascade must pass the append-only trigger)", err)
	}
	for _, tb := range vendorKeyTables {
		if got := scopedTenantCount(t, pg, "tenant:"+a, tb, a, true); got != 0 {
			t.Errorf("after the tenant delete A holds %d %s rows", got, tb)
		}
	}
	if got := scopedTenantCount(t, pg, "tenant:"+b, "workspace_vendor_keys", b, false); got != 1 {
		t.Errorf("A's delete took B's key: B reads %d, want 1", got)
	}
}

// asOperator2 runs one statement in the operator scope and returns the rows
// it reached.
func (s *Postgres) asOperator2(ctx context.Context, sql string, args ...any) (int64, error) {
	var n int64
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, sql, args...)
		n = tag.RowsAffected()
		return err
	})
	return n, err
}

// TestVendorKeyAuditAppendOnly: an UPDATE and a DELETE of an audit row are
// refused in the workspace's own scope and in the operator scope. CONTROL:
// with the trigger dropped (rolled back) the same UPDATE passes, so the
// refusal is the trigger's and not RLS's.
func TestVendorKeyAuditAppendOnly(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	if err := seedVendorKeys(ctx, pg, a); err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{`UPDATE workspace_vendor_key_audit SET last4 = 'xxxx' WHERE tenant_id = $1`,
		`DELETE FROM workspace_vendor_key_audit WHERE tenant_id = $1`} {
		if _, err := pg.execTenant(ctx, a, w, a); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("workspace scope: %s: %v, want the append-only refusal", w, err)
		}
		if _, err := pg.asOperator2(ctx, w, a); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("operator scope: %s: %v, want the append-only refusal", w, err)
		}
	}
	var n int64
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DROP TRIGGER append_only ON workspace_vendor_key_audit`); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE workspace_vendor_key_audit SET last4 = 'xxxx' WHERE tenant_id = $1`, a)
		n = tag.RowsAffected()
		if err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) || n != 1 {
		t.Fatalf("CONTROL: without the trigger the UPDATE reached %d rows (%v), want 1", n, err)
	}
}

// TestVendorKeysShape: the five kinds of section 3 and no other, one key per
// kind (23505), base_url on qwen alone and https only, a 64-hex
// fingerprint, last4 at most 4; an audit row's action is one of 4.2's seven,
// a key action names its kind and a lease or box action its box (23514).
func TestVendorKeysShape(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	key := func(kind, extra string) string {
		return `INSERT INTO workspace_vendor_keys (tenant_id, kind, key_id, ciphertext, wrapped_dek, kms_key_version, last4, fingerprint, set_by, base_url)
			VALUES ($1, '` + kind + `', gen_random_uuid(), '\x01'::bytea, '\x02'::bytea, 'v1', '0000', repeat('0', 64), 'HUM-1', ` + extra + `)`
	}
	audit := func(cols, vals string) string {
		return `INSERT INTO workspace_vendor_key_audit (tenant_id, actor` + cols + `) VALUES ($1, 'HUM-1'` + vals + `)`
	}
	for _, c := range []struct{ name, sql, code string }{
		{"claude", key("claude", "NULL"), ""},
		{"grok", key("grok", "NULL"), ""},
		{"agy", key("agy", "NULL"), ""},
		{"mistral", key("mistral", "NULL"), ""},
		{"qwen with its endpoint", key("qwen", "'https://llm.example.com/v1'"), ""},
		{"a second claude key", key("claude", "NULL"), "23505"},
		{"an unknown kind", key("openai", "NULL"), "23514"},
		{"base_url on a non-qwen kind", key("grok", "'https://x.example.com'"), "23514"},
		{"base_url over http", key("qwen", "'http://llm.example.com'"), "23514"},
		{"a short fingerprint", `INSERT INTO workspace_vendor_keys (tenant_id, kind, key_id, ciphertext, wrapped_dek, kms_key_version, last4, fingerprint, set_by)
			VALUES ($1, 'qwen', gen_random_uuid(), '\x01'::bytea, '\x02'::bytea, 'v1', '0000', 'abc', 'HUM-1')`, "23514"},
		{"last4 of five", `INSERT INTO workspace_vendor_keys (tenant_id, kind, key_id, ciphertext, wrapped_dek, kms_key_version, last4, fingerprint, set_by)
			VALUES ($1, 'qwen', gen_random_uuid(), '\x01'::bytea, '\x02'::bytea, 'v1', '00000', repeat('0', 64), 'HUM-1')`, "23514"},
		{"an empty ciphertext", `INSERT INTO workspace_vendor_keys (tenant_id, kind, key_id, ciphertext, wrapped_dek, kms_key_version, last4, fingerprint, set_by)
			VALUES ($1, 'qwen', gen_random_uuid(), ''::bytea, '\x02'::bytea, 'v1', '0000', repeat('0', 64), 'HUM-1')`, "23514"},
		{"audit set", audit(", kind, action, last4", ", 'claude', 'set', '0000'"), ""},
		{"audit set without a kind", audit(", action", ", 'set'"), "23514"},
		{"audit lease", audit(", kind, action, box_id, last4", ", 'claude', 'lease', 'box-a', '0000'"), ""},
		{"audit lease without a box", audit(", kind, action", ", 'claude', 'lease'"), "23514"},
		{"audit box approve", audit(", action, box_id", ", 'box_approve', 'box-a'"), ""},
		{"audit box revoke without a box", audit(", action", ", 'box_revoke'"), "23514"},
		{"audit admin confirm", audit(", action, subject", ", 'admin_confirm', 'HUM-7'"), ""},
		// rdb 0232: an admin_confirm names the member it confirms, and only it.
		{"audit admin confirm without a subject", audit(", action", ", 'admin_confirm'"), "23514"},
		{"audit set with a subject", audit(", kind, action, last4, subject", ", 'claude', 'set', '0000', 'HUM-7'"), "23514"},
		{"audit admin confirm of a non-HUM subject", audit(", action, subject", ", 'admin_confirm', 'operator'"), "23514"},
		{"audit unknown action", audit(", action", ", 'read'"), "23514"},
		{"audit last4 of five", audit(", kind, action, last4", ", 'claude', 'set', '00000'"), "23514"},
	} {
		_, err := pg.execTenant(ctx, a, c.sql, a)
		if pgCode(err) != c.code && !(c.code == "" && err == nil) {
			t.Errorf("%s: %v, want %q", c.name, err, c.code)
		}
	}
}

// TestUsageEventsKeySource (7.2, C12): key_source is NOT NULL, one of
// hub | workspace, and has NO default: a writer that forgets it is refused
// (23502), never charged. CONTROL: under rdb 0174's expand default the same
// insert passed and read 'hub', so this goes red if the default comes back.
func TestUsageEventsKeySource(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	ins := `INSERT INTO usage_events (tenant_id, turn_id, kind, key_source) VALUES ($1, $2, 'unmetered', $3)`
	for _, c := range []struct {
		src  any
		code string
	}{{"workspace", ""}, {"hub", ""}, {"guess", "23514"}, {nil, "23502"}} {
		if _, err := pg.execTenant(ctx, a, ins, a, uid("turn-"), c.src); pgCode(err) != c.code && !(c.code == "" && err == nil) {
			t.Errorf("key_source %v: %v, want %q", c.src, err, c.code)
		}
	}
	forgot := `INSERT INTO usage_events (tenant_id, turn_id, kind) VALUES ($1, $2, 'unmetered')`
	if _, err := pg.execTenant(ctx, a, forgot, a, uid("turn-")); pgCode(err) != "23502" {
		t.Errorf("a row written without key_source: %v, want 23502 (no default)", err)
	}
	var def *string
	if err := pg.pool.QueryRow(ctx, `SELECT column_default FROM information_schema.columns
		WHERE table_schema = current_schema() AND table_name = 'usage_events' AND column_name = 'key_source'`).Scan(&def); err != nil || def != nil {
		t.Errorf("usage_events.key_source default %v (%v), want none", show(def), err)
	}
}
