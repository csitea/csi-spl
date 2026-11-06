package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// spec 130 section 3.1 (owner HUM-10, t1 82dff03c, msgs 47ec5aab and
// 6a0ec650, poll answer C): any member reads any member's or agent's whole
// Flow with GET /v1/view/flow?member=<id>, in their own workspace only. A
// guest or a non-member reads none; the read moves nobody's marks.

// flowMember admits a developer of tid, as the identity <sub>@<tid>.
func flowMember(t *testing.T, e *env, tid, sub string) string {
	t.Helper()
	ctx, now := context.Background(), time.Now()
	h := e.st.(store.Humans)
	mail := sub + "." + tid + "@example.com"
	if err := h.PutInvite(ctx, store.Invite{TenantID: tid, Email: mail, Role: "developer", InvitedBy: store.AdmittedOperator,
		ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	id, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: sub + tid, Email: mail}, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// flowOf is the viewer's GET of path on tid: the status, the body and its event count.
func flowOf(t *testing.T, e *env, tid, path, viewer string) (int, map[string]any, int) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, path, viewer, nil)
	events, _ := out["events"].([]any)
	lines, _ := out["lines"].([]any)
	return code, out, len(events) + len(lines)
}

type flowMemberEnv struct {
	e                     *env
	tid, other            string
	viewer, target, alien string
}

// newFlowMemberEnv: viewer mentions target in tid's lobby; alien is a member
// of the other workspace only; box-a of tid runs agent c-002.
func newFlowMemberEnv(t *testing.T) flowMemberEnv {
	e := followEnv(t)
	x := flowMemberEnv{e: e}
	x.tid, _ = e.tenant()
	x.other, _ = e.tenant()
	x.viewer, x.target = flowMember(t, e, x.tid, "viewer"), flowMember(t, e, x.tid, "target")
	x.alien = flowMember(t, e, x.other, "alien")
	e.pin(x.tid, e.box(x.tid, "box-a", "c-002"))
	dialFlowMember(t, e, x.tid, x.target)
	v := dialFlowMember(t, e, x.tid, x.viewer)
	wsjson.Write(context.Background(), v, map[string]any{"type": "send", "task_id": "lobby", "kind": "chat", "body": "hey @" + x.target + " look"}) //nolint:errcheck
	readFrame(t, v, "ack")
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, _, n := flowOf(t, e, x.tid, "/v1/view/flow", x.target); n == 1 {
			return x
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the target's mention never reached its flow")
	return x
}

func TestFlowMemberReadsAnothersFlow(t *testing.T) {
	x := newFlowMemberEnv(t)
	if code, out, n := flowOf(t, x.e, x.tid, "/v1/view/flow?member="+x.target, x.viewer); code != http.StatusOK || n != 1 {
		t.Fatalf("viewer reads target's flow: %d %v", code, out)
	}
	if code, out, n := flowOf(t, x.e, x.tid, "/v1/view/flow?fold=day&member="+x.target, x.viewer); code != http.StatusOK || n != 1 {
		t.Fatalf("viewer reads target's folded flow: %d %v", code, out)
	}
	if code, out, n := flowOf(t, x.e, x.tid, "/v1/view/flow", x.viewer); code != http.StatusOK || n != 0 {
		t.Fatalf("CONTROL: no ?member= is the viewer's own (empty) flow: %d %v", code, out)
	}
	if code, out, n := flowOf(t, x.e, x.tid, "/v1/view/flow?member="+x.viewer, x.viewer); code != http.StatusOK || n != 0 {
		t.Fatalf("?member=<self> is the viewer's own flow: %d %v", code, out)
	}
	if code, out := call(t, x.e, x.tid, http.MethodGet, "/v1/view/flow?member=c-002@box-a", x.viewer, nil); code != http.StatusOK {
		t.Fatalf("an agent of the workspace: %d %v", code, out)
	}
	for _, m := range []string{"c-002@box-zz", "c-002", "HUM-999999", "ALL-0", "not-an-id"} {
		if code, out := call(t, x.e, x.tid, http.MethodGet, "/v1/view/flow?member="+m, x.viewer, nil); code != http.StatusNotFound {
			t.Errorf("?member=%s: %d %v, want 404", m, code, out)
		}
	}
}

func TestFlowMemberNeverAcrossWorkspaces(t *testing.T) {
	x := newFlowMemberEnv(t)
	if code, out := call(t, x.e, x.tid, http.MethodGet, "/v1/view/flow?member="+x.alien, x.viewer, nil); code != http.StatusNotFound {
		t.Fatalf("a member of another workspace by id: %d %v, want 404", code, out)
	}
	if code, out := call(t, x.e, x.other, http.MethodGet, "/v1/view/flow?member="+x.alien, x.viewer, nil); code != http.StatusForbidden {
		t.Fatalf("the other workspace's host, viewer no member there: %d %v, want 403", code, out)
	}
	if code, out := call(t, x.e, x.other, http.MethodGet, "/v1/view/flow?member="+x.target, x.alien, nil); code != http.StatusNotFound {
		t.Fatalf("alien names tid's target on its own host: %d %v, want 404", code, out)
	}
	if code, out := call(t, x.e, x.other, http.MethodGet, "/v1/view/flow?member=c-002@box-a", x.alien, nil); code != http.StatusNotFound {
		t.Fatalf("alien names tid's agent: %d %v, want 404", code, out)
	}
	if code, out := call(t, x.e, x.other, http.MethodGet, "/v1/view/flow", x.alien, nil); code != http.StatusOK {
		t.Fatalf("CONTROL: alien reads its own flow: %d %v", code, out)
	}
}

func TestFlowMemberGuestAndNonMemberRefused(t *testing.T) {
	x := newFlowMemberEnv(t)
	guest, _ := seatIdent(t, x.e, x.tid, rbac.ChannelGuest)
	demo, _ := seatIdent(t, x.e, x.tid, rbac.DemoUser)
	for _, v := range []string{"GST-1", "HUM-999999", guest, demo} {
		if code, out := call(t, x.e, x.tid, http.MethodGet, "/v1/view/flow?member="+x.target, v, nil); code != http.StatusForbidden {
			t.Errorf("viewer %s: %d %v, want 403", v, code, out)
		}
	}
}

// While a box of the workspace is locked to someone other than the reader,
// every read of someone else's Flow is 403, folded or not: the unfolded
// page's counts, unread and keys would still name the locked box's topics
// (row B5). The lock's owner, hiding nothing, still reads others.
func TestFlowMemberRefusedWhileABoxIsLocked(t *testing.T) {
	r := newViewRig(t)
	for _, q := range []string{"", "&fold=day", "&counts_only=true"} {
		if code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/view/flow?member="+r.owner+q, r.admin, nil); code != http.StatusForbidden {
			t.Errorf("admin reads the lock owner's flow%s: %d %v, want 403", q, code, out)
		}
	}
	if code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/view/flow?member="+r.admin, r.owner, nil); code != http.StatusOK {
		t.Errorf("CONTROL: the lock owner reads the admin's flow: %d %v", code, out)
	}
	if code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/view/flow", r.admin, nil); code != http.StatusOK {
		t.Errorf("CONTROL: the admin reads its own flow: %d %v", code, out)
	}
}

