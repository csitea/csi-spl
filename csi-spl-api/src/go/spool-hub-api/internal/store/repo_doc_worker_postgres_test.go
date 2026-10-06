package store

import (
	"context"
	"testing"
	"time"
)

// TestRepoDocWorkerLockIsExclusive: the env has one worker; a second lock
// attempt is refused while the first is held and succeeds once it closes.
func TestRepoDocWorkerLockIsExclusive(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	a, ok, err := pg.LockRepoDocWorker(ctx)
	if err != nil || !ok {
		t.Fatalf("first lock: ok=%v err=%v", ok, err)
	}
	if b, ok, err := pg.LockRepoDocWorker(ctx); err != nil || ok {
		if b != nil {
			_ = b.Close()
		}
		t.Fatalf("second lock while held: ok=%v err=%v", ok, err)
	}
	// A timeout is a quiet wake-up, not a lost lock.
	if err := a.Wait(ctx, 50*time.Millisecond); err != nil {
		t.Fatalf("idle wait: %v", err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	c, ok, err := pg.LockRepoDocWorker(ctx)
	if err != nil || !ok {
		t.Fatalf("lock after release: ok=%v err=%v", ok, err)
	}
	_ = c.Close()
}

// TestRepoDocWorkerWakesOnSave: a save's NOTIFY ends the worker's wait long
// before its poll; the session still holds the lock afterwards.
func TestRepoDocWorkerWakesOnSave(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	sess, ok, err := pg.LockRepoDocWorker(ctx)
	if err != nil || !ok {
		t.Fatalf("lock: ok=%v err=%v", ok, err)
	}
	defer sess.Close()
	tenant := repoDocTenant(t, pg)
	go func() {
		time.Sleep(100 * time.Millisecond)
		repoDocInsert(t, pg, repoDocSave(tenant, "hum-w", "doc/"+uid("w-")+".md"), repoDocNow())
	}()
	start := time.Now()
	if err := sess.Wait(ctx, 20*time.Second); err != nil {
		t.Fatalf("wait: %v", err)
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("woke after %s: no NOTIFY", d)
	}
	if _, ok, _ := pg.LockRepoDocWorker(ctx); ok {
		t.Fatal("lock lost after a wake-up")
	}
}

// TestRepoDocEditStatuses: the sweep reads any workspace's statuses by
// edit_id; an id without a row is absent.
func TestRepoDocEditStatuses(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	t1, t2 := repoDocTenant(t, pg), repoDocTenant(t, pg)
	now := repoDocNow()
	a, _ := repoDocInsert(t, pg, repoDocSave(t1, "hum-a", "doc/"+uid("s-")+".md"), now)
	b, _ := repoDocInsert(t, pg, repoDocSave(t2, "hum-b", "doc/"+uid("s-")+".md"), now)
	missing := uuid4()
	got, err := pg.RepoDocEditStatuses(ctx, []string{a.EditID, b.EditID, missing})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[a.EditID] != RepoDocQueued || got[b.EditID] != RepoDocQueued {
		t.Fatalf("statuses = %v", got)
	}
	if empty, err := pg.RepoDocEditStatuses(ctx, nil); err != nil || len(empty) != 0 {
		t.Fatalf("no ids: %v %v", empty, err)
	}
}
