package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// putFleetPrice adds one model_prices row to st (Postgres: as the operator,
// as do_spl_model_prices_sync does).
func putFleetPrice(t *testing.T, st Store, p ModelPrice) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		s.PutModelPrice(p)
	case *Postgres:
		if _, err := s.asOperator2(context.Background(), `INSERT INTO model_prices (provider, model, kind, micros_per_million, currency, valid_from)
			VALUES ($1, $2, $3, $4, $5, $6)`, p.Provider, p.Model, p.Kind, p.MicrosPerMillion, p.Currency, p.ValidFrom); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no price seam for %T", st)
	}
}

func fleetSample(agent, vendor, model string, minute time.Time, in, out, cr, cw int64) wire.FleetTokenSample {
	s := wire.FleetTokenSample{AgentID: agent, Vendor: vendor, Minute: minute, TokensIn: in, TokensOut: out, CacheRead: cr, CacheWrite: cw, IsMetered: true}
	if model != "" {
		s.Model = &model
	}
	return s
}

// boxRows is the rows of one box (the Postgres table is shared by every test).
func boxRows(t *testing.T, ft FleetTokenStore, box string, since time.Time) []FleetTokenBucket {
	t.Helper()
	rows, err := ft.ListBuckets(context.Background(), since, "")
	if err != nil {
		t.Fatal(err)
	}
	var out []FleetTokenBucket
	for _, r := range rows {
		if r.BoxTag == box {
			out = append(out, r)
		}
	}
	return out
}

// spec 140 T010: a minute is one row per (box, agent, minute); a re-sent
// minute overwrites its counts, never adds a row; another box's lane of the
// same id is its own row. Memory and Postgres.
func TestFleetTokenStoreUpsert(t *testing.T) {
	ctx := context.Background()
	m0 := time.Now().UTC().Truncate(time.Minute).Add(-10 * time.Minute)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ft, ok := st.(FleetTokenStore)
			if !ok {
				t.Fatalf("%s keeps no fleet token burn", name)
			}
			box, other := strings.ToLower(uid("b")), strings.ToLower(uid("o"))
			n, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{
				fleetSample("c-001", "claude", "no-such-model", m0, 100, 10, 1000, 5),
				fleetSample("c-001", "claude", "no-such-model", m0.Add(time.Minute), 200, 20, 0, 0),
				{AgentID: "a-204", Vendor: "agy", Minute: m0},
			})
			if err != nil || n != 3 {
				t.Fatalf("record: %d %v", n, err)
			}
			// The same minute again with a new running count: overwritten.
			if n, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{fleetSample("c-001", "claude", "no-such-model", m0, 150, 15, 1500, 5)}); err != nil || n != 1 {
				t.Fatalf("re-send: %d %v", n, err)
			}
			if _, err := ft.RecordSamples(ctx, other, []wire.FleetTokenSample{fleetSample("c-001", "claude", "", m0, 1, 1, 1, 1)}); err != nil {
				t.Fatal(err)
			}
			rows := boxRows(t, ft, box, m0)
			if len(rows) != 3 {
				t.Fatalf("rows %+v, want 3 (the re-send overwrote)", rows)
			}
			first := rows[0]
			if first.AgentID == "a-204" {
				first = rows[1]
			}
			if first.TokensIn != 150 || first.CacheRead != 1500 || first.Total() != 1670 || first.Fresh() != 170 || first.Vendor != "claude" || first.Model != "no-such-model" {
				t.Fatalf("overwritten minute %+v", first)
			}
			for _, r := range rows {
				if r.AgentID == "a-204" && (r.IsMetered || r.Total() != 0 || r.Model != "") {
					t.Fatalf("agy row %+v", r)
				}
			}
			if o := boxRows(t, ft, other, m0); len(o) != 1 || o[0].Model != "" {
				t.Fatalf("other box %+v", o)
			}
			// The vendor filter.
			agy, _ := ft.ListBuckets(ctx, m0, "agy")
			for _, r := range agy {
				if r.Vendor != "agy" {
					t.Fatalf("vendor filter %+v", r)
				}
			}
		})
	}
}

