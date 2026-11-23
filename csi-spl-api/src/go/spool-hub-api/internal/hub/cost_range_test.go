package hub_test

import (
	"bytes"
	"io"
	"net/http"
	"net/url"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-6300 (spec 123 5.2 and 5.5): the cost reads take a month range,
// ?from=YYYY-MM&to=YYYY-MM, both months included. Synthetic rows only, in
// 2012-01..2012-03 (the cost tests' 2011-03 stays theirs). On Postgres the
// real store reads them; on the memory store costReadStub answers by day.

// callRaw is call's answer as the bytes the hub wrote.
func callRaw(t *testing.T, e *env, tid, path, as string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+path, nil)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, raw
}

// costRangeEnv is costReadEnv with one estate project costing 1.00, 2.00
// and 4.00 USD in 2012-01, -02 and -03, and the operator workspace's own
// 0.50 in 2012-02.
func costRangeEnv(t *testing.T) (e *env, op, pov string, who map[string]string) {
	t.Helper()
	e, op, _, who, _, stub := costReadEnv(t)
	pov = newTenantID("csi-spl-")
	costSeedRows(t, e, stub, "2012-01-01", "2012-04-01", []costSeedRow{
		{"", pov, 1_000_000, "2012-01-10"}, {"", pov, 2_000_000, "2012-02-10"}, {"", pov, 4_000_000, "2012-03-10"},
		{op, "op-range", 500_000, "2012-02-15"},
	})
	return e, op, pov, who
}

func costTotalUSD(body map[string]any) any {
	tot, _ := body["total"].(map[string]any)
	return tot["usd_micros"]
}

// partOf is the part of an answer whose project_or_vendor is pov.
func partOf(body map[string]any, pov string) map[string]any {
	parts, _ := body["parts"].([]any)
	for _, p := range parts {
		if row := p.(map[string]any); row["project_or_vendor"] == pov {
			return row
		}
	}
	return nil
}

// TestCostReadRangeOneMonth: from=M&to=M answers ?month=M byte for byte,
// and ?month= is unchanged (no month_from / month_to). CONTROL: the answer
// holds 2011-03's rows, so the equality is of a full answer, not two empties.
func TestCostReadRangeOneMonth(t *testing.T) {
	e, op, _, who := costRangeEnv(t)
	code, month := callRaw(t, e, op, "/v1/tenant/costs?month=2011-03", who[rbac.Admin])
	if code != http.StatusOK || !bytes.Contains(month, []byte(`"op-own"`)) {
		t.Fatalf("CONTROL: ?month=2011-03: %d %s", code, month)
	}
	if bytes.Contains(month, []byte("month_from")) {
		t.Errorf("?month= answer carries a range: %s", month)
	}
	code, rng := callRaw(t, e, op, "/v1/tenant/costs?from=2011-03&to=2011-03", who[rbac.Admin])
	if code != http.StatusOK || !bytes.Equal(month, rng) {
		t.Errorf("from=to=2011-03: %d\n%s\nwant byte for byte\n%s", code, rng, month)
	}
}

// TestCostReadRangeSums: a 3-month range is the months summed: the project's
// part 7.00 USD over 3 cost days, the total the sum of the three month
// totals, days 91 (2012 is a leap year) all ended. CONTROL: each month
// alone reads its own amount, so the sum is of three different months.
func TestCostReadRangeSums(t *testing.T) {
	e, op, pov, who := costRangeEnv(t)
	sum := float64(0)
	for m, want := range map[string]float64{"2012-01": 1_000_000, "2012-02": 2_000_000, "2012-03": 4_000_000} {
		code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs?month="+m, who[rbac.Admin], nil)
		if p := partOf(body, pov); code != http.StatusOK || p == nil || p["usd_micros"] != want {
			t.Fatalf("CONTROL: %s: %d %v, want %v", m, code, p, want)
		}
		sum += costTotalUSD(body).(float64)
	}
	code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs?from=2012-01&to=2012-03", who[rbac.Admin], nil)
	p := partOf(body, pov)
	if code != http.StatusOK || p == nil || p["usd_micros"] != float64(7_000_000) || p["eur_micros"] != float64(7_000_000) || p["days"] != float64(3) {
		t.Fatalf("2012-01..03: %d part %v, want 7.00 USD over 3 days (%v)", code, p, body)
	}
	if costTotalUSD(body) != sum || sum != float64(7_500_000) {
		t.Errorf("range total %v, want the months' sum %v = 7.50", costTotalUSD(body), sum)
	}
	if body["month_from"] != "2012-01" || body["month_to"] != "2012-03" || body["from"] != "2012-01-01" || body["to"] != "2012-03-31" ||
		body["days"] != float64(91) || body["days_ended"] != float64(91) || body["status"] != "ended" {
		t.Errorf("range window: %v", body)
	}
	if p["pct"] != float64(93.3) {
		t.Errorf("pct %v, want 93.3 (7.00 of 7.50)", p["pct"])
	}
}

