package store

import (
	"context"
	"testing"
	"time"
)

// SPL-5194 (rdb 0272): an X channel, the X dispatch list and the token swap
// a rotating refresh token needs. The Postgres cases run under hub-pg; on
// the 0270 schema alone (red control) the platform 'x' is refused.

func TestMarketingXChannelAndTokenSwap(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := mktTenant(t, pg), mktTenant(t, pg)
	now := time.Now().UTC()
	old := MarketingToken{Ciphertext: "v1.sealed.x." + a, KMSKeyID: "kms/key/1"}
	x, err := pg.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: a, Platform: MarketingPlatformX, AccountRef: "42",
		AccountName: "@example", DelegatedBy: "HUM-1", Metadata: map[string]any{"username": "example"}}, old, now)
	if err != nil {
		t.Fatalf("x channel: %v", err)
	}
	if x.AccountType != "personal" || x.AutoPublish || x.Metadata["username"] != "example" {
		t.Fatalf("x channel read back %+v", x)
	}
	if _, err := connectMeta(ctx, pg, a, MarketingPlatformFacebook, "page"); err != nil {
		t.Fatal(err)
	}
	chs, err := pg.XMarketingChannels(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, c := range chs {
		if c.Platform != MarketingPlatformX {
			t.Fatalf("XMarketingChannels lists a %s channel", c.Platform)
		}
		if c.ID == x.ID {
			found++
		}
	}
	if found != 1 {
		t.Fatalf("XMarketingChannels lists the new channel %d times", found)
	}
	if metas, _ := pg.MetaMarketingChannels(ctx); containsChannel(metas, x.ID) {
		t.Fatal("the Meta dispatch lists the X channel")
	}
	if autos, _ := pg.AutoMarketingChannels(ctx); containsChannel(autos, x.ID) {
		t.Fatal("the LinkedIn sweep lists the X channel")
	}
	next := MarketingToken{Ciphertext: "v1.sealed.x2." + a, KMSKeyID: "kms/key/2"}
	if ok, err := pg.SwapMarketingToken(ctx, b, x.ID, old, next, now); err != nil || ok {
		t.Fatalf("tenant B swapped A's token: %v %v", ok, err)
	}
	if ok, err := pg.SwapMarketingToken(ctx, a, x.ID, old, next, now); err != nil || !ok {
		t.Fatalf("swap: %v %v", ok, err)
	}
	if ok, err := pg.SwapMarketingToken(ctx, a, x.ID, old, MarketingToken{Ciphertext: "v1.lost"}, now); err != nil || ok {
		t.Fatalf("a second swap from the old token won: %v %v", ok, err)
	}
	if got, err := pg.MarketingToken(ctx, a, x.ID); err != nil || got != next {
		t.Fatalf("token after swap = %+v, %v; want %+v", got, err, next)
	}
}

func containsChannel(chs []MarketingChannel, id string) bool {
	for _, c := range chs {
		if c.ID == id {
			return true
		}
	}
	return false
}

// The Memory store keeps the same list and swap (hub tests run on it).
func TestMarketingXMemory(t *testing.T) {
	m := NewMemory()
	ctx := context.Background()
	if err := m.CreateTenant(ctx, Tenant{ID: "t-mem", RootPubKey: pubkey()}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	old := MarketingToken{Ciphertext: "v1.x"}
	ch, err := m.ConnectMarketingChannel(ctx, MarketingChannel{Tenant: "t-mem", Platform: MarketingPlatformX, AccountRef: "42"}, old, now)
	if err != nil {
		t.Fatal(err)
	}
	if chs, _ := m.XMarketingChannels(ctx); len(chs) != 1 || chs[0].ID != ch.ID {
		t.Fatalf("memory x channels = %+v", chs)
	}
	next := MarketingToken{Ciphertext: "v1.x2"}
	if ok, _ := m.SwapMarketingToken(ctx, "other", ch.ID, old, next, now); ok {
		t.Fatal("another tenant swapped the token")
	}
	if ok, _ := m.SwapMarketingToken(ctx, "t-mem", ch.ID, old, next, now); !ok {
		t.Fatal("swap refused")
	}
	if ok, _ := m.SwapMarketingToken(ctx, "t-mem", ch.ID, old, MarketingToken{Ciphertext: "v1.lost"}, now); ok {
		t.Fatal("a stale swap won")
	}
	if got, _ := m.MarketingToken(ctx, "t-mem", ch.ID); got != next {
		t.Fatalf("token = %+v", got)
	}
}
