package store

import (
	"context"
	"math/big"
	"testing"
	"time"
)

// Spec 121 T304: the budget half of the store. A budget's use is what the
// ledger holds in its windows (UTC day, UTC month, since the top-up) and in
// its scope (the workspace, or one channel); the 80 % notice is claimed once
// per window. Postgres only: Memory keeps no time or channel per ledger row
// and holds no budgets.

func i64(n int64) *int64 { return &n }

// budgetStore is the Postgres driver, or a skip without $SPOOL_TEST_PG_DSN.
func budgetStore(t *testing.T) *Postgres {
	t.Helper()
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("token budgets are Postgres only; set SPOOL_TEST_PG_DSN")
	}
	if _, ok := Store(NewMemory()).(TokenBudgets); ok {
		t.Fatal("Memory claims token budgets it cannot count")
	}
	return pg
}

// meter writes one reported turn of in+out tokens at at in channel.
func meter(t *testing.T, s *Postgres, tenant, model, channel string, at time.Time, in, out int64) {
	t.Helper()
	if _, err := s.MeterTurn(context.Background(), tenant, TurnUsage{TurnRef: TurnRef{TurnID: uid("turn-"),
		ChannelID: channel, AgentID: "c-782", At: at}, Provider: "anthropic", Model: model, TokensIn: in, TokensOut: out}); err != nil {
		t.Fatal(err)
	}
}

