package store

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 090 T031 / SPL-3873 (rdb 0236): Facebook Page and Instagram channels
// with their metadata, a post's media assets, and the approval hold. Every
// case runs on Postgres; on the 0187 schema alone (red control) the Meta
// platforms, the held status and the new columns are all refused.

func connectMeta(ctx context.Context, pg *Postgres, tenant, platform, accountType string) (MarketingChannel, error) {
	return pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: tenant, Platform: platform, AccountType: accountType,
		AccountRef: platform + "-" + tenant, AccountName: "Example Page", DelegatedBy: "HUM-1",
		Metadata: map[string]any{"page_id": "1001", "username": "example"}},
		MarketingToken{Ciphertext: "v1.sealed.meta." + tenant, KMSKeyID: "kms/key/1"}, time.Now().UTC())
}

func TestMarketingMetaChannelsRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := mktTenant(t, pg), mktTenant(t, pg)
	fb, err := connectMeta(ctx, pg, a, MarketingPlatformFacebook, "page")
	if err != nil {
		t.Fatalf("facebook_page channel: %v", err)
	}
	ig, err := connectMeta(ctx, pg, a, MarketingPlatformIG, "business")
	if err != nil {
		t.Fatalf("instagram_business channel: %v", err)
	}
	if fb.AccountType != "page" || ig.AccountType != "business" || fb.Metadata["page_id"] != "1001" || ig.Metadata["username"] != "example" {
		t.Fatalf("read back fb=%+v ig=%+v", fb, ig)
	}
	// a LinkedIn connect that names no type or metadata keeps the 0187 defaults
	li, err := pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: a, Platform: MarketingPlatformLinkedIn, AccountRef: "member-" + a,
		DelegatedBy: "HUM-1"}, MarketingToken{Ciphertext: "v1.li", KMSKeyID: "kms/key/1"}, time.Now().UTC())
	if err != nil || li.AccountType != "personal" || li.Metadata == nil || len(li.Metadata) != 0 {
		t.Fatalf("linkedin defaults = %+v, %v", li, err)
	}
	if chs, err := pg.MarketingChannels(ctx, a); err != nil || len(chs) != 3 {
		t.Fatalf("A lists %d channels, %v; want 3", len(chs), err)
	}
	// tenant B sees none of A's Meta channels and none of their tokens
	if chs, err := pg.MarketingChannels(ctx, b); err != nil || len(chs) != 0 {
		t.Fatalf("B lists %d of A's channels, %v", len(chs), err)
	}
	for _, ch := range []MarketingChannel{fb, ig} {
		if _, err := pg.MarketingToken(ctx, b, ch.ID); err != ErrNotFound {
			t.Fatalf("B read A's %s token: %v", ch.Platform, err)
		}
	}
	var n int
	if err := pg.inTenant(ctx, b, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM marketing_channel_tokens WHERE channel_id = ANY($1::uuid[])`,
			[]string{fb.ID, ig.ID}).Scan(&n)
	}); err != nil || n != 0 {
		t.Fatalf("B's raw read of A's Meta tokens = %d rows, %v; want 0", n, err)
	}
	if _, err := pg.MarketingToken(ctx, a, ig.ID); err != nil {
		t.Fatalf("control: A reads its own Instagram token: %v", err)
	}
}

func TestMarketingMetaApprovalHold(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := connectMeta(ctx, pg, tn, MarketingPlatformIG, "business")
	if err != nil {
		t.Fatal(err)
	}
	media := []MarketingMediaAsset{{URL: "https://example.com/a.png", Width: 1080, Height: 1350, AspectRatio: 0.8, Selected: true},
		{URL: "https://example.com/b.png", Width: 1080, Height: 1080, AspectRatio: 1}}
	now := time.Now().UTC()
	made, err := pg.ScheduleMarketingPost(ctx, MarketingPost{Tenant: tn, ChannelID: ch.ID, SourceType: MarketingSourceBlog,
		SourceRef: "2026-10-27-held", Status: MarketingAwaitingApproval, MediaAssets: media}, now)
	if err != nil || !made {
		t.Fatalf("hold = %v, %v", made, err)
	}
	if ps, err := pg.ClaimMarketingPosts(ctx, tn, ch.ID, now.Add(time.Hour)); err != nil || len(ps) != 0 {
		t.Fatalf("a held post was claimed: %+v, %v", ps, err)
	}
	var id string
	if err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT post_id::text FROM marketing_posts WHERE channel_id = $1::uuid AND status = 'awaiting_approval'`, ch.ID).Scan(&id)
	}); err != nil {
		t.Fatalf("held row: %v", err)
	}
	other := mktTenant(t, pg)
	if err := pg.ApproveMarketingPost(ctx, other, id, "HUM-9", now); err != ErrNotFound {
		t.Fatalf("another tenant approved it: %v", err)
	}
	if err := pg.ApproveMarketingPost(ctx, tn, id, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	if err := pg.ApproveMarketingPost(ctx, tn, id, "HUM-1", now); err != ErrNotFound {
		t.Fatalf("second approve = %v, want ErrNotFound", err)
	}
	ps, err := pg.ClaimMarketingPosts(ctx, tn, ch.ID, now)
	if err != nil || len(ps) != 1 || ps[0].ID != id {
		t.Fatalf("claim after approve = %+v, %v; want the post once", ps, err)
	}
	if got := ps[0].MediaAssets; len(got) != 2 || got[0] != media[0] || got[1] != media[1] {
		t.Fatalf("media assets read back %+v, want %+v", got, media)
	}
	assertMktEvents(t, pg, tn, id, "post_held", "post_approved", "post_dispatched")
}

