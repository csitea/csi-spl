package hubclient

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 025 box-owner-lock.md 4.4, row B9: a sealed box's client against the
// real hub (memory store), the real sealed files and the real lockd. Before
// B9 the client read the clear box-<id>.key (gone once sealed) and sent no
// proof, so a sealed box never came online. Drop the addUnlock call in hello
// and the first unlocked dial is refused locked_box_sealed.

const (
	b9Tenant = "t1"
	b9Box    = "box-own"
	b9Secret = "a lock secret of several words"
)

// b9Clock is a settable clock shared by the hub or the client.
type b9Clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *b9Clock) now() time.Time  { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *b9Clock) set(t time.Time) { c.mu.Lock(); c.t = t; c.mu.Unlock() }

func TestSealedBoxUnlockHello(t *testing.T) {
	ctx := context.Background()
	// A unix socket path has ~108 bytes: t.TempDir() under a long test name
	// can pass that, so the keys dir is short.
	keys, err := os.MkdirTemp("", "b9")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(keys) })
	if _, err := lockkey.Seal(keys, b9Tenant, b9Box, []byte(b9Secret), lockkey.Params{Time: 1, MemKiB: 64, Threads: 1}); err != nil {
		t.Fatal(err)
	}
	k, err := lockkey.Unseal(keys, []byte(b9Secret)) // the owner's statement, signed on the box (spool lock create)
	if err != nil {
		t.Fatal(err)
	}
	boxPub := k.Box.Public().(ed25519.PublicKey)

	st := store.NewMemory()
	hubClock := &b9Clock{t: time.Now()}
	_, wuiKey, _ := ed25519.GenerateKey(nil)
	rootPub, _, _ := ed25519.GenerateKey(nil)
	if err := st.CreateTenant(ctx, store.Tenant{ID: b9Tenant, RootPubKey: rootPub}); err != nil {
		t.Fatal(err)
	}
	if err := st.PutPin(ctx, b9Tenant, b9Box, boxPub, true, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	l := store.BoxLock{TenantID: b9Tenant, BoxID: b9Box, LockPubKey: k.Meta.LockPubkey, BoxPubKey: k.Meta.BoxPubkey,
		Owners: []string{"HUM-1"}, HidePosts: true, Version: 1}
	l.SignedBody = store.BoxLockBody(l)
	l.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(k.Lock, []byte(l.SignedBody)))
	k.Wipe()
	if err := st.CreateBoxLock(ctx, l, "HUM-1", time.Now()); err != nil {
		t.Fatal(err)
	}
	// HelloSkew is wide so the hub's clock can pass the ticket's TTL while
	// the client's hello ts stays now; the proof's own 120 s still holds.
	srv, err := hub.New(hub.Options{Store: st, Blob: blob.Dir{Root: t.TempDir()}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}.hub.test", HelloSkew: 30 * 24 * time.Hour, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: time.Hour, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 100, Version: "test",
		WUIKey: wuiKey, Now: hubClock.now})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() { srv.Shutdown(); ts.Close() })

	root := t.TempDir()
	clientClock := &b9Clock{t: time.Now()}
	c := New(&config.Config{SpoolRoot: filepath.Join(root, "spool"), KeysDir: keys, PinsDir: filepath.Join(root, "spool", "pins"),
		BoxID: b9Box, Tenant: b9Tenant, HubURL: ts.URL, SubmitSocket: "off"})
	c.Now = clientClock.now
	c.ReadyTimeout = 5 * time.Second
	dial := func() error {
		s, err := c.Dial(ctx, wire.RoleBox)
		if err == nil {
			s.Close()
		}
		return err
	}
	sealedHellos := func() int {
		rows, err := st.BoxLockAudits(ctx, b9Tenant, b9Box, 100)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, a := range rows {
			if a.Verdict == store.BoxLockSealedHello {
				n += a.Count
			}
		}
		return n
	}

	// 1. No holder runs: there is no box key at all, so no hello is sent.
	if err := dial(); !errors.Is(err, lockkey.ErrSealed) {
		t.Fatalf("no holder: %v, want ErrSealed", err)
	}
	h := &lockkey.Holder{KeysDir: keys, Backoff: time.Hour}
	hctx, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() { done <- h.Serve(hctx) }()
	t.Cleanup(func() { cancel(); <-done })
	b9WaitSock(t, keys)
	// 2. The holder runs sealed: the same.
	if err := dial(); !errors.Is(err, lockkey.ErrSealed) {
		t.Fatalf("sealed holder: %v, want ErrSealed", err)
	}

	// 3. The owner unlocks: the hello carries the proof, the welcome a
	// ticket, and the holder drops K_lock.
	if err := lockkey.HolderUnlock(keys, []byte(b9Secret)); err != nil {
		t.Fatal(err)
	}
	if err := dial(); err != nil {
		t.Fatalf("unlocked box refused: %v", err)
	}
	if c.liveTicket() == "" {
		t.Fatal("no unlock ticket kept from the welcome")
	}
	if _, held, err := lockkey.HolderStatus(keys); err != nil || held {
		t.Fatalf("the holder still holds the lock key after the ticket (held %v, %v)", held, err)
	}

	// 4. A reconnect within the TTL shows the ticket: K_lock is gone, so no
	// proof could be made, and it is welcomed.
	if err := dial(); err != nil {
		t.Fatalf("reconnect with the ticket refused: %v", err)
	}

	// 5. Past the TTL the hub refuses the ticket, and the client forgets it.
	hubClock.set(time.Now().Add(8 * 24 * time.Hour))
	before := sealedHellos()
	var he *HubError
	if err := dial(); !errors.As(err, &he) || he.Token != helloLockedSealed {
		t.Fatalf("expired ticket: %v, want %s", err, helloLockedSealed)
	}
	if c.liveTicket() != "" {
		t.Fatal("the refused ticket was kept")
	}
	// 6. No ticket and no K_lock: the hello has no proof and is refused, audited.
	if err := dial(); !errors.As(err, &he) || he.Token != helloLockedSealed {
		t.Fatalf("no proof, no ticket: %v, want %s", err, helloLockedSealed)
	}
	if n := sealedHellos() - before; n != 2 {
		t.Fatalf("sealed_hello audit rows %d, want 2", n)
	}

	// 7. The owner types the secret again: a fresh proof brings it back.
	clientClock.set(hubClock.now())
	if err := lockkey.HolderUnlock(keys, []byte(b9Secret)); err != nil {
		t.Fatal(err)
	}
	if err := dial(); err != nil {
		t.Fatalf("fresh proof after the TTL refused: %v", err)
	}
	if c.liveTicket() == "" {
		t.Fatal("no new ticket after the fresh proof")
	}
}

// TestUnsealedHelloUnchanged: a box with no lock files sends no boot id,
// proof or ticket (an unsealed box behaves as before B9).
func TestUnsealedHelloUnchanged(t *testing.T) {
	h := &scriptedHub{first: challenge, afterHello: wire.Frame{Type: wire.TWelcome, UploadToken: "tok",
		UploadTokenExpiresAt: "2030-01-01T00:00:00Z", UnlockTicket: "x.y"}}
	s, err := dialScripted(t, h, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	h.mu.Lock()
	got := h.hello
	h.mu.Unlock()
	if got.BootID != "" || got.UnlockProof != "" || got.UnlockTicket != "" {
		t.Fatalf("unsealed hello carries unlock fields: %+v", got)
	}
	if s.c.liveTicket() != "" {
		t.Fatal("an unsealed box kept a ticket")
	}
}

func b9WaitSock(t *testing.T, dir string) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(filepath.Join(lockkey.LockDir(dir), "lockd.sock")); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("lockd socket did not appear")
}
