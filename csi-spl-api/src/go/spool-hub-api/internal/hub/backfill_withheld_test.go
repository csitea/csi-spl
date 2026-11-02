package hub_test

import (
	"context"
	"crypto/ed25519"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 169 T4c: a row whose signature fails against its box's live pin here is
// not sent to a new seat, and the agent is told.

// putSignedRow stores a post into tenant as if the hub had taken it: signed by
// priv, whatever key the workspace pins for fromBox now. A row moved in from
// another workspace looks exactly like this.
func putSignedRow(t *testing.T, e *env, tenant string, priv ed25519.PrivateKey, fromBox, from, toBox, channel string) *msg.Message {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	m := &msg.Message{V: msg.V1, MsgID: uuidV4(), TaskID: uuidV4(), TS: now.Format(time.RFC3339), From: from, To: "HUM-1",
		Kind: "note", Body: "from " + from}
	env, err := wire.NewEnvelopeIn(priv, fromBox, toBox, channel, "", m)
	if err != nil {
		t.Fatal(err)
	}
	canon, err := env.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.st.InsertMessage(context.Background(), store.Message{TenantID: tenant, MsgID: m.MsgID, TaskID: m.TaskID,
		Channel: channel, IsParent: 1, TS: now, FromBox: fromBox, FromID: from, ToBox: toBox, ToID: m.To, Kind: m.Kind,
		Body: m.Body, Files: []byte(`[]`), Msg: env.Msg, EnvSig: env.Sig, Env: canon, ReceivedAt: now,
		ExpiresAt: now.Add(30 * 24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	return m
}

// withheldRig: channel "mobile", agent CLE-35 on box-desk owed a back-fill
// (not yet seated: seat() does it), box-x (CLE-40) pinned with its own key.
type withheldRig struct {
	e         *env
	tid       string
	d, x      *box
	xKey, wui ed25519.PrivateKey
	pokes     func() []string
}

func newWithheldRig(t *testing.T) withheldRig {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e := backfillEnv(t, key, 200)
	tid, _ := e.tenant()
	d, x := e.box(tid, "box-desk", "CLE-35"), e.box(tid, "box-x", "CLE-40")
	pokes := pokeLog(t, d)
	e.pin(tid, d)
	e.pin(tid, x)
	e.pinKey(tid, hub.WUIBox, pub)
	if err := e.st.CreateChannel(context.Background(), store.Channel{TenantID: tid, ChannelID: "mobile",
		Name: "mobile", CreatedBy: "HUM-1", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	xKey, err := sign.LoadPrivate(x.cfg.KeysDir, "box-x")
	if err != nil {
		t.Fatal(err)
	}
	return withheldRig{e: e, tid: tid, d: d, x: x, xKey: xKey, wui: key, pokes: pokes}
}

// seat invites CLE-35 and runs the back-fill on a live session; it returns once
// the seat is stamped, with the session still open for its error list.
func (g withheldRig) seat(t *testing.T) *seatedSession {
	t.Helper()
	ctx := context.Background()
	if err := g.e.st.InviteChannelAgent(ctx, g.tid, "mobile", "box-desk", "CLE-35", time.Now()); err != nil {
		t.Fatal(err)
	}
	s, err := g.d.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeWait(s) })
	bf := g.e.st.(store.Backfills)
	eventually(t, "seat stamped", func() bool {
		p, _ := bf.PendingBackfills(ctx, g.tid, "box-desk")
		return len(p) == 0
	})
	return &seatedSession{errs: func() int { return len(s.RecvErrors()) }}
}

type seatedSession struct{ errs func() int }

func foreignKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, k, _ := ed25519.GenerateKey(nil)
	return k
}

func sortedIDs(ms ...*msg.Message) string {
	var out []string
	for _, m := range ms {
		out = append(out, m.MsgID)
	}
	sort.Strings(out)
	return strings.Join(out, ",")
}

func TestBackfillWithholdsARowThatFailsItsPin(t *testing.T) {
	g := newWithheldRig(t)
	human := putSignedRow(t, g.e, g.tid, g.wui, hub.WUIBox, "HUM-1", "box-desk", "mobile")
	moved := putSignedRow(t, g.e, g.tid, foreignKey(t), "box-x", "CLE-40", hub.WUIBox, "mobile")
	still := putSignedRow(t, g.e, g.tid, g.xKey, "box-x", "CLE-40", hub.WUIBox, "mobile")
	s := g.seat(t)
	eventually(t, "two rows, one poke", func() bool {
		return strings.Join(inboxIDs(t, g.d, "CLE-35"), ",") == sortedIDs(human, still) && len(g.pokes()) == 1
	})
	p := g.pokes()[0]
	t.Logf("MEASURED poke: %s", p)
	want := "added to #mobile: 2 earlier messages in 2 topics, newest from "
	if !strings.Contains(p, want) || !strings.Contains(p, "; 1 earlier message not sent: signed by a key this workspace does not pin for the sender's box; newest in topic "+moved.TaskID) {
		t.Fatalf("summary: %s", p)
	}
	if n := s.errs(); n != 0 {
		t.Fatalf("the box refused %d frames: the hub sent a row it should have withheld", n)
	}
}

// Nothing written still rings: this line is all the agent ever hears of them.
func TestBackfillAllWithheldStillRings(t *testing.T) {
	g := newWithheldRig(t)
	moved := putSignedRow(t, g.e, g.tid, foreignKey(t), "box-x", "CLE-40", hub.WUIBox, "mobile")
	g.seat(t)
	eventually(t, "one poke", func() bool { return len(g.pokes()) == 1 })
	p := g.pokes()[0]
	t.Logf("MEASURED poke: %s", p)
	if !strings.Contains(p, "added to #mobile: 1 earlier message not sent") || !strings.Contains(p, moved.TaskID) || strings.Contains(p, "0 earlier") {
		t.Fatalf("summary: %s", p)
	}
	if ids := inboxIDs(t, g.d, "CLE-35"); len(ids) != 0 {
		t.Fatalf("inbox %v", ids)
	}
}

// A re-keyed box's old row in a channel that never moved fails the same way, so
// the line names no move. Back-fill stays on the current pin, not the history:
// the box holds one pin and would refuse a row that passed on an older key.
func TestBackfillRekeyedBoxRowIsWithheldNotMoved(t *testing.T) {
	g := newWithheldRig(t)
	old := putSignedRow(t, g.e, g.tid, g.xKey, "box-x", "CLE-40", hub.WUIBox, "mobile")
	pub, _, _ := ed25519.GenerateKey(nil)
	later := time.Now().Add(time.Second)
	if err := g.e.st.PutPin(context.Background(), g.tid, "box-x", pub, true, later, later); err != nil {
		t.Fatal(err)
	}
	g.seat(t)
	eventually(t, "one poke", func() bool { return len(g.pokes()) == 1 })
	p := g.pokes()[0]
	if !strings.Contains(p, "1 earlier message not sent") || !strings.Contains(p, old.TaskID) {
		t.Fatalf("summary: %s", p)
	}
	if strings.Contains(strings.ToLower(p), "moved") {
		t.Fatalf("a re-keyed box's row is called moved: %s", p)
	}
}

// Rows that must not change. Normally a box has ANOTHER key in <DST>
// (pins_pubkey_live_unique): the same key can only be live there once its
// <SRC> pin is revoked, which this fixture does on purpose. Such a moved row is
// delivered as now, with no mention of anything withheld.
func TestBackfillSameKeyMovedRowIsDelivered(t *testing.T) {
	g := newWithheldRig(t)
	ctx := context.Background()
	src, _ := g.e.tenant()
	pub, key, _ := ed25519.GenerateKey(nil)
	now := time.Now()
	if err := g.e.st.PutPin(ctx, src, "box-y", pub, false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := g.e.st.PutPin(ctx, g.tid, "box-y", pub, false, now, now); err == nil {
		t.Fatal("control: the key is live in <SRC>, its pin in <DST> must be refused")
	}
	later := now.Add(time.Second)
	if err := g.e.st.RevokePin(ctx, src, "box-y", later, later); err != nil {
		t.Fatal(err)
	}
	if err := g.e.st.PutPin(ctx, g.tid, "box-y", pub, false, later, later); err != nil {
		t.Fatal(err)
	}
	human := putSignedRow(t, g.e, g.tid, g.wui, hub.WUIBox, "HUM-1", "box-desk", "mobile")
	moved := putSignedRow(t, g.e, g.tid, key, "box-y", "CLE-41", hub.WUIBox, "mobile")
	g.seat(t)
	eventually(t, "both rows, one poke", func() bool {
		return strings.Join(inboxIDs(t, g.d, "CLE-35"), ",") == sortedIDs(human, moved) && len(g.pokes()) == 1
	})
	if p := g.pokes()[0]; strings.Contains(p, "not sent") || !strings.Contains(p, "2 earlier messages in 2 topics") {
		t.Fatalf("summary: %s", p)
	}
}

// What tail can read of a withheld row: BoxTaskEnvelopes shows a box what it
// sent, what is addressed to it, and what was delivered to it.
func TestBackfillWithheldRowByTail(t *testing.T) {
	g := newWithheldRig(t)
	own := putSignedRow(t, g.e, g.tid, foreignKey(t), "box-desk", "CLE-36", hub.WUIBox, "mobile")
	other := putSignedRow(t, g.e, g.tid, foreignKey(t), "box-x", "CLE-40", hub.WUIBox, "mobile")
	g.seat(t)
	ctx := context.Background()
	s, err := g.d.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(s)
	nOwn, err := s.Tail(ctx, own.TaskID, false, func(*wire.Envelope) {})
	if err != nil {
		t.Fatal(err)
	}
	nOther, err := s.Tail(ctx, other.TaskID, false, func(*wire.Envelope) {})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("MEASURED tail from box-desk: own box row %d, other box row %d", nOwn, nOther)
	if nOwn != 1 || nOther != 0 {
		t.Fatalf("tail own %d other %d, want 1 and 0", nOwn, nOther)
	}
}