func TestMarketingMetaHandOver(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := connectMeta(ctx, pg, tn, MarketingPlatformFacebook, "page")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if _, err := pg.ScheduleMarketingPost(ctx, MarketingPost{Tenant: tn, ChannelID: ch.ID, SourceType: MarketingSourceBlog,
		SourceRef: "2026-10-27-hand", Status: MarketingAwaitingApproval}, now); err != nil {
		t.Fatal(err)
	}
	var id string
	if err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT post_id::text FROM marketing_posts WHERE channel_id = $1::uuid`, ch.ID).Scan(&id)
	}); err != nil {
		t.Fatal(err)
	}
	if err := pg.HandOverMarketingPost(ctx, tn, id, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	if err := pg.HandOverMarketingPost(ctx, tn, id, "HUM-1", now); err != ErrNotFound {
		t.Fatalf("second hand over = %v, want ErrNotFound", err)
	}
	var status, ppid string
	if err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT status, platform_post_id FROM marketing_posts WHERE post_id = $1::uuid`, id).Scan(&status, &ppid)
	}); err != nil || status != MarketingPublished || ppid != MarketingManualPostID {
		t.Fatalf("handed over row = %s %s, %v", status, ppid, err)
	}
	assertMktEvents(t, pg, tn, id, "post_held", "post_handed_over")
}

