package hub_test

// specs/036 FR-009..FR-011: a terminal-typed line is posted from=<agent> with
// typed_by=<HUM-n> on the send frame. The hub accepts the claim only when the
// agent is one the sending box announced, the human is a member of the tenant
// and a box_operators binding (rdb 0040) says that human operates that box;
// otherwise the send is refused with typed_by_not_bound and nothing is stored.
// An accepted claim is stored and reaches the view API and the browser frame,
// never a box.

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func TestTypedByVerifiedStoredAndShownToBrowsersOnly(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC()
	a := e.box(tid, "box-a", "CLE-01")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	for _, x := range []*box{a, b} {
		s, err := x.c.Dial(ctx, wire.RoleBox)
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(s)
	}
	eventually(t, "CLE-07@box-b known on box-a", func() bool {
		tb, err := a.c.ResolveToBox("CLE-07", "")
		return err == nil && tb == "box-b"
	})

	h := e.st.(store.Humans)
	admit := func(sub string) string { // the first bootstraps; the rest are invited
		mail := sub + tid + "@example.com"
		if err := h.PutInvite(ctx, store.Invite{TenantID: tid, Email: mail, Role: "developer", InvitedBy: "operator",
			ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		hum, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: sub + tid, Email: mail},
			tid, store.AdmitPolicy{BootstrapOwner: true}, now)
		if err != nil {
			t.Fatal(err)
		}
		return hum
	}
	bound, unbound := admit("op-"), admit("other-")
	ops := e.st.(store.BoxOperators)
	if err := ops.GrantBoxOperator(ctx, tid, "box-a", bound, "operator", now); err != nil {
		t.Fatal(err)
	}
	if err := ops.GrantBoxOperator(ctx, tid, "box-a", "HUM-999999", "operator", now); err == nil {
		t.Fatal("a binding for a non-member was accepted")
	}

	task := "7d2f7a0e-4b1c-4c55-8e0f-3a9b1c2d4e5f"
	w := dialWUI(t, e, tid, bound)
	w.send(map[string]string{"type": "subscribe", "task_id": task})
	w.read("subscribed")

	sendAs := func(from, typedBy, body string) (action.SendResult, error) {
		return action.SendCtx(ctx, a.cfg, action.SendArgs{From: from, To: "CLE-07", Kind: "note", Body: body,
			TaskID: task, ToBox: "box-b", TypedBy: typedBy, Hub: a.c})
	}
	refused := func(what, from, typedBy string) {
		t.Helper()
		out, err := sendAs(from, typedBy, what)
		if err == nil || !strings.Contains(err.Error(), "typed_by_not_bound") {
			t.Fatalf("%s: want typed_by_not_bound, got %+v %v", what, out, err)
		}
		if has, _ := e.st.HasMessage(ctx, tid, out.MsgID); out.MsgID != "" && has {
			t.Fatalf("%s: the refused send was stored", what)
		}
	}
	refused("a member with no binding", "CLE-01", unbound)
	refused("not a member of the tenant", "CLE-01", "HUM-999999")
	// An agent box-a never announced is refused before typed_by is read:
	// onSend's sender check, with or without a claim. A role=cli
	// send keeps it pending for the box session to announce; nothing stored.
	for _, claim := range []string{bound, ""} {
		out, err := sendAs("GRK-99", claim, "never announced")
		if err != nil || out.Delivery != wire.DeliveryPending {
			t.Fatalf("an agent box-a never announced (typed_by %q): want pending, got %+v %v", claim, out, err)
		}
		if has, _ := e.st.HasMessage(ctx, tid, out.MsgID); has {
			t.Fatalf("an agent box-a never announced (typed_by %q): stored", claim)
		}
	}
	if _, err := sendAs("CLE-01", "bob", "malformed"); err == nil {
		t.Fatal("a non HUM-* typed_by was sent")
	}

	// Accepted.
	out, err := sendAs("CLE-01", bound, "typed at the terminal")
	if err != nil || out.Delivery != wire.DeliverySent {
		t.Fatalf("bound send: %+v %v", out, err)
	}
	if f := w.read("message"); f.TypedBy != bound || innerOf(t, f)["from"] != "CLE-01" {
		t.Fatalf("browser frame typed_by=%q from=%v, want %s / CLE-01", f.TypedBy, innerOf(t, f)["from"], bound)
	}
	// CONTROL: the same agent without a claim is the agent, as before.
	plain, err := sendAs("CLE-01", "", "the agent itself")
	if err != nil {
		t.Fatal(err)
	}
	if f := w.read("message"); f.TypedBy != "" {
		t.Fatalf("an unclaimed send carried typed_by=%q", f.TypedBy)
	}

	code, _, body := viewGet(t, e, tid, "/v1/view/topics/"+task)
	if code != 200 {
		t.Fatalf("view: %d %s", code, body)
	}
	var v struct {
		Messages []struct {
			Env     json.RawMessage `json:"env"`
			TypedBy *string         `json:"typed_by"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &v); err != nil || len(v.Messages) != 2 {
		t.Fatalf("view: %v %s", err, body)
	}
	got := map[string]string{}
	for _, m := range v.Messages {
		// DB payload cut 4: the view's env.msg leaves out a task_id equal to
		// the topic's, so it is not a whole v:1 message; read the msg_id only.
		var env struct {
			Msg struct {
				MsgID string `json:"msg_id"`
			} `json:"msg"`
		}
		json.Unmarshal(m.Env, &env) //nolint:errcheck
		inner := env.Msg
		tb := "<absent>"
		if m.TypedBy != nil {
			tb = *m.TypedBy
		}
		got[inner.MsgID] = tb
	}
	if got[out.MsgID] != bound || got[plain.MsgID] != "<absent>" {
		t.Fatalf("view typed_by = %v, want %s for %s and absent for %s", got, bound, out.MsgID, plain.MsgID)
	}

	// Never to a box: box-b's inbox copy is the signed v:1, with no claim.
	eventually(t, "both notes in CLE-07's inbox", func() bool { return len(inbox(t, b, "CLE-07")) == 2 })
	raw, _ := os.ReadDir(filepath.Join(b.cfg.SpoolRoot, "CLE-07", "inbox"))
	for _, f := range raw {
		bs, _ := os.ReadFile(filepath.Join(b.cfg.SpoolRoot, "CLE-07", "inbox", f.Name()))
		if strings.Contains(string(bs), "typed_by") || strings.Contains(string(bs), bound) {
			t.Fatalf("the claim reached a box: %s", bs)
		}
	}

	// Revoked: refused again.
	if err := ops.RevokeBoxOperator(ctx, tid, "box-a", bound); err != nil {
		t.Fatal(err)
	}
	refused("a revoked binding", "CLE-01", bound)
}
