package hub_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// CLE-77895: a box agent adds / removes an emoji reaction through the real
// front end (action.React == `spool react`), the box twin of the browser's
// PUT/DELETE /v1/messages/{msg_id}/reactions. Every refusal is a control:
// remove its guard in box_react.go and that case turns red.

func reactAnswer(t *testing.T, raw json.RawMessage) (string, []any) {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	id, _ := out["msg_id"].(string)
	rs, _ := out["reactions"].([]any)
	return id, rs
}

// reactedBy is the actor list of emoji on msg, as stored.
func reactedBy(t *testing.T, e *env, tid, msg, emoji string) []string {
	t.Helper()
	rows, err := e.st.ReactionsFor(context.Background(), tid, []string{msg})
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, r := range rows[msg] {
		if r.Emoji == emoji {
			out = append(out, r.Actor)
		}
	}
	return out
}

func TestBoxReactOnHold(t *testing.T) {
	e, tid, task, card, b, _ := boxArchiveRig(t)
	ctx := context.Background()
	reply := putCard(t, e, tid, task, "", "HUM-1", hub.WUIBox, 0, time.Now().UTC().Add(time.Second))
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	wsjson.Write(ctx, watcher, map[string]string{"type": "subscribe", "task_id": task}) //nolint:errcheck
	readType(t, watcher, "subscribed")

	// No --msg: the topic's opening card. The bare ⏸ is stored in the
	// picker's spelling.
	raw, err := action.React(ctx, b.cfg, action.ReactArgs{TaskID: task, Emoji: "⏸", As: "CLE-08", Hub: b.c})
	if err != nil {
		t.Fatalf("react: %v", err)
	}
	if id, rs := reactAnswer(t, raw); id != card || len(rs) != 1 {
		t.Fatalf("react answer %s", raw)
	}
	if got := reactedBy(t, e, tid, card, "⏸️"); len(got) != 1 || got[0] != "CLE-08" {
		t.Fatalf("stored actors %v", got)
	}
	if f := readType(t, watcher, "message_reaction"); f["msg_id"] != card {
		t.Fatalf("browser frame %v", f)
	}

	// --msg names a reply of the same topic.
	if _, err := action.React(ctx, b.cfg, action.ReactArgs{TaskID: task, MsgID: reply, Emoji: "✅", As: "CLE-08", Hub: b.c}); err != nil {
		t.Fatalf("react on reply: %v", err)
	}
	if got := reactedBy(t, e, tid, reply, "✅"); len(got) != 1 {
		t.Fatalf("reply actors %v", got)
	}

	// --msg alone: the hub finds the topic.
	if _, err := action.React(ctx, b.cfg, action.ReactArgs{MsgID: reply, Emoji: "👀", As: "CLE-08", Hub: b.c}); err != nil {
		t.Fatalf("react by msg only: %v", err)
	}
	if got := reactedBy(t, e, tid, reply, "👀"); len(got) != 1 {
		t.Fatalf("msg-only actors %v", got)
	}

	// --remove takes it off again.
	raw, err = action.React(ctx, b.cfg, action.ReactArgs{TaskID: task, Emoji: "⏸️", As: "CLE-08", Remove: true, Hub: b.c})
	if err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, rs := reactAnswer(t, raw); len(rs) != 0 {
		t.Fatalf("remove answer %s", raw)
	}
	if got := reactedBy(t, e, tid, card, "⏸️"); len(got) != 0 {
		t.Fatalf("still stored %v", got)
	}
}

func TestBoxReactRefusals(t *testing.T) {
	e, tid, task, card, b, c := boxArchiveRig(t)
	ctx := context.Background()
	other := uuidV4()
	elsewhere := putCard(t, e, tid, other, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	refused := func(label, want string, in action.ReactArgs, bx *box) {
		t.Helper()
		in.Hub = bx.c
		if in.Emoji == "" {
			in.Emoji = "⏸️"
		}
		if _, err := action.React(ctx, bx.cfg, in); hubToken(err) != want {
			t.Fatalf("%s: want %s, got %v", label, want, err)
		}
		for _, id := range []string{card, elsewhere} {
			if rows, _ := e.st.ReactionsFor(ctx, tid, []string{id}); len(rows[id]) != 0 {
				t.Fatalf("%s stored a reaction on %s: %v", label, id, rows[id])
			}
		}
	}
	refused("unannounced agent", hub.TokenFromNotAnnounced, action.ReactArgs{TaskID: task, As: "CLE-09"}, b)
	refused("human id", hub.TokenFromNotAnnounced, action.ReactArgs{TaskID: task, As: "HUM-1"}, b)
	refused("not a picker glyph", "bad_emoji", action.ReactArgs{TaskID: task, As: "CLE-08", Emoji: "😠"}, b)
	refused("two glyphs", "bad_emoji", action.ReactArgs{TaskID: task, As: "CLE-08", Emoji: "⏸️✅"}, b)
	refused("unread topic", "not_found", action.ReactArgs{TaskID: task, As: "CLE-09"}, c)
	refused("unknown task", "not_found", action.ReactArgs{TaskID: uuidV4(), As: "CLE-08"}, b)
	refused("message of another topic", "not_found", action.ReactArgs{TaskID: task, MsgID: elsewhere, As: "CLE-08"}, b)
	refused("unknown message", "not_found", action.ReactArgs{TaskID: task, MsgID: uuidV4(), As: "CLE-08"}, b)
	refused("unread message, no task", "not_found", action.ReactArgs{MsgID: card, As: "CLE-09"}, c)
	refused("the lobby, no message", "not_a_card", action.ReactArgs{TaskID: lobby, As: "CLE-08"}, b)

	// Control: the same box and agent may react once the request is right.
	if _, err := action.React(ctx, b.cfg, action.ReactArgs{TaskID: other, MsgID: elsewhere, Emoji: "⏸️", As: "CLE-08", Hub: b.c}); err != nil {
		t.Fatalf("control: %v", err)
	}
}

// The front end refuses a malformed request before it dials.
func TestReactArgs(t *testing.T) {
	e, _, task, _, b, _ := boxArchiveRig(t)
	_ = e
	for label, in := range map[string]action.ReactArgs{
		"no task":  {Emoji: "⏸️", As: "CLE-08"},
		"bad msg":  {TaskID: task, MsgID: "nope", Emoji: "⏸️", As: "CLE-08"},
		"no emoji": {TaskID: task, As: "CLE-08"},
		"no agent": {TaskID: task, Emoji: "⏸️"},
	} {
		in.Hub = b.c
		if _, err := action.React(context.Background(), b.cfg, in); err == nil {
			t.Fatalf("%s: accepted", label)
		}
	}
}
