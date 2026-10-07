package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 099 T003, section 7.4: the head tables under row level security and
// the roles that write them. rls_failclosed_test.go's catalogue gate already
// covers the three tables' policies (rdb 0144 is in its catalogue); this
// file proves the behaviour: what each scope reads and may write, that the
// triggers keep heads right when the hub's runtime role writes, and when the
// operator scope (the sweep, the orc actions) writes, and that a tenant
// delete (E25) takes the heads with it. Postgres only (SPOOL_TEST_PG_DSN);
// the runtime cases need SPOOL_TEST_PG_RUNTIME_DSN (hub-pg.tst.sh).

// headTables are rdb 0144's tables.
var headTables = []string{"topic_heads", "topic_head_parts", "topic_head_tenants"}

// headRowCounts is how many rows of tenant each head table shows in the
// scope that setup set on tx ("" setup = none).
func headRowCounts(ctx context.Context, tx pgx.Tx, tenant string) (string, error) {
	out := ""
	for _, tb := range headTables {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+tb+` WHERE tenant_id = $1`, tenant).Scan(&n); err != nil {
			return "", err
		}
		out += fmt.Sprintf("%s=%d ", tb, n)
	}
	return out, nil
}

// headRLSFix is a tenant with two heads, two parts and a backfill mark.
func headRLSFix(t *testing.T, pg *Postgres) *headFix {
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	f.line("x0", "X", time.Minute, lineOpt{card: true})
	f.line("y0", "Y", time.Minute, dmHumAgt)
	_, err := pg.execTenant(context.Background(), f.tn, `INSERT INTO topic_head_tenants (tenant_id, backfilled_at) VALUES ($1, now())`, f.tn)
	f.must("mark", err)
	return f
}

// scopedCounts reads t1's head rows in one fresh transaction under scope:
// "tenant:<id>", "operator", "empty" (app.tenant_id = ”) or "none".
func scopedCounts(t *testing.T, pg *Postgres, scope, t1 string) string {
	t.Helper()
	ctx := context.Background()
	var got string
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		switch {
		case scope == "operator":
			_, err = tx.Exec(ctx, pgScopeOperator)
		case scope == "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		case len(scope) > 7 && scope[:7] == "tenant:":
			_, err = tx.Exec(ctx, pgScopeTenant, scope[7:])
		}
		if err != nil {
			return err
		}
		got, err = headRowCounts(ctx, tx, t1)
		return err
	})
	if err != nil {
		t.Fatalf("%s: %v", scope, err)
	}
	return got
}

// TestRLSTopicHeadScopes: t2's scope, an empty scope and no scope read none
// of t1's head, part and mark rows; t1's scope and the operator read all of
// them; a write of a t1 row under t2's scope fails WITH CHECK, and an
// UPDATE of t1's rows under t2's scope touches none. CONTROL: with FORCE
// row level security lifted (rolled back) the owner role reads t1's heads
// under t2's scope, so the counts above are the policy's doing.
func TestRLSTopicHeadScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	f, t2 := headRLSFix(t, pg), newTenant(t, pg)
	all, none := "topic_heads=2 topic_head_parts=2 topic_head_tenants=1 ", "topic_heads=0 topic_head_parts=0 topic_head_tenants=0 "
	for _, c := range []struct{ scope, want string }{
		{"tenant:" + t2, none}, {"empty", none}, {"none", none}, {"tenant:" + f.tn, all}, {"operator", all},
	} {
		if got := scopedCounts(t, pg, c.scope, f.tn); got != c.want {
			t.Errorf("scope %s reads %s, want %s", c.scope, got, c.want)
		}
	}
	writes := []string{ // $2 is X's task id where the statement needs it
		`INSERT INTO topic_heads (tenant_id, task_id, last_at, last_msg_id, valid_until, card_archived, archived_rows, rev, changed_at)
			VALUES ($1, gen_random_uuid(), now(), gen_random_uuid(), now(), $2::uuid IS NULL, 0, 1, now())`,
		`INSERT INTO topic_head_parts (tenant_id, task_id, part, channel, last_at, last_msg_id, valid_until, rev)
			VALUES ($1, $2, 'c:x', 'x', now(), gen_random_uuid(), now(), 1)`,
		`INSERT INTO topic_head_tenants (tenant_id) SELECT $1 WHERE $2::uuid IS NOT NULL ON CONFLICT DO NOTHING`,
	}
	for _, w := range writes {
		_, err := pg.execTenant(ctx, t2, w, f.tn, f.task["X"])
		if pgCode(err) != "42501" {
			t.Errorf("a t1 row written under t2's scope: %v (want WITH CHECK, 42501)\n%s", err, w)
		}
	}
	for _, tb := range headTables {
		tag, err := pg.execTenant(ctx, t2, `UPDATE `+tb+` SET tenant_id = tenant_id WHERE tenant_id = $1`, f.tn)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope updated %d %s rows of t1: %v", tag.RowsAffected(), tb, err)
		}
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("diff: %v", d)
	}
	rlsLiftControl(t, pg, f.tn, t2)
}