// TestCostReadRangeRefused: a bad range is 400 naming why; ?month= still
// refuses as before. CONTROL: the same reader reads the good range 200.
func TestCostReadRangeRefused(t *testing.T) {
	e, op, _, who := costRangeEnv(t)
	if code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs?from=2012-01&to=2012-03", who[rbac.Admin], nil); code != http.StatusOK {
		t.Fatalf("CONTROL: %d %v", code, body)
	}
	for q, why := range map[string]string{
		"from=2012-03&to=2012-01":               "from 2012-03 is after to 2012-01",
		"from=2012-01":                          "from and to come together, both YYYY-MM",
		"to=2012-01":                            "from and to come together, both YYYY-MM",
		"month=2012-01&from=2012-01&to=2012-02": "month and from/to are one period: ask one",
		"from=2012-1&to=2012-03":                "from must be YYYY-MM",
		"from=2012-01&to=march":                 "to must be YYYY-MM",
		"from=2010-01&to=2012-01":               "a range is at most 24 months",
		"from=2012-01&to=2999-01":               "a range is at most 24 months",
		"from=2998-12&to=2999-01":               "month 2998-12 has not started",
	} {
		code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs?"+q, who[rbac.Admin], nil)
		if code != http.StatusBadRequest || body["detail"] != why {
			t.Errorf("?%s: %d %v, want 400 %q", q, code, body, why)
		}
	}
	if code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs?month=2011-3", who[rbac.Admin], nil); code != http.StatusBadRequest {
		t.Errorf("?month=2011-3: %d %v, want 400", code, body)
	}
}

// TestCostCloudDaysRange: the Cloud drill's day level over a range is every
// month's days, oldest first; from=to is the month read. CONTROL: ?month=
// alone holds one of the three days.
func TestCostCloudDaysRange(t *testing.T) {
	e, op, pov, who := costRangeEnv(t)
	p := "&project=" + url.QueryEscape(pov)
	code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs/cloud?month=2012-02"+p, who[rbac.Admin], nil)
	if days, _ := body["days"].([]any); code != http.StatusOK || len(days) != 1 || body["month_from"] != nil {
		t.Fatalf("CONTROL: month 2012-02: %d %v", code, body)
	}
	code, body = call(t, e, op, http.MethodGet, "/v1/tenant/costs/cloud?from=2012-01&to=2012-03"+p, who[rbac.Admin], nil)
	days, _ := body["days"].([]any)
	if code != http.StatusOK || len(days) != 3 || body["month_from"] != "2012-01" || body["month_to"] != "2012-03" {
		t.Fatalf("range: %d %v", code, body)
	}
	for i, want := range []string{"2012-01-10", "2012-02-10", "2012-03-10"} {
		if d := days[i].(map[string]any); d["day"] != want {
			t.Errorf("day %d %v, want %s", i, d, want)
		}
	}
	if code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs/cloud?from=2012-03&to=2012-01"+p, who[rbac.Admin], nil); code != http.StatusBadRequest {
		t.Errorf("from after to: %d %v, want 400", code, body)
	}
}

// TestCostProjectRange: the project's cost takes the range as period
// "range": Cloud is the three months' estate and own rows, 7.50 USD;
// from/to with year is 400. CONTROL: the single month 2012-02 is 2.50.
func TestCostProjectRange(t *testing.T) {
	e, op, _, who := costRangeEnv(t)
	code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs/project?month=2012-02", who[rbac.Admin], nil)
	if _, by := projectParts(t, body); code != http.StatusOK || body["period"] != "month" || by["cloud"]["usd_micros"] != float64(2_500_000) {
		t.Fatalf("CONTROL: 2012-02: %d %v", code, body)
	}
	code, body = call(t, e, op, http.MethodGet, "/v1/tenant/costs/project?from=2012-01&to=2012-03", who[rbac.Admin], nil)
	_, by := projectParts(t, body)
	if code != http.StatusOK || body["period"] != "range" || body["month_from"] != "2012-01" || body["month_to"] != "2012-03" ||
		by["cloud"]["usd_micros"] != float64(7_500_000) || body["days"] != float64(91) {
		t.Errorf("range: %d %v", code, body)
	}
	code, body = call(t, e, op, http.MethodGet, "/v1/tenant/costs/project?from=2012-02&to=2012-02", who[rbac.Admin], nil)
	if code != http.StatusOK || body["period"] != "month" || body["month_from"] != nil {
		t.Errorf("from=to: %d %v, want the month answer", code, body)
	}
	if code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs/project?from=2012-01&to=2012-03&year=2012", who[rbac.Admin], nil); code != http.StatusBadRequest {
		t.Errorf("range and year: %d %v, want 400", code, body)
	}
}