// Reading another's Flow is read-only: neither the target's nor the
// viewer's counts move, and the next read of the target answers the same.
func TestFlowMemberReadMovesNoMarks(t *testing.T) {
	x := newFlowMemberEnv(t)
	counts := func(as string) (float64, float64) {
		_, out := call(t, x.e, x.tid, http.MethodGet, "/v1/view/flow?counts_only=true", as, nil)
		return countOf(out, "counts", "total"), countOf(out, "unread", "total")
	}
	tc, tu := counts(x.target)
	vc, vu := counts(x.viewer)
	if tc != 1 || tu != 1 {
		t.Fatalf("CONTROL: the target starts with 1 unseen, 1 unread: %v %v", tc, tu)
	}
	for _, q := range []string{"", "&fold=day", "&counts_only=true"} {
		if code, _ := call(t, x.e, x.tid, http.MethodGet, "/v1/view/flow?member="+x.target+q, x.viewer, nil); code != http.StatusOK {
			t.Fatalf("read%s: %d", q, code)
		}
	}
	if c, u := counts(x.target); c != tc || u != tu {
		t.Fatalf("the target's counts moved: %v/%v -> %v/%v", tc, tu, c, u)
	}
	if c, u := counts(x.viewer); c != vc || u != vu {
		t.Fatalf("the viewer's counts moved: %v/%v -> %v/%v", vc, vu, c, u)
	}
	if _, out, _ := flowOf(t, x.e, x.tid, "/v1/view/flow?member="+x.target, x.viewer); out["events"].([]any)[0].(map[string]any)["unread"] != true {
		t.Fatalf("the target's event reads as read after the viewer's reads: %v", out)
	}
}
