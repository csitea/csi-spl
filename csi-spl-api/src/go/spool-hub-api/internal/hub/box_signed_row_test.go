package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 169 T4c: a write authorised by box NAME also needs the stored row's
// signature to verify against this box's current pin or a key in this
// workspace's pins_history. A row moved in from another workspace fails (a move
// does not carry the history), a re-keyed box's own old row passes. Remove
// boxSignedRow from boxOwnMessage or boxMayMove and the refusals turn red.

func TestBoxEditRefusesARowItsKeysDidNotSign(t *testing.T) {
	e, tid, a, _, _, _ := boxEditRig(t)
	ctx := context.Background()
	moved := putSignedRow(t, e, tid, foreignKey(t), "box-a", "CLE-07", hub.WUIBox, "")
	if _, err := action.Edit(ctx, a.cfg, action.EditArgs{MsgID: moved.MsgID, As: "CLE-07", Body: "taken over", Hub: a.c}); hubToken(err) != "not_author" {
		t.Fatalf("edit: want not_author, got %v", err)
	}
	if _, err := action.Delete(ctx, a.cfg, action.EditArgs{MsgID: moved.MsgID, As: "CLE-07", Hub: a.c}); hubToken(err) != "not_author" {
		t.Fatalf("delete: want not_author, got %v", err)
	}
	m, err := e.st.GetEditable(ctx, tid, moved.MsgID, time.Now())
	if err != nil || m.Body != moved.Body {
		t.Fatalf("row after the refusals: %q %v", m.Body, err)
	}
}

func TestBoxEditKeepsARekeyedBoxsOldRow(t *testing.T) {
	e, tid, a, _, sent, _ := boxEditRig(t)
	ctx := context.Background()
	pubB64, err := sign.GenerateKey(a.cfg.KeysDir, "box-a", true)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := base64.StdEncoding.DecodeString(pubB64)
	if err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(time.Second)
	if err := e.st.PutPin(ctx, tid, "box-a", ed25519.PublicKey(pub), true, later, later); err != nil {
		t.Fatal(err)
	}
	if _, err := action.Edit(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-07", Body: "still mine", Hub: a.c}); err != nil {
		t.Fatalf("edit of the old-key row: %v", err)
	}
	m, err := e.st.GetEditable(ctx, tid, sent.MsgID, time.Now())
	if err != nil || m.Body != "still mine" {
		t.Fatalf("row %q %v", m.Body, err)
	}
}

// A row with no stored signature has nothing to verify: it stays as it was
// (prd holds 3161 such rows from live boxes, 2026-11-02).
func TestBoxEditLeavesAnUnsignedRowAsItWas(t *testing.T) {
	e, tid, a, _, _, _ := boxEditRig(t)
	ctx := context.Background()
	m := putSignedRow(t, e, tid, foreignKey(t), "box-a", "CLE-07", hub.WUIBox, "")
	unsigned := unsignedCopy(t, e, tid, m)
	if _, err := action.Edit(ctx, a.cfg, action.EditArgs{MsgID: unsigned, As: "CLE-07", Body: "edited", Hub: a.c}); err != nil {
		t.Fatalf("edit of an unsigned row: %v", err)
	}
}

// unsignedCopy stores m once more under a new id with no signature.
func unsignedCopy(t *testing.T, e *env, tid string, m *msg.Message) string {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	c := *m
	c.MsgID, c.TaskID = uuidV4(), uuidV4()
	inner, err := msg.Canonical(&c)
	if err != nil {
		t.Fatal(err)
	}
	raw := append(append([]byte(`{"from_box":"box-a","to_box":"box-wui","msg":`), inner...), '}')
	if _, err := e.st.InsertMessage(ctx, store.Message{TenantID: tid, MsgID: c.MsgID, TaskID: c.TaskID, IsParent: 1, TS: now,
		FromBox: "box-a", FromID: c.From, ToBox: hub.WUIBox, ToID: c.To, Kind: c.Kind, Body: c.Body, Files: []byte(`[]`),
		Msg: inner, Env: raw, ReceivedAt: now, ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	return c.MsgID
}

func TestBoxMoveRefusesARowItsKeysDidNotSign(t *testing.T) {
	g := boxMoveEnv(t)
	ctx := context.Background()
	moved := putSignedRow(t, g.e, g.tid, foreignKey(t), "box-b", "CLE-08", hub.WUIBox, "devel")
	if _, err := action.Move(ctx, g.b.cfg, action.MoveArgs{TaskID: moved.TaskID, Channel: "ops", As: "CLE-08", Hub: g.b.c}); hubToken(err) != "not_allowed" {
		t.Fatalf("move: want not_allowed, got %v", err)
	}
	if ch := g.channelOf(t, moved.MsgID); ch != "devel" {
		t.Fatalf("the row moved to %q", ch)
	}
	// Control: the same row signed by the box's own key moves.
	key, err := sign.LoadPrivate(g.b.cfg.KeysDir, "box-b")
	if err != nil {
		t.Fatal(err)
	}
	own := putSignedRow(t, g.e, g.tid, key, "box-b", "CLE-08", hub.WUIBox, "devel")
	if _, err := action.Move(ctx, g.b.cfg, action.MoveArgs{TaskID: own.TaskID, Channel: "ops", As: "CLE-08", Hub: g.b.c}); err != nil {
		t.Fatalf("control: %v", err)
	}
	if ch := g.channelOf(t, own.MsgID); ch != "ops" {
		t.Fatalf("control: the row stayed in %q", ch)
	}
}
