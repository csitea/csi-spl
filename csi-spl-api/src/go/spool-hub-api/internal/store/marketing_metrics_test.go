package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 163 B1 (SPL-4250): the marketing metrics store, rdb 0244. The
// contract runs on Memory and Postgres (drivers); the RLS cases are
// Postgres only (SPOOL_TEST_PG_DSN, hub-pg.tst.sh). crosstenant_test.go
// seeds both tables per tenant and lists them append-only.

func mktSample(metric, value string, start time.Time) MarketingMetricSample {
	return MarketingMetricSample{Source: "linkedin", ObjectType: "post", ObjectRef: "urn:li:share:1", Metric: metric,
		Value: value, PeriodStart: start, PeriodEnd: start.Add(24 * time.Hour), RunID: "run-1"}
}

// TestMarketingMetrics: a re-fetch adds a row and the read answers the
// newest per key, another tenant's rows never; a definition gets version
// 1, 2, ... per metric and the Q7 default (last touch, 28 days); bad rows,
// no tenant and an unknown tenant are refused.
func TestMarketingMetrics(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			mm := s.(MarketingMetrics)
			a, b := newTenant(t, s), newTenant(t, s)
			day := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
			if _, err := mm.AddMarketingMetricSample(ctx, "", mktSample("impressions", "1", day), now); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
			if _, err := mm.AddMarketingMetricSample(ctx, uid("t-none-"), mktSample("impressions", "1", day), now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown tenant: %v", err)
			}
			for _, bad := range []func(*MarketingMetricSample){
				func(m *MarketingMetricSample) { m.Source = "LinkedIn" },
				func(m *MarketingMetricSample) { m.ObjectType = "story" },
				func(m *MarketingMetricSample) { m.Metric = "" },
				func(m *MarketingMetricSample) { m.Value = "1e3" },
				func(m *MarketingMetricSample) { m.PeriodEnd = m.PeriodStart.Add(-time.Second) },
				func(m *MarketingMetricSample) { m.PostID = "not-a-uuid" },
			} {
				m := mktSample("impressions", "1", day)
				bad(&m)
				if _, err := mm.AddMarketingMetricSample(ctx, a, m, now); err == nil {
					t.Errorf("a bad sample was stored: %+v", m)
				}
			}
			first, err := mm.AddMarketingMetricSample(ctx, a, mktSample("impressions", "100", day), now)
			if err != nil {
				t.Fatal(err)
			}
			if first.Unit != "count" || !first.FetchedAt.Equal(now) || first.ID == 0 {
				t.Errorf("defaults: unit %q fetched %v id %d", first.Unit, first.FetchedAt, first.ID)
			}
			refetch := mktSample("impressions", "123.5", day)
			refetch.FetchedAt = now.Add(time.Hour)
			if _, err := mm.AddMarketingMetricSample(ctx, a, refetch, now); err != nil {
				t.Fatal(err)
			}
			if _, err := mm.AddMarketingMetricSample(ctx, a, mktSample("clicks", "7", day), now); err != nil {
				t.Fatal(err)
			}
			if _, err := mm.AddMarketingMetricSample(ctx, b, mktSample("impressions", "999", day), now); err != nil {
				t.Fatal(err)
			}
			got, err := mm.ReadMarketingMetrics(ctx, a)
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Samples) != 2 || got.Samples[0].Metric != "clicks" || got.Samples[1].Metric != "impressions" || got.Samples[1].Value != "123.5" {
				t.Fatalf("newest per key: %+v, want clicks 7 and impressions 123.5", got.Samples)
			}

			d1, err := mm.AddMarketingMetricDefinition(ctx, a, MarketingMetricDefinition{Metric: "cpl", Formula: "spend / leads", CreatedBy: "HUM-1"}, now)
			if err != nil {
				t.Fatal(err)
			}
			if d1.Version != 1 || d1.AttributionRule != MarketingAttributionLastTouch || d1.AttributionWindowDays != 28 {
				t.Errorf("Q7 default: version %d rule %q window %d, want 1 last_touch 28", d1.Version, d1.AttributionRule, d1.AttributionWindowDays)
			}
			signed := now.Add(time.Minute)
			d2, err := mm.AddMarketingMetricDefinition(ctx, a, MarketingMetricDefinition{Metric: "cpl", Formula: "spend / leads",
				Params: map[string]string{"period": "month"}, SignedOffBy: "HUM-1", SignedOffAt: &signed}, now)
			if err != nil || d2.Version != 2 {
				t.Fatalf("the sign-off is version 2: %d (%v)", d2.Version, err)
			}
			for _, bad := range []MarketingMetricDefinition{{Metric: "cpl", AttributionRule: "first_touch"},
				{Metric: "cpl", AttributionWindowDays: 400}, {Metric: "cpl", SignedOffBy: "HUM-1"}, {Metric: "Bad"}} {
				if _, err := mm.AddMarketingMetricDefinition(ctx, a, bad, now); err == nil {
					t.Errorf("a bad definition was stored: %+v", bad)
				}
			}
			got, err = mm.ReadMarketingMetrics(ctx, a)
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Definitions) != 1 || got.Definitions[0].Version != 2 || got.Definitions[0].SignedOffBy != "HUM-1" ||
				got.Definitions[0].Params["period"] != "month" || got.Definitions[0].SignedOffAt == nil {
				t.Fatalf("newest definition: %+v", got.Definitions)
			}
			other, err := mm.ReadMarketingMetrics(ctx, b)
			if err != nil {
				t.Fatal(err)
			}
			if len(other.Samples) != 1 || other.Samples[0].Value != "999" || len(other.Definitions) != 0 {
				t.Fatalf("B reads %+v, want its one sample and no definition", other)
			}
		})
	}
}

