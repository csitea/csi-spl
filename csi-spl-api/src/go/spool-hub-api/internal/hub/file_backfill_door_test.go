package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-5521, the prd case: a picture posted into a new channel a second
// before its agents were invited reached the seated box only by the
// back-fill (SPL-987), which writes no delivery row. The box held the post
// and its files[], and its fetch of the file answered not_found. A box that
// seats an agent of the carrier's channel now reads the file; a box that
// seats none, a carrier in a private topic and a DM carrier stay 404 (the
// CONTROLS, so "every box reads everything" fails too).
func TestFileDoorSeatedChannelBoxReadsBackfilledFile(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	seat, out := e.box(tid, "box-seat", "CLE-09"), e.box(tid, "box-out", "CLE-11")
	for _, x := range []*box{seat, out} {
		e.pin(tid, x)
	}
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "ledger",
		Name: "ledger", CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	chFile, privFile, dmFile := sha256Hex([]byte("the bytes")), strings.Repeat("e2", 32), strings.Repeat("e3", 32)
	privTask := uuidV4()
	putFileRow(t, e, tid, uuidV4(), "ledger", "HUM-1", "box-wui", chFile, now)
	putFileRow(t, e, tid, privTask, "ledger", "HUM-1", "box-wui", privFile, now)
	putFileRow(t, e, tid, uuidV4(), "", "HUM-1", "CLE-09", dmFile, now)
	if err := e.st.(store.DedicatedStore).SetPrivateScope(ctx, tid, store.ScopeTopic, privTask, true, now); err != nil {
		t.Fatal(err)
	}
	// Seated AFTER the posts, as the invite at 12:17:30Z was.
	if err := e.st.InviteChannelAgent(ctx, tid, "ledger", "box-seat", "CLE-09", now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{chFile, privFile, dmFile} {
		ageBlob(t, e, tid, id, now.Add(-2*hub.FileUploadGrace))
	}
	for _, tc := range []struct {
		what, file string
		b          *box
		want       int
	}{
		{"the seated box reads the channel post's file", chFile, seat, http.StatusOK},
		{"a box seating no member of the channel", chFile, out, http.StatusNotFound},
		{"a carrier in a private topic", privFile, seat, http.StatusNotFound},
		{"a DM carrier the box is no end of", dmFile, seat, http.StatusNotFound},
	} {
		if got, _ := e.getFile(tid, tc.file, e.uploadToken(tid, tc.b)); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.what, got, tc.want)
		}
	}
	// The same door through the box client (spool hub-get-file, the call
	// that answered not_found on prd).
	for _, tc := range []struct {
		b  *box
		ok bool
	}{{seat, true}, {out, false}} {
		sess, err := tc.b.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		err = sess.FetchFile(ctx, chFile)
		sess.Close()
		var he *hubclient.HubError
		if tc.ok && err != nil {
			t.Errorf("%s FetchFile: %v", tc.b.id, err)
		}
		if !tc.ok && (!errors.As(err, &he) || he.Token != "not_found") {
			t.Errorf("%s FetchFile: %v, want not_found", tc.b.id, err)
		}
	}
}

// The other refused classes of the channel half, each on its own box so no
// seat leaks into another case: an agent dedicated to another channel, a
// hidden channel (#issues: it takes no agents, so the box is seated in
// #ledger and the carrier is an issue discussion), a seat that was removed again, and a box of
// another workspace seated in a same-named channel there. The CONTROL is an
// agent dedicated to the carrier's own channel, which reads it.
func TestFileDoorSeatedChannelBoxRefusals(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for _, c := range []struct{ tenant, ch string }{{tid, "ledger"}, {tid, "elsewhere"}, {other, "ledger"}} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: c.tenant, ChannelID: c.ch,
			Name: c.ch, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
			t.Fatalf("channel %s: %v", c.ch, err)
		}
	}
	chFile, hidFile := strings.Repeat("f1", 32), strings.Repeat("f2", 32)
	putFileRow(t, e, tid, uuidV4(), "ledger", "HUM-1", "box-wui", chFile, now)
	putFileRow(t, e, tid, uuidV4(), store.ChannelIssues, "HUM-1", "box-wui", hidFile, now)
	ds := e.st.(store.DedicatedStore)
	seat := func(tenant, boxID, agent, ch string) *box {
		t.Helper()
		b := e.box(tenant, boxID, agent)
		e.pin(tenant, b)
		if err := e.st.InviteChannelAgent(ctx, tenant, ch, boxID, agent, now); err != nil {
			t.Fatalf("invite %s: %v", agent, err)
		}
		return b
	}
	bind := func(boxID, agent, ch string) {
		t.Helper()
		if _, err := ds.SetDedicatedBinding(ctx, store.DedicatedBinding{TenantID: tid, AgentID: agent, BoxID: boxID,
			ScopeType: store.ScopeChannel, ScopeID: ch, BoundBy: "HUM-1", BoundAt: now}); err != nil {
			t.Fatalf("bind %s: %v", agent, err)
		}
	}
	own, away := seat(tid, "box-own", "CLE-21", "ledger"), seat(tid, "box-away", "CLE-23", "ledger")
	bind("box-own", "CLE-21", "ledger")
	bind("box-away", "CLE-23", "elsewhere")
	hidden := seat(tid, "box-hidden", "CLE-25", "ledger")
	left := seat(tid, "box-left", "CLE-27", "ledger")
	if err := e.st.RemoveChannelAgent(ctx, tid, "ledger", "box-left", "CLE-27", now); err != nil {
		t.Fatal(err)
	}
	foreign := seat(other, "box-own", "CLE-21", "ledger")
	for _, id := range []string{chFile, hidFile} {
		ageBlob(t, e, tid, id, now.Add(-2*hub.FileUploadGrace))
	}
	for _, tc := range []struct {
		what, tenant, file string
		b                  *box
		want               int
	}{
		{"an agent dedicated to the carrier's channel (CONTROL)", tid, chFile, own, http.StatusOK},
		{"an agent dedicated to another channel", tid, chFile, away, http.StatusNotFound},
		{"a carrier in a hidden channel", tid, hidFile, hidden, http.StatusNotFound},
		{"a seat removed again", tid, chFile, left, http.StatusNotFound},
		{"a box of another workspace", other, chFile, foreign, http.StatusNotFound},
	} {
		if got, _ := e.getFile(tc.tenant, tc.file, e.uploadToken(tc.tenant, tc.b)); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.what, got, tc.want)
		}
	}
}
