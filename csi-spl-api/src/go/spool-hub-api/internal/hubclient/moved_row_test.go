package hubclient

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 169 row T4c: an agent row moved from <SRC> to <DST> keeps the envelope
// its box signed with the <SRC> key, while the same-named box in <DST> holds a
// DIFFERENT key (rdb 0154 lets a box key be live in one workspace only).

// movedRowWorld is box-a seen from <DST>: its pin is the <DST> key, src is the
// box's retired <SRC> key, wui is the hub's own key, the same in every
// workspace.
func movedRowWorld(t *testing.T) (src, dst, wui peer, h *opsHub, c *Client) {
	t.Helper()
	src, dst, wui = newPeer(t, "box-a"), newPeer(t, "box-a"), newPeer(t, wuiBox)
	h = &opsHub{pins: []wire.PinEntry{dst.pin, wui.pin}}
	c = opsClient(t, h)
	return src, dst, wui, h, c
}

// The hub withholds such a row (hub/backfill.go), but the box stays its own
// check: if one arrives, say from a hub of an older version, it is refused, it
// does not stop the rest of the run, and the rest lands.
func TestMovedRowBackfillRefusedAlone(t *testing.T) {
	src, dst, wui, h, c := movedRowWorld(t)
	human := note("HUM-1", "ALL-0", "note", "a human post")
	moved := note("c-009", "ALL-0", "note", "an agent post from <SRC>")
	after := note("c-009", "ALL-0", "note", "an agent post at <DST>")
	bf := func(raw []byte) wire.Frame {
		return wire.Frame{Type: wire.TRecv, Env: raw, Agents: []string{"c-007"}, Backfill: "ops"}
	}
	h.push = []wire.Frame{
		bf(envRaw(t, wui, wuiBox, "ops", human)),
		bf(envRaw(t, src, wuiBox, "ops", moved)),
		bf(envRaw(t, dst, wuiBox, "ops", after)),
	}
	r, err := c.Sync(context.Background())
	if !errors.Is(err, sign.ErrVerify) {
		t.Errorf("sync err %v, want sign.ErrVerify", err)
	}
	if r.Delivered != 2 || r.Refused != 1 || inbox(t, c, "c-007") != 2 {
		t.Errorf("report %+v inbox %d, want 2 delivered and 1 refused", r, inbox(t, c, "c-007"))
	}
}

// backfill_end names withheld rows even when nothing was written: without the
// field the box stays silent, as it does for a run that wrote nothing.
func TestBackfillEndRingsForWithheld(t *testing.T) {
	_, _, _, h, c := movedRowWorld(t)
	pokes := pokeLog(t, c)
	task, id := note("c-009", "ALL-0", "note", "x").TaskID, note("c-009", "ALL-0", "note", "x").MsgID
	h.push = []wire.Frame{
		{Type: wire.TBackfillEnd, Backfill: "quiet", Agents: []string{"c-007"}, From: "c-009", TaskID: task, MsgID: id},
		{Type: wire.TBackfillEnd, Backfill: "ops", Agents: []string{"c-008"}, From: "c-009", TaskID: task, MsgID: id,
			Withheld: 2, WithheldTask: task},
	}
	if _, err := c.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	p := readPokes(t, pokes)
	if strings.Contains(p, "--to c-007") || !strings.Contains(p, "--to c-008") {
		t.Errorf("pokes:\n%s", p)
	}
}

// What the summary says, also what an older hub's frame (no Withheld) still
// says, word for word. It names no move: a re-keyed box's rows read the same.
func TestBackfillSummaryWithheld(t *testing.T) {
	cases := []struct {
		f    wire.Frame
		want string
	}{
		{wire.Frame{Backfill: "ops", Count: 2, Topics: 1, From: "c-009"},
			"added to #ops: 2 earlier messages in 1 topic, newest from c-009"},
		{wire.Frame{Backfill: "ops", Count: 2, Topics: 1, From: "c-009", Withheld: 1, WithheldTask: "t-9"},
			"added to #ops: 2 earlier messages in 1 topic, newest from c-009; 1 earlier message not sent: signed by a key this workspace does not pin for the sender's box; newest in topic t-9; spool may not show them here, a person can read them in the browser: ask in the channel"},
		{wire.Frame{Backfill: "ops", From: "c-009", Withheld: 3, WithheldTask: "t-9"},
			"added to #ops: 3 earlier messages not sent: signed by a key this workspace does not pin for the sender's box; newest in topic t-9; spool may not show them here, a person can read them in the browser: ask in the channel"},
	}
	for _, tc := range cases {
		got := BackfillSummary(tc.f, "c-007").Body
		if got != tc.want {
			t.Errorf("body %q, want %q", got, tc.want)
		}
		// tail shows a box only rows it sent, was addressed by or had
		// delivered: the line never sends the agent there for these rows.
		if strings.Contains(got, "tail") || strings.Contains(strings.ToLower(got), "moved") {
			t.Errorf("body points at tail or names a move: %q", got)
		}
	}
}

