package store

import (
	"context"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// spec 143 costs-redesign 3.3.1 rule (SPL-3810): a workspace with 25 % of an
// agent type's tokens on a day gets floor(25 % of that day's micros); the
// NULL (operator) tokens stay in the denominator and get nothing; a day with
// no token gives no share. RED CONTROL: the shares of one item on one day
// never sum above its daily amount (10000 random splits).
func TestAIShareSplit(t *testing.T) {
	got := AIShareSplit(3_333_333, map[string]int64{"ws-a": 25, "ws-b": 45, "": 30})
	if len(got) != 2 || got["ws-a"] != 833_333 || got["ws-b"] != 1_499_999 {
		t.Fatalf("split %v, want ws-a 833333 (25 %%, rounded down), ws-b 1499999, no NULL share", got)
	}
	if got := AIShareSplit(3_333_333, map[string]int64{"": 100}); len(got) != 0 {
		t.Fatalf("NULL-stamped tokens only: %v, want no share", got)
	}
	if got := AIShareSplit(3_333_333, map[string]int64{}); len(got) != 0 {
		t.Fatalf("no token of the type: %v, want no share", got)
	}
	if got := AIShareSplit(9e15, map[string]int64{"ws-a": 4e9, "": 4e9}); got["ws-a"] != 45e14 {
		t.Fatalf("large micros x tokens: %v, want 4.5e15 (no int64 overflow)", got)
	}
	x := int64(1) // a fixed LCG: the same 10000 splits every run
	next := func(n int64) int64 {
		x = x*6364136223846793005 + 1442695040888963407
		return (x & math.MaxInt64) % n
	}
	for i := 0; i < 10000; i++ {
		micros, tokens := next(1e10)+1, map[string]int64{"": next(1000)}
		for w := int64(0); w < 1+next(6); w++ {
			tokens["ws-"+strconv.FormatInt(w, 10)] = next(1e9)
		}
		var sum int64
		for _, v := range AIShareSplit(micros, tokens) {
			sum += v
		}
		if sum > micros {
			t.Fatalf("shares %d sum above the daily amount %d: tokens %v", sum, micros, tokens)
		}
	}
}

// aiTestMonth is a random 31-day month of 1200..1999 (the Postgres tables are
// shared by every test and run).
func aiTestMonth() time.Time {
	n, _ := strconv.ParseUint(uid("")[:4], 16, 32)
	months := []time.Month{time.January, time.March, time.May, time.July, time.August, time.October, time.December}
	return time.Date(1200+int(n%800), months[int(n/800)%len(months)], 1, 0, 0, 0, 0, time.UTC)
}

// putFleetDayWS is putFleetDay with the rollup's work_tenant (rdb 0229).
func putFleetDayWS(t *testing.T, st Store, d FleetTokenDay) {
	t.Helper()
	pg, ok := st.(*Postgres)
	if !ok {
		putFleetDay(t, st, d)
		return
	}
	if _, err := pg.asOperator2(context.Background(), `INSERT INTO fleet_token_burn_daily (day_bucket, box_tag, agent_id, vendor,
		minutes, tokens_in, tokens_out, cache_read, cache_write, cost_micros, currency, is_metered, work_tenant)
		VALUES ($1::date, $2, $3, $4, 1, $5, 0, $6, 0, 0, 'USD', true, nullif($7, ''))`, d.Day.Format(time.DateOnly), d.BoxTag,
		d.AgentID, d.Vendor, d.TokensIn, d.CacheRead, d.WorkTenant); err != nil {
		t.Fatal(err)
	}
}

// seedAIMonth writes month m's paid items and burn into st: a 30-day claude
// item from day 17 (15 of its days in m), an XTS item no rate exists for,
// and four days of burn (see TestAIPaidMonthRead).
func seedAIMonth(t *testing.T, st Store, m time.Time, ws, other string) {
	t.Helper()
	ctx, fp, ft := context.Background(), st.(FleetPaidStore), st.(FleetTokenStore)
	day := func(n int) time.Time { return m.AddDate(0, 0, n-1) }
	for _, it := range []FleetPaidItem{
		paidItem("ai-test", "claude", "subscription", 1, 100, "USD", day(17).Format(time.DateOnly), day(47).Format(time.DateOnly)),
		paidItem("ai-test", "mistral", "topup", 1, 30, "XTS", day(5).Format(time.DateOnly), day(8).Format(time.DateOnly)),
	} {
		got, err := fp.CreatePaidItem(ctx, it)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = fp.DeletePaidItem(ctx, got.ID) })
	}
	box := strings.ToLower(uid("ai"))
	at := func(s wire.FleetTokenSample, tenant string) wire.FleetTokenSample { s.WorkTenant = tenant; return s }
	if _, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{
		at(fleetSample("c-1", "claude", "", day(20).Add(10*time.Hour), 20, 0, 999, 5), ws), // 25: cache reads out
		at(fleetSample("c-2", "claude", "", day(20).Add(10*time.Hour), 45, 0, 0, 0), other),
		at(fleetSample("c-3", "claude", "", day(20).Add(11*time.Hour), 30, 0, 0, 0), ""),
		at(fleetSample("c-3", "claude", "", day(21).Add(11*time.Hour), 100, 0, 0, 0), ""),
		at(fleetSample("m-1", "mistral", "", day(22).Add(11*time.Hour), 100, 0, 0, 0), ws),
	}); err != nil {
		t.Fatal(err)
	}
	// Day 20 is in the minutes: its stale rollup is never read. Day 23 is
	// in the rollup only.
	putFleetDayWS(t, st, FleetTokenDay{Day: day(20), BoxTag: box, AgentID: "c-1", Vendor: "claude", TokensIn: 999999, IsMetered: true, WorkTenant: ws})
	putFleetDayWS(t, st, FleetTokenDay{Day: day(23), BoxTag: box, AgentID: "c-1", Vendor: "claude", TokensIn: 10, IsMetered: true, WorkTenant: ws})
	putFleetDayWS(t, st, FleetTokenDay{Day: day(23), BoxTag: box, AgentID: "c-3", Vendor: "claude", TokensIn: 30, IsMetered: true})
}