// SPL-4477: the publish that approved a post claims it even while a racing
// transaction (a losing approve) holds the row's lock; the sweep's claim
// (SKIP LOCKED) skips it then, and on the old code so did the publish, which
// answered 200 and posted nothing until the next sweep.
func TestMarketingMetaClaimOneWaitsForLock(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	ch, err := connectMeta(ctx, pg, tn, MarketingPlatformFacebook, "page")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if _, err := pg.ScheduleMarketingPost(ctx, MarketingPost{Tenant: tn, ChannelID: ch.ID, SourceType: MarketingSourceBlog,
		SourceRef: "2026-10-31-race", Status: MarketingAwaitingApproval}, now); err != nil {
		t.Fatal(err)
	}
	p, err := pg.MarketingPostByRef(ctx, tn, ch.ID, MarketingSourceBlog, "2026-10-31-race")
	if err != nil {
		t.Fatal(err)
	}
	if err := pg.ApproveMarketingPost(ctx, tn, p.ID, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	locked, release, held := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	var unlock sync.Once
	free := func() { unlock.Do(func() { close(release) }) }
	t.Cleanup(free) // a failed case still ends the lock holder's transaction
	go func() {
		held <- pg.inTenant(ctx, tn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT 1 FROM marketing_posts WHERE post_id = $1::uuid FOR UPDATE`, p.ID); err != nil {
				return err
			}
			close(locked)
			<-release
			return nil
		})
	}()
	<-locked
	if ps, err := pg.ClaimMarketingPosts(ctx, tn, ch.ID, now); err != nil || len(ps) != 0 {
		t.Fatalf("the sweep's claim took a locked row: %+v, %v", ps, err)
	}
	type claimed struct {
		ps  []MarketingPost
		err error
	}
	done := make(chan claimed, 1)
	go func() {
		ps, err := pg.ClaimMarketingPost(ctx, tn, p.ID, now)
		done <- claimed{ps, err}
	}()
	waitLockWaiter(t, pg, done)
	free()
	if err := <-held; err != nil {
		t.Fatal(err)
	}
	if c := <-done; c.err != nil || len(c.ps) != 1 || c.ps[0].ID != p.ID || c.ps[0].Status != MarketingDispatching || c.ps[0].Attempts != 1 {
		t.Fatalf("claim after the lock = %+v, %v; want the post once", c.ps, c.err)
	}
	if ps, err := pg.ClaimMarketingPost(ctx, tn, p.ID, now); err != nil || len(ps) != 0 {
		t.Fatalf("second claim = %+v, %v; want none", ps, err)
	}
	assertMktEvents(t, pg, tn, p.ID, "post_held", "post_approved", "post_dispatched")
}

// waitLockWaiter returns once a ClaimMarketingPost waits on a row lock; it
// fails when the claim returns first (it skipped the locked row).
func waitLockWaiter[T any](t *testing.T, pg *Postgres, done chan T) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case c := <-done:
			t.Fatalf("the claim returned while the row was locked: %+v", c)
		default:
		}
		var n int
		if err := pg.Pool().QueryRow(context.Background(), `SELECT count(*) FROM pg_stat_activity
			WHERE wait_event_type = 'Lock' AND query LIKE '%post_id = $2::uuid AND status = ''scheduled''%'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the claim never waited on the row lock")
}

func TestMarketingMetaChecksRefuse(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := mktTenant(t, pg)
	if _, err := connectMeta(ctx, pg, tn, "tiktok", "page"); err == nil || !strings.Contains(err.Error(), "platform_check") {
		t.Errorf("unknown platform: %v, want the platform CHECK", err)
	}
	ch, err := connectMeta(ctx, pg, tn, MarketingPlatformFacebook, "page")
	if err != nil {
		t.Fatal(err)
	}
	for q, want := range map[string]string{
		`UPDATE marketing_channels SET metadata = '[]'::jsonb WHERE channel_id = $1::uuid`: "metadata_object",
		`UPDATE marketing_channels SET account_type = 'group' WHERE channel_id = $1::uuid`: "account_type_check",
		`INSERT INTO marketing_posts (tenant_id, channel_id, source_type, source_ref, status, media_assets)
			SELECT tenant_id, channel_id, 'blog', 'x', 'held', '[]' FROM marketing_channels WHERE channel_id = $1::uuid`: "status_check",
		`INSERT INTO marketing_posts (tenant_id, channel_id, source_type, source_ref, status, media_assets)
			SELECT tenant_id, channel_id, 'blog', 'y', 'scheduled', '{}' FROM marketing_channels WHERE channel_id = $1::uuid`: "media_assets_array",
	} {
		err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, q, ch.ID); return err })
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v, want %s", q, err, want)
		}
	}
}

// assertMktEvents checks the post's audit trail, in order.
func assertMktEvents(t *testing.T, pg *Postgres, tenant, postID string, want ...string) {
	t.Helper()
	var got []string
	err := pg.inTenant(context.Background(), tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(context.Background(), `SELECT event_type FROM marketing_post_events WHERE post_id = $1::uuid ORDER BY event_id`, postID)
		if err != nil {
			return err
		}
		return scanRows(rows, func(r pgx.Rows) error {
			var e string
			err := r.Scan(&e)
			got = append(got, e)
			return err
		})
	})
	if err != nil || strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("events = %v, %v; want %v", got, err, want)
	}
}

// The Memory store keeps the same hold (hub tests run on it).
func TestMarketingMetaMemoryHold(t *testing.T) {
	m := NewMemory()
	ctx := context.Background()
	if err := m.CreateTenant(ctx, Tenant{ID: "t-mem", RootPubKey: pubkey()}); err != nil {
		t.Fatal(err)
	}
	ch, err := m.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: "t-mem", Platform: MarketingPlatformIG, AccountType: "business",
		AccountRef: "ig-1"}, MarketingToken{Ciphertext: "v1.x"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if _, err := m.ScheduleMarketingPost(ctx, MarketingPost{Tenant: "t-mem", ChannelID: ch.ID, SourceType: MarketingSourceBlog,
		SourceRef: "held", Status: MarketingAwaitingApproval}, now); err != nil {
		t.Fatal(err)
	}
	if ps, _ := m.ClaimMarketingPosts(ctx, "t-mem", ch.ID, now); len(ps) != 0 {
		t.Fatalf("memory claimed a held post: %+v", ps)
	}
	id := m.MarketingPostsOf(ch.ID)[0].ID
	if err := m.ApproveMarketingPost(ctx, "t-mem", id, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	if ps, _ := m.ClaimMarketingPosts(ctx, "t-mem", ch.ID, now); len(ps) != 1 {
		t.Fatalf("memory claim after approve = %+v, want 1", ps)
	}
	if err := m.HandOverMarketingPost(ctx, "t-mem", id, "HUM-1", now); err != ErrNotFound {
		t.Fatalf("hand over of a dispatching post = %v, want ErrNotFound", err)
	}
}
