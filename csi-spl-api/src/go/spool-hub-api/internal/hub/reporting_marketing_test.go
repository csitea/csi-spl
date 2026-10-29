package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 163 row B1 (SPL-4250): GET /v1/reporting/marketing, the Reporting
// Marketing tab's read. Memory, and Postgres under SPOOL_TEST_PG_DSN (rdb
// 0244's RLS). RED CONTROL (master): the route did not exist, every call
// answered 404.

const marketingReportPath = "/v1/reporting/marketing"

type marketingReport struct {
	AsOf        string `json:"as_of"`
	Attribution struct {
		Rule       string `json:"rule"`
		WindowDays int    `json:"window_days"`
	} `json:"attribution"`
	Stages  []string `json:"stages"`
	Samples []struct {
		Source string `json:"source"`
		Metric string `json:"metric"`
		Value  string `json:"value"`
	} `json:"samples"`
	Definitions []struct {
		Metric  string `json:"metric"`
		Version int    `json:"version"`
	} `json:"definitions"`
}

// TestReportingMarketing (Q8): the workspace's owner (biz_owner) and an
// admin read its marketing numbers; every other role, a member included,
// and the anonymous guest get 403 reporting.marketing. The answer carries
// the Q7 attribution (last touch, 28 days), the seven stage cards in the
// overview's order, and this workspace's newest samples and definitions,
// never another workspace's.
func TestReportingMarketing(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	mm := e.st.(store.MarketingMetrics)
	day := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	for tid, value := range map[string]string{other: "42", op: "7"} {
		if _, err := mm.AddMarketingMetricSample(ctx, tid, store.MarketingMetricSample{Source: "ga4", ObjectType: "site",
			Metric: "sessions", Value: value, PeriodStart: day, PeriodEnd: day.Add(24 * time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := mm.AddMarketingMetricDefinition(ctx, other, store.MarketingMetricDefinition{Metric: "cpl", Formula: "spend / leads"}, now); err != nil {
		t.Fatal(err)
	}
	for _, role := range rbac.RoleIDs {
		want := http.StatusForbidden
		if role == rbac.Admin || role == rbac.BizOwner {
			want = http.StatusOK
		}
		code, body := call(t, e, other, http.MethodGet, marketingReportPath, whoOther[role], nil)
		if code != want {
			t.Errorf("%s: %d %v, want %d", role, code, body, want)
			continue
		}
		if want == http.StatusForbidden {
			if body["permission"] != "reporting.marketing" {
				t.Errorf("%s: %v, want permission reporting.marketing", role, body)
			}
			continue
		}
		raw, _ := json.Marshal(body)
		var got marketingReport
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatal(err)
		}
		if got.Attribution.Rule != "last_touch" || got.Attribution.WindowDays != 28 {
			t.Errorf("%s: attribution %+v, want last_touch 28 (Q7)", role, got.Attribution)
		}
		if !slices.Equal(got.Stages, []string{"reach", "engagement", "acquisition", "conversion", "revenue", "retention", "content_seo"}) {
			t.Errorf("%s: stages %v", role, got.Stages)
		}
		if len(got.Samples) != 1 || got.Samples[0].Value != "42" || len(got.Definitions) != 1 || got.Definitions[0].Version != 1 || got.AsOf == "" {
			t.Errorf("%s: reads %+v, want this workspace's one sample (42) and one definition", role, got)
		}
	}
	if code, body := call(t, e, other, http.MethodGet, marketingReportPath, "", nil); code != http.StatusForbidden || body["permission"] != "reporting.marketing" {
		t.Errorf("anonymous: %d %v, want 403 reporting.marketing", code, body)
	}
	code, body := call(t, e, op, http.MethodGet, marketingReportPath, who[rbac.Admin], nil)
	raw, _ := json.Marshal(body)
	var theirs marketingReport
	_ = json.Unmarshal(raw, &theirs)
	if code != http.StatusOK || len(theirs.Samples) != 1 || theirs.Samples[0].Value != "7" || len(theirs.Definitions) != 0 {
		t.Errorf("another workspace's admin: %d %+v, want only its own sample (7)", code, theirs)
	}
}
