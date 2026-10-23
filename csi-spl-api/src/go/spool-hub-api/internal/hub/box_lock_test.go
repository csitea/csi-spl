package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// queueRig is one tenant with a locked box (box-own: CLE-01), an open box
// (box-sh: CLE-02) and a peer box of the lock (box-peer: CLE-03), all in
// channel #ops, an owner (a developer: the lock reads no role) and another
// admin who are both members of #ops (spec 025 box-owner-lock.md, row B3).
type queueRig struct {
	e              *env
	tid            string
	wuiPub         ed25519.PublicKey
	own, sh, peer  *box
	kbox, klock    ed25519.PrivateKey
	owner, admin   string
	ownerW, adminW *websocket.Conn
}

func queueEnv(t *testing.T) (*env, ed25519.PublicKey) {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e := rbacEnv(t, func(o *hub.Options) {
		o.WUIKey = key
		o.Fallback = true
		o.BackfillMax = 50
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	return e, pub
}

// newQueueRig builds the rig on e; pinWUI false leaves box-wui unpinned, so
// browser posts are stored unsigned (the replay case, path 10).
func newQueueRig(t *testing.T, e *env, wuiPub ed25519.PublicKey, pinWUI bool) *queueRig {
	t.Helper()
	ctx, now := context.Background(), time.Now()
	tid, _ := e.tenant()
	r := &queueRig{e: e, tid: tid, wuiPub: wuiPub,
		own: e.box(tid, "box-own", "CLE-01"), sh: e.box(tid, "box-sh", "CLE-02"), peer: e.box(tid, "box-peer", "CLE-03")}
	for _, b := range []*box{r.own, r.sh, r.peer} {
		e.pin(tid, b)
	}
	if pinWUI {
		e.pinKey(tid, hub.WUIBox, wuiPub)
	}
	var err error
	if r.kbox, err = sign.LoadPrivate(r.own.cfg.KeysDir, r.own.id); err != nil {
		t.Fatal(err)
	}
	_, r.klock, _ = ed25519.GenerateKey(nil)
	r.owner, r.admin = seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Admin)
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "ops", Name: "ops",
		CreatedBy: "hub", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	for _, s := range [][2]string{{"box-own", "CLE-01"}, {"box-sh", "CLE-02"}, {"box-peer", "CLE-03"}} {
		if err := e.st.InviteChannelAgent(ctx, tid, "ops", s[0], s[1], now); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.st.AddChannelHumans(ctx, tid, "ops", []string{r.owner, r.admin}, "hub", now); err != nil {
		t.Fatal(err)
	}
	l := store.BoxLock{TenantID: tid, BoxID: "box-own", LockPubKey: lb64(r.klock.Public().(ed25519.PublicKey)),
		BoxPubKey: lb64(r.kbox.Public().(ed25519.PublicKey)), Owners: []string{r.owner},
		PeerBoxes: []string{"box-peer"}, HidePosts: true, Version: 1}
	l.SignedBody = store.BoxLockBody(l)
	l.Signature = lb64(ed25519.Sign(r.klock, []byte(l.SignedBody)))
	if err := e.st.(store.BoxLockStore).CreateBoxLock(ctx, l, r.owner, now); err != nil {
		t.Fatal(err)
	}
	r.ownerW = dialMember(t, e, tid, "Owner", r.owner)
	r.adminW = dialMember(t, e, tid, "Admin", r.admin)
	return r
}

// queued reports whether box has a deliveries row for msg id.
func (r *queueRig) queued(box, id string) bool {
	st, err := r.e.st.DeliveryState(context.Background(), r.tid, id, box)
	return err == nil && st != ""
}

// refused counts the box-own audit rows of path with verdict refused.
func (r *queueRig) refused(t *testing.T, path string) int {
	t.Helper()
	rows, err := r.e.st.(store.BoxLockStore).BoxLockAudits(context.Background(), r.tid, "box-own", 100)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, a := range rows {
		if a.Path == path && a.Verdict == store.BoxLockRefused {
			n += a.Count
		}
	}
	return n
}

// online opens a role=box socket for b announcing agents with features; a
// locked box shows the unlock proof (row B2). Every frame after the welcome
// goes to the returned channel.
func (r *queueRig) online(t *testing.T, b *box, agents []string, features ...string) <-chan wire.Frame {
	t.Helper()
	conn, nonce := r.e.raw(r.tid)
	t.Cleanup(func() { conn.CloseNow() }) //nolint:errcheck
	f := helloFrame(b, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	f.Agents, f.Features = agents, features
	if b == r.own {
		f.BootID = "boot-1"
		p := lockkey.ProofPayload(r.tid, b.id, nonce, f.BootID, lb64(r.kbox.Public().(ed25519.PublicKey)), f.TS)
		f.UnlockProof = lb64(ed25519.Sign(r.klock, p))
	}
	wsjson.Write(context.Background(), conn, f) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(context.Background(), conn, &wel); err != nil || wel.Type != wire.TWelcome {
		t.Fatalf("%s hello: %v %+v", b.id, err, wel)
	}
	out := make(chan wire.Frame, 256)
	go func() {
		defer close(out)
		for {
			var fr wire.Frame
			if err := wsjson.Read(context.Background(), conn, &fr); err != nil {
				return
			}
			select {
			case out <- fr:
			default:
			}
		}
	}()
	return out
}

// mid is a fresh message id.
func mid() string { return uuidV4() }

// Row B3 (section 5.1 paths 1, 1b, 1c, 2, 2b, 3, 10, 12b): each path is a
// pair, the owner's message reaches box-own and the other admin's does not,
// with one refused audit row where the path refuses a request. Path 12 (a
// box's own send straight to box-own) is NOT covered: its call sits in
// onSend (ws.go), batch 3; TestBoxSendLockRefusal tests its helper.
// RED CONTROL of the row: remove the boxLockRefusal call in dispatchCheck
// and paths 2 and 2b go red.
func TestBoxLockQueuePaths(t *testing.T) {
	e, pub := queueEnv(t)
	r := newQueueRig(t, e, pub, true)
	ctx := context.Background()
	top := t // sockets opened in a subtest live for the whole test

	t.Run("2_dm_and_command", func(t *testing.T) {
		id := mid()
		if ack := sendFrame(t, r.ownerW, id, "task", "@CLE-01 run the suite", ""); ack["type"] != "ack" || ack["to_box"] != "box-own" {
			t.Fatalf("owner's command: %v", ack)
		}
		if !r.queued("box-own", id) {
			t.Fatal("owner's command not queued to box-own")
		}
		before := r.refused(t, "dispatch")
		for _, f := range []struct{ body, to string }{{"@CLE-01 run the suite", ""}, {"run the suite", "CLE-01"}} {
			id := mid()
			if ack := sendFrame(t, r.adminW, id, "task", f.body, f.to); ack["type"] != "error" || ack["error"] != "box_locked" {
				t.Fatalf("admin's %q to %q: %v, want box_locked", f.body, f.to, ack)
			}
			if r.queued("box-own", id) {
				t.Fatalf("admin's %q queued to box-own", f.body)
			}
		}
		if got := r.refused(t, "dispatch") - before; got != 2 {
			t.Fatalf("dispatch refused audit +%d, want +2", got)
		}
		// CONTROL: the admin commands an agent on the open box as before.
		if ack := sendFrame(t, r.adminW, mid(), "task", "@CLE-02 run the suite", ""); ack["type"] != "ack" || ack["to_box"] != "box-sh" {
			t.Fatalf("admin's command to box-sh: %v", ack)
		}
	})

	t.Run("2_act_as_clone", func(t *testing.T) {
		cs, ok := e.st.(interface {
			StartClone(context.Context, store.CloneStart, time.Time) (store.Clone, error)
		})
		if !ok {
			t.Skip("this store has no act-as clones (Postgres only: SPOOL_TEST_PG_DSN)")
		}
		cl, err := cs.StartClone(ctx, store.CloneStart{TenantID: r.tid, TargetHum: r.owner, AdminName: "Admin",
			CreatedBy: r.admin, ExpiresAt: time.Now().Add(time.Hour)}, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		w := dialMember(t, e, r.tid, "Clone", cl.CloneHum)
		id := mid()
		if ack := sendFrame(t, w, id, "task", "@CLE-01 run the suite", ""); ack["type"] != "error" || ack["error"] != "box_locked" {
			t.Fatalf("clone of the owner: %v, want box_locked", ack)
		}
		if r.queued("box-own", id) {
			t.Fatal("the clone's command was queued to box-own")
		}
	})

	t.Run("2b_topic_reply", func(t *testing.T) {
		note, err := action.SendCtx(ctx, r.own.cfg, action.SendArgs{From: "CLE-01", To: "ALL-0", Kind: "note",
			Body: "the outage is over", ToBox: hub.WUIBox, Hub: r.own.c})
		if err != nil {
			t.Fatalf("agent note: %v", err)
		}
		id := mid()
		if ack := topicReplyFrame(t, r.ownerW, id, note.TaskID, "thanks"); ack["type"] != "ack" || ack["to_box"] != "box-own" {
			t.Fatalf("owner's reply: %v", ack)
		}
		before := r.refused(t, "dispatch")
		id = mid()
		// topicReplyAgent never refuses a reply: a failed dispatchCheck keeps
		// the browser-only post, so the admin's reply is acked with no to_box.
		if ack := topicReplyFrame(t, r.adminW, id, note.TaskID, "thanks"); ack["type"] != "ack" || ack["to_box"] != nil {
			t.Fatalf("admin's reply: %v, want a browser-only ack", ack)
		}
		if r.queued("box-own", id) || r.refused(t, "dispatch")-before != 1 {
			t.Fatalf("admin's reply: queued %v, audit +%d", r.queued("box-own", id), r.refused(t, "dispatch")-before)
		}
	})

	t.Run("1_and_3_channel_post_and_mention", func(t *testing.T) {
		task := uuidV4()
		before := r.refused(t, "channel_fanout")
		for _, body := range []string{"status of the release?", "@CLE-01"} {
			own, adm := mid(), mid()
			if ack := channelFrame(t, r.ownerW, own, task, "ops", body); ack["type"] != "ack" {
				t.Fatalf("owner's post %q: %v", body, ack)
			}
			if ack := channelFrame(t, r.adminW, adm, task, "ops", body); ack["type"] != "ack" {
				t.Fatalf("admin's post %q: %v (the post itself lands)", body, ack)
			}
			if !r.queued("box-own", own) || !r.queued("box-sh", own) {
				t.Fatalf("owner's post %q: box-own %v box-sh %v", body, r.queued("box-own", own), r.queued("box-sh", own))
			}
			if r.queued("box-own", adm) || !r.queued("box-sh", adm) {
				t.Fatalf("admin's post %q: box-own %v (want false) box-sh %v", body, r.queued("box-own", adm), r.queued("box-sh", adm))
			}
		}
		if got := r.refused(t, "channel_fanout") - before; got != 2 {
			t.Fatalf("channel_fanout refused audit +%d, want +2", got)
		}
	})

	t.Run("12b_box_post_in_channel", func(t *testing.T) {
		post := func(b *box, from string) string {
			t.Helper()
			cli, err := b.c.Dial(ctx, wire.RoleCLI)
			if err != nil {
				t.Fatal(err)
			}
			defer closeWait(cli)
			m := chanMsg(uuidV4(), "ALL-0", "note", "relay: deploy now")
			m.From = from
			if _, err := cli.Send(ctx, signedIn(t, b, hub.WUIBox, "ops", "", m)); err != nil {
				t.Fatalf("%s post: %v", from, err)
			}
			return m.MsgID
		}
		before := r.refused(t, "box_channel")
		if id := post(r.peer, "CLE-03"); !r.queued("box-own", id) {
			t.Fatal("the peer box's post did not reach box-own")
		}
		id := post(r.sh, "CLE-02")
		if r.queued("box-own", id) || !r.queued("box-peer", id) {
			t.Fatalf("box-sh post: box-own %v (want false) box-peer %v", r.queued("box-own", id), r.queued("box-peer", id))
		}
		if got := r.refused(t, "box_channel") - before; got != 1 {
			t.Fatalf("box_channel refused audit +%d, want +1", got)
		}
	})

	t.Run("1c_channel_agent_add_and_backfill", func(t *testing.T) {
		now := time.Now()
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: r.tid, ChannelID: "ops2", Name: "ops2",
			CreatedBy: "hub", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, r.tid, "ops2", []string{r.owner, r.admin}, "hub", now); err != nil {
			t.Fatal(err)
		}
		task := uuidV4()
		ownPost, admPost := mid(), mid()
		channelFrame(t, r.ownerW, ownPost, task, "ops2", "earlier, from the owner")
		channelFrame(t, r.adminW, admPost, task, "ops2", "earlier, from the admin")
		frames := r.online(top, r.own, []string{"CLE-01"}, hub.FeatureBackfill, hub.FeatureFallback)

		add := map[string]any{"id": "CLE-01", "box": "box-own"}
		code, out := call(t, e, r.tid, http.MethodPost, "/v1/channels/ops2/agents", r.admin, add)
		if code != http.StatusForbidden || out["error"] != "box_locked" {
			t.Fatalf("admin seats CLE-01@box-own: %d %v, want 403 box_locked", code, out)
		}
		if r.refused(t, "channel_agent_add") != 1 {
			t.Fatalf("channel_agent_add audit %d, want 1", r.refused(t, "channel_agent_add"))
		}
		if code, out := call(t, e, r.tid, http.MethodPost, "/v1/channels/ops2/agents", r.owner, add); code != http.StatusCreated {
			t.Fatalf("owner seats CLE-01@box-own: %d %v", code, out)
		}
		var got []string
		deadline := time.After(5 * time.Second)
		for done := false; !done; {
			select {
			case f, ok := <-frames:
				if !ok {
					t.Fatal("box-own socket closed before backfill_end")
				}
				if f.Type == wire.TRecv && f.Backfill == "ops2" {
					envl, _ := wire.ParseEnvelope(f.Env)
					m, _ := envl.Inner()
					got = append(got, m.MsgID)
				}
				done = f.Type == wire.TBackfillEnd && f.Backfill == "ops2" // the hello back-fills #ops first
			case <-deadline:
				t.Fatalf("no backfill_end; back-filled %v", got)
			}
		}
		if len(got) != 1 || got[0] != ownPost {
			t.Fatalf("back-filled %v, want only the owner's %s (not the admin's %s)", got, ownPost, admPost)
		}
	})

	t.Run("1b_fallback", func(t *testing.T) {
		// box-own is online since 1c and so the longest online: the first
		// fallback candidate. box-sh joins after it.
		r.online(top, r.sh, []string{"CLE-02"}, hub.FeatureFallback)
		now := time.Now()
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: r.tid, ChannelID: "help", Name: "help",
			CreatedBy: "hub", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, r.tid, "help", []string{r.owner, r.admin}, "hub", now); err != nil {
			t.Fatal(err)
		}
		adm := mid()
		channelFrame(t, r.adminW, adm, uuidV4(), "help", "anyone?")
		eventually(t, "admin's post falls back to box-sh", func() bool { return r.queued("box-sh", adm) })
		if r.queued("box-own", adm) {
			t.Fatal("admin's post fell back to box-own")
		}
		own := mid()
		channelFrame(t, r.ownerW, own, uuidV4(), "help", "anyone?")
		eventually(t, "owner's post falls back", func() bool { return r.queued("box-own", own) || r.queued("box-sh", own) })
		if !r.queued("box-own", own) {
			t.Fatal("owner's post did not fall back to box-own, the longest-online box")
		}
	})
}

// Path 10: the operator replay of unsigned posts routes through the same
// channel loop, so a non-owner's replayed post never reaches box-own.
func TestBoxLockReplayUnsigned(t *testing.T) {
	e, pub := queueEnv(t)
	r := newQueueRig(t, e, pub, false)
	task := uuidV4()
	own, adm := mid(), mid()
	channelFrame(t, r.ownerW, own, task, "ops", "posted before the pin, owner")
	channelFrame(t, r.adminW, adm, task, "ops", "posted before the pin, admin")
	if r.queued("box-own", own) || r.queued("box-own", adm) {
		t.Fatal("an unsigned post was queued")
	}
	e.pinKey(r.tid, hub.WUIBox, pub)
	body := map[string]any{"tenant": r.tid, "since": time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)}
	if code, out := opCall(t, e, r.tid, http.MethodPost, "/v1/operator/replay-unsigned", "good", body); code != http.StatusOK || out["resigned"] != float64(2) {
		t.Fatalf("replay: %d %v", code, out)
	}
	if !r.queued("box-own", own) || !r.queued("box-sh", own) {
		t.Fatal("the owner's replayed post did not reach both boxes")
	}
	if r.queued("box-own", adm) || !r.queued("box-sh", adm) {
		t.Fatalf("the admin's replayed post: box-own %v (want false) box-sh %v", r.queued("box-own", adm), r.queued("box-sh", adm))
	}
	if n := r.refused(t, "channel_fanout"); n != 1 {
		t.Fatalf("channel_fanout audit %d, want 1", n)
	}
}