// SPL-3810, the S3 row of spec 143 costs-redesign 5: the month read's AI
// parts, Memory and Postgres. The claude item pays 100 USD for 30 days,
// round(3.333333 USD) = 3333333 micros a day, 15 of them in the 31-day month.
// The workspace holds 25 % of day 20's claude tokens (25 of 100: 45 another
// workspace's, 30 NULL) and 10 of 40 on day 23 (the rollup); day 21 is NULL
// tokens only, day 22 mistral only. RED CONTROLS: the workspace answer
// carries no ai_paid part and not the other workspace's share; the estate's
// total is the full amount however the tokens are stamped.
func TestAIPaidMonthRead(t *testing.T) {
	ctx := context.Background()
	m := aiTestMonth()
	q := AIPaidQuery{Operator: strings.ToLower(uid("op")), From: m.Format(time.DateOnly),
		CoverTo: m.AddDate(0, 1, 0).Format(time.DateOnly), Currency: "USD"}
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ar := st.(AIPaidRead)
			ws, other := strings.ToLower(uid("w")), strings.ToLower(uid("x"))
			before, err := ar.AIPaidMonthRead(ctx, q)
			if err != nil {
				t.Fatal(err)
			}
			seedAIMonth(t, st, m, ws, other)
			estate, err := ar.AIPaidMonthRead(ctx, q)
			if err != nil {
				t.Fatal(err)
			}
			checkAIEstate(t, estate, len(before.Parts))
			wq := q
			wq.Workspace = ws
			mine, err := ar.AIPaidMonthRead(ctx, wq)
			if err != nil {
				t.Fatal(err)
			}
			checkAIShare(t, mine, m)
			wq.Workspace = q.Operator
			if _, err := ar.AIPaidMonthRead(ctx, wq); err == nil {
				t.Fatal("the operator workspace's members got a share read")
			}
		})
	}
}

// checkAIEstate: one claude part of the full 15 days, the XTS item's 3 days
// not read, no share part.
func checkAIEstate(t *testing.T, got AIPaidMonth, had int) {
	t.Helper()
	if had != 0 || len(got.Parts) != 1 {
		t.Fatalf("estate parts %+v (before the seed: %d), want one", got.Parts, had)
	}
	p := got.Parts[0]
	if !p.Estate || p.Source != CostSourceAIPaid || p.ProjectOrVendor != "claude" || p.Kind != "claude subscription" ||
		p.USDMicros != 15*3_333_333 || p.Days != 15 {
		t.Fatalf("estate part %+v, want ai_paid claude, 15 days x 3333333 micros (the full amount, no share taken)", p)
	}
	if c := got.Coverage; c.Source != CostSourceAIPaid || c.OK != 28 || c.Missing != 3 {
		t.Fatalf("estate coverage %+v, want 28 days read, 3 missing (the XTS item has no rate)", c)
	}
}

// checkAIShare: one claude ai_share part of 833333 (day 20) + 833333 (day
// 23), nothing of day 21 (NULL only) or 22 (no claude token).
func checkAIShare(t *testing.T, got AIPaidMonth, m time.Time) {
	t.Helper()
	if len(got.Parts) != 1 {
		t.Fatalf("workspace parts %+v, want one ai_share part", got.Parts)
	}
	p := got.Parts[0]
	if p.Estate || p.Source != CostSourceAIShare || p.ProjectOrVendor != "claude" || p.Kind != "share" ||
		p.USDMicros != 2*833_333 || p.Days != 2 {
		t.Fatalf("workspace part %+v, want ai_share claude 2 x 833333 on 2 days (25 %% of 3333333, rounded down)", p)
	}
	if got.Coverage.Source != CostSourceAIShare || got.ShareFrom != m.AddDate(0, 0, 19).Format(time.DateOnly) {
		t.Fatalf("workspace coverage %+v, share from %q, want ai_share from day 20", got.Coverage, got.ShareFrom)
	}
}

// SPL-3810 RLS: the burn rows the share reads are operator scope; a
// workspace scope reads none of them, its own or another's. Postgres only.
func TestWorkspaceBurnDaysRLS(t *testing.T) {
	ctx := context.Background()
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	m := aiTestMonth()
	ws, other := strings.ToLower(uid("w")), strings.ToLower(uid("x"))
	seedAIMonth(t, pg, m, ws, other)
	args := []any{m.Format(time.DateOnly), m.AddDate(0, 1, 0).Format(time.DateOnly)}
	op, err := pg.WorkspaceBurnDays(ctx, m, m.AddDate(0, 1, 0))
	if err != nil || len(op) == 0 {
		t.Fatalf("operator scope: %v rows, %v; want the seeded burn", len(op), err)
	}
	for _, tenant := range []string{ws, other} {
		n := 0
		if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, workspaceBurnDaysSQL, args...)
			if err != nil {
				return err
			}
			for rows.Next() {
				n++
			}
			rows.Close()
			return rows.Err()
		}); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Fatalf("workspace scope %s read %d burn rows, want 0", tenant, n)
		}
	}
}