// spec 140 T010: each sample is priced against the model_prices row in force
// at its minute (a later price never re-prices an earlier minute, a
// "[1m]" suffix and a "-YYYYMMDD" snapshot date name the same model); a model with no price stores cost 0
// and priced false (red control), its tokens still count. Memory and Postgres.
func TestFleetTokenStorePricing(t *testing.T) {
	ctx := context.Background()
	m0 := time.Now().UTC().Truncate(time.Minute).Add(-20 * time.Minute)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ft := st.(FleetTokenStore)
			box, model := strings.ToLower(uid("p")), uid("claude-test-")
			for _, p := range []ModelPrice{
				{"anthropic", model, UsageKindIn, 4_000_000, "USD", m0.Add(-time.Hour)},
				{"anthropic", model, UsageKindOut, 20_000_000, "USD", m0.Add(-time.Hour)},
				{"anthropic", model, UsageKindCacheRead, 200_000, "USD", m0.Add(-time.Hour)},
				{"anthropic", model, UsageKindCacheWrite, 5_000_000, "USD", m0.Add(-time.Hour)},
				// Doubled from m0+5m on: minutes before keep the old price.
				{"anthropic", model, UsageKindIn, 8_000_000, "USD", m0.Add(5 * time.Minute)},
			} {
				putFleetPrice(t, st, p)
			}
			if _, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{
				fleetSample("c-1", "claude", model, m0, 12450, 850, 34000, 4200),
				fleetSample("c-1", "claude", model+"[1m]", m0.Add(5*time.Minute), 1000, 0, 0, 0),
				fleetSample("c-4", "claude", model+"-20251001", m0, 1000, 0, 0, 0),
				fleetSample("c-2", "claude", uid("unpriced-"), m0, 5000, 0, 0, 0),
				fleetSample("m-1", "mistral", model, m0, 7, 0, 0, 0),
				fleetSample("c-3", "claude", model, m0, 0, 0, 0, 0),
			}); err != nil {
				t.Fatal(err)
			}
			got := map[string]FleetTokenBucket{}
			for _, r := range boxRows(t, ft, box, m0) {
				got[r.AgentID+"@"+r.Minute.Format("15:04")] = r
			}
			at := func(a string, m time.Time) FleetTokenBucket { return got[a+"@"+m.Format("15:04")] }
			// 12450*4 + 850*20 + 34000*0.2 + 4200*5 = 49800 + 17000 + 6800 + 21000 micros.
			if r := at("c-1", m0); !r.Priced || r.CostMicros != 94600 || r.Currency != "USD" {
				t.Fatalf("priced minute %+v, want 94600 micros", r)
			}
			if r := at("c-1", m0.Add(5*time.Minute)); !r.Priced || r.CostMicros != 8000 || r.Model != model+"[1m]" {
				t.Fatalf("later minute at the new price %+v, want 8000 micros", r)
			}
			if r := at("c-4", m0); !r.Priced || r.CostMicros != 4000 || r.Model != model+"-20251001" {
				t.Fatalf("a dated id at its base model's price %+v, want 4000 micros", r)
			}
			if r := at("c-2", m0); r.Priced || r.CostMicros != 0 || r.TokensIn != 5000 {
				t.Fatalf("RED CONTROL: unpriced model %+v, want cost 0, priced false, tokens kept", r)
			}
			if r := at("m-1", m0); r.Priced || r.CostMicros != 0 {
				t.Fatalf("another provider's model does not take anthropic's price: %+v", r)
			}
			if r := at("c-3", m0); !r.Priced || r.CostMicros != 0 {
				t.Fatalf("a zero minute is priced at 0: %+v", r)
			}
		})
	}
}

