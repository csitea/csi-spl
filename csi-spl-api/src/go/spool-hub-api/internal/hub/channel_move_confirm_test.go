// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// confirm is the menu's confirm (spec 169 T15) as hum.
func (b *browserMove) confirm(t *testing.T, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, b.e, b.src, http.MethodPost, b.probe, as, body)
}

// confirmable gives <DST> an orchestrator seat, so nothing blocks the move;
// it skips on Memory, which has no journal (501).
func confirmable(t *testing.T, mut ...func(*hub.Options)) *browserMove {
	t.Helper()
	b := browserMoveFixture(t, mut...)
	if _, ok := b.e.st.(*store.Postgres); !ok {
		t.Skip("the journal needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	if err := b.e.st.SetRoster(context.Background(), b.dst, "box-a", []string{"c-001"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	return b
}

// C32: the confirm writes the GO and runs P1. The answer and its form are in a
// new topic of the operator workspace, written by the session's person from
// box-wui; the form names <SRC>/<CHANNEL> and <DST>; the journal in <DST> holds
// that answer's msg id, P1 is done and keeps the dialog's detail for P2. The
// GO passes channelMoveGo unchanged on the operator route; a replay of it for
// another dst is refused. A second confirm writes nothing. RED CONTROL: a form
// that does not name <DST> (channelMoveGoPosts) -> 403 go_required.
func TestChannelMoveConfirmGoC32(t *testing.T) {
	b := confirmable(t)
	code, out := b.confirm(t, b.owner, map[string]any{"dst": b.dst, "leave_hours": []string{b.owner}})
	if code != http.StatusOK {
		t.Fatalf("confirm: %d %v", code, out)
	}
	moveID, topic := out["move_id"].(string), out["topic"].(string)
	ctx := context.Background()
	j, err := b.e.st.(store.ChannelMoveJournals).ChannelMoveJournal(ctx, b.dst, b.src, b.ch)
	if err != nil || j == nil || j.MoveID != moveID || !j.StepDone("P1") {
		t.Fatalf("journal %+v (%v), want move %s with P1 done", j, err, moveID)
	}
	ans, err := b.e.st.GetMessageClaim(ctx, b.op, j.GoMsgID)
	if err != nil || ans.FromID != b.owner || ans.FromBox != "box-wui" || ans.TaskID != topic || ans.Channel != store.ChannelLobby {
		t.Fatalf("the GO answer %+v (%v): want %s from box-wui in topic %s", ans, err, b.owner, topic)
	}
	body := moveInnerBody(t, ans)
	if !strings.HasSuffix(body, "\nAnswer: GO — Go") {
		t.Fatalf("the GO answer's body %q", body)
	}
	formID := strings.TrimPrefix(strings.SplitN(body, "\n", 2)[0], "Poll: ")
	form, err := b.e.st.GetMessageClaim(ctx, b.op, formID)
	if err != nil || form.TaskID != topic || form.FromID != b.owner {
		t.Fatalf("the form %s: %+v (%v)", formID, form, err)
	}
	if fb := moveInnerBody(t, form); !strings.Contains(fb, b.src+"/"+b.ch+" to "+b.dst+"?") || !strings.Contains(fb, "```poll\n") || !strings.Contains(fb, "\n(GO) Go\n") {
		t.Fatalf("the form's body %q", fb)
	}
	var p1 struct {
		Inputs struct {
			LeaveHours []string `json:"leave_hours"`
		} `json:"inputs"`
	}
	if err := json.Unmarshal(j.Steps["P1"].Detail, &p1); err != nil || len(p1.Inputs.LeaveHours) != 1 || p1.Inputs.LeaveHours[0] != b.owner {
		t.Fatalf("P1's detail %s (%v): want the dialog's leave_hours", j.Steps["P1"].Detail, err)
	}

	// The GO stands on the operator route, as the box's pick-up sends it (T16).
	step := func(dst string) map[string]any {
		_, out := opCall(t, b.e, b.src, http.MethodPost, moveURL, "good", chanMoveBody("step", b.src, b.ch, dst,
			map[string]any{"go_msg_id": j.GoMsgID, "move_id": moveID, "step": "P2"}))
		return out
	}
	if out := step(b.dst); out["error"] == "go_required" {
		t.Errorf("the confirm's GO on the operator route: %v", out)
	}
	if out := step(b.op); out["error"] != "go_required" {
		t.Errorf("a replay of the GO for another dst: %v, want go_required", out)
	}

	// A second click: refused, and no second GO is written.
	posts := browserMoveRows(t, b, `SELECT count(*) FROM messages WHERE tenant_id = $1`, b.op)
	code, out = b.confirm(t, b.owner, map[string]any{"dst": b.dst})
	if code != http.StatusConflict || out["error"] != "move_open" || out["move_id"] != moveID {
		t.Errorf("a second confirm: %d %v", code, out)
	}
	if n := browserMoveRows(t, b, `SELECT count(*) FROM messages WHERE tenant_id = $1`, b.op); n != posts || posts != 2 {
		t.Errorf("operator posts %d after the second confirm, %d after the first, want 2 and 2", n, posts)
	}
}

// R7 W1: concurrent clicks of the owner's confirm open one move. 24 confirms
// at once on one move: one 200, every other 409 move_open (refused before any
// post, so no GO is written even for a moment), one journal row in <DST> and
// the one GO's two posts in the operator workspace. Measured before the lock
// (eb0a86221, n=5): 6, 2, 2, 4, 4 journal rows. RED CONTROL: drop the
// LockChannelMove call (handleChannelMoveConfirm) -> losers pass to P1 and
// answer move_refused, and this test fails.
func TestChannelMoveConfirmRaceW1(t *testing.T) {
	b := confirmable(t)
	const clicks = 24
	codes, tokens := make([]int, clicks), make([]any, clicks)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range clicks {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			var out map[string]any
			codes[i], out = b.confirm(t, b.owner, map[string]any{"dst": b.dst})
			tokens[i] = out["error"]
		}()
	}
	close(start)
	wg.Wait()
	ok, open := 0, 0
	for i, c := range codes {
		switch {
		case c == http.StatusOK:
			ok++
		case c == http.StatusConflict && tokens[i] == "move_open":
			open++
		}
	}
	if ok != 1 || open != clicks-1 {
		t.Errorf("%d clicks: %d answered 200 and %d 409 move_open, want 1 and %d (%v %v)", clicks, ok, open, clicks-1, codes, tokens)
	}
	if n := browserMoveRows(t, b, `SELECT count(*) FROM channel_move_journal WHERE tenant_id = $1`, b.dst); n != 1 {
		t.Errorf("%d journal rows in <DST>, want 1", n)
	}
	if n := browserMoveRows(t, b, `SELECT count(*) FROM messages WHERE tenant_id = $1`, b.op); n != 2 {
		t.Errorf("%d posts in the operator workspace, want the one GO's 2", n)
	}
}

// R7 W2: a confirm that P1 refuses after the GO was written leaves no GO. The
// first move is confirmed, then P4 and the journal are marked done, so the
// next confirm passes the open-journal check and P1 refuses it (409
// move_refused): its form and answer are deleted, and only the first GO's two
// posts stay. RED CONTROL: drop channelMoveGoWithdraw after P1's refusal ->
// 4 posts, and this test fails.
func TestChannelMoveConfirmRefusedW2(t *testing.T) {
	b := confirmable(t)
	code, out := b.confirm(t, b.owner, map[string]any{"dst": b.dst})
	if code != http.StatusOK {
		t.Fatalf("confirm: %d %v", code, out)
	}
	ctx := context.Background()
	jr := b.e.st.(store.ChannelMoveJournals)
	moveID := out["move_id"].(string)
	if err := jr.FinishChannelMoveStep(ctx, b.dst, moveID, b.ch, "P4", store.ChannelMoveStepDone{}); err != nil {
		t.Fatal(err)
	}
	if err := jr.CloseChannelMove(ctx, b.dst, moveID); err != nil {
		t.Fatal(err)
	}
	code, out = b.confirm(t, b.owner, map[string]any{"dst": b.dst})
	if code != http.StatusConflict || out["error"] != "move_refused" {
		t.Fatalf("a confirm after a done move: %d %v, want 409 move_refused", code, out)
	}
	if n := browserMoveRows(t, b, `SELECT count(*) FROM messages WHERE tenant_id = $1`, b.op); n != 2 {
		t.Errorf("%d posts in the operator workspace after the refusal, want the first GO's 2", n)
	}
}

// C32's stops: while anything blocks the move the confirm answers 409 with
// .blocked and writes nothing: no journal row in <DST>, no post in the operator
// workspace. CONTROL: TestChannelMoveConfirmGoC32, the same move with a seat.
// RED CONTROL: drop the .blocked check (handleChannelMoveConfirm) -> the GO is
// written and P1 runs, and this test fails.
func TestChannelMoveConfirmBlockedC32(t *testing.T) {
	b := browserMoveFixture(t)
	if _, ok := b.e.st.(*store.Postgres); !ok {
		t.Skip("the journal needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	code, out := b.confirm(t, b.owner, map[string]any{"dst": b.dst})
	blocked := anyStrings(out["blocked"])
	if code != http.StatusConflict || out["error"] != "move_blocked" || len(blocked) != 1 || !strings.Contains(blocked[0], "has no orchestrator seat") {
		t.Fatalf("a blocked confirm: %d %v", code, out)
	}
	if n := browserMoveRows(t, b, `SELECT count(*) FROM channel_move_journal WHERE tenant_id = $1`, b.dst); n != 0 {
		t.Errorf("a blocked confirm wrote %d journal rows in <DST>", n)
	}
	if n := browserMoveRows(t, b, `SELECT count(*) FROM messages WHERE tenant_id = $1`, b.op); n != 0 {
		t.Errorf("a blocked confirm wrote %d posts in the operator workspace", n)
	}
}

// C33: the browser has no step. The confirm refuses a body with step or mark
// (an unknown field), anyone but the operator workspace's biz owner, and the
// service account's token; the operator route refuses the owner's member
// session. A Memory hub, which has no journal, answers 501 and writes no GO.
// CONTROL: the owner's plain confirm passes the door (TestChannelMoveConfirmGoC32).
// RED CONTROL: accept step in channelMoveBrowserBody -> the body with step is
// read and this test fails.
func TestChannelMoveConfirmNoStepC33(t *testing.T) {
	b := browserMoveFixture(t)
	opAdmin := seatAs(t, b.e, b.op, rbac.Admin, b.src, rbac.Admin)
	for _, c := range []struct {
		name, as, token string
		body            map[string]any
		code            int
	}{
		{"a step", b.owner, "bad_json", map[string]any{"dst": b.dst, "step": "P4"}, http.StatusBadRequest},
		{"a mark", b.owner, "bad_json", map[string]any{"dst": b.dst, "mark": "P2b"}, http.StatusBadRequest},
		{"a go_msg_id", b.owner, "bad_json", map[string]any{"dst": b.dst, "go_msg_id": uuid4()}, http.StatusBadRequest},
		{"an admin of the operator workspace", opAdmin, "channel_move_owner", map[string]any{"dst": b.dst}, http.StatusForbidden},
		{"no session", "", "channel_move_owner", map[string]any{"dst": b.dst}, http.StatusForbidden},
		{"a hidden workspace", b.owner, "unknown_tenant", map[string]any{"dst": b.hidden}, http.StatusNotFound},
	} {
		if code, out := b.confirm(t, c.as, c.body); code != c.code || out["error"] != c.token {
			t.Errorf("%s: %d %v, want %d %s", c.name, code, out, c.code, c.token)
		}
	}
	if code, out := opCall(t, b.e, b.src, http.MethodPost, b.probe, "good", map[string]any{"dst": b.dst}); code != http.StatusForbidden || out["move_id"] != nil {
		t.Errorf("the service account's token on the confirm: %d %v", code, out)
	}
	if code, out := call(t, b.e, b.src, http.MethodPost, moveURL, b.owner, chanMoveBody("plan", b.src, b.ch, b.dst, nil)); code != http.StatusUnauthorized {
		t.Errorf("the owner's member session on the operator route: %d %v", code, out)
	}
	if _, pg := b.e.st.(*store.Postgres); pg {
		return
	}
	code, out := b.confirm(t, b.owner, map[string]any{"dst": b.dst})
	if code != http.StatusNotImplemented || out["error"] != "unsupported" {
		t.Errorf("Memory: %d %v, want 501 unsupported", code, out)
	}
	if n, err := b.e.st.CountMessagesSince(context.Background(), b.op, time.Time{}); err != nil || n != 0 {
		t.Errorf("Memory wrote %d posts in the operator workspace (%v)", n, err)
	}
}

// moveInnerBody is a stored message's text, from its inner message, as
// channelMoveGo reads it.
func moveInnerBody(t *testing.T, m store.Message) string {
	t.Helper()
	var inner struct {
		Body string `json:"body"`
	}
	if err := json.Unmarshal(m.Msg, &inner); err != nil {
		t.Fatalf("inner message of %s: %v", m.MsgID, err)
	}
	return inner.Body
}

// failP1Finish fails P1's step row after OpenChannelMove committed the
// journal, as a database error or a closed request would.
type failP1Finish struct{ *store.Postgres }

func (f failP1Finish) FinishChannelMoveStep(ctx context.Context, dst, moveID, channel, step string, d store.ChannelMoveStepDone) error {
	if step == "P1" {
		return errors.New("injected failure after OpenChannelMove committed")
	}
	return f.Postgres.FinishChannelMoveStep(ctx, dst, moveID, channel, step, d)
}

// R7 W3: a P1 that fails after its journal row was committed keeps the GO
// that row names, so the move can go on with it; only the click answers 500.
// RED CONTROL: withdraw the GO on every P1 error (drop channelMoveGoJournaled)
// -> the journal names a deleted GO, and this test fails.
func TestChannelMoveConfirmJournaledGoW3(t *testing.T) {
	b := confirmable(t, func(o *hub.Options) {
		if pg, ok := o.Store.(*store.Postgres); ok {
			o.Store = failP1Finish{pg}
		}
	})
	if code, out := b.confirm(t, b.owner, map[string]any{"dst": b.dst}); code != http.StatusInternalServerError {
		t.Fatalf("confirm with P1's step row failing: %d %v, want 500", code, out)
	}
	ctx := context.Background()
	j, err := b.e.st.(store.ChannelMoveJournals).ChannelMoveJournal(ctx, b.dst, b.src, b.ch)
	if err != nil || j == nil || j.Done {
		t.Fatalf("journal after the failed P1: %+v %v, want an open row", j, err)
	}
	if _, err := b.e.st.GetMessageClaim(ctx, b.op, j.GoMsgID); err != nil {
		t.Errorf("the open journal names GO %s, which is gone: %v", j.GoMsgID, err)
	}
	if n := browserMoveRows(t, b, `SELECT count(*) FROM messages WHERE tenant_id = $1`, b.op); n != 2 {
		t.Errorf("%d posts in the operator workspace, want the GO's 2", n)
	}
}
