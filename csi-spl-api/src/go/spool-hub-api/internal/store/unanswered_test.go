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
		TenantID: tenant, MsgID: uuid4(), TaskID: task, Channel: channel, TS: at,
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
			// task_id is a UUID column on Postgres, so every topic id is a uuid4.
			taskUnheard, taskAnswered, taskDM, taskAgent, taskFresh := uuid4(), uuid4(), uuid4(), uuid4(), uuid4()

			// (1) a human channel post nobody answered -> unanswered.
			unheard := ins(humanPost(tid, taskUnheard, "devel", "anyone there?", base))

			// (2) CONTROL: a human post an agent replied to in the topic.
			answered := ins(humanPost(tid, taskAnswered, "devel", "help?", base.Add(time.Second)))
			ins(agentReply(tid, taskAnswered, base.Add(2*time.Second)))

			// (3) CONTROL: a human DM to a person never falls back.
			dm := humanPost(tid, taskDM, "", "hey", base.Add(3*time.Second))
			dm.ToBox, dm.ToID = "box-wui", "HUM-google-sub-27"
			ins(dm)

			// (4) CONTROL: an agent's own channel post is not a human post.
			ins(agentReply(tid, taskAgent, base.Add(4*time.Second)))

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
			ins(humanPost(tid, taskFresh, "devel", "just now", time.Now().UTC()))
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

// SPL-1225 miss fix (prd t1 4b0ba40a): a post that WAS escalated but stayed
// unanswered is re-escalatable once its last attempt is old enough, until the
// attempts cap. BumpFallback advances it and counts the attempt.
func TestReescalatablePosts(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tid := newTenant(t, s)
			fb := s.(Fallbacks)
			t0 := time.Now().UTC().Truncate(time.Microsecond).Add(-time.Hour)
			post := humanPost(tid, uuid4(), "devel", "anyone?", t0)
			if _, err := s.InsertMessage(ctx, post); err != nil {
				t.Fatal(err)
			}
			rec := FallbackDelivery{TenantID: tid, MsgID: post.MsgID, Channel: "devel", Box: "box-desk", Agent: "CLE-001", DeliveredAt: t0.Add(2 * time.Minute)}
			if won, err := fb.ClaimFallback(ctx, rec); err != nil || !won {
				t.Fatalf("claim: won=%v err=%v", won, err)
			}
			until := time.Now().UTC()
			const maxAtt = 3
			// Not yet re-escalatable: last attempt is newer than escalatedBefore.
			if got, err := fb.ReescalatablePosts(ctx, tid, t0.Add(-time.Minute), t0.Add(time.Minute), until, maxAtt, 20); err != nil || len(got) != 0 {
				t.Fatalf("too-recent attempt must not re-escalate: got %d err %v", len(got), err)
			}
			// Due once escalatedBefore passes the attempt.
			got, err := fb.ReescalatablePosts(ctx, tid, t0.Add(-time.Minute), t0.Add(5*time.Minute), until, maxAtt, 20)
			if err != nil || len(got) != 1 || got[0].MsgID != post.MsgID {
				t.Fatalf("want the post re-escalatable: got %d err %v", len(got), err)
			}
			// CONTROL (side effect fix): the age bound. The same due post is NOT
			// re-escalated when it is older than `since` - an ancient probe post
			// with a stale SPL-997 fallback row must never be dug up.
			if old, err := fb.ReescalatablePosts(ctx, tid, t0.Add(time.Minute), t0.Add(5*time.Minute), until, maxAtt, 20); err != nil || len(old) != 0 {
				t.Fatalf("a post older than the since bound must not re-escalate: got %d err %v", len(old), err)
			}
			// Bump to attempt 2, then 3; the 3rd bump reaches the cap.
			for att := 2; att <= maxAtt; att++ {
				won, err := fb.BumpFallback(ctx, FallbackDelivery{TenantID: tid, MsgID: post.MsgID, Box: "box-desk", Agent: "CLE-001", DeliveredAt: t0.Add(time.Duration(att) * 3 * time.Minute)}, maxAtt)
				if err != nil || !won {
					t.Fatalf("bump to %d: won=%v err=%v", att, won, err)
				}
			}
			// CONTROL: at the cap, no more re-escalation and no more bumps.
			if got, err := fb.ReescalatablePosts(ctx, tid, t0.Add(-time.Minute), until, until, maxAtt, 20); err != nil || len(got) != 0 {
				t.Fatalf("capped post must not re-escalate: got %d err %v", len(got), err)
			}
			if won, err := fb.BumpFallback(ctx, FallbackDelivery{TenantID: tid, MsgID: post.MsgID, Box: "box-desk", Agent: "CLE-001", DeliveredAt: until}, maxAtt); err != nil || won {
				t.Fatalf("bump past the cap must not win: won=%v err=%v", won, err)
			}
			// CONTROL: an answered post is never re-escalatable.
			ins := humanPost(tid, uuid4(), "devel", "help?", t0)
			ans := ins
			if _, err := s.InsertMessage(ctx, ans); err != nil {
				t.Fatal(err)
			}
			if _, err := fb.ClaimFallback(ctx, FallbackDelivery{TenantID: tid, MsgID: ans.MsgID, Channel: "devel", Box: "box-desk", Agent: "CLE-001", DeliveredAt: t0}); err != nil {
				t.Fatal(err)
			}
			reply := agentReply(tid, ans.TaskID, t0.Add(time.Second))
			if _, err := s.InsertMessage(ctx, reply); err != nil {
				t.Fatal(err)
			}
			got, err = fb.ReescalatablePosts(ctx, tid, t0.Add(-time.Minute), until, until, maxAtt, 20)
			for _, q := range got {
				if q.MsgID == ans.MsgID {
					t.Fatalf("an answered post must not be re-escalatable")
				}
			}
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}
