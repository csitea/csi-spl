package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/121 T105: the embed abuse store side (embed_abuse.go), run as the
// runtime role spool_hub_rt, so FORCE RLS binds every statement.

// quotaN is the (tenant, key, kind, window) count, 0 when no row.
func quotaN(t *testing.T, pg *Postgres, tenant, key, kind string, window time.Time) int {
	t.Helper()
	var n int
	err := pg.inTenant(context.Background(), tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT coalesce(sum(n), 0)::int FROM quota_counts
			WHERE tenant_id = $1 AND human_id = $2 AND kind = $3 AND window_start = $4`, tenant, key, kind, window.UTC()).Scan(&n)
	})
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// TestEmbedTakeQuotasAllOrNone: two takes in one call take both or none.
// When the second counter is full the first is NOT taken (rolled back) and
// the refused index names the second; a limit below 1 refuses before any
// write. Both in the channel scope (a visitor) and before the mint (no
// channel). CONTROL: with room, both counters move by one.
func TestEmbedTakeQuotasAllOrNone(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Hour)
	a := newTenant(t, pg)
	v, _ := mintVisitor(t, rt, a, seedEmbedCustomer(t, pg, a, true), now)
	for _, sc := range []EmbedScope{{TenantID: a, ChannelID: v.ChannelID}, {TenantID: a}} {
		key := "k-" + sc.ChannelID
		minute, day := EmbedTake{key, "embed_post_min", now, 5}, EmbedTake{key, "embed_post", now, 1}
		if r, err := rt.TakeEmbedQuotas(ctx, sc, []EmbedTake{minute, day}); err != nil || r != -1 {
			t.Fatalf("%+v CONTROL: first take = %d, %v", sc, r, err)
		}
		if r, err := rt.TakeEmbedQuotas(ctx, sc, []EmbedTake{minute, day}); err != nil || r != 1 {
			t.Fatalf("%+v: day full = %d, %v, want 1", sc, r, err)
		}
		if n := quotaN(t, pg, a, key, "embed_post_min", now); n != 1 {
			t.Errorf("%+v: the refused call took the minute: n = %d, want 1", sc, n)
		}
		if r, err := rt.TakeEmbedQuotas(ctx, sc, []EmbedTake{{key, "embed_turn", now, 0}}); err != nil || r != 0 {
			t.Errorf("%+v: limit 0 = %d, %v, want refused", sc, r, err)
		}
		if n := quotaN(t, pg, a, key, "embed_turn", now); n != 0 {
			t.Errorf("%+v: limit 0 wrote n = %d", sc, n)
		}
	}
}

// TestEmbedBansAndHits: an automatic ban counts only after autoSince, an
// owner's always; a repeat automatic ban restarts its time but never
// rewrites an owner's ban; hits sum the hours of the window. Another
// workspace sees none of it (CONTROL for the tenant_id of every statement,
// operator scope included).
func TestEmbedBansAndHits(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC()
	a, b := newTenant(t, pg), newTenant(t, pg)
	sc, other := EmbedScope{TenantID: a}, EmbedScope{TenantID: b}
	auto, owner := EmbedBanKey("ip", "aa"), EmbedBanKey("visitor", "v1")
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(rt.BanEmbedKey(ctx, sc, auto, EmbedAutoBanBy, now.Add(-2*time.Hour)))
	must(rt.BanEmbedKey(ctx, sc, owner, "HUM-owner", now.Add(-48*time.Hour)))
	banned := func(sc EmbedScope, key string, since time.Time) bool {
		t.Helper()
		got, err := rt.EmbedBanned(ctx, sc, []string{key}, since)
		must(err)
		return got
	}
	if !banned(sc, auto, now.Add(-3*time.Hour)) || banned(sc, auto, now.Add(-time.Hour)) {
		t.Error("an automatic ban must hold after autoSince and lapse before it")
	}
	if !banned(sc, owner, now) {
		t.Error("an owner's ban must hold whatever autoSince")
	}
	if banned(other, auto, time.Time{}) || banned(other, owner, time.Time{}) {
		t.Error("CONTROL: another workspace sees the bans")
	}
	must(rt.BanEmbedKey(ctx, sc, auto, EmbedAutoBanBy, now))
	if !banned(sc, auto, now.Add(-time.Hour)) {
		t.Error("a repeat automatic ban must restart its time")
	}
	must(rt.BanEmbedKey(ctx, sc, owner, EmbedAutoBanBy, now))
	if !banned(sc, owner, now.Add(time.Hour)) {
		t.Error("an automatic ban rewrote an owner's ban")
	}
	key := EmbedIPKey([]byte{1, 2, 3})
	for i, at := range []time.Time{now.Add(-30 * time.Hour), now.Add(-2 * time.Hour), now} {
		n, err := rt.EmbedHit(ctx, sc, key, at, now.Add(-24*time.Hour))
		must(err)
		if want := []int{0, 1, 2}[i]; n != want { // the first hit is outside the window
			t.Errorf("hit %d: %d in the window, want %d", i+1, n, want)
		}
	}
	if n, err := rt.EmbedHits(ctx, other, key, now.Add(-48*time.Hour)); err != nil || n != 0 {
		t.Errorf("CONTROL: another workspace counts %d hits (%v)", n, err)
	}
}

// TestSweepEmbed: the sweep retires an expired visitor's token (hash
// rehashed, ip_hash cleared, once: a second sweep touches nothing), drops
// embed counters older than countsBefore and automatic bans at or before
// bansBefore. CONTROL: a live visitor, a fresh embed counter, a non-embed
// counter of the same age, and an owner's ban of the same age all stay.
func TestSweepEmbed(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	ip := make([]byte, 32)
	mintIP := func(at time.Time) (EmbedVisitor, []byte) {
		h := newTokenHash(t)
		v, err := rt.MintEmbedVisitor(ctx, EmbedVisitorMint{TenantID: a, EmbedID: embed, TokenHash: h, IPHash: ip, Life: testEmbedLife}, at)
		if err != nil {
			t.Fatal(err)
		}
		return v, h
	}
	_, oldHash := mintIP(now.Add(-31 * day))
	live, liveHash := mintIP(now)
	if n, err := rt.EmbedLiveVisitors(ctx, a, embed, now); err != nil || n != 1 {
		t.Fatalf("live visitors = %d, %v, want 1", n, err)
	}
	sc, stale := EmbedScope{TenantID: a}, now.Add(-72*time.Hour).Truncate(time.Hour)
	for _, q := range []EmbedTake{{"k", "embed_post", stale, 9}, {"k", "embed_post", now, 9}, {"k", "post_day", stale, 9}} {
		if r, err := rt.TakeEmbedQuotas(ctx, sc, []EmbedTake{q}); err != nil || r != -1 {
			t.Fatalf("seed %+v: %d %v", q, r, err)
		}
	}
	autoKey, ownerKey := EmbedBanKey("ip", "old"), EmbedBanKey("visitor", "old")
	for k, by := range map[string]string{autoKey: EmbedAutoBanBy, ownerKey: "HUM-owner"} {
		if err := rt.BanEmbedKey(ctx, sc, k, by, now.Add(-25*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	out, err := rt.SweepEmbed(ctx, now, now.Add(-48*time.Hour), now.Add(-24*time.Hour))
	if err != nil || out.Tokens != 1 || out.Counts < 1 || out.Bans < 1 {
		t.Fatalf("sweep = %+v, %v; want 1 token, >= 1 count, >= 1 ban", out, err)
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, oldHash, now.Add(-day)); err == nil {
		t.Error("the swept token still names its visitor (in its own lifetime)")
	}
	if got, err := rt.EmbedVisitorByToken(ctx, embed, liveHash, now); err != nil || got.VisitorID != live.VisitorID {
		t.Errorf("CONTROL: the live token: %+v %v", got, err)
	}
	if n := quotaN(t, pg, a, "k", "embed_post", stale); n != 0 {
		t.Errorf("a stale embed counter stayed: %d", n)
	}
	if quotaN(t, pg, a, "k", "embed_post", now) != 1 || quotaN(t, pg, a, "k", "post_day", stale) != 1 {
		t.Error("CONTROL: a fresh embed counter or a non-embed counter was dropped")
	}
	if b, _ := rt.EmbedBanned(ctx, sc, []string{autoKey}, time.Time{}); b {
		t.Error("a lapsed automatic ban stayed")
	}
	if b, _ := rt.EmbedBanned(ctx, sc, []string{ownerKey}, now); !b {
		t.Error("CONTROL: the owner's ban was dropped")
	}
	if again, err := rt.SweepEmbed(ctx, now, now.Add(-48*time.Hour), now.Add(-24*time.Hour)); err != nil || again.Tokens != 0 {
		t.Errorf("a second sweep = %+v, %v; want no token (each is retired once)", again, err)
	}
}
