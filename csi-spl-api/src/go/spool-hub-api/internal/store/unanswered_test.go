package store

import (
	"context"
	"testing"
	"time"
)

// SPL-1225: UnansweredPosts finds a signed human post that no agent replied
// to in its topic. Unlike UnheardPosts it ignores whether a box was "sent"
// the frame - box-desk is always sent a channel post, so that test caught
// nothing for the owner's case. The ground truth is a REPLY in the topic.

// humanPost is one signed browser post by a person into a channel.
func humanPost(tenant, task, channel, body string, at time.Time) Message {
	return Message{
		TenantID: tenant, MsgID: uuid4(), TaskID: task, Channel: channel,
		FromBox: "box-wui", FromID: "HUM-google-sub-10", ToBox: "box-wui", ToID: "ALL-0",
		Kind: "note", Body: body, Files: []byte(`[]`), Msg: []byte(`{"v":1}`),
		EnvSig: "sig", Env: []byte(`{"env":1}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour),
	}
}

// agentReply is one reply an agent posts through its desk into a topic.
func agentReply(tenant, task string, at time.Time) Message {
	m := humanPost(tenant, task, "devel", "on it", at)
	m.FromBox, m.FromID, m.ToID = "box-desk", "CLE-77", "ALL-0"
	return m
}

func TestUnansweredPosts(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tid := newTenant(t, s)
			base := time.Now().UTC().Truncate(time.Microsecond).Add(-time.Hour)
			ins := func(m Message) Message {
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}

			// (1) a human channel post nobody answered -> unanswered.
			unheard := ins(humanPost(tid, "task-unheard", "devel", "anyone there?", base))

			// (2) CONTROL: a human post an agent replied to in the topic.
			answered := ins(humanPost(tid, "task-answered", "devel", "help?", base.Add(time.Second)))
			ins(agentReply(tid, "task-answered", base.Add(2*time.Second)))

			// (3) CONTROL: a human DM to a person never falls back.
			dm := humanPost(tid, "task-dm", "", "hey", base.Add(3*time.Second))
			dm.ToBox, dm.ToID = "box-wui", "HUM-google-sub-27"
			ins(dm)

			// (4) CONTROL: an agent's own channel post is not a human post.
			ins(agentReply(tid, "task-agent-only", base.Add(4*time.Second)))

			got, err := s.(Fallbacks).UnansweredPosts(ctx, tid, base.Add(-time.Minute), time.Now().UTC(), 20)
			if err != nil {
				t.Fatal(err)
			}
			ids := map[string]bool{}
			for _, q := range got {
				ids[q.MsgID] = true
			}
			if !ids[unheard.MsgID] {
				t.Fatalf("the unanswered post %s was not returned: %v", unheard.MsgID, ids)
			}
			if ids[answered.MsgID] {
				t.Fatalf("the answered post %s must not be returned (a reply is the ground truth)", answered.MsgID)
			}
			if len(got) != 1 {
				t.Fatalf("want exactly the one unanswered post, got %d: %v", len(got), ids)
			}

			// (5) CONTROL: once it has a fallback record, it is not returned
			// again (the per-msg claim that stops a double escalation).
			if err := s.(Fallbacks).RecordFallback(ctx, FallbackDelivery{
				TenantID: tid, MsgID: unheard.MsgID, Channel: "devel", Box: "box-desk",
				Agent: "CLE-001", DeliveredAt: time.Now().UTC()}); err != nil {
				t.Fatal(err)
			}
			got, err = s.(Fallbacks).UnansweredPosts(ctx, tid, base.Add(-time.Minute), time.Now().UTC(), 20)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 0 {
				t.Fatalf("a recorded fallback must exclude the post, got %d", len(got))
			}

			// (6) the grace: a post newer than `until` is not yet due.
			ins(humanPost(tid, "task-fresh", "devel", "just now", time.Now().UTC()))
			got, err = s.(Fallbacks).UnansweredPosts(ctx, tid, base.Add(-time.Minute), time.Now().UTC().Add(-30*time.Second), 20)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 0 {
				t.Fatalf("a post inside the grace must not be due yet, got %d", len(got))
			}
		})
	}
}
