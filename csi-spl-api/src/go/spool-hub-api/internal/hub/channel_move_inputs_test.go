// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The detail of a plan or a step (spec 169 T7d): the owner's keep, keep_emails,
// leave_hours and the box rule's doc reach the store, and the caller is the seat
// P2 checks.

func moveDetail(d map[string]any) map[string]any { return map[string]any{"detail": d} }

// moveCount counts rows under the operator scope, as a fixture reads them.
func moveCount(t *testing.T, e *env, sql string, args ...any) int {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		return tx.QueryRow(ctx, sql, args...).Scan(&n)
	})
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// Q5: an hours row of a member who does not come along stops plan, P2 and P4
// until leave_hours names that member; P4 then leaves the row in <SRC>.
// CONTROLS in the same run: without the detail plan and P2 refuse on the same
// stop, and a P4 whose detail is not P2's is refused.
func TestChannelMoveLeaveHoursT7d(t *testing.T) {
	f := moveFixture(t, true)
	moveExec(t, f.e, `INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by, entered_by)
		VALUES ($1, $2, '2026-06-10', $3, 30, 'proposed', $2, $2)`, f.src, f.admin, "ch:"+f.ch)
	q5 := "hours: " + f.admin + " 1 rows not coming to " + f.dst + " (Q5)"
	leave := moveDetail(map[string]any{"leave_hours": []string{f.admin}})
	if r := anyStrings(f.must(t, "plan", "", nil)["refuse"]); !slices.Contains(r, q5) {
		t.Fatalf("CONTROL: plan without the detail must name %q: %v", q5, r)
	}
	if r := f.must(t, "plan", "", leave)["refuse"]; listLen(r) != 0 {
		t.Fatalf("leave_hours clears the stop in plan: %v", r)
	}
	f.moveID, _ = f.must(t, "step", "P1", leave)["move_id"].(string)
	f.refused(t, "step", "P2", q5, nil)
	f.must(t, "step", "P2", leave)
	f.must(t, "mark", "P2b", f.probes(f.probe(t)))
	f.must(t, "step", "P3", leave)
	f.refused(t, "step", "P4", "not the one P2 checked", nil)
	f.must(t, "step", "P4", leave)
	q := `SELECT count(*) FROM hours_entries WHERE tenant_id = $1 AND member_id = $2`
	if n := moveCount(t, f.e, q, f.src, f.admin); n != 1 {
		t.Errorf("the row the owner said to leave: %d in <SRC>, want 1", n)
	}
	if n := moveCount(t, f.e, q, f.dst, f.admin); n != 0 {
		t.Errorf("the row the owner said to leave was carried: %d in <DST>", n)
	}
}

// Q5 and 5.1b: keep takes a person off the leaving list, keep_emails moves that
// channel invite with its workspace invite; the other invite is deleted.
// CONTROL: plan without keep lists the person as leaving.
func TestChannelMoveKeepT7d(t *testing.T) {
	f := moveFixture(t, true)
	for _, m := range []string{"kept@example.com", "gone@example.com"} {
		moveExec(t, f.e, `INSERT INTO tenant_invites (tenant_id, email, role, invited_by, expires_at) VALUES ($1, $2, 'member', $3, now() + interval '1 day')`, f.src, m, f.admin)
		moveExec(t, f.e, `INSERT INTO channel_invites (tenant_id, channel_id, email, added_by) VALUES ($1, $2, $3, $4)`, f.src, f.ch, m, f.admin)
	}
	if lost := anyStrings(f.must(t, "plan", "", nil)["members_lost"]); !slices.Contains(lost, f.admin) {
		t.Fatalf("CONTROL: without keep %s leaves: %v", f.admin, lost)
	}
	keep := moveDetail(map[string]any{"keep": []string{f.admin}, "keep_emails": []string{"kept@example.com"}})
	if lost := f.must(t, "plan", "", keep)["members_lost"]; listLen(lost) != 0 {
		t.Fatalf("keep takes %s off the leaving list: %v", f.admin, lost)
	}
	f.moveID, _ = f.must(t, "step", "P1", keep)["move_id"].(string)
	f.must(t, "step", "P2", keep)
	f.must(t, "mark", "P2b", f.probes(f.probe(t)))
	f.must(t, "step", "P3", keep)
	f.must(t, "step", "P4", keep)
	inv := `SELECT count(*) FROM channel_invites WHERE tenant_id = $1 AND email = $2`
	if n := moveCount(t, f.e, inv, f.dst, "kept@example.com"); n != 1 {
		t.Errorf("the kept invite in <DST>: %d, want 1", n)
	}
	if n := moveCount(t, f.e, `SELECT count(*) FROM tenant_invites WHERE tenant_id = $1 AND email = 'kept@example.com'`, f.dst); n != 1 {
		t.Errorf("the kept invite's workspace invite in <DST>: %d, want 1", n)
	}
	if n := moveCount(t, f.e, inv, f.src, "gone@example.com") + moveCount(t, f.e, inv, f.dst, "gone@example.com"); n != 0 {
		t.Errorf("the invite not kept: %d rows left", n)
	}
}

// F14: a Qto doc named only by the box rule row is in the set when the detail
// carries it. CONTROL: the same plan without rule_doc leaves it out.
func TestChannelMoveRuleDocT7d(t *testing.T) {
	f := moveFixture(t, true)
	doc, _, err := f.e.st.(*store.Postgres).DocCreate(context.Background(), f.src, "the channel's rules", "", f.admin)
	if err != nil {
		t.Fatal(err)
	}
	counts := func(out map[string]any) any { c, _ := out["counts"].(map[string]any); return c["workspace_doc"] }
	if n := counts(f.must(t, "plan", "", nil)); n != float64(0) {
		t.Fatalf("CONTROL: without rule_doc the doc is not in the set: %v", n)
	}
	if n := counts(f.must(t, "plan", "", moveDetail(map[string]any{"rule_doc": doc}))); n != float64(1) {
		t.Errorf("rule_doc puts the doc in the set: %v", n)
	}
}

// MOVE_CALLER: P2 checks the caller's seat, on its box when it names one.
// CONTROL: the same move with no caller, or the orchestrator's own seat, passes.
func TestChannelMoveCallerT7d(t *testing.T) {
	f := moveFixture(t, true)
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	for _, c := range []string{"c-001@box-z", "c-204@box-a", "c-009"} {
		f.refused(t, "step", "P2", "caller "+c+" is no orchestrator seat", moveDetail(map[string]any{"caller": c}))
	}
	for _, c := range []string{"", "c-001", "c-001@box-a"} {
		f.must(t, "step", "P2", moveDetail(map[string]any{"caller": c}))
	}
}

// A detail the hub does not read is refused, not dropped: a typo would leave a
// stop the owner meant to clear.
func TestChannelMoveBadDetailT7d(t *testing.T) {
	e := chanMoveEnv(t)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	moveChannel(t, e, src, "proj-d", seat(t, e, src, "admin"))
	for _, d := range []map[string]any{
		{"leave_hour": []string{"HUM-1"}}, {"keep": []string{"c-204"}}, {"keep_emails": []string{"no-at"}},
		{"rule_doc": "not-a-uuid"}, {"caller": "HUM-10"},
	} {
		code, out := opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("plan", src, "proj-d", dst, moveDetail(d)))
		if code != http.StatusBadRequest || out["error"] != "bad_detail" {
			t.Errorf("detail %v: %d %v, want 400 bad_detail", d, code, out)
		}
	}
}
