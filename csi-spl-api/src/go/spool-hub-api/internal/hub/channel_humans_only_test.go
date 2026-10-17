package hub_test

import (
	"bytes"
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-2423 (rdb 0206): a channel whose people removed every agent is
// humans-only. Owner HUM-10 2026-10-17, poll answer A: no agent is a member,
// none reads or posts in it. A person's invite lifts it. Memory store, and
// Postgres with SPOOL_TEST_PG_DSN.

func removeAgent(t *testing.T, r *fallbackRig, ch, box, id string) {
	t.Helper()
	if code, out := call(t, r.e, r.tid, http.MethodDelete, "/v1/channels/"+ch+"/agents/"+box+"/"+id, r.human, nil); code != http.StatusNoContent {
		t.Fatalf("remove %s from #%s: %d %v", id, ch, code, out)
	}
}

func TestChannelHumansOnlyNoAgentReadsIt(t *testing.T) {
	r, b := aiRig(t)
	has := func(id string) bool { return strings.Contains(strings.Join(inboxIDs(t, b, "GRK-36"), ","), id) }
	if _, ok := membersOf(t, r)["humans_only"]; ok {
		t.Fatalf("humans_only on a channel with an agent: %v", membersOf(t, r))
	}

	removeAgent(t, r, "drivers", "box-b", "GRK-36")
	out := membersOf(t, r)
	if out["humans_only"] != true || len(out["agents"].([]any)) != 0 {
		t.Fatalf("members answer after the last agent went: %v", out)
	}
	if _, ok := out["fallback"]; ok {
		t.Fatalf("a humans-only channel names a fallback responder: %v", out)
	}
	// A plain post, and an @agent send, which there is a plain post too: no
	// agent, no box and no fallback responder gets either.
	m1, m2 := "a2423000-0000-4000-8000-000000000001", "a2423000-0000-4000-8000-000000000002"
	threadFrame(t, r.ws, m1, "b2423000-0000-4000-8000-000000000001", "drivers", 1, "humans only now")
	threadFrame(t, r.ws, m2, "b2423000-0000-4000-8000-000000000002", "drivers", 1, "@GRK-36 please check car 7")
	watch(400*time.Millisecond, func() bool { return has(m1) || has(m2) || len(inbox(t, r.desk, "CLE-001")) != 0 })
	if has(m1) || has(m2) {
		t.Fatalf("a humans-only channel's post reached GRK-36: %v", inboxIDs(t, b, "GRK-36"))
	}
	if ids := inboxIDs(t, r.desk, "CLE-001"); len(ids) != 0 || len(r.pokes()) != 0 {
		t.Fatalf("a humans-only channel's post fell back: inbox %v pokes %v", ids, r.pokes())
	}

	// The @agent line gets the SPL-2419 note naming the agent; the plain one none.
	note := func(task string) string {
		envs, err := r.e.st.TaskEnvelopes(context.Background(), r.tid, task)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range envs {
			if bytes.Contains(e, []byte(`"from":"`+hub.PublicNoticeFrom+`"`)) {
				return string(e)
			}
		}
		return ""
	}
	eventually(t, "the humans-only note on the @agent line", func() bool {
		n := note("b2423000-0000-4000-8000-000000000002") // SPL-2426 may drop the "@": match the id and the words
		return strings.Contains(n, "GRK-36") && strings.Contains(n, "does not belong to this channel")
	})
	if n := note("b2423000-0000-4000-8000-000000000001"); n != "" {
		t.Fatalf("a plain line got a note: %s", n)
	}

	// A person invites the agent again: the mark is gone, posts flow.
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/channels/drivers/agents", r.human,
		map[string]string{"id": "GRK-36", "box": "box-b"}); code != http.StatusCreated {
		t.Fatalf("re-invite: %d %v", code, out)
	}
	if _, ok := membersOf(t, r)["humans_only"]; ok {
		t.Fatalf("humans_only after a person invited an agent: %v", membersOf(t, r))
	}
	m3 := "a2423000-0000-4000-8000-000000000003"
	threadFrame(t, r.ws, m3, "b2423000-0000-4000-8000-000000000003", "drivers", 1, "agents again")
	eventually(t, "GRK-36 got the post after the re-invite", func() bool { return has(m3) })
}

// Removing one of two agents leaves an ordinary channel; #lobby, the one
// channel an agent may post to without a seat (SPL-961), refuses an agent
// once it is humans-only.
func TestChannelHumansOnlyLobbyRefusesAgentPost(t *testing.T) {
	r, b := aiRig(t)
	ctx := context.Background()
	for _, id := range []string{"GRK-36"} {
		if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/channels/lobby/agents", r.human,
			map[string]string{"id": id, "box": "box-b"}); code != http.StatusCreated {
			t.Fatalf("lobby invite: %d %v", code, out)
		}
	}
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/channels/lobby/agents", r.human,
		map[string]string{"id": "CLE-001", "box": "box-desk"}); code != http.StatusCreated {
		t.Fatalf("lobby invite CLE-001: %d %v", code, out)
	}
	removeAgent(t, r, "lobby", "box-desk", "CLE-001")
	lobby := func() map[string]any {
		_, out := call(t, r.e, r.tid, http.MethodGet, "/v1/channels/lobby/members", r.human, nil)
		return out
	}
	if _, ok := lobby()["humans_only"]; ok {
		t.Fatalf("humans_only with GRK-36 still a member: %v", lobby())
	}
	if out, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "GRK-36", Channel: "lobby", Body: "hello", Hub: b.c}); err != nil || out.Delivery != wire.DeliverySent {
		t.Fatalf("lobby post before the mark: %v %+v", err, out)
	}
	removeAgent(t, r, "lobby", "box-b", "GRK-36")
	if lobby()["humans_only"] != true {
		t.Fatalf("lobby not humans-only after its last agent went: %v", lobby())
	}
	if _, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "GRK-36", Channel: "lobby", Body: "hello again", Hub: b.c}); err == nil ||
		!strings.Contains(err.Error(), "unknown_channel") {
		t.Fatalf("GRK-36 into a humans-only #lobby: %v (want unknown_channel)", err)
	}
}
