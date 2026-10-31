package store

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 090 T035 / SPL-4496: disconnecting a channel on Postgres, under RLS.
// Another tenant deletes nothing; an Instagram account goes alone; a
// Facebook Page takes its linked Instagram account (metadata page_id) with
// it, tokens and posts included; the events stay (append-only).

func connectMktChannel(ctx context.Context, t *testing.T, pg *Postgres, tenant, platform, ref, page string) MarketingChannel {
	t.Helper()
	ch, err := pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: tenant, Platform: platform, AccountRef: ref,
		AccountName: ref, DelegatedBy: "HUM-1", Metadata: map[string]any{"page_id": page}},
		MarketingToken{Ciphertext: "v1.sealed." + ref, KMSKeyID: "kms/key/1"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

func TestMarketingDisconnectCascadesUnderRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := mktTenant(t, pg), mktTenant(t, pg)
	li := connectMktChannel(ctx, t, pg, a, MarketingPlatformLinkedIn, "member-"+a, "")
	page := connectMktChannel(ctx, t, pg, a, MarketingPlatformFacebook, "1001", "1001")
	ig := connectMktChannel(ctx, t, pg, a, MarketingPlatformIG, "17841", "1001")
	page2 := connectMktChannel(ctx, t, pg, a, MarketingPlatformFacebook, "2002", "2002")
	ig2 := connectMktChannel(ctx, t, pg, a, MarketingPlatformIG, "27841", "2002")
	for _, ch := range []MarketingChannel{page, ig} {
		if _, err := pg.ScheduleMarketingPost(ctx, MarketingPost{Tenant: a, ChannelID: ch.ID, SourceType: MarketingSourceBlog,
			SourceRef: "2026-10-30-hello"}, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pg.DisconnectMarketingChannel(ctx, b, page.ID); err != ErrNotFound {
		t.Fatalf("B disconnects A's Page: %v, want ErrNotFound", err)
	}
	if _, err := pg.DisconnectMarketingChannel(ctx, a, "00000000-0000-4000-8000-000000000000"); err != ErrNotFound {
		t.Fatalf("unknown channel: %v, want ErrNotFound", err)
	}
	if ids, err := pg.DisconnectMarketingChannel(ctx, a, ig2.ID); err != nil || !slices.Equal(ids, []string{ig2.ID}) {
		t.Fatalf("disconnect Instagram alone = %v, %v; want [%s]", ids, err, ig2.ID)
	}
	ids, err := pg.DisconnectMarketingChannel(ctx, a, page.ID)
	if err != nil || !slices.Equal(ids, []string{page.ID, ig.ID}) {
		t.Fatalf("disconnect Page = %v, %v; want [%s %s]", ids, err, page.ID, ig.ID)
	}
	for _, ch := range []MarketingChannel{page, ig, ig2} {
		if _, err := pg.MarketingToken(ctx, a, ch.ID); err != ErrNotFound {
			t.Fatalf("%s token after the disconnect: %v", ch.AccountRef, err)
		}
	}
	chs, err := pg.MarketingChannels(ctx, a)
	if err != nil || len(chs) != 2 || chs[0].ID != li.ID || chs[1].ID != page2.ID {
		t.Fatalf("A keeps %+v, %v; want LinkedIn and Page 2002", chs, err)
	}
	var posts, events int
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM marketing_posts WHERE channel_id = ANY($1::uuid[])`, ids).Scan(&posts); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM marketing_post_events WHERE channel_id = ANY($1::uuid[])`, ids).Scan(&events)
	}); err != nil || posts != 0 || events == 0 {
		t.Fatalf("after the disconnect: %d posts (want 0), %d events (want kept), %v", posts, events, err)
	}
}
