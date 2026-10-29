package store

import (
	"context"
	"errors"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 162 row B3 (rdb 0240, SPL-4167): the Workspace and System logs on
// memory and, with SPOOL_TEST_PG_DSN, Postgres. Each case names its spec 4
// row: C10 and its RED control C11 (the policy without NULLIF), C14 (the
// delete trace) and C15 (the trims).

// TestLogEventKinds pins the kinds the hub writes (spec 162 3.1): each fits
// rdb 0240's kind CHECK, none twice. A new kind is added here on purpose.
func TestLogEventKinds(t *testing.T) {
	want := []string{"log.deleted",
		"lease.claim", "lease.rotation", "lease.seat_move", "lease.failover", "lease.handback", "lease.vendor", "lease.limit",
		"hub.started",
		"member.invited", "member.invite_revoked", "member.role_changed", "member.removed",
		"channel.deleted", "box.join_token_minted", "box.join_token_revoked", "box.pin_revoked"}
	if !slices.Equal(LogEventKinds, want) {
		t.Fatalf("LogEventKinds = %q, want %q", LogEventKinds, want)
	}
	seen := map[string]bool{}
	for _, k := range LogEventKinds {
		if _, err := normLogEvent(LogEvent{Kind: k}); err != nil || seen[k] {
			t.Errorf("kind %q: %v (twice: %v)", k, err, seen[k])
		}
		seen[k] = true
	}
}

// TestLogEvents: each log reads newest first and pages; a bad row is refused
// as the table would; a workspace sees only its own rows; a delete names 1..200
// ids, removes only the log's own (another workspace's id counts 0) and
// leaves one log.deleted row by the deleter (C14); a delete that removes
// nothing leaves none.
func TestLogEvents(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			es := s.(LogEvents)
			a, b := newTenant(t, s), newTenant(t, s)
			if _, err := es.AddWorkspaceEvent(ctx, "", LogEvent{Kind: LogKindMemberInvited}, now); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
			if _, err := es.AddWorkspaceEvent(ctx, uid("t-none-"), LogEvent{Kind: LogKindMemberInvited}, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown tenant: %v", err)
			}
			for _, bad := range []LogEvent{{Kind: "Member"}, {Kind: "member"}, {Kind: "a." + strings.Repeat("b", 47)},
				{Kind: "member.x", Level: "debug"}, {Kind: "member.x", OriginKind: "box", OriginRef: "x"},
				{Kind: "member.x", OriginKind: LogOriginTopic}, {Kind: "member.x", OriginRef: "x"},
				{Kind: "member.x", Actor: strings.Repeat("a", 65)}, {Kind: "member.x", Message: strings.Repeat("m", 801)},
				{Kind: "member.x", OriginKind: LogOriginComponent, OriginRef: strings.Repeat("r", 121)}, {Kind: "member.x", Message: "\xff"}} {
				if _, err := es.AddWorkspaceEvent(ctx, a, bad, now); err == nil {
					t.Fatalf("bad row accepted: %+v", bad)
				}
				if _, err := es.AddSystemEvent(ctx, bad, now); err == nil {
					t.Fatalf("bad system row accepted: %+v", bad)
				}
			}
			one, err := es.AddWorkspaceEvent(ctx, a, LogEvent{Kind: LogKindMemberInvited, Actor: "HUM-1", Message: "one",
				OriginKind: LogOriginComponent, OriginRef: "members"}, now)
			if err != nil || one.ID == 0 || one.Tenant != a || one.Level != LogLevelInfo || !one.At.Equal(now) {
				t.Fatalf("add: %+v %v", one, err)
			}
			var ids []int64
			for _, m := range []string{"two", "three"} {
				e, err := es.AddWorkspaceEvent(ctx, a, LogEvent{Kind: LogKindChannelDeleted, Level: LogLevelWarn, Message: m}, now)
				if err != nil {
					t.Fatal(err)
				}
				ids = append(ids, e.ID)
			}
			theirs, err := es.AddWorkspaceEvent(ctx, b, LogEvent{Kind: LogKindMemberRemoved, Message: "theirs"}, now)
			if err != nil {
				t.Fatal(err)
			}
			got, err := es.WorkspaceEventsPage(ctx, a, 0, 10)
			if err != nil || len(got) != 3 || got[0].Message != "three" || got[2] != one {
				t.Fatalf("page: %v %+v", err, got)
			}
			if p, _ := es.WorkspaceEventsPage(ctx, a, got[0].ID, 1); len(p) != 1 || p[0].Message != "two" {
				t.Fatalf("before: %+v", p)
			}
			if _, err := es.DeleteWorkspaceEvents(ctx, a, nil, "HUM-1", now); !errors.Is(err, ErrLogEventIDs) {
				t.Fatalf("0 ids: %v", err)
			}
			if _, err := es.DeleteWorkspaceEvents(ctx, a, make([]int64, LogEventsDeleteMax+1), "HUM-1", now); !errors.Is(err, ErrLogEventIDs) {
				t.Fatalf("201 ids: %v", err)
			}
			// C14: two own ids and B's one; B's row stays.
			n, err := es.DeleteWorkspaceEvents(ctx, a, append(slices.Clone(ids), theirs.ID), "HUM-7", now)
			if err != nil || n != 2 {
				t.Fatalf("delete: %d %v", n, err)
			}
			got, _ = es.WorkspaceEventsPage(ctx, a, 0, 10)
			if len(got) != 2 || got[1] != one || got[0].Kind != LogKindDeleted || got[0].Actor != "HUM-7" || got[0].Message != "2 rows deleted" {
				t.Fatalf("C14 after delete: %+v", got)
			}
			if p, _ := es.WorkspaceEventsPage(ctx, b, 0, 10); len(p) != 1 || p[0].ID != theirs.ID {
				t.Fatalf("B after A's delete: %+v", p)
			}
			if n, err := es.DeleteWorkspaceEvents(ctx, a, ids, "HUM-7", now); err != nil || n != 0 {
				t.Fatalf("delete again: %d %v", n, err)
			}
			if p, _ := es.WorkspaceEventsPage(ctx, a, 0, 10); len(p) != 2 {
				t.Fatalf("a delete of nothing left a trace: %+v", p)
			}

			// System log: the same contract, hub-wide.
			marker := uid("sys-")
			s1, err := es.AddSystemEvent(ctx, LogEvent{Kind: LogKindHubStarted, Actor: "hub", Message: marker}, now)
			if err != nil || s1.ID == 0 || s1.Tenant != "" {
				t.Fatalf("system add: %+v %v", s1, err)
			}
			s2, err := es.AddSystemEvent(ctx, LogEvent{Kind: LogKindLeaseFailover, Level: LogLevelWarn, Message: marker,
				OriginKind: LogOriginComponent, OriginRef: "lease/main/orch"}, now)
			if err != nil {
				t.Fatal(err)
			}
			if p, _ := es.SystemEventsPage(ctx, s2.ID+1, 2); len(p) != 2 || p[0] != s2 || p[1] != s1 {
				t.Fatalf("system page: %+v", p)
			}
			if n, err := es.DeleteSystemEvents(ctx, []int64{s1.ID}, "HUM-9", now); err != nil || n != 1 {
				t.Fatalf("system delete: %d %v", n, err)
			}
			p, _ := es.SystemEventsPage(ctx, 0, 1)
			if len(p) != 1 || p[0].Kind != LogKindDeleted || p[0].Message != "1 row deleted" || p[0].Actor != "HUM-9" {
				t.Fatalf("system trace: %+v", p)
			}
			if p, _ := es.SystemEventsPage(ctx, s2.ID+1, 2); len(p) == 0 || p[0] != s2 || (len(p) == 2 && p[1].ID == s1.ID) {
				t.Fatalf("system after delete: %+v", p)
			}
			if _, err := es.DeleteSystemEvents(ctx, nil, "HUM-9", now); !errors.Is(err, ErrLogEventIDs) {
				t.Fatalf("system 0 ids: %v", err)
			}
		})
	}
}

