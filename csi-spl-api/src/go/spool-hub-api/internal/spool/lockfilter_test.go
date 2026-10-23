package spool

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Spec 025 box-owner-lock.md 5.3, row B7: the owner box drops what its
// lock does not admit. Placeholders only: box-owner, box-shared, box-peer.
const (
	lfTenant = "t-lock"
	lfBox    = "box-owner"
	lfOwner  = "HUM-01"
	lfOther  = "HUM-02"
)

// sealLockFiles writes the public lock.json and, when body is not nil, the
// owner's signed lock signed by signer (K_lock unless a test swaps it).
func sealLockFiles(t *testing.T, cfg *config.Config, lockPub ed25519.PublicKey, signer ed25519.PrivateKey, body *lockkey.Body) {
	t.Helper()
	dir := lockkey.LockDir(cfg.KeysDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	meta := lockkey.Meta{V: 1, Tenant: lfTenant, Box: lfBox, LockPubkey: lockkey.PubB64(lockPub), BoxPubkey: lockkey.PubB64(lockPub)}
	writeJSON(t, filepath.Join(dir, "lock.json"), meta)
	if body == nil {
		return
	}
	cb, err := body.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	writeJSON(t, filepath.Join(dir, signedLockFile), signedLockStatement{SignedBody: string(cb), Signature: lockkey.SignB64(signer, cb)})
}

func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func lockBody(lockPub ed25519.PublicKey, owners, peers []string) *lockkey.Body {
	return &lockkey.Body{TenantID: lfTenant, BoxID: lfBox, LockPubkey: lockkey.PubB64(lockPub), BoxPubkey: lockkey.PubB64(lockPub),
		Owners: owners, PeerBoxes: peers, HidePosts: true, Version: 1}
}

// deliverOne delivers a fresh message from `from` via fromBox to CLE-07 and
// reports whether it reached the inbox.
func deliverOne(t *testing.T, st *Store, fromBox, from string) bool {
	t.Helper()
	m, err := st.Compose(from, "CLE-07", "", "task", "do x via "+fromBox, nil)
	if err != nil {
		t.Fatal(err)
	}
	wrote, err := st.FromBox(fromBox).Deliver(m)
	if err != nil {
		t.Fatalf("deliver: %v", err)
	}
	_, statErr := os.Stat(filepath.Join(st.dir("CLE-07", boxInbox), msg.Filename(m)))
	if wrote != (statErr == nil) {
		t.Fatalf("wrote=%v but inbox stat err %v", wrote, statErr)
	}
	return wrote
}

func newKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

// TestBoxLockFilter is the row's red control: a box-wui post from a
// non-owner is dropped (remove the lockDrops call in deliverTo -> red),
// each case paired with one that passes.
func TestBoxLockFilter(t *testing.T) {
	type send struct {
		fromBox, from string
		want          bool
	}
	lockPub, lockPriv := newKey(t)
	_, otherPriv := newKey(t)
	locked := lockBody(lockPub, []string{lfOwner}, []string{"box-peer"})
	widened := lockBody(lockPub, []string{lfOwner, lfOther}, []string{"box-peer", "box-shared"})
	cases := []struct {
		name   string
		setup  func(t *testing.T, cfg *config.Config)
		sends  []send
		logHas string
	}{
		{"unsealed box: nothing filtered", func(*testing.T, *config.Config) {}, []send{
			{"box-wui", lfOther, true}, {"box-shared", "CLE-09", true}, {"", "CLE-09", true},
		}, ""},
		{"locked: owner and peers in, others dropped", func(t *testing.T, cfg *config.Config) {
			sealLockFiles(t, cfg, lockPub, lockPriv, locked)
		}, []send{
			{"box-wui", lfOwner, true},
			{"box-wui", lfOther, false}, // the row's case: a non-owner human
			{"box-wui", "CLE-09", false},
			{"box-peer", "CLE-09", true},
			{"box-shared", "CLE-09", false},
			{lfBox, "CLE-09", true},
			{"", "CLE-09", true},
		}, "not an owner or a peer box"},
		{"sealed, no signed lock: own box only", func(t *testing.T, cfg *config.Config) {
			sealLockFiles(t, cfg, lockPub, lockPriv, nil)
		}, []send{
			{"box-wui", lfOwner, false}, {"box-peer", "CLE-09", false}, {lfBox, "CLE-09", true},
		}, "no signed lock"},
		{"widened lock signed by another key: own box only", func(t *testing.T, cfg *config.Config) {
			sealLockFiles(t, cfg, lockPub, otherPriv, widened)
		}, []send{
			{"box-wui", lfOwner, false}, {"box-wui", lfOther, false}, {"box-shared", "CLE-09", false}, {lfBox, "CLE-09", true},
		}, "signature does not hold"},
		{"lock of another box: own box only", func(t *testing.T, cfg *config.Config) {
			b := *locked
			b.BoxID = "box-shared"
			sealLockFiles(t, cfg, lockPub, lockPriv, &b)
		}, []send{
			{"box-wui", lfOwner, false}, {lfBox, "CLE-09", true},
		}, "another box or key"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := newCfg(t)
			var log bytes.Buffer
			st := New(cfg)
			st.warn = &log
			tc.setup(t, cfg)
			for _, s := range tc.sends {
				if got := deliverOne(t, st, s.fromBox, s.from); got != s.want {
					t.Errorf("from %s via %q: delivered=%v, want %v", s.from, s.fromBox, got, s.want)
				}
			}
			if tc.logHas != "" && !strings.Contains(log.String(), tc.logHas) {
				t.Errorf("drop log %q lacks %q", log.String(), tc.logHas)
			}
			if strings.Contains(log.String(), "do x via") {
				t.Errorf("drop log carries a message body: %q", log.String())
			}
		})
	}
}

// TestBoxLockFilterQuiet: the back-fill and fallback deliveries (DeliverQuiet)
// pass through the same check.
func TestBoxLockFilterQuiet(t *testing.T) {
	lockPub, lockPriv := newKey(t)
	cfg := newCfg(t)
	sealLockFiles(t, cfg, lockPub, lockPriv, lockBody(lockPub, []string{lfOwner}, nil))
	st := New(cfg)
	st.warn = &bytes.Buffer{}
	for from, want := range map[string]bool{lfOwner: true, lfOther: false} {
		m, err := st.Compose(from, "CLE-07", "", "task", "back-filled", nil)
		if err != nil {
			t.Fatal(err)
		}
		if wrote, err := st.FromBox("box-wui").DeliverQuiet(m, "CLE-08"); err != nil || wrote != want {
			t.Errorf("DeliverQuiet from %s: wrote=%v err=%v, want %v", from, wrote, err, want)
		}
	}
}