// An old box: it decodes the frame with no such fields. encoding/json ignores
// what a struct does not name (wsjson.Read is json.Unmarshal), so the new
// fields cannot break its read loop.
func TestBackfillEndNewFieldsIgnoredByOldDecoder(t *testing.T) {
	raw, err := json.Marshal(wire.Frame{Type: wire.TBackfillEnd, Backfill: "ops", Count: 2, Withheld: 1, WithheldTask: "t-9"})
	if err != nil {
		t.Fatal(err)
	}
	var old struct {
		Type     string `json:"type"`
		Backfill string `json:"backfill"`
		Count    int    `json:"count"`
	}
	if err := json.Unmarshal(raw, &old); err != nil || old.Count != 2 || old.Type != wire.TBackfillEnd {
		t.Errorf("old decoder: %+v %v", old, err)
	}
}

// A queued delivery that moved with its post (spec M3) reaches the box as an
// ordinary recv frame: refused AND committed, so the hub never sends it again.
// That is why the move expires such rows at apply (T5); this pins the box side.
func TestMovedRowQueuedDeliveryIsCommitted(t *testing.T) {
	src, _, _, h, c := movedRowWorld(t)
	moved := note("c-009", "c-007", "task", "queued at <SRC>, moved before it was delivered")
	h.push = []wire.Frame{{Type: wire.TRecv, Env: envRaw(t, src, "box-a", "", moved)}}
	if _, err := c.Sync(context.Background()); !errors.Is(err, sign.ErrVerify) {
		t.Errorf("sync err %v, want sign.ErrVerify", err)
	}
	eventually(t, func() bool { return len(h.frames(wire.TCommit)) == 1 })
	if n := inbox(t, c, "c-007"); n != 0 {
		t.Errorf("inbox %d", n)
	}
}

// A human row needs no box key of <SRC>: box-wui's key is the hub's.
func TestMovedHumanRowPasses(t *testing.T) {
	_, _, wui, h, c := movedRowWorld(t)
	human := note("HUM-1", "ALL-0", "note", "a human post")
	fb := note("HUM-1", "c-008", "task", "an unheard human post")
	h.push = []wire.Frame{
		{Type: wire.TRecv, Env: envRaw(t, wui, wuiBox, "ops", human), Agents: []string{"c-007"}, Backfill: "ops"},
		{Type: wire.TRecv, Env: envRaw(t, wui, wuiBox, "", fb), Agents: []string{"c-008"}, Fallback: "#ops"},
	}
	r, err := c.Sync(context.Background())
	if err != nil || r.Delivered != 2 || r.Refused != 0 {
		t.Errorf("report %+v err %v, want both delivered", r, err)
	}
}

// Tail hands out what the hub stored and verifies nothing, moved or not.
func TestMovedRowTailDoesNotVerify(t *testing.T) {
	src, _, _, h, c := movedRowWorld(t)
	moved := note("c-009", "c-007", "task", "an agent post from <SRC>")
	raw := envRaw(t, src, "box-a", "", moved)
	h.reply = func(f wire.Frame) []wire.Frame {
		if f.Type != wire.TTail {
			return nil
		}
		return []wire.Frame{{Type: wire.TTailMsg, Env: raw}, {Type: wire.TTailEnd, TaskID: f.TaskID}}
	}
	s, err := c.Dial(context.Background(), wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	n, err := s.Tail(context.Background(), moved.TaskID, false, func(*wire.Envelope) {})
	if err != nil || n != 1 {
		t.Errorf("tail n=%d err=%v, want the moved row handed out", n, err)
	}
}

func eventually(t *testing.T, ok func() bool) {
	t.Helper()
	for range 200 {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition not met in 2 s")
}