// seedLogRows writes n rows into tenant's log ("" = the system log), oldest
// first, and answers the first id. Postgres seeds in one statement.
func seedLogRows(t *testing.T, s Store, tenant string, n int, now time.Time) int64 {
	t.Helper()
	ctx := context.Background()
	if pg, ok := s.(*Postgres); ok {
		var first int64
		var err error
		if tenant == "" {
			err = pg.pool.QueryRow(ctx, `WITH ins AS (INSERT INTO system_events (at, kind, message)
				SELECT $1, 'hub.started', 'seed ' || g FROM generate_series(1, $2) g RETURNING id) SELECT min(id) FROM ins`, now, n).Scan(&first)
		} else {
			err = pg.queryRowTenant(ctx, tenant, `WITH ins AS (INSERT INTO workspace_events (tenant_id, at, kind, message)
				SELECT $1, $2, 'member.invited', 'seed ' || g FROM generate_series(1, $3) g RETURNING id) SELECT min(id) FROM ins`,
				[]any{tenant, now, n}, &first)
		}
		if err != nil {
			t.Fatal(err)
		}
		return first
	}
	es := s.(LogEvents)
	var first int64
	for i := 0; i < n; i++ {
		var e LogEvent
		var err error
		if tenant == "" {
			e, err = es.AddSystemEvent(ctx, LogEvent{Kind: LogKindHubStarted, Message: "seed"}, now)
		} else {
			e, err = es.AddWorkspaceEvent(ctx, tenant, LogEvent{Kind: LogKindMemberInvited, Message: "seed"}, now)
		}
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			first = e.ID
		}
	}
	return first
}