// TestMarketingMetricsColumnDefaults: rdb 0244's own defaults are the Q7
// answer, so a writer that names no attribution (a later row's SQL) gets
// last touch over 28 days, the same as the Go constants.
func TestMarketingMetricsColumnDefaults(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	var rule string
	var days int
	err := pg.queryRowTenant(ctx, a, `INSERT INTO marketing_metric_definitions (tenant_id, metric, version) VALUES ($1, 'roas', 1)
		RETURNING attribution_rule, attribution_window_days`, []any{a}, &rule, &days)
	if err != nil {
		t.Fatal(err)
	}
	if rule != MarketingAttributionLastTouch || days != MarketingAttributionWindowDays {
		t.Errorf("rdb 0244 defaults: %q %d, want %q %d (Q7)", rule, days, MarketingAttributionLastTouch, MarketingAttributionWindowDays)
	}
}

// mktCount counts tenant's rows of table in one fresh transaction under
// scope: "tenant:<id>", "empty" (app.tenant_id = the empty string) or "none".
func mktCount(t *testing.T, pg *Postgres, table, scope, tenant string) int {
	t.Helper()
	ctx := context.Background()
	n := -1
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		switch {
		case scope == "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		case strings.HasPrefix(scope, "tenant:"):
			_, err = tx.Exec(ctx, pgScopeTenant, strings.TrimPrefix(scope, "tenant:"))
		}
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{table}.Sanitize()+` WHERE tenant_id = $1`, tenant).Scan(&n)
	})
	if err != nil {
		t.Fatalf("%s %s: %v", table, scope, err)
	}
	return n
}

