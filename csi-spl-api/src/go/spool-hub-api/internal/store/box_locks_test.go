package store

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 025 box owner lock, row B1 (rdb 0213, SPL-2952): box_locks, its audit
// and the signature verify on load. Memory always, Postgres with a DSN
// (hub-pg.tst.sh, PRE_PUSH_TIER=full).

// testLockKey is a K_lock for a test.
func testLockKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, k, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// signLock renders l's body and signs it with k, as spool lock sign does.
func signLock(l BoxLock, k ed25519.PrivateKey) BoxLock {
	l.LockPubKey = base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
	l.SignedBody = BoxLockBody(l)
	l.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(k, []byte(l.SignedBody)))
	return l
}

// newBoxLock is a version 1 lock of box owned by owners, signed by k.
func newBoxLock(tid, box string, k ed25519.PrivateKey, owners ...string) BoxLock {
	return signLock(BoxLock{TenantID: tid, BoxID: box, BoxPubKey: base64.StdEncoding.EncodeToString(pubkey()),
		Owners: owners, HidePosts: true, Version: 1}, k)
}

// forgetLocks clears the Postgres lock cache (a raw SQL edit bypasses it).
func forgetLocks(s Store) {
	if pg, ok := s.(*Postgres); ok {
		pg.locks.forget()
	}
}