// The price row's model of a collector's model name: only a context suffix
// and an 8-digit snapshot date go.
func TestFleetTokenModel(t *testing.T) {
	for in, want := range map[string]string{
		"claude-haiku-4-5-20251001":      "claude-haiku-4-5",
		"claude-opus-5-5[1m]":            "claude-opus-5-5",
		"claude-sonnet-4-5-20250929[1m]": "claude-sonnet-4-5",
		"claude-opus-5-5":                "claude-opus-5-5",
		"mistral-large":                  "mistral-large",
		"mistral-large-2512":             "mistral-large-2512",
		"mistral-large-latest":           "mistral-large-latest",
		"model-2025100x":                 "model-2025100x",
		"-20251001":                      "-20251001",
	} {
		if got := fleetTokenModel(in); got != want {
			t.Errorf("fleetTokenModel(%q) = %q, want %q", in, got, want)
		}
	}
}

// spec 140 T013: the retention pass rolls whole UTC days into the daily
// table, drops minutes of days older than 30 days (a 31-day-old minute goes,
// a 29-day-old one stays) and daily rows older than 365 days. RED CONTROL:
// before the pass the old minutes are there. Memory and Postgres.
func TestFleetTokenStorePrune(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	old, keep := now.Add(-31*24*time.Hour).Truncate(24*time.Hour).Add(10*time.Hour), now.Add(-29*24*time.Hour).Truncate(time.Minute)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ft := st.(FleetTokenStore)
			box := strings.ToLower(uid("r"))
			if _, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{
				fleetSample("c-1", "claude", "", old, 10, 1, 0, 0),
				fleetSample("c-1", "claude", "", old.Add(time.Minute), 20, 2, 0, 0),
				fleetSample("c-1", "claude", "", keep, 5, 0, 0, 0),
				fleetSample("c-1", "claude", "", now.Truncate(time.Minute).Add(-time.Minute), 7, 0, 0, 0),
			}); err != nil {
				t.Fatal(err)
			}
			if rows := boxRows(t, ft, box, old.Add(-time.Hour)); len(rows) != 4 {
				t.Fatalf("RED CONTROL: before the pass %d rows, want 4", len(rows))
			}
			if pg, ok := st.(*Postgres); ok { // a 400-day-old rollup to prune
				if _, err := pg.asOperator2(ctx, `INSERT INTO fleet_token_burn_daily (day_bucket, box_tag, agent_id, vendor, minutes,
					tokens_in, tokens_out, cache_read, cache_write, cost_micros, currency, is_metered)
					VALUES ($1::date, $2, 'c-9', 'claude', 1, 1, 1, 1, 1, 0, 'USD', true)`, now.Add(-400*24*time.Hour).Format(time.DateOnly), box); err != nil {
					t.Fatal(err)
				}
			} else {
				memFleetTokensMu.Lock()
				if memFleetDays[st.(*Memory)] == nil {
					memFleetDays[st.(*Memory)] = map[[3]string]FleetTokenDay{}
				}
				d := now.Add(-400 * 24 * time.Hour).Truncate(24 * time.Hour)
				memFleetDays[st.(*Memory)][[3]string{d.Format(time.DateOnly), box, "c-9"}] = FleetTokenDay{Day: d, BoxTag: box, AgentID: "c-9", Vendor: "claude", Minutes: 1}
				memFleetTokensMu.Unlock()
			}
			res, err := ft.PruneOldBuckets(ctx, now)
			if err != nil || res.PrunedMinutes < 2 || res.PrunedDays < 1 || res.RolledDays < 2 {
				t.Fatalf("prune %+v %v", res, err)
			}
			rows := boxRows(t, ft, box, old.Add(-time.Hour))
			if len(rows) != 2 || !rows[0].Minute.Equal(keep) {
				t.Fatalf("after the pass %+v, want the 29-day-old and today's minute", rows)
			}
			days, err := ft.ListDays(ctx, now.Add(-500*24*time.Hour))
			if err != nil {
				t.Fatal(err)
			}
			var mine []FleetTokenDay
			for _, d := range days {
				if d.BoxTag == box {
					mine = append(mine, d)
				}
			}
			if len(mine) != 2 || !mine[0].Day.Equal(old.Truncate(24*time.Hour)) || mine[0].Minutes != 2 || mine[0].TokensIn != 30 || mine[0].TokensOut != 3 ||
				mine[1].TokensIn != 7 {
				t.Fatalf("rollups %+v, want the pruned day (2 minutes, 30 in) and today, not the 400-day-old one", mine)
			}
			// A second pass changes nothing it already rolled.
			if _, err := ft.PruneOldBuckets(ctx, now); err != nil {
				t.Fatal(err)
			}
			again, _ := ft.ListDays(ctx, old.Add(-time.Hour))
			for _, d := range again {
				if d.BoxTag == box && d.Day.Equal(old.Truncate(24*time.Hour)) && d.TokensIn != 30 {
					t.Fatalf("second pass rewrote the pruned day: %+v", d)
				}
			}
		})
	}
}

