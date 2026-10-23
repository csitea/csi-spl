package hubclient

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 025 box-owner-lock.md 5.3, row B7: the sidecar names each frame's
// from_box to the spool's box lock filter, so a hub that lost its check
// still cannot put a non-peer box's or a non-owner's post in a locked box's
// inbox. Red control: drop FromBox(e.FromBox) at a delivery call -> the
// box-b frame reads as local and is delivered.
func TestSyncBoxLockDrops(t *testing.T) {
	b, wui := newPeer(t, "box-b"), newPeer(t, wuiBox)
	h := &opsHub{pins: []wire.PinEntry{b.pin, wui.pin}, roster: map[string][]string{"box-b": {"c-009"}}}
	c := opsClient(t, h)
	pokeLog(t, c)
	sealTestLock(t, c.Cfg.KeysDir, c.Cfg.Tenant, "box-a", []string{"HUM-1"})

	fromB := note("c-009", "c-007", "task", "a DM from a box the lock does not list")
	owner := note("HUM-1", "c-007", "task", "the owner's DM")
	other := note("HUM-2", "c-007", "task", "another member's DM")
	bf := note("c-009", "ALL-0", "note", "an earlier post from box-b")
	fbOther := note("HUM-2", "c-008", "task", "another member's unanswered post")
	fbOwner := note("HUM-1", "c-008", "task", "the owner's unanswered post")
	h.push = []wire.Frame{
		{Type: wire.TRecv, Env: envRaw(t, b, "box-a", "", fromB)},
		{Type: wire.TRecv, Env: envRaw(t, wui, "box-a", "", owner)},
		{Type: wire.TRecv, Env: envRaw(t, wui, "box-a", "", other)},
		{Type: wire.TRecv, Env: envRaw(t, b, wuiBox, "lobby", bf), Agents: []string{"c-007"}, Backfill: "general"},
		{Type: wire.TRecv, Env: envRaw(t, wui, wuiBox, "", fbOther), Agents: []string{"c-008"}, Fallback: "DM to c-008"},
		{Type: wire.TRecv, Env: envRaw(t, wui, wuiBox, "", fbOwner), Agents: []string{"c-008"}, Fallback: "DM to c-008"},
	}
	r, err := c.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// delivered: the owner's DM (c-007) and the owner's fallback post (c-008)
	if r.Delivered != 2 || r.Refused != 0 {
		t.Errorf("report %+v, want 2 delivered, 0 refused", r)
	}
	if n7, n8 := inbox(t, c, "c-007"), inbox(t, c, "c-008"); n7 != 1 || n8 != 1 {
		t.Errorf("inboxes c-007 %d c-008 %d, want 1 and 1", n7, n8)
	}
}

// sealTestLock writes a sealed box's public lock.json and the owner's
// signed lock (owners, no peer box) under keysDir, as `spool lock create`
// prints it.
func sealTestLock(t *testing.T, keysDir, tenant, box string, owners []string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	dir := lockkey.LockDir(keysDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	k := lockkey.PubB64(pub)
	writeTestJSON(t, filepath.Join(dir, "lock.json"), lockkey.Meta{V: 1, Tenant: tenant, Box: box, LockPubkey: k, BoxPubkey: k})
	cb, err := lockkey.Body{TenantID: tenant, BoxID: box, LockPubkey: k, BoxPubkey: k, Owners: owners, HidePosts: true, Version: 1}.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	writeTestJSON(t, filepath.Join(dir, "lock.signed.json"),
		map[string]string{"signed_body": string(cb), "signature": lockkey.SignB64(priv, cb)})
}

func writeTestJSON(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}
