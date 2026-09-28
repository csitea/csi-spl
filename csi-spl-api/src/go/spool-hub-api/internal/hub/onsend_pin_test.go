package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Pins of the box send refusals no other test drove, taken before onSend
// was split into named check groups (SPL-1029 round 2): each answers an
// error frame with its token and status, in the order the checks run.
func TestOnSendRefusalShapes(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	priv, err := sign.LoadPrivate(a.cfg.KeysDir, a.id)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	c, nonce := e.raw(tid)
	defer c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	hello := helloFrame(a, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	hello.Agents = []string{"GRK-03"}
	wsjson.Write(ctx, c, hello) //nolint:errcheck
	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, c, &f); err != nil {
			t.Fatal(err)
		}
		if f.Type == wire.TWelcome {
			break
		}
	}
	answer := func(id string) wire.Frame {
		t.Helper()
		for {
			var f wire.Frame
			if err := wsjson.Read(ctx, c, &f); err != nil {
				t.Fatal(err)
			}
			if (f.Type == wire.TError || f.Type == wire.TSent) && f.MsgID == id {
				return f
			}
		}
	}
	send := func(toBox, ts, body, id string) wire.Frame {
		t.Helper()
		m := &msg.Message{V: msg.V1, MsgID: id, TaskID: uuidV4(), TS: ts, From: "GRK-03", To: "CLE-07", Kind: "note", Body: body, Files: []msg.Attachment{}}
		env, err := wire.NewEnvelope(priv, "box-a", toBox, m)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := env.Marshal()
		wsjson.Write(ctx, c, wire.Frame{Type: wire.TSend, Env: raw}) //nolint:errcheck
		return answer(id)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	// an envelope that does not parse is answered under the frame's msg_id
	bad := uuidV4()
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TSend, MsgID: bad, Env: []byte(`"not an envelope"`)}) //nolint:errcheck
	if f := answer(bad); f.Error != "bad_json" || f.Status != 400 {
		t.Errorf("unparsable envelope: %+v", f)
	}
	for _, tc := range []struct {
		name, toBox, ts, token string
		status                 int
	}{
		{"no to_box", "", now, "missing_to_box", 400},
		{"invalid to_box", "Bad Box", now, "bad_json", 400},
		{"unknown to_box", "box-zz", now, "unpinned_box", 404},
		{"bad ts", "box-b", "yesterday", "bad_json", 400},
	} {
		if f := send(tc.toBox, tc.ts, "x", uuidV4()); f.Error != tc.token || f.Status != tc.status {
			t.Errorf("%s: %+v, want %s %d", tc.name, f, tc.token, tc.status)
		}
	}
	// the same msg_id with a different envelope is a conflict
	id := uuidV4()
	if f := send("box-b", now, "first", id); f.Type != wire.TSent {
		t.Fatalf("first send: %+v", f)
	}
	if f := send("box-b", now, "second", id); f.Error != "conflict_msg" || f.Status != 409 {
		t.Errorf("msg_id reuse: %+v", f)
	}
	// the sender's pin is revoked after its hello
	if err := e.st.RevokePin(ctx, tid, "box-a", time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	if f := send("box-b", now, "x", uuidV4()); f.Error != "unpinned_box" || f.Status != 400 {
		t.Errorf("revoked sender: %+v", f)
	}
}
