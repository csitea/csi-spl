package hub_test

import (
	"context"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
)

// Spec 108 section 4, pair (e), n=5: cross-workspace spool send. A box of
// workspace A sends to an agent that lives on a box of workspace B, naming
// that box as to_box. The hub refuses it (to_box is not pinned in A), B's
// box receives nothing and B's store holds nothing. CONTROL: the same send
// to an agent on another box of A is delivered, so the refusal means
// "another workspace", not "this box cannot send".

// TestCrossTenantSendPairRefusedAcrossWorkspaces is pair (e), n=5.
func TestCrossTenantSendPairRefusedAcrossWorkspaces(t *testing.T) {
	e := newEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	sender := e.box(a, "box-a1", "CLE-41")
	peer := e.box(a, "box-a2", "CLE-42")
	foreign := e.box(b, "box-b1", "CLE-51")
	e.pin(a, sender)
	e.pin(a, peer)
	e.pin(b, foreign)
	ctx := context.Background()
	for _, bx := range []*box{peer, foreign} {
		if _, err := bx.c.Sync(ctx); err != nil {
			t.Fatal(err)
		}
	}

	// CONTROL: within workspace A the send is delivered to the peer's inbox.
	own := send(t, sender, "CLE-41", "CLE-42", "task", "within A", "box-a2")
	if _, err := peer.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	got := inbox(t, peer, "CLE-42")
	if len(got) != 1 || got[0].MsgID != own.MsgID {
		t.Fatalf("control: CLE-42's inbox after a send within A: %d message(s), want %s", len(got), own.MsgID)
	}

	// PAIR: the same box sending to B's agent (CLE-51) on B's box is refused.
	const marker = "across workspaces"
	out, err := action.SendCtx(ctx, sender.cfg, action.SendArgs{
		From: "CLE-41", To: "CLE-51", Kind: "task", Body: marker, ToBox: "box-b1", Hub: sender.c,
	})
	if err == nil {
		t.Fatalf("send from workspace A to workspace B's box-b1 was accepted: %+v", out)
	}
	if !strings.Contains(err.Error(), "unpinned_box") {
		t.Fatalf("send from A to B's box-b1: %v, want unpinned_box", err)
	}

	// Nothing of it reached B: not B's box, not B's store.
	if _, err := foreign.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if got := inbox(t, foreign, "CLE-51"); len(got) != 0 {
		t.Fatalf("CLE-51 (workspace B) received %d message(s) from workspace A", len(got))
	}
	if out.TaskID != "" {
		if envs, err := e.st.TaskEnvelopes(ctx, b, out.TaskID); err != nil || len(envs) != 0 {
			t.Fatalf("workspace B's store holds %d envelope(s) of A's refused send: %v", len(envs), err)
		}
	}
}