// rawEditLock rewrites the stored row behind the store's back, as a holder
// of a database credential could: no K_lock, no cache clear.
func rawEditLock(t *testing.T, s Store, tid, box string, edit func(*BoxLock)) {
	t.Helper()
	switch st := s.(type) {
	case *Memory:
		st.mu.Lock()
		l := st.boxLocks.locks[[2]string{tid, box}]
		edit(&l)
		st.boxLocks.locks[[2]string{tid, box}] = l
		st.mu.Unlock()
	case *Postgres:
		var l BoxLock
		ctx := context.Background()
		if err := st.queryRowTenant(ctx, tid, boxLockSQL, []any{tid, box}, boxLockDest(&l)...); err != nil {
			t.Fatal(err)
		}
		edit(&l)
		if err := st.inTenant(ctx, tid, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE box_locks SET owners = $3, peer_boxes = $4, signed_body = $5
				WHERE tenant_id = $1 AND box_id = $2`, tid, box, l.Owners, nonNilStrings(l.PeerBoxes), l.SignedBody)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no raw edit for %T", s)
	}
}

func boxLocks(s Store) BoxLockStore { return s.(BoxLockStore) }

// countVerdict sums the count of box's audit rows with verdict v.
func countVerdict(t *testing.T, s Store, tid, box, v string) int {
	t.Helper()
	rows, err := boxLocks(s).BoxLockAudits(context.Background(), tid, box, 0)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range rows {
		if r.Verdict == v {
			n += r.Count
		}
	}
	return n
}

// TestBoxLockTamper is row B1's red control (section 6.1): a row whose
// owners were widened in the database, with the old signature, loads as
// tampered = locked to nobody, with a tampered audit row. Remove the
// VerifyBoxLock call from a load and this test fails.
func TestBoxLockTamper(t *testing.T) {
	cases := map[string]func(*BoxLock){
		// owners widened, signed_body left: the body no longer is the row's
		"owners widened": func(l *BoxLock) { l.Owners = append(l.Owners, "HUM-intruder") },
		// owners widened and signed_body re-rendered: the old signature
		// does not hold over the new body
		"owners and body rewritten": func(l *BoxLock) {
			l.Owners = append(l.Owners, "HUM-intruder")
			l.SignedBody = BoxLockBody(*l)
		},
		"peer box added": func(l *BoxLock) {
			l.PeerBoxes = []string{"box-shared"}
			l.SignedBody = BoxLockBody(*l)
		},
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC()
			for cname, edit := range cases {
				t.Run(cname, func(t *testing.T) {
					tid := newTenant(t, s)
					k := testLockKey(t)
					if err := boxLocks(s).CreateBoxLock(ctx, newBoxLock(tid, "box-own", k, "HUM-owner"), "HUM-owner", now); err != nil {
						t.Fatalf("create: %v", err)
					}
					// CONTROL: the untouched row verifies and its owner is in.
					l, err := boxLocks(s).BoxLock(ctx, tid, "box-own")
					if err != nil || l == nil || l.Tampered || !l.IsOwner("HUM-owner") {
						t.Fatalf("untouched lock: %+v, %v", l, err)
					}
					rawEditLock(t, s, tid, "box-own", edit)
					forgetLocks(s)
					l, err = boxLocks(s).BoxLock(ctx, tid, "box-own")
					if err != nil || l == nil {
						t.Fatalf("tampered load: %+v, %v", l, err)
					}
					if !l.Tampered {
						t.Fatalf("a row edited without K_lock loaded as verified: %+v", l)
					}
					for _, h := range []string{"HUM-owner", "HUM-intruder"} {
						if l.IsOwner(h) {
							t.Fatalf("tampered lock lets %s in", h)
						}
					}
					if l.IsPeer("box-shared") {
						t.Fatal("tampered lock lets a peer box in")
					}
					if n := countVerdict(t, s, tid, "box-own", BoxLockTamperedRow); n != 1 {
						t.Fatalf("tampered audit count %d, want 1", n)
					}
				})
			}
		})
	}
}

// TestBoxLockLifecycle: create, read, change, lift, each audited; an
// unlocked box reads nil.
func TestBoxLockLifecycle(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
			tid := newTenant(t, s)
			if l, err := boxLocks(s).BoxLock(ctx, tid, "box-own"); l != nil || err != nil {
				t.Fatalf("unlocked box: %+v, %v", l, err)
			}
			k := testLockKey(t)
			l1 := newBoxLock(tid, "box-own", k, "HUM-owner")
			if err := boxLocks(s).CreateBoxLock(ctx, l1, "HUM-owner", now); err != nil {
				t.Fatal(err)
			}
			if err := boxLocks(s).CreateBoxLock(ctx, l1, "HUM-owner", now); !errors.Is(err, ErrBoxLockExists) {
				t.Fatalf("second create: %v, want ErrBoxLockExists", err)
			}
			got, err := boxLocks(s).BoxLock(ctx, tid, "box-own")
			if err != nil || got == nil || got.Tampered || got.Version != 1 || !got.HidePosts ||
				!got.IsOwner("HUM-owner") || got.IsOwner("HUM-admin") || len(got.PeerBoxes) != 0 {
				t.Fatalf("read back: %+v, %v", got, err)
			}
			l2 := l1
			l2.Owners, l2.PeerBoxes, l2.Version = []string{"HUM-owner", "HUM-second"}, []string{"box-peer"}, 2
			l2 = signLock(l2, k)
			if err := boxLocks(s).ChangeBoxLock(ctx, l2, "HUM-owner", now); err != nil {
				t.Fatalf("change: %v", err)
			}
			got, err = boxLocks(s).BoxLock(ctx, tid, "box-own")
			if err != nil || got.Version != 2 || !got.IsOwner("HUM-second") || !got.IsPeer("box-peer") || got.Tampered {
				t.Fatalf("after change (no stale cache on this store): %+v, %v", got, err)
			}
			if err := boxLocks(s).LiftBoxLock(ctx, tid, "box-own", "HUM-owner", now); err != nil {
				t.Fatal(err)
			}
			if l, err := boxLocks(s).BoxLock(ctx, tid, "box-own"); l != nil || err != nil {
				t.Fatalf("lifted box: %+v, %v", l, err)
			}
			if err := boxLocks(s).LiftBoxLock(ctx, tid, "box-own", "HUM-owner", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second lift: %v, want ErrNotFound", err)
			}
			for _, v := range []string{BoxLockCreated, BoxLockChanged, BoxLockLifted} {
				if n := countVerdict(t, s, tid, "box-own", v); n != 1 {
					t.Fatalf("%s audit count %d, want 1", v, n)
				}
			}
		})
	}
}

// TestBoxLockWriteRefusals: no write takes a body that does not verify, a
// change signed by another key, or a change at the wrong version. CONTROL:
// the same change, signed by the K_lock on file at version + 1, lands.
func TestBoxLockWriteRefusals(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC()
			tid := newTenant(t, s)
			k, other := testLockKey(t), testLockKey(t)
			bad := newBoxLock(tid, "box-own", k, "HUM-owner")
			bad.Owners = append(bad.Owners, "HUM-intruder")
			if err := boxLocks(s).CreateBoxLock(ctx, bad, "HUM-owner", now); !errors.Is(err, ErrBoxLockTampered) {
				t.Fatalf("create with a body that is not the row: %v", err)
			}
			if err := boxLocks(s).CreateBoxLock(ctx, newBoxLock(tid, "box-own", k), "HUM-owner", now); !errors.Is(err, ErrBoxLockTampered) {
				t.Fatalf("create with no owner: %v", err)
			}
			base := newBoxLock(tid, "box-own", k, "HUM-owner")
			if err := boxLocks(s).CreateBoxLock(ctx, base, "HUM-owner", now); err != nil {
				t.Fatal(err)
			}
			next := base
			next.Owners, next.Version = []string{"HUM-owner", "HUM-admin"}, 2
			if err := boxLocks(s).ChangeBoxLock(ctx, signLock(next, other), "HUM-admin", now); !errors.Is(err, ErrBoxLockKey) {
				t.Fatalf("change signed by another key: %v, want ErrBoxLockKey", err)
			}
			forged := signLock(next, k)
			forged.Signature = signLock(next, other).Signature
			if err := boxLocks(s).ChangeBoxLock(ctx, forged, "HUM-admin", now); !errors.Is(err, ErrBoxLockTampered) {
				t.Fatalf("change naming K_lock but signed by another key: %v", err)
			}
			skip := next
			skip.Version = 3
			if err := boxLocks(s).ChangeBoxLock(ctx, signLock(skip, k), "HUM-owner", now); !errors.Is(err, ErrBoxLockVersion) {
				t.Fatalf("change at version 3 over 1: %v, want ErrBoxLockVersion", err)
			}
			got, err := boxLocks(s).BoxLock(ctx, tid, "box-own")
			if err != nil || got.Version != 1 || got.IsOwner("HUM-admin") {
				t.Fatalf("refused changes wrote: %+v, %v", got, err)
			}
			if err := boxLocks(s).ChangeBoxLock(ctx, signLock(next, k), "HUM-owner", now); err != nil {
				t.Fatalf("control change: %v", err)
			}
			if err := boxLocks(s).ChangeBoxLock(ctx, signLock(next, k), "HUM-owner", now); !errors.Is(err, ErrBoxLockVersion) {
				t.Fatalf("replayed change: %v, want ErrBoxLockVersion", err)
			}
			nl := newBoxLock(tid, "box-none", k, "HUM-owner")
			nl.Version = 2
			if err := boxLocks(s).ChangeBoxLock(ctx, signLock(nl, k), "HUM-owner", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("change of no lock: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestBoxLockAuditBump: refusals of one key within a minute bump one row
// (section 6.3); after the minute, or for another human, a new row.
func TestBoxLockAuditBump(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
			tid := newTenant(t, s)
			a := BoxLockAudit{TenantID: tid, BoxID: "box-own", HumanID: "HUM-admin", Path: "dm", Verdict: BoxLockRefused}
			for i, at := range []time.Time{now, now.Add(10 * time.Second), now.Add(59 * time.Second)} {
				if err := boxLocks(s).RecordBoxLockAudit(ctx, a, at); err != nil {
					t.Fatalf("refusal %d: %v", i, err)
				}
			}
			rows, err := boxLocks(s).BoxLockAudits(ctx, tid, "box-own", 0)
			if err != nil || len(rows) != 1 || rows[0].Count != 3 || !rows[0].LastAt.Equal(now.Add(59*time.Second)) ||
				!rows[0].FirstAt.Equal(now) {
				t.Fatalf("one bumped row: %+v, %v", rows, err)
			}
			if err := boxLocks(s).RecordBoxLockAudit(ctx, a, now.Add(61*time.Second)); err != nil {
				t.Fatal(err)
			}
			b := a
			b.HumanID, b.FromBox = "", "box-shared"
			if err := boxLocks(s).RecordBoxLockAudit(ctx, b, now.Add(62*time.Second)); err != nil {
				t.Fatal(err)
			}
			rows, err = boxLocks(s).BoxLockAudits(ctx, tid, "box-own", 0)
			if err != nil || len(rows) != 3 || rows[0].FromBox != "box-shared" || rows[0].HumanID != "" {
				t.Fatalf("after the minute: %+v, %v", rows, err)
			}
			if rows, _ := boxLocks(s).BoxLockAudits(ctx, tid, "box-own", 1); len(rows) != 1 {
				t.Fatalf("limit 1: %d rows", len(rows))
			}
			for _, bad := range []BoxLockAudit{{TenantID: tid, BoxID: "box-own", Path: "dm", Verdict: "allowed"},
				{TenantID: tid, BoxID: "box-own", Verdict: BoxLockRefused}} {
				if err := boxLocks(s).RecordBoxLockAudit(ctx, bad, now); !errors.Is(err, ErrBadBoxLockAudit) {
					t.Fatalf("bad row %+v: %v", bad, err)
				}
			}
		})
	}
}

// TestBoxLockCache (Postgres): a load is served from cache for 5 s, so a
// raw edit by another process is seen within the TTL; a write through the
// store clears it at once.
func TestBoxLockCache(t *testing.T) {
	s, ok := drivers(t)["postgres"]
	if !ok {
		t.Skip("postgres only: SPOOL_TEST_PG_DSN is unset")
	}
	ctx, now := context.Background(), time.Now().UTC()
	tid := newTenant(t, s)
	k := testLockKey(t)
	if err := boxLocks(s).CreateBoxLock(ctx, newBoxLock(tid, "box-own", k, "HUM-owner"), "HUM-owner", now); err != nil {
		t.Fatal(err)
	}
	clock := time.Now()
	hotNow = func() time.Time { return clock }
	t.Cleanup(func() { hotNow = time.Now })
	if l, err := boxLocks(s).BoxLock(ctx, tid, "box-own"); err != nil || l.Tampered {
		t.Fatalf("first load: %+v, %v", l, err)
	}
	rawEditLock(t, s, tid, "box-own", func(l *BoxLock) { l.Owners = append(l.Owners, "HUM-intruder") })
	clock = clock.Add(4 * time.Second)
	if l, _ := boxLocks(s).BoxLock(ctx, tid, "box-own"); l.Tampered || l.IsOwner("HUM-intruder") {
		t.Fatalf("within the TTL the cached verified row is served: %+v", l)
	}
	clock = clock.Add(2 * time.Second)
	if l, _ := boxLocks(s).BoxLock(ctx, tid, "box-own"); !l.Tampered {
		t.Fatalf("past the TTL the edit must load as tampered: %+v", l)
	}
	if err := boxLocks(s).LiftBoxLock(ctx, tid, "box-own", "HUM-owner", now); err != nil {
		t.Fatal(err)
	}
	if l, err := boxLocks(s).BoxLock(ctx, tid, "box-own"); l != nil || err != nil {
		t.Fatalf("a lift is seen at once: %+v, %v", l, err)
	}
}

// TestVerifyBoxLock: each part of the check refuses on its own.
func TestVerifyBoxLock(t *testing.T) {
	k := testLockKey(t)
	good := newBoxLock("t-1", "box-own", k, "HUM-owner")
	if err := VerifyBoxLock(good); err != nil {
		t.Fatalf("control: %v", err)
	}
	cases := map[string]func(*BoxLock){
		"short key":      func(l *BoxLock) { l.LockPubKey = base64.StdEncoding.EncodeToString([]byte("short")) },
		"not base64 sig": func(l *BoxLock) { l.Signature = "!!" },
		"version 0":      func(l *BoxLock) { l.Version = 0; *l = signLock(*l, k) },
		"no owner":       func(l *BoxLock) { l.Owners = nil; *l = signLock(*l, k) },
		"box moved":      func(l *BoxLock) { l.BoxID = "box-other" },
		"hide flipped":   func(l *BoxLock) { l.HidePosts = false },
		"other key":      func(l *BoxLock) { l.LockPubKey = signLock(*l, testLockKey(t)).LockPubKey },
	}
	for name, edit := range cases {
		l := good
		l.Owners = append([]string(nil), good.Owners...)
		edit(&l)
		if err := VerifyBoxLock(l); !errors.Is(err, ErrBoxLockTampered) {
			t.Errorf("%s: %v, want ErrBoxLockTampered", name, err)
		}
	}
	want := `{"tenant_id":"t-1","box_id":"box-own","lock_pubkey":"` + good.LockPubKey + `","box_pubkey":"` +
		good.BoxPubKey + `","owners":["HUM-owner"],"peer_boxes":[],"hide_posts":true,"version":1}`
	if good.SignedBody != want {
		t.Fatalf("canonical body\n got %s\nwant %s", good.SignedBody, want)
	}
}