// TestLogEventsTrim (C15): the 5001st row of a workspace trims the oldest of
// that workspace only; the 10001st system row trims the oldest system row.
func TestLogEventsTrim(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			es := s.(LogEvents)
			a, b := newTenant(t, s), newTenant(t, s)
			first := seedLogRows(t, s, a, WorkspaceEventsKeep, now)
			other := seedLogRows(t, s, b, 3, now)
			last, err := es.AddWorkspaceEvent(ctx, a, LogEvent{Kind: LogKindMemberRemoved, Message: "the 5001st"}, now)
			if err != nil {
				t.Fatal(err)
			}
			all, _ := es.WorkspaceEventsPage(ctx, a, 0, WorkspaceEventsKeep+10)
			if len(all) != WorkspaceEventsKeep || all[0] != last || all[len(all)-1].ID != first+1 {
				t.Fatalf("C15 workspace trim: %d rows, newest %d (want %d), oldest %d (want %d)",
					len(all), all[0].ID, last.ID, all[len(all)-1].ID, first+1)
			}
			if p, _ := es.WorkspaceEventsPage(ctx, b, 0, 10); len(p) != 3 || p[2].ID != other {
				t.Fatalf("C15: A's trim touched B: %+v", p)
			}

			sysFirst := seedLogRows(t, s, "", SystemEventsKeep, now)
			sysLast, err := es.AddSystemEvent(ctx, LogEvent{Kind: LogKindHubStarted, Message: "the 10001st"}, now)
			if err != nil {
				t.Fatal(err)
			}
			sys, _ := es.SystemEventsPage(ctx, 0, SystemEventsKeep+10)
			if len(sys) != SystemEventsKeep || sys[0] != sysLast || sys[len(sys)-1].ID <= sysFirst {
				t.Fatalf("C15 system trim: %d rows, newest %d (want %d), oldest %d (want > %d)",
					len(sys), sys[0].ID, sysLast.ID, sys[len(sys)-1].ID, sysFirst)
			}
		})
	}
}

