package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// specs/032 FR-ED-012..016, contracts/message-edit-v1.md §10: a box edits
// and deletes a message IT sent, re-signed with its own key, through the
// real front end (action.Edit == `spool edit`). Every refusal below is a
// control: remove its guard in box_edit.go and that case turns red.

func hubToken(err error) string {
	var he *hubclient.HubError
	if errors.As(err, &he) {
		return he.Token
	}
	return ""
}

// boxEditRig: box-a (CLE-07) has sent HUM-1 one DM, which HUM-1's browser
// watches; box-b (CLE-08) is a second pinned box of the same tenant.
func boxEditRig(t *testing.T) (e *env, tid string, a, b *box, sent action.SendResult, watcher func(string) map[string]any) {
	t.Helper()
	e = followEnv(t)
	tid, _ = e.tenant()
	ctx := context.Background()
	a = e.box(tid, "box-a", "CLE-07")
	b = e.box(tid, "box-b", "CLE-08")
	e.pin(tid, a)
	e.pin(tid, b)
	var err error
	sent, err = action.SendCtx(ctx, a.cfg, action.SendArgs{From: "CLE-07", To: "HUM-1", ToBox: hub.WUIBox,
		Kind: "note", Body: "col a / col b / col c", Hub: a.c})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	c := dialMember(t, e, tid, "HUM-1", "HUM-1")
	wsjson.Write(ctx, c, map[string]string{"type": "subscribe", "task_id": sent.TaskID}) //nolint:errcheck
	readType(t, c, "subscribed")
	return e, tid, a, b, sent, func(want string) map[string]any { return readType(t, c, want) }
}

