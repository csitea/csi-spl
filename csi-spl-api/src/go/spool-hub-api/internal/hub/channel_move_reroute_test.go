// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 169 T7b, the real hub: a re-routed post retried lands once in <DST>. The
// box client signs the same inner msg under the desk's key, so a retry is the
// same envelope, stored once per (tenant, msg_id). CONTROLS: a new msg id on the
// same task is a second row, so the count can move; the same msg id with other
// bytes is refused, never a second row.
func TestChannelMoveRerouteRetryLandsOnce(t *testing.T) {
	e := chanMoveEnv(t)
	ctx := context.Background()
	src, _ := e.tenant()
	dst, _ := e.tenant()
	a := moveBoxes(t, e, src, dst)
	d := e.box(dst, "box-d", "GRK-03")
	e.pin(dst, d)
	task := uuid4()
	moveRedirect(t, e, src, task, dst, time.Hour, 30*24*time.Hour)

	post := chanMsg(task, "c-120", "note", "into the moved topic")
	send := func(t *testing.T, env *wire.Envelope) (wire.Frame, *hubclient.HubError) {
		t.Helper()
		d.c.Cfg.HubURL = e.url(dst)
		sess, err := d.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		defer sess.Close()
		f, err := sess.Send(ctx, env)
		var he *hubclient.HubError
		if errors.As(err, &he) {
			return f, he
		}
		if err != nil {
			t.Fatal(err)
		}
		return f, nil
	}

	// <SRC> refuses the post under its key: no row, the destination named.
	a.c.Cfg.HubURL = e.url(src)
	sess, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	_, err = sess.Send(ctx, signedIn(t, a, "box-b", "", "", post))
	sess.Close()
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Token != wire.TokenTopicMoved {
		t.Fatalf("<SRC>: %v", err)
	}
	if ten, _, ok := wire.ParseMovedDetail(he.Detail); !ok || ten != dst {
		t.Fatalf("<SRC> names %q", he.Detail)
	}

	for i := 1; i <= 3; i++ {
		if f, he := send(t, signedIn(t, d, "box-b", "", "", post)); he != nil || f.Delivery == "" {
			t.Fatalf("send %d: %+v %+v", i, he, f)
		}
		if n := taskRows(t, e, dst, task); n != 1 {
			t.Fatalf("after send %d: %d rows in <DST>, want 1", i, n)
		}
	}
	if n := taskRows(t, e, src, task); n != 0 {
		t.Errorf("%d rows in <SRC>", n)
	}

	other := *post
	other.Body = "other bytes under the same id"
	if _, he := send(t, signedIn(t, d, "box-b", "", "", &other)); he == nil || he.Token != "conflict_msg" {
		t.Errorf("the same id with other bytes: %+v", he)
	}
	if n := taskRows(t, e, dst, task); n != 1 {
		t.Errorf("after the conflict: %d rows", n)
	}

	if _, he := send(t, signedIn(t, d, "box-b", "", "", chanMsg(task, "c-120", "note", "the next post"))); he != nil {
		t.Fatalf("control: %+v", he)
	}
	if n := taskRows(t, e, dst, task); n != 2 {
		t.Errorf("control: a new msg id is a new row, got %d", n)
	}
}
