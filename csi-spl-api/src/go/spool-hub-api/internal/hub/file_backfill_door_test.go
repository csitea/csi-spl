package hub_test

import (
	"context"
	"crypto/ed25519"
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

// The channel half admits only what the back-fill would have handed the box
// (R7 of SPL-5521): a box outside the channel's box pins (spec 164 5.3), a
// channel whose AI agents are off (SPL-1684) or that is humans-only
// (SPL-2423), and a locked box asked for a non-owner's post (spec 025 B3)
// stay 404 although the box seats a member. The CONTROLS are the pinned box
// and the locked box reading its owner's post.
func TestFileDoorSeatedChannelBoxChannelRules(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for _, ch := range []string{"ledger", "quiet", "hush", "open"} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch,
			Name: ch, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
			t.Fatalf("channel %s: %v", ch, err)
		}
	}
	seat := func(boxID, agent, ch string) *box {
		t.Helper()
		b := e.box(tid, boxID, agent)
		e.pin(tid, b)
		if err := e.st.InviteChannelAgent(ctx, tid, ch, boxID, agent, now); err != nil {
			t.Fatalf("invite %s: %v", agent, err)
		}
		return b
	}
	pinned, unpinned := seat("box-pin", "CLE-31", "ledger"), seat("box-unpin", "CLE-33", "ledger")
	quiet, hush := seat("box-quiet", "CLE-35", "quiet"), seat("box-hush", "CLE-37", "hush")
	locked := seat("box-locked", "CLE-39", "open")
	tokens := map[*box]string{}
	for _, b := range []*box{pinned, unpinned, quiet, hush, locked} { // before the lock: a locked box dials with an unlock proof
		tokens[b] = e.uploadToken(tid, b)
	}
	if err := e.st.(store.ChannelBoxPins).SetChannelBoxPins(ctx, tid, "ledger", []string{"box-pin"}, "HUM-1"); err != nil {
		t.Fatal(err)
	}
	off := false
	if err := e.st.(store.ChannelAIAgents).SetChannelAIAgents(ctx, tid, "quiet", &off, now); err != nil {
		t.Fatal(err)
	}
	if err := e.st.(store.ChannelHumansOnly).SetChannelHumansOnly(ctx, tid, "hush", true, now); err != nil {
		t.Fatal(err)
	}
	_, klock, _ := ed25519.GenerateKey(nil)
	_, kbox, _ := ed25519.GenerateKey(nil)
	l := store.BoxLock{TenantID: tid, BoxID: "box-locked", LockPubKey: lb64(klock.Public().(ed25519.PublicKey)),
		BoxPubKey: lb64(kbox.Public().(ed25519.PublicKey)), Owners: []string{"HUM-1"}, HidePosts: true, Version: 1}
	l.SignedBody = store.BoxLockBody(l)
	l.Signature = lb64(ed25519.Sign(klock, []byte(l.SignedBody)))
	if err := e.st.(store.BoxLockStore).CreateBoxLock(ctx, l, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	pinFile, quietFile, hushFile := strings.Repeat("a1", 32), strings.Repeat("a2", 32), strings.Repeat("a3", 32)
	ownerFile, otherFile := strings.Repeat("a4", 32), strings.Repeat("a5", 32)
	for _, r := range []struct{ ch, from, file string }{{"ledger", "HUM-1", pinFile}, {"quiet", "HUM-1", quietFile},
		{"hush", "HUM-1", hushFile}, {"open", "HUM-1", ownerFile}, {"open", "HUM-2", otherFile}} {
		putFileRow(t, e, tid, uuidV4(), r.ch, r.from, "box-wui", r.file, now)
		ageBlob(t, e, tid, r.file, now.Add(-2*hub.FileUploadGrace))
	}
	for _, tc := range []struct {
		what, file string
		b          *box
		want       int
	}{
		{"a box in the channel's pins (CONTROL)", pinFile, pinned, http.StatusOK},
		{"a box outside the channel's pins", pinFile, unpinned, http.StatusNotFound},
		{"a channel with its AI agents off", quietFile, quiet, http.StatusNotFound},
		{"a humans-only channel", hushFile, hush, http.StatusNotFound},
		{"a locked box, its owner's post (CONTROL)", ownerFile, locked, http.StatusOK},
		{"a locked box, a non-owner's post", otherFile, locked, http.StatusNotFound},
	} {
		if got, _ := e.getFile(tid, tc.file, tokens[tc.b]); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.what, got, tc.want)
		}
	}
}
