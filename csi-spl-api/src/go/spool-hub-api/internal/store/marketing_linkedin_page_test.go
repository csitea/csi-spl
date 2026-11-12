package store

import (
	"context"
	"sync"
	"testing"
	"time"
)

// SPL-5258 (rdb 0277): a LinkedIn Company Page channel, its dispatch list,
// tenant isolation under FORCE RLS and the token swap two refreshing hubs
// race on. The Postgres cases run under hub-pg; on the schema without 0277
// (red control) the platform 'linkedin_page' is refused.

func connectLinkedInPage(ctx context.Context, pg *Postgres, tenant, org string, tok MarketingToken) (MarketingChannel, error) {
	return pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: tenant, Platform: MarketingPlatformLinkedInPage, AccountType: "page",
		AccountRef: org, AccountName: "Example Page", DelegatedBy: "HUM-1",
		Metadata: map[string]any{"organization_urn": "urn:li:organization:" + org, "vanity_name": "example", "role": "ADMINISTRATOR"}},
		tok, time.Now().UTC())
}

func TestMarketingLinkedInPageChannelRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := mktTenant(t, pg), mktTenant(t, pg)
	old := MarketingToken{Ciphertext: "v1.sealed.li-page." + a, KMSKeyID: "kms/key/1"}
	pageCh, err := connectLinkedInPage(ctx, pg, a, "1001", old)
	if err != nil {
		t.Fatalf("linkedin_page channel: %v", err)
	}
	if pageCh.AccountType != "page" || pageCh.AutoPublish || pageCh.Metadata["organization_urn"] != "urn:li:organization:1001" {
		t.Fatalf("linkedin_page channel read back %+v", pageCh)
	}
	if chs, err := pg.MarketingChannels(ctx, b); err != nil || containsChannel(chs, pageCh.ID) {
		t.Fatalf("tenant B sees A's Page channel: %v", err)
	}
	if _, err := pg.MarketingToken(ctx, b, pageCh.ID); err == nil {
		t.Fatal("tenant B read A's sealed Page token")
	}
	x, err := pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: a, Platform: MarketingPlatformX, AccountRef: "42"},
		MarketingToken{Ciphertext: "v1.x"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	chs, err := pg.LinkedInPageChannels(ctx)
	if err != nil || !containsChannel(chs, pageCh.ID) || containsChannel(chs, x.ID) {
		t.Fatalf("LinkedInPageChannels: %v (want the Page, not the X channel)", err)
	}
	for _, c := range chs {
		if c.Platform != MarketingPlatformLinkedInPage {
			t.Fatalf("LinkedInPageChannels lists a %s channel", c.Platform)
		}
	}
	if autos, _ := pg.AutoMarketingChannels(ctx); containsChannel(autos, pageCh.ID) {
		t.Fatal("the personal-profile LinkedIn sweep lists the Page channel")
	}
	if xs, _ := pg.XMarketingChannels(ctx); containsChannel(xs, pageCh.ID) {
		t.Fatal("the X dispatch lists the Page channel")
	}
	// two hubs refresh at once from the same sealed bundle: one swap wins
	var wins int
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			next := MarketingToken{Ciphertext: "v1.sealed.li-page.next" + string(rune('a'+i)), KMSKeyID: "kms/key/2"}
			ok, err := pg.SwapMarketingToken(ctx, a, pageCh.ID, old, next, time.Now().UTC())
			if err != nil {
				t.Errorf("swap: %v", err)
			}
			if ok {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("%d refreshes won the swap, want exactly 1", wins)
	}
}

// The Memory store keeps the same list (hub tests run on it).
func TestMarketingLinkedInPageMemory(t *testing.T) {
	m := NewMemory()
	ctx := context.Background()
	if err := m.CreateTenant(ctx, Tenant{ID: "t-mem", RootPubKey: pubkey()}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	pageCh, err := m.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: "t-mem", Platform: MarketingPlatformLinkedInPage,
		AccountType: "page", AccountRef: "1001"}, MarketingToken{Ciphertext: "v1.p"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: "t-mem", Platform: MarketingPlatformX, AccountRef: "42"},
		MarketingToken{Ciphertext: "v1.x"}, now); err != nil {
		t.Fatal(err)
	}
	if chs, _ := m.LinkedInPageChannels(ctx); len(chs) != 1 || chs[0].ID != pageCh.ID {
		t.Fatalf("memory linkedin_page channels = %+v", chs)
	}
}