// rlsLiftControl lifts FORCE on topic_heads in a rolled-back transaction:
// the owner then reads t1's heads under t2's scope.
func rlsLiftControl(t *testing.T, pg *Postgres, t1, t2 string) {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		for _, q := range []string{`ALTER TABLE topic_heads NO FORCE ROW LEVEL SECURITY`, `SELECT set_config('app.tenant_id', '` + t2 + `', true)`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM topic_heads WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("control: %v", err)
	}
	if n != 2 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of t1's heads under t2's scope, want 2", n)
	}
}

// runtimeStore opens the hub's runtime login (DML grants only, not the
// owner) as a store, and names its role.
func runtimeStore(t *testing.T) (*Postgres, string) {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_RUNTIME_DSN unset (hub-pg.tst.sh sets it to the runtime role)")
	}
	ctx := context.Background()
	rt, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.Close)
	var role string
	if err := rt.pool.QueryRow(ctx, `SELECT current_user`).Scan(&role); err != nil {
		t.Fatal(err)
	}
	if by, err := rt.RLSBypassed(ctx); err != nil || by {
		t.Fatalf("the runtime role %s bypasses RLS (%v): it would prove nothing", role, err)
	}
	return rt, role
}

// TestTopicHeadRuntimeRole: E01, E07, E13, E16 and E18 written by the
// runtime role through the store, under its tenant scope; the triggers'
// functions are SECURITY INVOKER, so they write the heads as that role: each
// step moves a rev (E07 moves E01's new latest line, E16 deletes B's latest)
// and the diff is empty after each. Then E25: the runtime role deletes the
// tenant under the operator scope, and its heads, parts and mark cascade
// away. CONTROL: with INSERT on topic_head_parts revoked (rolled back), the
// runtime role's insert fails at the drain.
func TestTopicHeadRuntimeRole(t *testing.T) {
	pg := rlsStore(t)
	rt, role := runtimeStore(t)
	ctx := context.Background()
	f := seedHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	rf := *f
	rf.pg = rt
	steps := []struct {
		id    string
		apply func() error
	}{
		{"E01", func() error { rf.line("a3", "A", time.Minute, lineOpt{}); return nil }},
		{"E07", func() error {
			_, err := rt.MoveMessage(ctx, f.tn, f.msg["a3"], f.task["B"], "crew", "HUM-1", f.t0, time.Time{})
			return err
		}},
		{"E13", func() error { _, err := rt.SetArchived(ctx, f.tn, f.msg["a0"], "HUM-1", f.t0, true); return err }},
		{"E16", func() error { return rt.DeleteMessage(ctx, f.tn, f.msg["a3"]) }},
		{"E18", func() error { _, err := rt.DeleteTopic(ctx, f.tn, f.msg["a0"], f.task["A"]); return err }},
	}
	for _, s := range steps {
		before := headRevs(f)
		if err := s.apply(); err != nil {
			t.Fatalf("%s as %s: %v", s.id, role, err)
		}
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("%s as %s: %v", s.id, role, d)
		}
		if fmt.Sprint(headRevs(f)) == fmt.Sprint(before) {
			t.Fatalf("%s as %s wrote no head", s.id, role)
		}
	}
	tenantDeleteAs(t, rt, f)
	runtimeGrantControl(t, pg, role)
}

// tenantDeleteAs is E25 run by s (the runtime role): an insert and the
// tenant's delete in ONE operator transaction - the drain at COMMIT finds
// the tenant gone and skips it - then no head, part or mark of it is left.
func tenantDeleteAs(t *testing.T, s *Postgres, f *headFix) {
	t.Helper()
	ctx := context.Background()
	m := f.lineMsg("e25", "E", 0, lineOpt{card: true})
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if err := txInsert(ctx, tx, m); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, f.tn)
		return err
	})
	if err != nil {
		t.Fatalf("E25: %v", err)
	}
	var got string
	f.must("E25 counts", pgOperatorTx(f.pg, func(tx pgx.Tx) (err error) {
		got, err = headRowCounts(ctx, tx, f.tn)
		return err
	}))
	if got != "topic_heads=0 topic_head_parts=0 topic_head_tenants=0 " {
		t.Fatalf("E25: after the tenant delete: %s", got)
	}
}

func pgOperatorTx(pg *Postgres, fn func(pgx.Tx) error) error {
	return pg.asOperator(context.Background(), fn)
}