// spec 140 3.5: the read answer. Rates are the mean of the last 5 full
// minutes, today is the UTC day, agy reads null (never 0), vendors list
// every kind, the history has one row per minute of the window.
func TestFleetTokenSummarize(t *testing.T) {
	now := time.Date(2026, 10, 15, 10, 42, 30, 0, time.UTC)
	m := func(back int) time.Time { return now.Truncate(time.Minute).Add(-time.Duration(back) * time.Minute) }
	rows := []FleetTokenBucket{
		{BoxTag: "sat", AgentID: "c-001", Vendor: "claude", Model: "claude-opus-5-5", Minute: m(90), TokensIn: 1000, CostMicros: 1e6, Currency: "USD", Priced: true, IsMetered: true},
		{BoxTag: "sat", AgentID: "c-001", Vendor: "claude", Model: "claude-opus-5-5", Minute: m(2), TokensIn: 5000, CacheRead: 10000, CostMicros: 500000, Currency: "USD", Priced: true, IsMetered: true},
		{BoxTag: "sat", AgentID: "c-001", Vendor: "claude", Model: "claude-opus-5-5", Minute: m(1), TokensIn: 3000, TokensOut: 2000, CostMicros: 250000, Currency: "USD", Priced: true, IsMetered: true},
		{BoxTag: "sat", AgentID: "m-183", Vendor: "mistral", Minute: m(1), TokensIn: 500, IsMetered: true},
		{BoxTag: "sat", AgentID: "a-204", Vendor: "agy", Minute: m(0), IsMetered: false},
	}
	got := FleetTokenSummarize(rows, "1h", now)
	s := got.Summary
	if s.BurnRateTokensPerMin != 4100 || s.FreshTokensPerMin != 2100 || s.ActiveAgents != 3 || s.UnmeteredAgents != 1 || s.UnpricedAgents != 1 ||
		s.TodayTotalTokens != 21500 || s.TodayCacheRead != 10000 || s.TodayTotalCost != 1.75 || s.Currency != "USD" || s.BurnRateCostPerHour != 9 {
		t.Fatalf("summary %+v", s)
	}
	if len(got.ByVendor) != 5 || got.ByVendor[0].Vendor != "claude" || *got.ByVendor[0].BurnRateTokensPerMin != 4000 || got.ByVendor[0].Status != "metered" {
		t.Fatalf("by vendor %+v", got.ByVendor)
	}
	for _, v := range got.ByVendor {
		switch v.Vendor {
		case "agy":
			if v.Status != "unmetered" || v.BurnRateTokensPerMin != nil || v.TodayTotalTokens != nil || v.TodayCost != nil || v.ActiveAgents != 1 {
				t.Fatalf("agy vendor %+v, want null sums", v)
			}
		case "grok", "qwen":
			if v.Status != "idle" || *v.TodayTotalTokens != 0 {
				t.Fatalf("idle vendor %+v", v)
			}
		}
	}
	if len(got.ByAgent) != 3 || got.ByAgent[0].AgentID != "c-001" || *got.ByAgent[0].BurnRate1m != 5000 || *got.ByAgent[0].TodayTotalTokens != 21000 ||
		*got.ByAgent[0].TodayCost != 1.75 || got.ByAgent[2].AgentID != "a-204" || got.ByAgent[2].BurnRateTokensPerMin != nil || got.ByAgent[2].IsMetered {
		t.Fatalf("by agent (burn rate desc, agy last with null) %+v", got.ByAgent)
	}
	if len(got.History) != 61 || got.History[59].Tokens != 5500 || got.History[0].Minute != m(60).Format(time.RFC3339) {
		t.Fatalf("history %d rows, last full minute %+v", len(got.History), got.History[59])
	}
	if day := FleetTokenSummarize(rows, "today", now); len(day.History) != 10*60+43 {
		t.Fatalf("today history %d", len(day.History))
	}
	if _, _, ok := FleetTokenWindowStart("7d", now); ok {
		t.Fatal("7d is not a window")
	}
}

