package store

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// SPL-4564 (spec 090 T034 follow-ups, review notes N2, N3, N5, N7): the
// Meta channel's cap is read and its posts claimed under one lock, a post
// in flight counting; a post the cap holds back is never claimed; a stuck
// post's failure text names its platform; the LinkedIn sweep's channel list
// never names a Meta channel. Each case runs on Postgres and on Memory.

type mktCapStore interface {
	Marketing
	MarketingMetaDispatch
}

// mktCapStores is the Memory store, plus Postgres when SPOOL_TEST_PG_DSN is
// set, each with one fresh tenant.
func mktCapStores(t *testing.T) map[string]func(t *testing.T) (mktCapStore, string) {
	return map[string]func(t *testing.T) (mktCapStore, string){
		"memory": func(t *testing.T) (mktCapStore, string) {
			m := NewMemory()
			if err := m.CreateTenant(context.Background(), Tenant{ID: "t-cap", RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			return m, "t-cap"
		},
		"postgres": func(t *testing.T) (mktCapStore, string) {
			pg := rlsStore(t)
			return pg, mktTenant(t, pg)
		},
	}
}

func mktCapChannel(t *testing.T, st mktCapStore, tenant, platform string, auto bool) MarketingChannel {
	t.Helper()
	ch, err := st.ConnectMarketingChannel(context.Background(), MarketingChannel{Tenant: tenant, Platform: platform,
		AccountType: map[string]string{MarketingPlatformLinkedIn: "personal", MarketingPlatformFacebook: "page",
			MarketingPlatformIG: "business"}[platform],
		AccountRef: platform + "-" + tenant, AccountName: "Example", DelegatedBy: "HUM-1", AutoPublish: auto},
		MarketingToken{Ciphertext: "v1.sealed", KMSKeyID: "kms/key/1"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

func mktCapPost(t *testing.T, st mktCapStore, ch MarketingChannel, ref string, now time.Time) MarketingPost {
	t.Helper()
	ctx := context.Background()
	if _, err := st.ScheduleMarketingPost(ctx, MarketingPost{Tenant: ch.Tenant, ChannelID: ch.ID, SourceType: MarketingSourceBlog,
		SourceRef: ref}, now); err != nil {
		t.Fatal(err)
	}
	p, err := st.MarketingPostByRef(ctx, ch.Tenant, ch.ID, MarketingSourceBlog, ref)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// N2 + N3: a post in flight takes the cap's one place; the next claim takes
// nothing, spends no attempt and says when the window frees.
func TestMarketingMetaCapCountsInFlight(t *testing.T) {
	for name, open := range mktCapStores(t) {
		t.Run(name, func(t *testing.T) {
			st, tn := open(t)
			ctx := context.Background()
			ch := mktCapChannel(t, st, tn, MarketingPlatformFacebook, false)
			now := time.Now().UTC().Truncate(time.Second)
			a := mktCapPost(t, st, ch, "2026-11-01-a", now.Add(-time.Minute))
			b := mktCapPost(t, st, ch, "2026-11-01-b", now)
			claim := MetaClaim{Tenant: tn, ChannelID: ch.ID, PostID: a.ID, Limit: 1, Window: 24 * time.Hour, Now: now}
			got, err := st.ClaimMetaMarketingPosts(ctx, claim)
			if err != nil || len(got.Posts) != 1 || got.Posts[0].ID != a.ID || got.Held {
				t.Fatalf("first claim = %+v, %v; want post a, nothing held", got, err)
			}
			claim.PostID = b.ID
			got, err = st.ClaimMetaMarketingPosts(ctx, claim)
			if err != nil || len(got.Posts) != 0 || !got.Held || !got.FreeAt.Equal(now.Add(24*time.Hour)) {
				t.Fatalf("claim while a is in flight = %+v, %v; want none, held until %s", got, err, now.Add(24*time.Hour))
			}
			claim.PostID = ""
			if got, err = st.ClaimMetaMarketingPosts(ctx, claim); err != nil || len(got.Posts) != 0 || !got.Held {
				t.Fatalf("sweep claim while a is in flight = %+v, %v; want none, held", got, err)
			}
			if p, _ := st.MarketingPostByRef(ctx, tn, ch.ID, MarketingSourceBlog, "2026-11-01-b"); p.Status != MarketingScheduled || p.Attempts != 0 {
				t.Fatalf("held post b = %+v; want scheduled, no attempt spent", p)
			}
			// a is published: it still holds the place for 24 h; then b goes
			if err := st.FinishMarketingPost(ctx, tn, a.ID, MarketingOutcome{Published: true, PlatformPostID: "1001_1"}, now); err != nil {
				t.Fatal(err)
			}
			claim.Now = now.Add(24*time.Hour + time.Second)
			if got, err = st.ClaimMetaMarketingPosts(ctx, claim); err != nil || len(got.Posts) != 1 || got.Posts[0].ID != b.ID || got.Posts[0].Attempts != 1 {
				t.Fatalf("claim after the window = %+v, %v; want b on its first attempt", got, err)
			}
		})
	}
}

// N2: racing capped claims of different posts on one channel take one
// place between them, never two.
func TestMarketingMetaCapClaimRace(t *testing.T) {
	for name, open := range mktCapStores(t) {
		t.Run(name, func(t *testing.T) {
			st, tn := open(t)
			ch := mktCapChannel(t, st, tn, MarketingPlatformFacebook, false)
			now := time.Now().UTC()
			var ids []string
			for _, ref := range []string{"r1", "r2", "r3", "r4", "r5", "r6"} {
				ids = append(ids, mktCapPost(t, st, ch, ref, now).ID)
			}
			var wg sync.WaitGroup
			var mu sync.Mutex
			claimed := 0
			for i, id := range ids {
				wg.Add(1)
				go func() {
					defer wg.Done()
					c := MetaClaim{Tenant: tn, ChannelID: ch.ID, PostID: id, Limit: 1, Window: 24 * time.Hour, Now: now}
					if i%2 == 1 {
						c.PostID = "" // the sweep's claim races the publishes
					}
					got, err := st.ClaimMetaMarketingPosts(context.Background(), c)
					if err != nil {
						t.Error(err)
					}
					mu.Lock()
					claimed += len(got.Posts)
					mu.Unlock()
				}()
			}
			wg.Wait()
			if claimed != 1 {
				t.Fatalf("racing claims took %d places, want 1 (cap 1)", claimed)
			}
		})
	}
}

// N5: a post stuck in dispatching fails with a text that names its own
// channel's platform (it reaches the holder's mail).
func TestMarketingStuckNamesPlatform(t *testing.T) {
	for name, open := range mktCapStores(t) {
		t.Run(name, func(t *testing.T) {
			st, tn := open(t)
			ctx := context.Background()
			then := time.Now().UTC().Add(-time.Hour)
			want := map[string]string{}
			for _, pl := range []string{MarketingPlatformLinkedIn, MarketingPlatformFacebook, MarketingPlatformIG} {
				ch := mktCapChannel(t, st, tn, pl, false)
				mktCapPost(t, st, ch, "stuck-"+pl, then)
				if ps, err := st.ClaimMarketingPosts(ctx, tn, ch.ID, then); err != nil || len(ps) != 1 {
					t.Fatalf("claim on %s: %+v, %v", pl, ps, err)
				}
				want[ch.ID] = map[string]string{MarketingPlatformLinkedIn: "LinkedIn", MarketingPlatformFacebook: "Facebook",
					MarketingPlatformIG: "Instagram"}[pl]
			}
			stuck, err := st.StuckMarketingPosts(ctx, time.Now().UTC().Add(-15*time.Minute), time.Now().UTC())
			var mine []MarketingPost
			for _, p := range stuck {
				if p.Tenant == tn {
					mine = append(mine, p)
				}
			}
			if err != nil || len(mine) != 3 {
				t.Fatalf("stuck = %+v, %v; want 3 of this tenant", mine, err)
			}
			for _, p := range mine {
				if w := "during the " + want[p.ChannelID] + " call"; !strings.Contains(p.LastError, w) || p.Status != MarketingFailed {
					t.Errorf("stuck post on %s: %q (%s), want %q", want[p.ChannelID], p.LastError, p.Status, w)
				}
			}
		})
	}
}

// N7: an auto_publish Meta channel never reaches the LinkedIn sweep's list.
func TestMarketingAutoChannelsLinkedInOnly(t *testing.T) {
	for name, open := range mktCapStores(t) {
		t.Run(name, func(t *testing.T) {
			st, tn := open(t)
			li := mktCapChannel(t, st, tn, MarketingPlatformLinkedIn, true)
			mktCapChannel(t, st, tn, MarketingPlatformFacebook, true)
			mktCapChannel(t, st, tn, MarketingPlatformIG, true)
			chs, err := st.AutoMarketingChannels(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			var mine []string
			for _, c := range chs {
				if c.Tenant == tn {
					mine = append(mine, c.Platform)
				}
			}
			if len(mine) != 1 || mine[0] != MarketingPlatformLinkedIn || li.Platform != MarketingPlatformLinkedIn {
				t.Fatalf("auto channels of the tenant = %v, want [linkedin] only", mine)
			}
		})
	}
}
