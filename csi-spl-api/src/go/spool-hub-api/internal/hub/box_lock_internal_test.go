package hub

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Path 12 (spec 025 box-owner-lock.md 5.1, row B3): a box's own send to a
// locked-box agent passes only from the locked box itself or a peer box of
// the lock, and a refusal is audited. The helper is NOT called yet: its call
// belongs in onSend (ws.go), batch 3. CONTROL: an unlocked target box.
func TestBoxSendLockRefusal(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	st := store.NewMemory()
	s, err := New(Options{Store: st, Blob: blob.Dir{Root: t.TempDir()}, TenantHostPattern: "{tenant}.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := st.CreateTenant(ctx, store.Tenant{ID: "t1", RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	kboxPub, _, _ := ed25519.GenerateKey(nil)
	lockPub, klock, _ := ed25519.GenerateKey(nil)
	b64 := base64.StdEncoding.EncodeToString
	l := store.BoxLock{TenantID: "t1", BoxID: "box-own", LockPubKey: b64(lockPub), BoxPubKey: b64(kboxPub),
		Owners: []string{"HUM-1"}, PeerBoxes: []string{"box-peer"}, HidePosts: true, Version: 1}
	l.SignedBody = store.BoxLockBody(l)
	l.Signature = b64(ed25519.Sign(klock, []byte(l.SignedBody)))
	if err := st.CreateBoxLock(ctx, l, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	x := &session{tenant: "t1"}
	for _, c := range []struct {
		from, to, want string
	}{
		{"box-sh", "box-own", codeBoxLocked},
		{"box-peer", "box-own", ""},
		{"box-own", "box-own", ""},
		{"box-sh", "box-other", ""}, // CONTROL: no lock on the target
	} {
		rf := s.boxSendLockRefusal(ctx, x, &wire.Envelope{FromBox: c.from, ToBox: c.to}, nil)
		got := ""
		if rf != nil {
			got = rf.token
		}
		if got != c.want {
			t.Fatalf("%s -> %s: %q, want %q", c.from, c.to, got, c.want)
		}
	}
	rows, err := st.BoxLockAudits(ctx, "t1", "box-own", 10)
	if err != nil {
		t.Fatal(err)
	}
	var refused []store.BoxLockAudit
	for _, a := range rows {
		if a.Verdict == store.BoxLockRefused {
			refused = append(refused, a)
		}
	}
	if len(refused) != 1 || refused[0].Path != boxLockPathBoxSend || refused[0].FromBox != "box-sh" {
		t.Fatalf("refused audit rows %+v, want one box_send from box-sh", refused)
	}
}

// Section 5.2: every queue write in internal/hub is one the lock covers -
// the routeChannel loop (channels.go), a box fallbackPick chose
// (fallback.go), the direct write after onSend / dispatchCheck (ws.go) - or
// one that queues only to box-wui, the browser's own box. A ninth write is a
// new path to a box: cover it with boxLockRefusal, then add it here.
func TestBoxLockQueueWriteInventory(t *testing.T) {
	want := map[string]int{
		"channels.go": 1, "fallback.go": 1, "ws.go": 1, // to an agent's box, covered (ws.go: path 12 is batch 3)
		"blocker_issue.go": 1, "dm_ref.go": 1, "fleet_tokens.go": 1, "issue_backlog.go": 1, "public_notice.go": 1, // box-wui only
	}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]int{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if n := strings.Count(string(raw), "Store.Enqueue("); n > 0 {
			got[f] = n
		}
	}
	var diff []string
	for f := range union(want, got) {
		if want[f] != got[f] {
			diff = append(diff, f)
		}
	}
	sort.Strings(diff)
	if len(diff) > 0 {
		t.Fatalf("queue writes changed in %v: got %v, want %v", diff, got, want)
	}
}

func union(a, b map[string]int) map[string]bool {
	out := map[string]bool{}
	for k := range a {
		out[k] = true
	}
	for k := range b {
		out[k] = true
	}
	return out
}
