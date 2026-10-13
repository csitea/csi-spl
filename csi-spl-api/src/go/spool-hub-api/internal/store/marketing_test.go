package store

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 090 / SPL-1634 (rdb 0187): the connected-account store on Postgres.
// The core proof is idempotence: a blog post is scheduled once per channel,
// and claimed by exactly one of two racing sweeps.

// seedMarketing connects one LinkedIn channel in tenant and schedules one
// post on it: a row in each of the four rdb 0187 tables.
func seedMarketing(ctx context.Context, pg *Postgres, tenant string) (MarketingChannel, error) {
	exp := time.Now().UTC().Add(60 * 24 * time.Hour)
	ch, err := pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: tenant, Platform: "linkedin",
		AccountRef: "member-" + tenant, AccountName: "FirstName LastName", DelegatedBy: "HUM-1", AutoPublish: true,
		ExpiresAt: &exp}, MarketingToken{Ciphertext: "v1.sealed." + tenant, KMSKeyID: "kms/key/1"}, time.Now().UTC())
	if err != nil {
		return ch, err
	}
	_, err = pg.ScheduleMarketingPost(ctx, MarketingPost{Tenant: tenant, ChannelID: ch.ID, SourceType: MarketingSourceBlog,
		SourceRef: "2026-10-13-seed"}, time.Now().UTC())
	return ch, err
}