// TestRLSMarketingMetrics: a row of workspace A is not read in B's scope,
// nor with an empty or no tenant set; B cannot write an A row (42501); an
// UPDATE or DELETE is refused as append-only, in A's own scope too; a
// tenant delete takes A's rows with it. CONTROL: with FORCE lifted (rolled
// back) the owner reads A's row with no tenant set, so the zeros are the
// policy's.
func TestRLSMarketingMetrics(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a, b := newTenant(t, pg), newTenant(t, pg)
	if _, err := pg.AddMarketingMetricSample(ctx, a, mktSample("impressions", "5", now), now); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.AddMarketingMetricDefinition(ctx, a, MarketingMetricDefinition{Metric: "ctr"}, now); err != nil {
		t.Fatal(err)
	}
	writes := map[string]string{
		"marketing_metric_samples": `INSERT INTO marketing_metric_samples (tenant_id, source, object_type, metric, value, period_start, period_end)
			VALUES ($1, 'ga4', 'site', 'sessions', 1, now(), now())`,
		"marketing_metric_definitions": `INSERT INTO marketing_metric_definitions (tenant_id, metric, version) VALUES ($1, 'b_wrote', 1)`,
	}
	for table, insert := range writes {
		for _, c := range []struct {
			scope string
			want  int
		}{{"tenant:" + b, 0}, {"empty", 0}, {"none", 0}, {"tenant:" + a, 1}} {
			if got := mktCount(t, pg, table, c.scope, a); got != c.want {
				t.Errorf("%s: scope %s reads %d of A's rows, want %d", table, c.scope, got, c.want)
			}
		}
		if _, err := pg.execTenant(ctx, b, insert, a); pgCode(err) != "42501" {
			t.Errorf("%s: an A row written under B's scope: %v (want 42501)", table, err)
		}
		for _, w := range []string{`UPDATE ` + table + ` SET tenant_id = tenant_id WHERE tenant_id = $1`, `DELETE FROM ` + table + ` WHERE tenant_id = $1`} {
			if _, err := pg.execTenant(ctx, a, w, a); err == nil || !strings.Contains(err.Error(), "append-only") {
				t.Errorf("%s: %s in A's own scope: %v, want the append-only refusal", table, w, err)
			}
		}
		var lifted int
		err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `ALTER TABLE `+table+` NO FORCE ROW LEVEL SECURITY`); err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, a).Scan(&lifted); err != nil {
				return err
			}
			return errRollback
		})
		if !errors.Is(err, errRollback) || lifted != 1 {
			t.Fatalf("%s CONTROL: without FORCE the owner read %d of A's rows with no tenant (%v), want 1", table, lifted, err)
		}
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, a)
		return err
	}); err != nil {
		t.Fatalf("a tenant delete with metrics rows: %v (the cascade must pass the append-only trigger)", err)
	}
	for table := range writes {
		if got := mktCount(t, pg, table, "tenant:"+a, a); got != 0 {
			t.Errorf("%s: %d rows outlive their tenant", table, got)
		}
	}
}

// TestRLSMarketingMetricsNullifControl (the RED control of the RLS case,
// the rls_failclosed_test.go pattern): rdb 0244's tenant_scope with the
// NULLIF taken out (the 0014 form) lets a statement with an empty tenant
// read a row whose tenant_id is empty, and the catalogue gate reports it;
// with 0244's own policies it reports nothing on either table.
func TestRLSMarketingMetricsNullifControl(t *testing.T) {
	rlsStore(t)
	ctx := context.Background()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	for _, table := range []string{"marketing_metric_samples", "marketing_metric_definitions"} {
		gaps, err := tenantPolicyGaps(ctx, dsn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `ALTER POLICY tenant_scope ON `+table+`
				USING (tenant_id = current_setting('app.tenant_id', true))
				WITH CHECK (tenant_id = current_setting('app.tenant_id', true))`)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		want := table + `.tenant_scope: tenant empty: USING is TRUE for a row with tenant_id ""`
		if !strings.Contains(strings.Join(gaps, "\n"), want) {
			t.Errorf("CONTROL: the policy without NULLIF was not reported (%q); gaps: %q", want, gaps)
		}
	}
	gaps, err := tenantPolicyGaps(ctx, dsn, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, g := range gaps {
		if strings.HasPrefix(g, "marketing_metric_") {
			t.Errorf("rdb 0244's own policy is reported: %s", g)
		}
	}
}
