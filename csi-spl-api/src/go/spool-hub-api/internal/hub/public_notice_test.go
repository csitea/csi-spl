package hub_test

import (
	"context"
	"crypto/ed25519"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// rdb 0173 (owner, 2026-10-10, msg 69e2d25f): every workspace has #public,
// and its #public holds exactly ONE hub notice that everything in it is
// public and visible to the whole internet. A second pass posts nothing.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestPublicNoticeOncePerTenant(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(nil)
	e := newEnv(t, func(o *hub.Options) { o.WUIKey = key })
	tid, _ := e.tenant()
	ctx := context.Background()

	// CONTROL: drop "public" from store.DefaultChannels and this is red.
	if ok, err := e.st.ChannelKnown(ctx, tid, store.ChannelPublicID); err != nil || !ok {
		t.Fatalf("a new tenant has no #public: %v %v", ok, err)
	}
	pn := e.st.(store.PublicNotices)
	missing := func() bool {
		ids, err := pn.TenantsMissingPublicNotice(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return slices.Contains(ids, tid)
	}
	notices := func() int {
		t.Helper()
		stats, err := e.st.ViewChannelStats(ctx, tid, time.Now(), nil, "", "")
		if err != nil {
			t.Fatal(err)
		}
		for _, st := range stats {
			if st.ChannelID == store.ChannelPublicID {
				if !st.Default {
					t.Fatalf("#public is not a default channel: %+v", st)
				}
				return st.Count
			}
		}
		t.Fatalf("#public not listed: %+v", stats)
		return 0
	}
	if !missing() || notices() != 0 {
		t.Fatalf("before the pass: missing=%v notices=%d", missing(), notices())
	}

	if n := e.srv.PostPublicNotices(ctx); n < 1 {
		t.Fatalf("first pass posted %d", n)
	}
	if missing() || notices() != 1 {
		t.Fatalf("after one pass: missing=%v notices=%d, want one", missing(), notices())
	}
	if ok, err := e.st.HasMessage(ctx, tid, store.PublicNoticeID(tid)); err != nil || !ok {
		t.Fatalf("the notice is not under its fixed id: %v %v", ok, err)
	}

	// Idempotent: again, and a direct post, store nothing new.
	e.srv.PostPublicNotices(ctx)
	if notices() != 1 {
		t.Fatalf("after two passes: %d notices, want one", notices())
	}
	other, _ := e.tenant()
	if ids, err := pn.TenantsMissingPublicNotice(ctx); err != nil || !slices.Contains(ids, other) || notices() != 1 {
		t.Fatalf("a tenant's notice is per tenant: %v %v", ids, err)
	}
}

// No box-wui key: nothing can be signed, so nothing is posted (and nothing
// unsigned is stored in its place).
func TestPublicNoticeNeedsWUIKey(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	if n := e.srv.PostPublicNotices(context.Background()); n != 0 {
		t.Fatalf("posted %d without a key", n)
	}
	if ok, _ := e.st.HasMessage(context.Background(), tid, store.PublicNoticeID(tid)); ok {
		t.Fatal("a notice was stored without a key")
	}
}