// wsEventCount counts tenant's workspace_events rows in one fresh
// transaction under scope: "tenant:<id>", "empty" (app.tenant_id set to the empty string) or
// "none" (never set), the cost_lines_rls_test.go shape.
func wsEventCount(t *testing.T, pg *Postgres, scope, tenant string) int {
	t.Helper()
	ctx := context.Background()
	n := -1
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		switch {
		case scope == "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		case strings.HasPrefix(scope, "tenant:"):
			_, err = tx.Exec(ctx, pgScopeTenant, strings.TrimPrefix(scope, "tenant:"))
		}
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM workspace_events WHERE tenant_id = $1`, tenant).Scan(&n)
	})
	if err != nil {
		t.Fatalf("%s: %v", scope, err)
	}
	return n
}

// TestRLSWorkspaceEvents (C10): a row of workspace A is not read in B's
// scope, nor with an empty or no tenant set, and B cannot write an A row
// (42501) nor delete one. CONTROL: with FORCE lifted (rolled back) the owner
// reads A's row with no tenant set, so the zeros are the policy's.
func TestRLSWorkspaceEvents(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	e, err := pg.AddWorkspaceEvent(ctx, a, LogEvent{Kind: LogKindMemberInvited, Message: "A only"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		scope string
		want  int
	}{{"tenant:" + b, 0}, {"empty", 0}, {"none", 0}, {"tenant:" + a, 1}} {
		if got := wsEventCount(t, pg, c.scope, a); got != c.want {
			t.Errorf("C10: scope %s reads %d of A's rows, want %d", c.scope, got, c.want)
		}
	}
	if _, err := pg.execTenant(ctx, b, `INSERT INTO workspace_events (tenant_id, kind) VALUES ($1, 'member.invited')`, a); pgCode(err) != "42501" {
		t.Errorf("C10: an A row written under B's scope: %v (want 42501)", err)
	}
	if n, err := pg.DeleteWorkspaceEvents(ctx, b, []int64{e.ID}, "HUM-1", time.Now().UTC()); err != nil || n != 0 {
		t.Errorf("C10: B deleted %d of A's rows (%v)", n, err)
	}
	if tag, err := pg.execTenant(ctx, b, `DELETE FROM workspace_events WHERE id = $1`, e.ID); err != nil || tag.RowsAffected() != 0 {
		t.Errorf("C10: B's unscoped delete reached %d of A's rows (%v)", tag.RowsAffected(), err)
	}
	if got := wsEventCount(t, pg, "tenant:"+a, a); got != 1 {
		t.Fatalf("C10: after B's writes A holds %d rows, want 1", got)
	}
	var lifted int
	err = pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `ALTER TABLE workspace_events NO FORCE ROW LEVEL SECURITY`); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM workspace_events WHERE tenant_id = $1`, a).Scan(&lifted); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) || lifted != 1 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of A's rows with no tenant (%v), want 1", lifted, err)
	}
}

// TestRLSWorkspaceEventsNullifControl (C11, the RED control of C10, the
// rls_failclosed_test.go pattern): rdb 0240's tenant_scope with the NULLIF
// taken out (the 0014 form) lets a statement with an empty tenant read a
// row whose tenant_id is empty, and the catalogue gate reports it; with
// 0240's own policy it reports nothing on workspace_events.
func TestRLSWorkspaceEventsNullifControl(t *testing.T) {
	rlsStore(t)
	ctx := context.Background()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	gaps, err := tenantPolicyGaps(ctx, dsn, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `ALTER POLICY tenant_scope ON workspace_events
			USING (tenant_id = current_setting('app.tenant_id', true))
			WITH CHECK (tenant_id = current_setting('app.tenant_id', true))`)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	const want = `workspace_events.tenant_scope: tenant empty: USING is TRUE for a row with tenant_id ""`
	if !strings.Contains(strings.Join(gaps, "\n"), want) {
		t.Errorf("C11 CONTROL: the policy without NULLIF was not reported (%q); gaps: %q", want, gaps)
	}
	gaps, err = tenantPolicyGaps(ctx, dsn, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, g := range gaps {
		if strings.HasPrefix(g, "workspace_events") {
			t.Errorf("C11: rdb 0240's own policy is reported: %s", g)
		}
	}
}