func TestBoxEditOwnMessage(t *testing.T) {
	e, tid, a, _, sent, watch := boxEditRig(t)
	ctx := context.Background()
	before, err := e.st.GetEditable(ctx, tid, sent.MsgID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	// The box is the unit of trust: an agent it no longer announces keeps
	// its posts editable by that box (a closed desk agent's lines).
	if err := e.st.SetRoster(ctx, tid, "box-a", []string{}, time.Now()); err != nil {
		t.Fatal(err)
	}
	table := "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |"
	r, err := action.Edit(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-07", Body: table, Hub: a.c})
	if err != nil {
		t.Fatalf("edit: %v", err)
	}
	if r.Revision != 2 || r.TaskID != sent.TaskID || r.From != "CLE-07" {
		t.Fatalf("edit result %+v", r)
	}
	after, err := e.st.GetEditable(ctx, tid, sent.MsgID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if after.Body != table || after.Revision != 2 || after.EditedBy != "CLE-07" || after.EditedAt.IsZero() {
		t.Fatalf("stored after edit: %+v", after)
	}
	// FR-ED-009: it does not move.
	if !after.ReceivedAt.Equal(before.ReceivedAt) || !after.TS.Equal(before.TS) || after.TaskID != before.TaskID {
		t.Fatalf("the edit moved the message: before %v/%v after %v/%v", before.TS, before.ReceivedAt, after.TS, after.ReceivedAt)
	}
	// The stored envelope is box-a's, re-signed, and verifies against its pin.
	env := storedEnvelope(t, e, tid, sent.MsgID)
	raw, _ := base64.StdEncoding.DecodeString(a.pub)
	if err := env.Verify(ed25519.PublicKey(raw)); err != nil || env.FromBox != "box-a" || env.ToBox != hub.WUIBox {
		t.Fatalf("stored envelope does not verify against box-a: %v %+v", err, env)
	}
	if after.EnvSig != env.Sig || after.EnvSig == before.EnvSig {
		t.Fatalf("env_sig column %q, envelope sig %q, before %q", after.EnvSig, env.Sig, before.EnvSig)
	}
	if m, err := env.Inner(); err != nil || m.Body != table || m.From != "CLE-07" || m.To != "HUM-1" {
		t.Fatalf("stored inner %+v %v", m, err)
	}
	revs := revisions(t, e, tid, sent.MsgID)
	if len(revs) != 2 || revs[0].Body != "col a / col b / col c" || revs[1].Body != table || revs[1].EditedBy != "CLE-07" {
		t.Fatalf("register: %+v", revs)
	}
	f := watch("message_edited")
	if f["msg_id"] != sent.MsgID || f["revision"] != float64(2) || f["edited_by"] != "CLE-07" {
		t.Fatalf("browser frame %v", f)
	}

	// A second edit appends revision 3.
	if r, err := action.Edit(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, Body: "third", Hub: a.c}); err != nil || r.Revision != 3 {
		t.Fatalf("second edit: %+v %v", r, err)
	}
}

func TestBoxEditRefusals(t *testing.T) {
	e, tid, a, b, sent, _ := boxEditRig(t)
	ctx := context.Background()
	body := func() string { return storedBody(t, e, tid, sent.MsgID) }
	const orig = "col a / col b / col c"

	// Another box of the same tenant: refused at the fetch, nothing changes.
	if _, err := action.Edit(ctx, b.cfg, action.EditArgs{MsgID: sent.MsgID, Body: "hijack", Hub: b.c}); hubToken(err) != "not_author" {
		t.Fatalf("other box edit: %v (want not_author)", err)
	}
	if _, err := action.Delete(ctx, b.cfg, action.EditArgs{MsgID: sent.MsgID, Hub: b.c}); hubToken(err) != "not_author" {
		t.Fatalf("other box delete: %v (want not_author)", err)
	}
	// Local author guard: --as names someone else.
	if _, err := action.Edit(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-99", Body: "x", Hub: a.c}); err == nil || !strings.Contains(err.Error(), "not CLE-99") {
		t.Fatalf("as mismatch: %v", err)
	}
	if _, err := action.Edit(ctx, a.cfg, action.EditArgs{MsgID: "00000000-0000-4000-8000-000000000000", Body: "x", Hub: a.c}); hubToken(err) != "not_found" {
		t.Fatalf("unknown msg: %v (want not_found)", err)
	}

	// Hand-built envelopes on box-a's own socket, each wrong in one way.
	sess, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	old, err := sess.EditFetch(ctx, sent.MsgID)
	if err != nil {
		t.Fatal(err)
	}
	priv, err := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	_, stranger, _ := ed25519.GenerateKey(nil)
	for _, c := range []struct {
		name, want string
		key        ed25519.PrivateKey
		toBox      string
		channel    string
		mut        func(m *messageFields)
	}{
		{"empty body", "empty_body", priv, old.ToBox, old.Channel, func(m *messageFields) { m.body = "  \n" }},
		{"moved ts", "bad_edit", priv, old.ToBox, old.Channel, func(m *messageFields) { m.ts = "2020-01-01T00:00:00Z" }},
		{"new addressee", "bad_edit", priv, old.ToBox, old.Channel, func(m *messageFields) { m.to = "HUM-2" }},
		{"new kind", "bad_edit", priv, old.ToBox, old.Channel, func(m *messageFields) { m.kind = "result" }},
		{"new to_box", "bad_edit", priv, "box-b", old.Channel, nil},
		{"new channel tag", "bad_edit", priv, old.ToBox, "releases", nil},
		{"signed by another key", "bad_sig", stranger, old.ToBox, old.Channel, nil},
	} {
		m, _ := old.Inner()
		f := messageFields{body: "edited", ts: m.TS, to: m.To, kind: m.Kind}
		if c.mut != nil {
			c.mut(&f)
		}
		m.Body, m.TS, m.To, m.Kind = f.body, f.ts, f.to, f.kind
		env, err := wire.NewEnvelopeIn(c.key, "box-a", c.toBox, c.channel, old.ParentTaskID, m)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := sess.EditApply(ctx, sent.MsgID, env); hubToken(err) != c.want {
			t.Fatalf("%s: %v (want %s)", c.name, err, c.want)
		}
		if got := body(); got != orig {
			t.Fatalf("%s changed the body: %q", c.name, got)
		}
	}
	// A valid envelope for a DIFFERENT msg_id than the frame names.
	m, _ := old.Inner()
	m.Body = "edited"
	env, _ := wire.NewEnvelopeIn(priv, "box-a", old.ToBox, old.Channel, old.ParentTaskID, m)
	other, _ := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "CLE-07", To: "HUM-1", ToBox: hub.WUIBox, Kind: "note", Body: "second", Hub: a.c})
	if _, err := sess.EditApply(ctx, other.MsgID, env); hubToken(err) != "bad_json" {
		t.Fatalf("msg_id mismatch: %v (want bad_json)", err)
	}
	if got := storedBody(t, e, tid, other.MsgID); got != "second" {
		t.Fatalf("mismatch changed the other message: %q", got)
	}
	if revs := revisions(t, e, tid, sent.MsgID); len(revs) != 0 {
		t.Fatalf("refusals wrote the register: %+v", revs)
	}
	// The browser still cannot edit a box-signed message (rules 6/7 unchanged).
	if code, out := patchEdit(t, e, tid, sent.MsgID, "HUM-1", map[string]string{"body": "from the browser"}); code != 403 || body() != orig {
		t.Fatalf("browser PATCH of a box message: %d %v", code, out)
	}
}

type messageFields struct{ body, ts, to, kind string }

func TestBoxDeleteOwnMessage(t *testing.T) {
	e, tid, a, _, sent, watch := boxEditRig(t)
	ctx := context.Background()
	if _, err := action.Delete(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-99", Hub: a.c}); err == nil {
		t.Fatal("delete with a wrong --as went through")
	}
	task, err := action.Delete(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-07", Hub: a.c})
	if err != nil || task != sent.TaskID {
		t.Fatalf("delete: %q %v", task, err)
	}
	if _, err := e.st.GetEditable(ctx, tid, sent.MsgID, time.Now()); err == nil {
		t.Fatal("deleted message is still readable")
	}
	if f := watch("message_deleted"); f["msg_id"] != sent.MsgID {
		t.Fatalf("browser frame %v", f)
	}
}
