// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// moveStatusFix is a move after P1, read through the status route as reader:
// the biz owner of the operator workspace and a member of <DST>.
type moveStatusFix struct {
	*moveFix
	reader string
	skew   *atomic.Int64
}

func moveStatusFixture(t *testing.T) moveStatusFix {
	t.Helper()
	skew := &atomic.Int64{}
	f := moveFixture(t, false, func(o *hub.Options) {
		o.Now = func() time.Time { return time.Now().Add(time.Duration(skew.Load())) }
	})
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	return moveStatusFix{moveFix: f, reader: seatAs(t, f.e, f.op, rbac.BizOwner, f.dst, rbac.Developer), skew: skew}
}

// status is GET /v1/channel-moves/{id} in <DST>'s host.
func (f moveStatusFix) status(t *testing.T, as, id string) (int, map[string]any) {
	t.Helper()
	return call(t, f.e, f.dst, http.MethodGet, "/v1/channel-moves/"+id, as, nil)
}

// state wants a 200 and answers it.
func (f moveStatusFix) state(t *testing.T) map[string]any {
	t.Helper()
	code, out := f.status(t, f.reader, f.moveID)
	if code != http.StatusOK {
		t.Fatalf("status: %d %v", code, out)
	}
	return out
}

// hubLines are the HUB-0 bodies of tenant's task, oldest first.
func hubLines(t *testing.T, e *env, tenant, task, channel string) []string {
	t.Helper()
	ctx := context.Background()
	var out []string
	err := pgx.BeginFunc(ctx, e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT body FROM messages WHERE tenant_id = $1 AND from_id = $2
			AND ($3 = '' OR task_id = $3::uuid) AND ($4 = '' OR channel = $4) ORDER BY received_at, msg_id`, tenant, hub.PublicNoticeFrom, task, channel)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var b string
			if err := rows.Scan(&b); err != nil {
				return err
			}
			out = append(out, b)
		}
		return rows.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// C35, the hub's half (spec 169 T17, 8.5.6), on a real P1 and a refused P2:
// the route answers the steps and the reason to the biz owner of the operator
// workspace in <DST>, and 404 to everyone else: a <DST> member, the operator
// workspace's admin, a member of <SRC> (all three <DST> members), an unknown
// id. A wait of 15 minutes posts one line in the GO's topic and one #alerts
// line, once however often the sweep runs. P2's refusal is stored in its row
// and posted once, however often it is refused for that reason. RED CONTROL:
// drop s.channelMoveRecord from channelMoveDrive -> the refusal is not stored,
// the state stays waiting and this test fails.
func TestChannelMoveStatusC35(t *testing.T) {
	f := moveStatusFixture(t)
	st := f.state(t)
	if st["state"] != "waiting" || st["stuck"] != false || st["src"] != f.src || st["channel"] != f.ch || st["dst"] != f.dst {
		t.Fatalf("after P1: %v", st)
	}
	if p1, _ := st["steps"].(map[string]any)["P1"].(map[string]any); p1["state"] != "done" {
		t.Fatalf("P1's step: %v", st["steps"])
	}
	for name, who := range map[string]string{
		"a <DST> member":        seat(t, f.e, f.dst, rbac.Developer),
		"the operator's admin":  seatAs(t, f.e, f.op, rbac.Admin, f.dst, rbac.Developer),
		"a member of <SRC>":     seatAs(t, f.e, f.src, rbac.Admin, f.dst, rbac.Developer),
		"the <SRC> member here": f.admin,
	} {
		code, out := f.status(t, who, f.moveID)
		want := http.StatusNotFound
		if who == f.admin {
			want = http.StatusForbidden // no <DST> member: the session door answers first (C29)
		}
		if code != want {
			t.Errorf("%s: %d %v, want %d", name, code, out, want)
		}
	}
	if code, _ := f.status(t, f.reader, uuid4()); code != http.StatusNotFound {
		t.Errorf("an unknown move: %d, want 404", code)
	}

	f.e.srv.SweepChannelMoves(context.Background())
	if lines := hubLines(t, f.e, f.op, f.formTask, ""); len(lines) != 0 {
		t.Fatalf("a wait of a moment posted %q", lines)
	}
	f.skew.Store(int64(16 * time.Minute))
	for range 2 {
		f.e.srv.SweepChannelMoves(context.Background())
	}
	if st := f.state(t); st["state"] != "waiting" || st["stuck"] != true {
		t.Fatalf("after 16 minutes: %v", st)
	}
	lines := hubLines(t, f.e, f.op, f.formTask, "")
	alerts := hubLines(t, f.e, f.op, "", store.ChannelAlerts)
	if len(lines) != 1 || !strings.HasPrefix(lines[0], "Waiting for a box to pick this up.") || len(alerts) != 1 || !strings.Contains(alerts[0], f.moveID) {
		t.Fatalf("the wait's line %q and alert %q, want one each", lines, alerts)
	}
	if strings.Contains(alerts[0], f.ch) {
		t.Errorf("the #alerts line names the channel: %q", alerts[0])
	}

	for range 2 {
		f.refused(t, "step", "P2", "no orchestrator seat", nil)
	}
	st = f.state(t)
	reason, _ := st["reason"].(string)
	p2, _ := st["steps"].(map[string]any)["P2"].(map[string]any)
	if st["state"] != "not_moved" || st["step"] != "P2" || !strings.Contains(reason, "no orchestrator seat") || p2["state"] != "refused" {
		t.Fatalf("a refused P2: %v", st)
	}
	lines = hubLines(t, f.e, f.op, f.formTask, "")
	if len(lines) != 2 || !strings.HasPrefix(lines[1], "Not moved. Nothing of the channel changed: ") || !strings.Contains(lines[1], "no orchestrator seat") {
		t.Fatalf("the GO's topic after two refusals: %q", lines)
	}
}

// C35, each later row of 8.5.6's table from a seeded journal: P6 refused after
// P4 -> cleanup_failed; P7 refused with a proof -> traces, naming the proof and
// its count; P7 done but no done_at -> not "moved"; done_at -> moved with
// P7's kept list. RED CONTROL: answer "moved" on P7 done (channelMoveStatusOf)
// -> the journal without done_at reads as moved and this test fails.
func TestChannelMoveStatusTableC35(t *testing.T) {
	f := moveStatusFixture(t)
	ctx := context.Background()
	jr := f.e.st.(store.ChannelMoveJournals)
	cs := f.e.st.(store.ChannelMoveStatuses)
	for _, step := range []string{"P2", "P2b", "P3", "P4", "P5"} {
		if err := jr.FinishChannelMoveStep(ctx, f.dst, f.moveID, f.ch, step, store.ChannelMoveStepDone{}); err != nil {
			t.Fatal(err)
		}
	}
	if st := f.state(t); st["state"] != "running" || !strings.Contains(st["line"].(string), "the clean-up runs") {
		t.Fatalf("P5 done: %v", st)
	}
	if err := cs.RefuseChannelMoveStep(ctx, f.dst, f.moveID, f.ch, "P6", map[string]any{"token": "internal", "reason": "bucket unreadable"}); err != nil {
		t.Fatal(err)
	}
	if st := f.state(t); st["state"] != "cleanup_failed" || st["reason"] != "bucket unreadable" || !strings.Contains(st["line"].(string), "/channel/"+f.ch) {
		t.Fatalf("P6 refused: %v", st)
	}
	if err := jr.FinishChannelMoveStep(ctx, f.dst, f.moveID, f.ch, "P6", store.ChannelMoveStepDone{}); err != nil {
		t.Fatal(err)
	}
	proofs := []map[string]any{{"name": "messages in " + f.src, "count": 3}}
	if err := cs.RefuseChannelMoveStep(ctx, f.dst, f.moveID, f.ch, "P7", map[string]any{"token": "proofs_failed", "reason": "a proof of section 5 is not 0", "proofs": proofs}); err != nil {
		t.Fatal(err)
	}
	if st := f.state(t); st["state"] != "traces" || !strings.Contains(st["line"].(string), "still holds traces: messages in "+f.src+" 3") {
		t.Fatalf("P7 refused: %v", st)
	}
	kept := []map[string]any{{"store": "hub logs", "gone_by": "the log bucket's retention: 2027-01-01", "expires": "2027-01-01"}}
	if err := jr.FinishChannelMoveStep(ctx, f.dst, f.moveID, f.ch, "P7", store.ChannelMoveStepDone{Proofs: map[string]any{"kept": kept}}); err != nil {
		t.Fatal(err)
	}
	if st := f.state(t); st["state"] == "moved" {
		t.Fatalf("P7 done without done_at reads as moved: %v", st)
	}
	if err := jr.CloseChannelMove(ctx, f.dst, f.moveID); err != nil {
		t.Fatal(err)
	}
	st := f.state(t)
	k, _ := st["kept"].([]any)
	if st["state"] != "moved" || !strings.HasPrefix(st["line"].(string), "Moved.") || len(k) != 1 {
		t.Fatalf("done_at set: %v", st)
	}
}