func mktTenant(t *testing.T, pg *Postgres) string {
	t.Helper()
	id := uid("t-")
	if err := pg.CreateTenant(context.Background(), Tenant{ID: id, RootPubKey: pubkey()}); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestMarketingConnectUpsertsOneChannel(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	a, err := seedMarketing(ctx, pg, tn)
	if err != nil {
		t.Fatal(err)
	}
	// a re-connect of the same LinkedIn member renews the same row and token
	b, err := pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: tn, Platform: "linkedin", AccountRef: a.AccountRef,
		DelegatedBy: "HUM-1", AutoPublish: true}, MarketingToken{Ciphertext: "v1.renewed", KMSKeyID: "kms/key/2"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if b.ID != a.ID {
		t.Fatalf("re-connect made a second channel %s, want %s", b.ID, a.ID)
	}
	tok, err := pg.MarketingToken(ctx, tn, a.ID)
	if err != nil || tok.Ciphertext != "v1.renewed" || tok.KMSKeyID != "kms/key/2" {
		t.Fatalf("token after re-connect = %+v, %v", tok, err)
	}
	chs, err := pg.MarketingChannels(ctx, tn)
	if err != nil || len(chs) != 1 {
		t.Fatalf("channels = %d, %v; want 1", len(chs), err)
	}
}

func TestMarketingScheduleIsOncePerSource(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := seedMarketing(ctx, pg, tn)
	if err != nil {
		t.Fatal(err)
	}
	p := MarketingPost{Tenant: tn, ChannelID: ch.ID, SourceType: MarketingSourceBlog, SourceRef: "2026-10-14-new"}
	for i, want := range []bool{true, false} {
		made, err := pg.ScheduleMarketingPost(ctx, p, time.Now().UTC())
		if err != nil || made != want {
			t.Fatalf("schedule #%d = %v, %v; want %v", i+1, made, err, want)
		}
	}
	// the seed's post is already there: scheduling it again changes nothing
	if made, err := pg.ScheduleMarketingPost(ctx, MarketingPost{Tenant: tn, ChannelID: ch.ID, SourceType: MarketingSourceBlog,
		SourceRef: "2026-10-13-seed"}, time.Now().UTC()); err != nil || made {
		t.Fatalf("re-schedule of the seed = %v, %v; want false", made, err)
	}
}

func TestMarketingTwoClaimsGetThePostOnce(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := seedMarketing(ctx, pg, tn)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var got []MarketingPost
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ps, err := pg.ClaimMarketingPosts(ctx, tn, ch.ID, time.Now().UTC())
			if err != nil {
				t.Error(err)
			}
			mu.Lock()
			got = append(got, ps...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	if len(got) != 1 || got[0].Status != MarketingDispatching || got[0].Attempts != 1 {
		t.Fatalf("4 racing claims got %+v, want the one post once", got)
	}
}

func TestMarketingRetryThenPublish(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := seedMarketing(ctx, pg, tn)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	ps, _ := pg.ClaimMarketingPosts(ctx, tn, ch.ID, now)
	if len(ps) != 1 {
		t.Fatalf("claim = %d", len(ps))
	}
	if err := pg.FinishMarketingPost(ctx, tn, ps[0].ID, MarketingOutcome{Retry: true, RetryAt: now.Add(time.Minute), Error: "HTTP 503"}, now); err != nil {
		t.Fatal(err)
	}
	if again, _ := pg.ClaimMarketingPosts(ctx, tn, ch.ID, now); len(again) != 0 {
		t.Fatalf("claimed %d before the retry time", len(again))
	}
	ps, _ = pg.ClaimMarketingPosts(ctx, tn, ch.ID, now.Add(2*time.Minute))
	if len(ps) != 1 || ps[0].Attempts != 2 {
		t.Fatalf("retry claim = %+v", ps)
	}
	if err := pg.FinishMarketingPost(ctx, tn, ps[0].ID, MarketingOutcome{Published: true, PlatformPostID: "urn:li:share:1"}, now); err != nil {
		t.Fatal(err)
	}
	// a settled post is never settled again
	if err := pg.FinishMarketingPost(ctx, tn, ps[0].ID, MarketingOutcome{Published: true}, now); err != ErrNotFound {
		t.Fatalf("second finish = %v, want ErrNotFound", err)
	}
}

func TestMarketingStuckPostIsFailedNotRetried(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := seedMarketing(ctx, pg, tn)
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Now().UTC()
	if ps, _ := pg.ClaimMarketingPosts(ctx, tn, ch.ID, t0); len(ps) != 1 {
		t.Fatal("no claim")
	}
	stuck, err := pg.StuckMarketingPosts(ctx, t0.Add(time.Minute), t0.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, p := range stuck {
		found = found || p.ChannelID == ch.ID
	}
	if !found {
		t.Fatalf("stuck = %+v, want this channel's post", stuck)
	}
	if ps, _ := pg.ClaimMarketingPosts(ctx, tn, ch.ID, t0.Add(2*time.Hour)); len(ps) != 0 {
		t.Fatalf("a stuck post was claimed again: %+v", ps)
	}
}

func TestMarketingBaselineSkipsOnce(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := seedMarketing(ctx, pg, tn)
	if err != nil {
		t.Fatal(err)
	}
	refs := []string{"2026-10-01-a", "2026-10-02-b", "2026-10-13-seed"}
	for range 2 {
		if err := pg.BaselineMarketingPosts(ctx, tn, ch.ID, refs, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	have, err := pg.MarketingPostRefs(ctx, tn, ch.ID)
	if err != nil || len(have) != 3 {
		t.Fatalf("refs = %v, %v; want 3", have, err)
	}
	chs, _ := pg.MarketingChannels(ctx, tn)
	if len(chs) != 1 || chs[0].BaselineAt == nil {
		t.Fatalf("baseline_at not set: %+v", chs)
	}
}

func TestMarketingReminderOnce(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := seedMarketing(ctx, pg, tn)
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range []bool{true, false} {
		won, err := pg.MarkMarketingReminded(ctx, tn, ch.ID, time.Now().UTC())
		if err != nil || won != want {
			t.Fatalf("remind #%d = %v, %v; want %v", i+1, won, err, want)
		}
	}
}

func TestMarketingTokenIsTenantScoped(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := mktTenant(t, pg), mktTenant(t, pg)
	ch, err := seedMarketing(ctx, pg, a)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pg.MarketingToken(ctx, b, ch.ID); err != ErrNotFound {
		t.Fatalf("B read A's token: %v", err)
	}
	if _, err := pg.MarketingToken(ctx, a, ch.ID); err != nil {
		t.Fatalf("control: A reads its own token: %v", err)
	}
}

func TestMarketingEventsAppendOnly(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	if _, err := seedMarketing(ctx, pg, tn); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{`UPDATE marketing_post_events SET actor_id = 'x'`, `DELETE FROM marketing_post_events`} {
		err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, q); return err })
		if err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("%s: %v, want the append-only refusal", q, err)
		}
	}
}