// spec 140 T001 (Postgres): the table is the operator's only. RED CONTROL:
// with no scope and in a workspace scope a read sees 0 rows and an insert is
// refused; a duplicate (box_tag, agent_id, minute_bucket) without ON CONFLICT
// is a unique violation; a minute not on the minute is refused.
func TestFleetTokenRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	box, m0 := strings.ToLower(uid("s")), time.Now().UTC().Truncate(time.Minute)
	if _, err := pg.RecordSamples(ctx, box, []wire.FleetTokenSample{fleetSample("c-1", "claude", "", m0, 1, 1, 1, 1)}); err != nil {
		t.Fatal(err)
	}
	tenant := newTenant(t, pg)
	for scope, run := range map[string]func(func(pgx.Tx) error) error{
		"none":      func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) },
		"workspace": func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, tenant, fn) },
	} {
		for _, table := range []string{"fleet_token_burn_events", "fleet_token_burn_daily"} {
			var n int
			if err := run(func(tx pgx.Tx) error { return tx.QueryRow(ctx, `SELECT count(*) FROM `+table).Scan(&n) }); err != nil || n != 0 {
				t.Errorf("%s scope reads %d rows of %s (%v), want 0", scope, n, table, err)
			}
		}
		err := run(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO fleet_token_burn_events (box_tag, agent_id, vendor, minute_bucket) VALUES ($1, 'c-x', 'claude', $2)`, box, m0)
			return err
		})
		if err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM fleet_token_burn_events WHERE box_tag = $1`, box); err != nil || n != 1 {
		t.Fatalf("CONTROL: the operator scope reads the row: %d %v", n, err)
	}
	if _, err := pg.asOperator2(ctx, `INSERT INTO fleet_token_burn_events (box_tag, agent_id, vendor, minute_bucket) VALUES ($1, 'c-1', 'claude', $2)`, box, m0); err == nil ||
		!strings.Contains(err.Error(), "fleet_token_burn_natural") {
		t.Fatalf("duplicate minute without ON CONFLICT: %v, want the unique violation", err)
	}
	if _, err := pg.asOperator2(ctx, `INSERT INTO fleet_token_burn_events (box_tag, agent_id, vendor, minute_bucket) VALUES ($1, 'c-2', 'claude', $2)`, box, m0.Add(time.Second)); err == nil {
		t.Fatal("a minute_bucket off the minute was accepted")
	}
	if _, err := pg.asOperator2(ctx, `INSERT INTO fleet_token_burn_events (box_tag, agent_id, vendor, minute_bucket, is_metered, tokens_in) VALUES ($1, 'a-1', 'agy', $2, false, 5)`, box, m0); err == nil {
		t.Fatal("an unmetered row with tokens was accepted")
	}
}
