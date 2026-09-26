package hub_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// specs/038: an agent broadcasts into a channel the way a human does. The
// post goes through the real front end (action.SendCtx == `spool send
// --channel`), is stored as a new level-1 topic of the channel, and reaches
// every OTHER member agent - on another box AND on the sender's own box -
// while the sender never reads its own post back.
func TestAgentChannelPost(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07", "CLE-08", "CLE-09")
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "releases", Name: "releases", CreatedBy: "wui", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	e.pin(tid, a)
	e.pin(tid, b)
	for _, m := range [][2]string{{"box-a", "GRK-03"}, {"box-b", "CLE-07"}, {"box-b", "CLE-08"}} {
		if err := e.st.InviteChannelAgent(ctx, tid, "releases", m[0], m[1], time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sa.Close()
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()

	// '#' and upper case are what an agent copies out of the WUI.
	out, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "CLE-07", Channel: "#Releases", Body: "v0.6 is cut", Hub: b.c})
	if err != nil || out.Delivery != wire.DeliverySent {
		t.Fatalf("channel post: %v %+v", err, out)
	}
	for _, r := range []struct {
		b  *box
		id string
	}{{a, "GRK-03"}, {b, "CLE-08"}} {
		eventually(t, r.id+" inbox", func() bool { return len(inbox(t, r.b, r.id)) == 1 })
		got := inbox(t, r.b, r.id)[0]
		if got.MsgID != out.MsgID || got.From != "CLE-07" || got.To != action.Broadcast || got.Kind != "note" {
			t.Fatalf("%s copy: %+v", r.id, got)
		}
	}
	// The sender does not read its own post; CLE-09 sits on the same box but
	// is no member. Both were settled by the time CLE-08's copy was written:
	// one recv frame carries the whole agents list of box-b.
	for _, id := range []string{"CLE-07", "CLE-09"} {
		if n := len(inbox(t, b, id)); n != 0 {
			t.Fatalf("%s inbox holds %d (sender / non-member must read nothing)", id, n)
		}
	}
	if errs := append(sa.RecvErrors(), sb.RecvErrors()...); len(errs) != 0 {
		t.Fatalf("recv errors: %v", errs)
	}
	// A new topic of the channel, level 1, addressed like a human's post.
	rows, _ := e.st.ViewTopics(ctx, tid, store.TopicQuery{Now: time.Now(), Channel: "releases"})
	if len(rows) != 1 || rows[0].TaskID != out.TaskID {
		t.Fatalf("channel feed: %+v", rows)
	}
	msgs, _ := e.st.ViewTopic(ctx, tid, store.TopicMsgQuery{TaskID: out.TaskID, Now: time.Now()})
	if len(msgs) != 1 || msgs[0].IsParent != 1 {
		t.Fatalf("stored post: %+v", msgs)
	}
	stored, err := wire.ParseEnvelope(msgs[0].Env)
	if err != nil || stored.ToBox != hub.WUIBox || stored.FromBox != "box-b" || stored.Channel != "releases" {
		t.Fatalf("stored envelope: %v %s", err, msgs[0].Env)
	}

	// FR-004: a non-member (CLE-09, and GRK-03 in #tasks) gets the read
	// door's 404 - the channel "does not exist" for it - and nothing is stored.
	for _, c := range []struct {
		b        *box
		from, ch string
	}{{b, "CLE-09", "releases"}, {a, "GRK-03", "tasks"}} {
		_, err := action.SendCtx(ctx, c.b.cfg, action.SendArgs{From: c.from, Channel: c.ch, Body: "let me in", Hub: c.b.c})
		if err == nil || !strings.Contains(err.Error(), "unknown_channel") {
			t.Fatalf("%s into #%s: %v (want unknown_channel)", c.from, c.ch, err)
		}
		if n, _ := e.st.CountMessagesSince(ctx, tid, time.Time{}); n != 1 {
			t.Fatalf("%s into #%s stored something: %d messages", c.from, c.ch, n)
		}
	}
}

// The front end refuses what a channel post cannot mean, before any I/O.
func TestAgentChannelPostArgs(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	b := e.box(tid, "box-b", "CLE-07")
	for _, c := range []struct {
		args action.SendArgs
		want string
	}{
		{action.SendArgs{From: "CLE-07", To: "CLE-08", Channel: "releases", Body: "x"}, "--to must be empty or ALL-0"},
		{action.SendArgs{From: "CLE-07", ToBox: "box-a", Channel: "releases", Body: "x"}, "drop --to-box"},
		{action.SendArgs{From: "CLE-07", Channel: "Bad Name", Body: "x"}, "--channel must match"},
	} {
		c.args.Hub = b.c
		if _, err := action.SendCtx(context.Background(), b.cfg, c.args); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Fatalf("%+v: %v (want %q)", c.args, err, c.want)
		}
	}
	local := *b.cfg
	local.HubURL = ""
	if _, err := action.SendCtx(context.Background(), &local, action.SendArgs{From: "CLE-07", Channel: "releases", Body: "x"}); err == nil || !strings.Contains(err.Error(), "hub mode") {
		t.Fatalf("local channel post: %v", err)
	}
}

// SPL-961: #lobby (and its #general alias) takes a new topic from any agent
// announced on the signing box, without a lobby seat, so the desk bots can
// welcome a new person. Nobody was picked as a lobby member, so no agent
// inbox is poked, and every other default channel keeps the FR-004 member
// rule. (The announced-sender rule runs first, senderRefusal, for any channel.)
func TestAgentLobbyPostNeedsNoSeat(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	b := e.box(tid, "box-b", "CLE-07", "CLE-08")
	e.pin(tid, b)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()

	for i, ch := range []string{"lobby", "#General"} {
		out, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "CLE-07", Channel: ch, Body: "Welcome aboard!", Hub: b.c})
		if err != nil || out.Delivery != wire.DeliverySent {
			t.Fatalf("#%s post: %v %+v", ch, err, out)
		}
		rows, _ := e.st.ViewTopics(ctx, tid, store.TopicQuery{Now: time.Now(), Channel: store.ChannelLobby})
		if len(rows) != i+1 {
			t.Fatalf("#%s: lobby feed holds %d topics, want %d", ch, len(rows), i+1)
		}
	}
	if n := len(inbox(t, b, "CLE-08")); n != 0 {
		t.Fatalf("CLE-08 is no lobby member and read %d post(s)", n)
	}
	if _, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "CLE-07", Channel: "alerts", Body: "hi", Hub: b.c}); err == nil ||
		!strings.Contains(err.Error(), "unknown_channel") {
		t.Fatalf("CLE-07 into #alerts: %v (want unknown_channel)", err)
	}
}