// runtimeGrantControl: in an owner transaction rolled back, INSERT on
// topic_head_parts is revoked from the runtime role, the transaction takes
// that role (becomeRuntime) and inserts a line; the drain, fired at once,
// fails with 42501 - a missing grant would turn the runtime test red.
func runtimeGrantControl(t *testing.T, pg *Postgres, role string) {
	t.Helper()
	ctx := context.Background()
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	m := f.lineMsg("g0", "G", 0, lineOpt{card: true})
	tx := ownerTx(t, pg)
	if _, err := tx.Exec(ctx, `REVOKE INSERT ON topic_head_parts FROM `+pgx.Identifier{role}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	becomeRuntime(t, tx, role)
	if _, err := tx.Exec(ctx, pgScopeTenant, f.tn); err != nil {
		t.Fatal(err)
	}
	if err := txInsert(ctx, tx, m); err != nil {
		t.Fatal(err)
	}
	_, err := tx.Exec(ctx, `SET CONSTRAINTS topic_head_apply IMMEDIATE`)
	if pgCode(err) != "42501" {
		t.Fatalf("CONTROL: the drain without INSERT on topic_head_parts: %v (want 42501)", err)
	}
}

// TestTopicHeadOperatorWrites: the operator scope's writers keep the heads
// right - the hub's Sweep (global, as the one sweeper runs it) purging two
// expired lines, then the orc topic delete (spl-topic-delete: the topic walk
// and one DELETE in one operator transaction) of A and its child K, then the
// orc message wipe (spl-msg-wipe) of the tenant; the diff is empty after
// each, and the wipe leaves no head.
func TestTopicHeadOperatorWrites(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	f := seedHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	expireOne(f, "a3", "A", lineOpt{})
	f.line("z0", "Z", 30*time.Second, lineOpt{card: true, ttl: headTTL})
	if _, err := pg.Sweep(ctx, f.now); err != nil {
		t.Fatal(err)
	}
	if n := lineCount(f, ""); n != 11 {
		t.Fatalf("after the sweep: %d lines, want 11", n)
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the sweep: %v", d)
	}
	f.must("topic delete", pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `WITH RECURSIVE topic(msg_id, task_id) AS (
				SELECT msg_id, task_id FROM messages WHERE tenant_id = $1 AND task_id = $2::uuid
			UNION
				SELECT m.msg_id, m.task_id FROM messages m JOIN topic t
				ON m.tenant_id = $1 AND (m.task_id = t.msg_id OR m.parent_task_id = t.task_id))
			DELETE FROM messages WHERE tenant_id = $1 AND msg_id IN (SELECT msg_id FROM topic)`, f.tn, f.task["A"])
		return err
	}))
	if a, k := lineCount(f, f.task["A"]), lineCount(f, f.task["K"]); a+k != 0 {
		t.Fatalf("the topic delete left %d lines in A and %d in K", a, k)
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the topic delete: %v", d)
	}
	f.must("wipe", pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM messages WHERE tenant_id = $1`, f.tn)
		return err
	}))
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the wipe: %v", d)
	}
	if revs := headRevs(f); len(revs) != 0 {
		t.Fatalf("the wipe left %d heads: %v", len(revs), revs)
	}
}

// TestCrossTenantTopicHeads: the store's writers, called with t2's tenant
// and t1's ids (the same task uuid exists in both), never touch t1's heads.
func TestCrossTenantTopicHeads(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	t0 := time.Now().UTC().Truncate(time.Microsecond)
	f1, f2 := seedHeadFix(t, pg, t0), lightHeadFix(t, pg, t0)
	f2.task["A"] = f1.task["A"]
	f2.line("a0", "A", time.Hour, lineOpt{card: true})
	before := headRevs(f1)
	_, _ = pg.MoveMessage(ctx, f2.tn, f1.msg["a2"], f1.task["B"], "crew", "HUM-1", t0, time.Time{})
	_, _ = pg.SetArchived(ctx, f2.tn, f1.msg["a0"], "HUM-1", t0, true)
	_ = pg.DeleteMessage(ctx, f2.tn, f1.msg["a1"])
	_, _ = pg.DeleteTopic(ctx, f2.tn, f1.msg["b0"], f1.task["B"])
	_, _ = pg.MergeTopic(ctx, f2.tn, f1.task["A"], f1.task["A"], f1.task["D"], ChannelLobby, "HUM-1", t0)
	if after := headRevs(f1); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Fatalf("writes under %s moved %s's heads:\n before %v\n after  %v", f2.tn, f1.tn, before, after)
	}
	for _, f := range []*headFix{f1, f2} {
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("tenant %s: %v", f.tn, d)
		}
	}
	// CONTROL: the same move under t1's own tenant does write t1's heads.
	if _, err := pg.MoveMessage(ctx, f1.tn, f1.msg["a2"], f1.task["B"], "crew", "HUM-1", t0, time.Time{}); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(headRevs(f1)) == fmt.Sprint(before) {
		t.Fatal("CONTROL: t1's own move wrote no head")
	}
}
