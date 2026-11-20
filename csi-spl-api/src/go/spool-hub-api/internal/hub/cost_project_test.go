package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 123 13.8 row P01: GET /v1/tenant/costs/project over the month read's
// rows of costReadEnv (one estate gcp row 5.00, the operator workspace's own
// 1.00, the other workspace's own 2.00, all in 2011-03).

// projectParts is part -> its row of an answer, in order.
func projectParts(t *testing.T, body map[string]any) (names []string, by map[string]map[string]any) {
	t.Helper()
	by = map[string]map[string]any{}
	parts, _ := body["parts"].([]any)
	for _, p := range parts {
		row := p.(map[string]any)
		names = append(names, row["part"].(string))
		by[row["part"].(string)] = row
	}
	return names, by
}

func projectTotalUSD(body map[string]any) any {
	tot, _ := body["total"].(map[string]any)
	priced, _ := tot["priced"].(map[string]any)
	return priced["usd_micros"]
}

// TestCostProjectRead: the operator admin reads the estate's four parts,
// Cloud holding the gcp rows; Human is not_tracked (null) and the total
// partial; another workspace's admin reads two parts, its own gcp row named
// in left_out, never in a part. year= sums the year's months; bad periods
// are 400. CONTROL: the other workspace's row is there (left_out names it),
// so its 0 total is the two-part rule, not an empty month.
func TestCostProjectRead(t *testing.T) {
	e, op, other, who, whoOther, stub := costReadEnv(t)
	code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs/project?month=2011-03", who[rbac.Admin], nil)
	names, by := projectParts(t, body)
	if code != http.StatusOK || body["scope"] != "estate" || len(names) != 4 || names[0] != "cloud" || names[3] != "human" {
		t.Fatalf("operator admin: %d %v", code, body)
	}
	if by["cloud"]["usd_micros"] != float64(6_000_000) || projectTotalUSD(body) != float64(6_000_000) || by["cloud"]["share"] != float64(100) {
		t.Errorf("cloud %v total %v: want 6.00 USD, 100 %%", by["cloud"], body["total"])
	}
	if h := by["human"]; h["usd_micros"] != nil || h["completeness"] != "not_tracked" || !body["total"].(map[string]any)["partial"].(bool) {
		t.Errorf("human %v total %v: want not_tracked, null, the total partial", h, body["total"])
	}
	if by["owned_hardware"]["usd_micros"] != float64(0) || by["owned_hardware"]["completeness"] != "hand" {
		t.Errorf("owned hardware %v: want 0 until P08, entered by hand", by["owned_hardware"])
	}
	code, body = call(t, e, other, http.MethodGet, "/v1/tenant/costs/project?month=2011-03", whoOther[rbac.Admin], nil)
	names, _ = projectParts(t, body)
	left, _ := body["left_out"].([]any)
	if code != http.StatusOK || body["scope"] != "workspace" || len(names) != 2 || names[0] != "ai_tokens" || projectTotalUSD(body) != float64(0) {
		t.Errorf("other admin: %d %v, want ai_tokens and human, 0 priced", code, body)
	}
	if len(left) != 1 || left[0].(map[string]any)["usd_micros"] != float64(2_000_000) {
		t.Errorf("CONTROL: other's own 2.00 row not in left_out: %v", body["left_out"])
	}
	asks := 0
	if stub != nil {
		asks = len(stub.asks)
	}
	yearUSD := float64(6_000_000) // Postgres: the rows are March's
	if stub != nil {
		yearUSD *= 12 // the memory stand-in answers every month with the same rows
	}
	code, body = call(t, e, op, http.MethodGet, "/v1/tenant/costs/project?year=2011", who[rbac.Admin], nil)
	if code != http.StatusOK || body["period"] != "year" || body["from"] != "2011-01-01" || body["to"] != "2011-12-31" ||
		body["status"] != "ended" || body["days"] != float64(365) || projectTotalUSD(body) != yearUSD {
		t.Errorf("year 2011: %d %v, want Jan..Dec, %v USD micros", code, body, yearUSD)
	}
	if stub != nil && len(stub.asks)-asks != 12 {
		t.Errorf("year 2011 read %d months, want 12", len(stub.asks)-asks)
	}
	for _, q := range []string{"?month=2011-03&year=2011", "?year=11", "?year=abcd", "?year=2999", "?month=2999-01", "?month=2011-3"} {
		if code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs/project"+q, who[rbac.Admin], nil); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", q, code, body)
		}
	}
	if code, _ := call(t, e, other, http.MethodGet, "/v1/tenant/costs/project", "", nil); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Errorf("no session: %d, want 401 or 403", code)
	}
}
