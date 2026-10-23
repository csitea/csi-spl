package store

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"slices"
	"strings"
	"testing"
	"time"
)

// Spec 025 box owner lock, row B6 (section 6.4, SPL-3014): cnf
// hub.box_locks_expected. Memory always, Postgres with a DSN.

func lockPub(k ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
}

// TestBoxLockExpected is row B6's red control: a listed box with no lock
// row loads as Tampered (locked to nobody) and is listed by LockedBoxes, so
// every hub check refuses it; the same holds for a row under another key.
// Remove the expectLocks.apply call from BoxLock and this test fails.
func TestBoxLockExpected(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC()
			tid := newTenant(t, s)
			k, other := testLockKey(t), testLockKey(t)
			s.(BoxLockExpecter).ExpectBoxLocks([]ExpectedBoxLock{
				{TenantID: tid, BoxID: "box-own", LockPubKey: lockPub(k)},
				{TenantID: tid, BoxID: "box-rekeyed", LockPubKey: lockPub(k)},
			})
			t.Cleanup(func() { s.(BoxLockExpecter).ExpectBoxLocks(nil) })

			// no row: refused for everyone, one tampered audit row
			l, err := boxLocks(s).BoxLock(ctx, tid, "box-own")
			if err != nil || l == nil || !l.Tampered || l.IsOwner("HUM-owner") {
				t.Fatalf("listed box with no row: %+v, %v; want a tampered lock", l, err)
			}
			if n := countVerdict(t, s, tid, "box-own", BoxLockTamperedRow); n != 1 {
				t.Fatalf("tampered audit count %d, want 1", n)
			}
			ids, err := s.(LockedBoxLister).LockedBoxes(ctx, tid)
			if err != nil || !slices.Contains(ids, "box-own") || !slices.Contains(ids, "box-rekeyed") {
				t.Fatalf("LockedBoxes %v, %v; want both listed boxes", ids, err)
			}
			// CONTROL: an unlisted box with no row is unlocked.
			if l, err := boxLocks(s).BoxLock(ctx, tid, "box-free"); err != nil || l != nil {
				t.Fatalf("CONTROL: unlisted box: %+v, %v; want nil", l, err)
			}

			// the row under the listed key: the owner is in again
			if err := boxLocks(s).CreateBoxLock(ctx, newBoxLock(tid, "box-own", k, "HUM-owner"), "HUM-owner", now); err != nil {
				t.Fatalf("create: %v", err)
			}
			if l, err := boxLocks(s).BoxLock(ctx, tid, "box-own"); err != nil || l == nil || l.Tampered || !l.IsOwner("HUM-owner") {
				t.Fatalf("listed box with its row: %+v, %v; want the owner in", l, err)
			}

			// a row under another K_lock than cnf lists: refused
			if err := boxLocks(s).CreateBoxLock(ctx, newBoxLock(tid, "box-rekeyed", other, "HUM-owner"), "HUM-owner", now); err != nil {
				t.Fatalf("create rekeyed: %v", err)
			}
			if l, err := boxLocks(s).BoxLock(ctx, tid, "box-rekeyed"); err != nil || l == nil || !l.Tampered || l.IsOwner("HUM-owner") {
				t.Fatalf("row under another key: %+v, %v; want a tampered lock", l, err)
			}

			// the row deleted without the cnf change: refused again
			if err := boxLocks(s).LiftBoxLock(ctx, tid, "box-own", "HUM-owner", now); err != nil {
				t.Fatalf("lift: %v", err)
			}
			if l, err := boxLocks(s).BoxLock(ctx, tid, "box-own"); err != nil || l == nil || !l.Tampered {
				t.Fatalf("listed box after its row went: %+v, %v; want a tampered lock", l, err)
			}

			// CheckExpectedBoxLocks (the hub start check) names both refused boxes
			refused, err := CheckExpectedBoxLocks(ctx, boxLocks(s), []ExpectedBoxLock{
				{TenantID: tid, BoxID: "box-own", LockPubKey: lockPub(k)},
				{TenantID: tid, BoxID: "box-rekeyed", LockPubKey: lockPub(k)},
			})
			if err != nil || len(refused) != 2 {
				t.Fatalf("start check: %+v, %v; want 2 refused", refused, err)
			}
		})
	}
}

func TestParseExpectedBoxLocks(t *testing.T) {
	k := lockPub(testLockKey(t))
	got, err := ParseExpectedBoxLocks(" t1:box-a:" + k + ", ,t2:box-b:" + k)
	if err != nil || len(got) != 2 || got[0] != (ExpectedBoxLock{"t1", "box-a", k}) || got[1].TenantID != "t2" {
		t.Fatalf("parse: %+v, %v", got, err)
	}
	if got, err := ParseExpectedBoxLocks(""); err != nil || got != nil {
		t.Fatalf("empty: %+v, %v", got, err)
	}
	for _, bad := range []string{
		"t1:box-a",                         // no key
		"t1:box-a:" + k + ":x",             // four parts
		":box-a:" + k,                      // no tenant
		"t1::" + k,                         // no box
		"t1:box-a:bm90LWEta2V5",            // not 32 bytes
		"t1:box-a:" + k + ",t1:box-a:" + k, // listed twice
	} {
		if _, err := ParseExpectedBoxLocks(bad); err == nil || !strings.Contains(err.Error(), "box_locks_expected") {
			t.Fatalf("%q parsed: %v", bad, err)
		}
	}
}
