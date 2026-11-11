package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Spec 090 section 22 / SPL-5240 (rdb 0274): the workspace's own posts on
// Postgres. A draft is edited and deleted until its first publish, its
// publishes are marketing_posts rows of source 'draft', and another
// workspace never reads or changes it.

// draftStores runs fn on the Postgres store (when SPOOL_TEST_PG_DSN is
// set) and on the Memory store, each with two fresh workspaces.
func draftStores(t *testing.T, fn func(t *testing.T, st interface {
	MarketingDrafts
	Marketing
}, a, b string)) {
	t.Run("memory", func(t *testing.T) {
		m := NewMemory()
		for _, id := range []string{"t-a", "t-b"} {
			if err := m.CreateTenant(context.Background(), Tenant{ID: id, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
		}
		fn(t, m, "t-a", "t-b")
	})
	t.Run("postgres", func(t *testing.T) {
		pg := rlsStore(t)
		fn(t, pg, mktTenant(t, pg), mktTenant(t, pg))
	})
}

func TestMarketingDraftLifecycle(t *testing.T) {
	draftStores(t, func(t *testing.T, st interface {
		MarketingDrafts
		Marketing
	}, a, _ string) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Microsecond)
		d, err := st.CreateMarketingDraft(ctx, MarketingDraft{Tenant: a, AuthorID: "HUM-1", Body: "first text"}, now)
		if err != nil || d.ID == "" || d.Body != "first text" || d.PublishedAt != nil || len(d.Posts) != 0 {
			t.Fatalf("create = %+v, %v", d, err)
		}
		d.Body, d.ImageURL = "second text", "https://example.com/a.jpg"
		got, err := st.UpdateMarketingDraft(ctx, d, now.Add(time.Minute))
		if err != nil || got.Body != "second text" || got.ImageURL != "https://example.com/a.jpg" || !got.UpdatedAt.After(got.CreatedAt) {
			t.Fatalf("update = %+v, %v", got, err)
		}
		// a publish on one channel: the row of source 'draft' is listed with the draft
		ch, err := st.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: a, Platform: MarketingPlatformLinkedIn, AccountRef: "m-" + a,
			DelegatedBy: "HUM-1"}, MarketingToken{Ciphertext: "v1.sealed", KMSKeyID: "k"}, now)
		if err != nil {
			t.Fatal(err)
		}
		if made, err := st.ScheduleMarketingPost(ctx, MarketingPost{Tenant: a, ChannelID: ch.ID, SourceType: MarketingSourceDraft,
			SourceRef: d.ID, ContentText: got.Body}, now); err != nil || !made {
			t.Fatalf("schedule draft = %v, %v", made, err)
		}
		if err := st.MarkMarketingDraftPublished(ctx, a, d.ID, now.Add(2*time.Minute)); err != nil {
			t.Fatal(err)
		}
		list, err := st.MarketingDrafts(ctx, a)
		if err != nil || len(list) != 1 || list[0].PublishedAt == nil || len(list[0].Posts) != 1 ||
			list[0].Posts[0].ChannelID != ch.ID || list[0].Posts[0].Status != MarketingScheduled {
			t.Fatalf("list after publish = %+v, %v", list, err)
		}
		// published: its text is what went out, kept as it is
		if _, err := st.UpdateMarketingDraft(ctx, MarketingDraft{ID: d.ID, Tenant: a, Body: "late edit"}, now); !errors.Is(err, ErrMarketingDraftPublished) {
			t.Fatalf("edit after publish = %v, want ErrMarketingDraftPublished", err)
		}
		if err := st.DeleteMarketingDraft(ctx, a, d.ID); !errors.Is(err, ErrMarketingDraftPublished) {
			t.Fatalf("delete after publish = %v, want ErrMarketingDraftPublished", err)
		}
		// an unpublished one is deleted
		e, err := st.CreateMarketingDraft(ctx, MarketingDraft{Tenant: a, AuthorID: "HUM-1", Body: "to delete"}, now)
		if err != nil {
			t.Fatal(err)
		}
		if err := st.DeleteMarketingDraft(ctx, a, e.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := st.MarketingDraft(ctx, a, e.ID); !errors.Is(err, ErrNotFound) {
			t.Fatalf("read after delete = %v, want ErrNotFound", err)
		}
	})
}

// TestMarketingDraftOtherWorkspace: workspace B neither reads, edits,
// deletes nor publishes A's draft; every call answers ErrNotFound and A's
// draft is unchanged.
func TestMarketingDraftOtherWorkspace(t *testing.T) {
	draftStores(t, func(t *testing.T, st interface {
		MarketingDrafts
		Marketing
	}, a, b string) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Microsecond)
		d, err := st.CreateMarketingDraft(ctx, MarketingDraft{Tenant: a, AuthorID: "HUM-1", Body: "A's own text"}, now)
		if err != nil {
			t.Fatal(err)
		}
		if list, err := st.MarketingDrafts(ctx, b); err != nil || len(list) != 0 {
			t.Fatalf("B lists %d drafts (%v), want 0", len(list), err)
		}
		if _, err := st.MarketingDraft(ctx, b, d.ID); !errors.Is(err, ErrNotFound) {
			t.Fatalf("B reads A's draft: %v", err)
		}
		if _, err := st.UpdateMarketingDraft(ctx, MarketingDraft{ID: d.ID, Tenant: b, Body: "B's text"}, now); !errors.Is(err, ErrNotFound) {
			t.Fatalf("B edits A's draft: %v", err)
		}
		if err := st.DeleteMarketingDraft(ctx, b, d.ID); !errors.Is(err, ErrNotFound) {
			t.Fatalf("B deletes A's draft: %v", err)
		}
		if err := st.MarkMarketingDraftPublished(ctx, b, d.ID, now); !errors.Is(err, ErrNotFound) {
			t.Fatalf("B publishes A's draft: %v", err)
		}
		got, err := st.MarketingDraft(ctx, a, d.ID)
		if err != nil || got.Body != "A's own text" || got.PublishedAt != nil {
			t.Fatalf("A's draft after B's calls = %+v, %v", got, err)
		}
		if _, err := st.MarketingDraft(ctx, a, "not-a-uuid"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("a malformed id = %v, want ErrNotFound", err)
		}
	})
}
