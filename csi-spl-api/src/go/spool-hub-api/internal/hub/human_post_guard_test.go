package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-2584 (hub/human_post_guard.go, how-to-post.md rule 18), through the
// real front end (action.SendCtx == `spool send`). On Postgres too when
// SPOOL_TEST_PG_DSN is set (newStore), which runs rdb 0211's
// spool_norm_body(). The controls: the same rig with the guard off stores
// every send the guard refuses (TestHumanPostGuardOffStoresAll).

func guardRig(t *testing.T, on bool) (e *env, tid string, b *box) {
	t.Helper()
	e = followEnv(t, func(o *hub.Options) { o.HumanPostGuard = on })
	tid, _ = e.tenant()
	b = e.box(tid, "box-a", "CLE-07", "CLE-08")
	e.pin(tid, b)
	if err := e.st.CreateChannel(context.Background(), store.Channel{TenantID: tid, ChannelID: "ops", Name: "ops",
		CreatedBy: "wui", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.InviteChannelAgent(context.Background(), tid, "ops", "box-a", "CLE-07", time.Now()); err != nil {
		t.Fatal(err)
	}
	return e, tid, b
}

func guardSend(b *box, task, to, kind, body string) (action.SendResult, error) {
	return guardSendAs(b, "CLE-07", task, to, kind, body)
}

func guardSendAs(b *box, from, task, to, kind, body string) (action.SendResult, error) {
	return action.SendCtx(context.Background(), b.cfg, action.SendArgs{From: from, To: to, ToBox: hub.WUIBox,
		TaskID: task, Kind: kind, Body: body, Hub: b.c})
}

func wantToken(t *testing.T, what string, err error, token string) {
	t.Helper()
	if got := hubToken(err); got != token {
		t.Fatalf("%s: want %q, got %q (%v)", what, token, got, err)
	}
}

func TestHumanPostGuardDMRule(t *testing.T) {
	_, _, e := guardRig(t, true)

	// 1. a note DM the person did not start: refused, nothing stored
	_, err := guardSend(e, uuid4(), "HUM-1", "note", "Orchestrator failover: c-001@box1 took over")
	wantToken(t, "note DM", err, hub.TokenDMNotBlocker)

	// 2. a blocker DM passes, and the agent may follow it up in that DM
	blk, err := guardSend(e, uuid4(), "HUM-1", "blocker", "I need your go for the prd apply")
	if err != nil {
		t.Fatalf("blocker DM: %v", err)
	}
	if _, err := guardSend(e, blk.TaskID, "HUM-1", "note", "the plan is in the topic now"); err != nil {
		t.Fatalf("follow-up in the blocker DM: %v", err)
	}
	// ... but not to another person in that DM
	_, err = guardSend(e, blk.TaskID, "HUM-2", "note", "fyi")
	wantToken(t, "other person in a blocker DM", err, hub.TokenDMNotBlocker)
}

func TestHumanPostGuardPersonStartedDM(t *testing.T) {
	e, tid, b := guardRig(t, true)
	c := dialMember(t, e, tid, "HUM-1", "HUM-1")
	task := uuid4()
	dmSend(c, task, "CLE-07", "how is the deploy going?")
	readType(t, c, "ack")
	if _, err := guardSend(b, task, "HUM-1", "note", "dev is green, prd rolls next"); err != nil {
		t.Fatalf("answer in a DM the person started: %v", err)
	}
}

// SPL-3420 (owner DM t1 679ee983, 2026-10-25): an agent opened a DM to the
// person (kind task), the person asked a question in it, and the starter was
// busy; every other agent was refused (dm_not_blocker) and the person waited
// 35 min. A person who has posted in a DM may be answered there by any agent.
// The control: the same DM before the person wrote in it refuses both agents.
func TestHumanPostGuardPersonRepliedInAgentDM(t *testing.T) {
	e, tid, b := guardRig(t, true)
	task := uuid4()
	putRow(t, e, tid, task, "", "CLE-07", "HUM-1", "alert: rotation failed", time.Now().Add(-time.Minute))

	_, err := guardSendAs(b, "CLE-08", task, "HUM-1", "note", "the rotation is retried")
	wantToken(t, "another agent, before the person wrote", err, hub.TokenDMNotBlocker)
	_, err = guardSend(b, task, "HUM-1", "note", "and again from the starter")
	wantToken(t, "the starter, before the person wrote", err, hub.TokenDMNotBlocker)

	c := dialMember(t, e, tid, "HUM-1", "HUM-1")
	dmSend(c, task, "CLE-07", "is this expected or a bug?")
	readType(t, c, "ack")
	if _, err := guardSendAs(b, "CLE-08", task, "HUM-1", "note", "a bug: the dead holder kept the lease"); err != nil {
		t.Fatalf("another agent answers the person's question: %v", err)
	}
	// the person's post opens only that DM to them: another person, or a new DM, stays refused
	_, err = guardSendAs(b, "CLE-08", task, "HUM-2", "note", "fyi, the lease bug")
	wantToken(t, "another person in that DM", err, hub.TokenDMNotBlocker)
	_, err = guardSendAs(b, "CLE-08", uuid4(), "HUM-1", "note", "a new unsolicited DM")
	wantToken(t, "a new DM to the same person", err, hub.TokenDMNotBlocker)
	// and duplicate_to_human still applies in it
	_, err = guardSend(b, task, "HUM-1", "note", "A bug: the dead holder  kept the lease")
	wantToken(t, "the same answer twice", err, hub.TokenDuplicateToHuman)
}

func TestHumanPostGuardChannelReplyPasses(t *testing.T) {
	_, _, b := guardRig(t, true)
	root, err := action.SendCtx(context.Background(), b.cfg, action.SendArgs{From: "CLE-07", Channel: "ops", Body: "deploy 1.4.2", Hub: b.c})
	if err != nil {
		t.Fatalf("channel post: %v", err)
	}
	if _, err := guardSend(b, root.TaskID, "HUM-1", "note", "@HUM-1 dev and prd serve 1.4.2"); err != nil {
		t.Fatalf("a note to a person in a channel topic: %v", err)
	}
}

func TestHumanPostGuardDuplicate(t *testing.T) {
	_, _, b := guardRig(t, true)
	root, err := action.SendCtx(context.Background(), b.cfg, action.SendArgs{From: "CLE-07", Channel: "ops", Body: "deploy 1.4.3", Hub: b.c})
	if err != nil {
		t.Fatalf("channel post: %v", err)
	}
	if _, err := guardSend(b, root.TaskID, "HUM-1", "note", "Dev and prd serve 1.4.3."); err != nil {
		t.Fatalf("first: %v", err)
	}
	// the same text, other case and whitespace, in a blocker DM: refused
	_, err = guardSend(b, uuid4(), "HUM-1", "blocker", "  dev and PRD\n serve   1.4.3.  ")
	wantToken(t, "same body as a DM", err, hub.TokenDuplicateToHuman)
	// and again in the channel topic: refused
	_, err = guardSend(b, root.TaskID, "HUM-1", "note", "dev and prd serve 1.4.3.")
	wantToken(t, "same body in the topic", err, hub.TokenDuplicateToHuman)
	// another person may get it
	if _, err := guardSend(b, root.TaskID, "HUM-2", "note", "Dev and prd serve 1.4.3."); err != nil {
		t.Fatalf("another person: %v", err)
	}
}

// TestHumanPostGuardOffStoresAll is the red control: with the guard off (the
// hub before SPL-2584) the refused sends above are all stored.
func TestHumanPostGuardOffStoresAll(t *testing.T) {
	_, _, b := guardRig(t, false)
	if _, err := guardSend(b, uuid4(), "HUM-1", "note", "Orchestrator failover"); err != nil {
		t.Fatalf("guard off, note DM: %v", err)
	}
	if _, err := guardSend(b, uuid4(), "HUM-1", "blocker", "orchestrator failover"); err != nil {
		t.Fatalf("guard off, the same text again: %v", err)
	}
}
