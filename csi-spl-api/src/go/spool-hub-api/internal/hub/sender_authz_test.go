package hub_test

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// the box key signs the envelope, not the agent, so onSend must
// bind msg.from to the SENDING box's announced roster. Before it, box-a could
// post as box-b's CLE-07 (or as a human) and the recipient read - and
// answered - the wrong author; only typed_by sends were checked (4336d9f).
func TestSendFromMustBeAnnouncedBySendingBox(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()

	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(cli)
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	sendAs := func(from string) (string, error) {
		m, err := spool.New(a.cfg).Compose(from, "CLE-07", "", "task", "as "+from, nil)
		if err != nil {
			t.Fatal(err)
		}
		env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
		_, err = cli.Send(ctx, env)
		return m.MsgID, err
	}
	refused := func(what, from string) {
		t.Helper()
		id, err := sendAs(from)
		var he *hubclient.HubError
		if !errors.As(err, &he) || he.Token != wire.TokenFromNotAnnounced || he.Status != http.StatusForbidden {
			t.Fatalf("%s: want 403 %s, got %v", what, wire.TokenFromNotAnnounced, err)
		}
		if has, _ := e.st.HasMessage(ctx, tid, id); has {
			t.Fatalf("%s: the refused send was stored", what)
		}
	}

	refused("box-b's agent sent by box-a", "CLE-07")
	refused("an agent no box announced", "AGY-09")
	// A human or guest id is never a box sender, even when the box announces it.
	if err := e.st.SetRoster(ctx, tid, "box-a", []string{"GRK-03", "GST-1", "HUM-1"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	cli2, err := a.c.Dial(ctx, wire.RoleCLI) // a fresh hello reads the new roster
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(cli2)
	cli = cli2
	refused("a human id", "HUM-1")
	refused("a guest id", "GST-1")

	// Control: the box's own agent is accepted on the same session.
	if id, err := sendAs("GRK-03"); err != nil {
		t.Fatalf("own agent: %v", err)
	} else if has, _ := e.st.HasMessage(ctx, tid, id); !has {
		t.Fatal("own agent's send was not stored")
	}
}

// A new agent's first line can beat its box's 10 s announce scan. The box
// client heals that without losing the line: a role=box session announces
// and resends once; a role=cli send stays pending for the box session's
// flush. An agent the box does not host is still refused.
func TestNewAgentFirstSendIsAnnouncedNotLost(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()

	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sb)
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")

	// role=box: a dir made after the hello, then its first send.
	os.MkdirAll(filepath.Join(a.cfg.SpoolRoot, "AGY-05", "inbox"), 0o775) //nolint:errcheck
	m, _ := spool.New(a.cfg).Compose("AGY-05", "CLE-07", "", "task", "first line", nil)
	env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
	if f, err := sa.SendTyped(ctx, env, ""); err != nil || f.Delivery != wire.DeliverySent {
		t.Fatalf("new agent over role=box: %+v %v", f, err)
	}
	if r, _ := e.st.Roster(ctx, tid); !slices.Contains(r["box-a"], "AGY-05") {
		t.Fatalf("AGY-05 not announced: %v", r["box-a"])
	}

	// role=cli (no sidecar): kept pending, then flushed by the box session.
	os.MkdirAll(filepath.Join(a.cfg.SpoolRoot, "GRK-44", "inbox"), 0o775) //nolint:errcheck
	out, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-44", To: "CLE-07", Kind: "task", Body: "queued", Hub: a.c})
	if err != nil || out.Delivery != wire.DeliveryPending {
		t.Fatalf("new agent over role=cli: want pending, got %+v %v", out, err)
	}
	if left, _ := a.c.Pending(); len(left) != 1 {
		t.Fatalf("pending after cli refusal: %d, want 1 (the line was dropped)", len(left))
	}
	if n, err := sa.Flush(ctx); err != nil || n != 1 {
		t.Fatalf("box flush: %d %v", n, err)
	}
	if has, _ := e.st.HasMessage(ctx, tid, out.MsgID); !has {
		t.Fatal("flushed line not stored")
	}

	// Not hosted here: the retry does not launder it.
	m2, _ := spool.New(a.cfg).Compose("CLE-07", "CLE-07", "", "task", "not mine", nil)
	env2, _ := wire.NewEnvelope(priv, "box-a", "box-b", m2)
	var he *hubclient.HubError
	if _, err := sa.SendTyped(ctx, env2, ""); !errors.As(err, &he) || he.Token != wire.TokenFromNotAnnounced {
		t.Fatalf("unhosted agent over role=box: want %s, got %v", wire.TokenFromNotAnnounced, err)
	}
}