func TestTokenBudgetUses(t *testing.T) {
	s := budgetStore(t)
	ctx := context.Background()
	tenant, other := newTenant(t, s), newTenant(t, s)
	model := uid("model-")
	t0 := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	putPrice(t, s, ModelPrice{"anthropic", model, UsageKindIn, 1_000_000, "EUR", t0})  // 1 micro a token
	putPrice(t, s, ModelPrice{"anthropic", model, UsageKindOut, 5_000_000, "EUR", t0}) // 5 micros a token
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	topup := at.Add(-30 * time.Hour)

	meter(t, s, tenant, model, "sales", at.Add(-time.Hour), 500, 100)    // today, sales: 600 tokens, 1000 micros
	meter(t, s, tenant, model, "lobby", at.Add(-26*time.Hour), 1500, 0)  // yesterday: 1500 tokens, 1500 micros
	meter(t, s, tenant, model, "sales", at.Add(-48*time.Hour), 400, 0)   // before the top-up: 400 tokens
	meter(t, s, tenant, model, "sales", at.AddDate(0, -1, 0), 90_000, 0) // last month: no window
	meter(t, s, tenant, model, "sales", at.Add(time.Hour), 70_000, 0)    // after at: not yet
	meter(t, s, other, model, "sales", at.Add(-time.Hour), 80_000, 0)    // another workspace

	ws, err := s.PutTokenBudget(ctx, tenant, TokenBudget{TokensPerDay: i64(1000), TokensPerMonth: i64(5000),
		TopupMicros: i64(10_000), TopupCurrency: "EUR", ToppedUpAt: topup})
	if err != nil {
		t.Fatal(err)
	}
	ch, err := s.PutTokenBudget(ctx, tenant, TokenBudget{ChannelID: "sales", TokensPerMonth: i64(750), Soft: true})
	if err != nil {
		t.Fatal(err)
	}

	uses, err := s.BudgetUses(ctx, tenant, "sales", at)
	if err != nil || len(uses) != 2 {
		t.Fatalf("BudgetUses(sales) = %d uses, %v; want the workspace's and the channel's", len(uses), err)
	}
	w, c := uses[0], uses[1]
	if w.ID != ws || w.ChannelID != "" || w.DayTokens != 600 || w.MonthTokens != 2500 || w.SpentMicros != "2500.000000" || w.Soft {
		t.Errorf("workspace use = %+v; want day 600, month 2500 (600+1500+400), 2500 micros since the top-up", w)
	}
	if c.ID != ch || c.ChannelID != "sales" || c.DayTokens != 600 || c.MonthTokens != 1000 || !c.Soft {
		t.Errorf("channel use = %+v; want day 600, month 1000 (600+400), soft", c)
	}
	if only, err := s.BudgetUses(ctx, tenant, "lobby", at); err != nil || len(only) != 1 || only[0].ID != ws {
		t.Errorf("BudgetUses(lobby) = %+v, %v; want the workspace's only", only, err)
	}
	if none, err := s.BudgetUses(ctx, other, "sales", at); err != nil || len(none) != 0 {
		t.Errorf("another workspace reads %+v, %v; want no budget", none, err)
	}

	// Levels: day 600/1000 = 60 %, month 2500/5000 = 50 %, top-up 2500/10000 = 25 %; channel 1000/750.
	lv := w.Levels()
	if len(lv) != 3 || lv[0].Limit != BudgetLimitDay || lv[0].Pct() != 60 || lv[1].Pct() != 50 || lv[2].Pct() != 25 ||
		lv[2].Since != topup || lv[0].Reached(80) {
		t.Errorf("workspace levels = %+v", lv)
	}
	if cl := c.Levels(); len(cl) != 1 || !cl[0].Reached(100) || cl[0].Pct() != 133 {
		t.Errorf("channel levels = %+v; want month 133 %%, reached", cl)
	}
	if z := (BudgetLevel{Used: new(big.Rat), Of: 0}); !z.Reached(100) {
		t.Error("a zero limit must read as reached")
	}

	// Spend in a currency the top-up cannot price reads as the whole balance.
	usd := uid("model-")
	putPrice(t, s, ModelPrice{"anthropic", usd, UsageKindIn, 1_000_000, "USD", t0})
	putPrice(t, s, ModelPrice{"anthropic", usd, UsageKindOut, 1_000_000, "USD", t0})
	meter(t, s, tenant, usd, "lobby", at.Add(-time.Minute), 1, 1)
	uses, _ = s.BudgetUses(ctx, tenant, "", at)
	if l := uses[0].Levels()[2]; uses[0].OtherCurrency != 2 || !l.Reached(100) {
		t.Errorf("a USD row against a EUR top-up: other %d, level %+v; want spent", uses[0].OtherCurrency, l)
	}

	// One notice per window: claimed once, then again only for a later window.
	day, _ := BudgetWindows(at)
	if ok, err := s.ClaimBudgetNotice(ctx, tenant, ws, day, at); err != nil || !ok {
		t.Fatalf("first claim = %v, %v; want claimed", ok, err)
	}
	if ok, err := s.ClaimBudgetNotice(ctx, tenant, ws, day, at.Add(time.Minute)); err != nil || ok {
		t.Errorf("second claim in the same window = %v, %v; want refused", ok, err)
	}
	if ok, err := s.ClaimBudgetNotice(ctx, other, ws, time.Time{}, at); err != nil || ok {
		t.Errorf("another workspace claimed this budget's notice: %v, %v", ok, err)
	}
	uses, _ = s.BudgetUses(ctx, tenant, "", at)
	if !uses[0].LowNoticeAt.Equal(at) {
		t.Errorf("low_notice_at = %v, want %v", uses[0].LowNoticeAt, at)
	}
	next := day.Add(24 * time.Hour)
	if ok, err := s.ClaimBudgetNotice(ctx, tenant, ws, next, next.Add(time.Hour)); err != nil || !ok {
		t.Errorf("claim in the next day's window = %v, %v; want claimed", ok, err)
	}

	// One budget per scope: a second put of the workspace's updates it.
	if id, err := s.PutTokenBudget(ctx, tenant, TokenBudget{TokensPerDay: i64(1)}); err != nil || id != ws {
		t.Errorf("re-put of the workspace budget = %d, %v; want id %d", id, err, ws)
	}
	if _, err := s.PutTokenBudget(ctx, tenant, TokenBudget{}); err == nil {
		t.Error("a budget with no limit was written")
	}
}
