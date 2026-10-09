package hub_test

import (
	"bytes"
	"encoding/csv"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/xlsx"
)

// Spec 107 T009: GET /v1/hours/export. Clock and weeks as hours_me_test.go.

func export(t *testing.T, e *env, tid, as, query string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/hours/export"+query, nil)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp, body
}

func csvLines(t *testing.T, body []byte) [][]string {
	t.Helper()
	rows, err := csv.NewReader(bytes.NewReader(body)).ReadAll()
	if err != nil {
		t.Fatalf("csv: %v\n%s", err, body)
	}
	return rows
}

// exportWeek: a and b approve entries of the week of 09-28 in a returned
// window, both rows frozen; then the owner approves a's period only.
func exportWeek(t *testing.T) (e *env, tid, owner, a, b string) {
	t.Helper()
	e, tid = hoursEnv(t)
	owner = seat(t, e, tid, rbac.BizOwner)
	a, b = seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	freezePrevWeek(t, e, tid, a, b)
	if code, out := decide(t, e, tid, owner, map[string]any{"period": hoursPrevWeek, "action": "return", "note": "add your week"}); code != http.StatusOK {
		t.Fatalf("return all: %d %v", code, out)
	}
	for _, h := range []string{a, b} {
		if code, out := putEntries(t, e, tid, h, map[string]any{"entries": []any{
			entry("2026-09-29", "t:task-x", 90, "approved"), entry("2026-09-30", "ch:general", 0, "rejected")},
			"resubmit": "2026-09-29"}); code != http.StatusOK {
			t.Fatalf("%s fills and resubmits: %d %v", h, code, out)
		}
	}
	if code, out := decide(t, e, tid, owner, map[string]any{"period": hoursPrevWeek, "action": "approve", "members": []string{a}}); code != http.StatusOK {
		t.Fatalf("approve a: %d %v", code, out)
	}
	return e, tid, owner, a, b
}

func TestHoursExportCSV(t *testing.T) {
	e, tid, owner, a, b := exportWeek(t)
	resp, body := export(t, e, tid, owner, "?period="+hoursPrevWeek)
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Content-Type") != "text/csv; charset=utf-8" {
		t.Fatalf("csv: %d %v %s", resp.StatusCode, resp.Header, body)
	}
	if cd, want := resp.Header.Get("Content-Disposition"), `attachment; filename="hours-`+tid+`-2026-09-28-2026-10-04.csv"`; cd != want {
		t.Fatalf("Content-Disposition %q, want %q", cd, want)
	}
	rows := csvLines(t, body)
	if strings.Join(rows[0], ",") != "date,member_id,member_name,target_type,target_id,target_name,issue_key,minutes,hours_decimal,suggested_minutes,note,period_state,approved_by,approved_at" {
		t.Fatalf("header: %v", rows[0])
	}
	// Final only (default): a's approved entry, never the rejected row nor b's frozen period.
	if len(rows) != 2 || rows[1][1] != a || rows[1][7] != "90" || rows[1][8] != "1.50" || rows[1][11] != "approved" || rows[1][12] != owner {
		t.Fatalf("final rows: %v", rows)
	}
	// final=false adds b's frozen period.
	_, body = export(t, e, tid, owner, "?period="+hoursPrevWeek+"&final=false")
	rows = csvLines(t, body)
	if len(rows) != 3 || rows[2][1] != b || rows[2][11] != "frozen" || strings.Contains(string(body), "ch:general") || strings.Contains(string(body), "general") {
		t.Fatalf("all rows: %v", rows)
	}
	// Refusals: no hours.read, a bad format.
	if resp, _ := export(t, e, tid, a, "?period="+hoursPrevWeek); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("developer export: %d", resp.StatusCode)
	}
	if resp, _ := export(t, e, tid, owner, "?format=pdf"); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("pdf: %d", resp.StatusCode)
	}
}

// The XLSX opens: the package parts, one sheet, the CSV's cells, numbers as
// numeric cells.
func TestHoursExportXLSX(t *testing.T) {
	e, tid, owner, a, _ := exportWeek(t)
	resp, body := export(t, e, tid, owner, "?period="+hoursPrevWeek+"&format=xlsx")
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Content-Type") != xlsx.ContentType ||
		!strings.HasSuffix(resp.Header.Get("Content-Disposition"), `-2026-09-28-2026-10-04.xlsx"`) {
		t.Fatalf("xlsx: %d %v", resp.StatusCode, resp.Header)
	}
	cells, err := xlsx.Read(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatal(err)
	}
	types, _ := xlsx.CellTypes(bytes.NewReader(body), int64(len(body)))
	if len(cells) != 2 || cells[0][0] != "date" || cells[1][1] != a || cells[1][7] != "90" || cells[1][8] != "1.5" {
		t.Fatalf("cells: %v", cells)
	}
	if types[1][7] != "n" || types[1][8] != "n" || types[1][9] != "n" || types[1][1] != "inlineStr" {
		t.Fatalf("types: %v", types)
	}
}

// A second workspace exports nothing of the first, and the first's owner
// cannot export the second.
func TestHoursExportCrossWorkspace(t *testing.T) {
	e, tid, owner, _, _ := exportWeek(t)
	t2, _ := e.tenant()
	owner2 := seat(t, e, t2, rbac.BizOwner)
	for _, q := range []string{"?period=" + hoursPrevWeek, "?period=" + hoursPrevWeek + "&final=false"} {
		resp, body := export(t, e, t2, owner2, q)
		if rows := csvLines(t, body); resp.StatusCode != http.StatusOK || len(rows) != 1 {
			t.Fatalf("t2 export%s: %d %v", q, resp.StatusCode, rows)
		}
	}
	if resp, _ := export(t, e, t2, owner, "?period="+hoursPrevWeek); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("t1 owner on t2: %d", resp.StatusCode)
	}
	// CONTROL: the first workspace's export holds the line.
	if _, body := export(t, e, tid, owner, "?period="+hoursPrevWeek); len(csvLines(t, body)) != 2 {
		t.Fatalf("CONTROL t1: %s", body)
	}
}
