package hub_test

import (
	"crypto/rand"
	"encoding/hex"
	"math/big"
	"net/http"
	"testing"
	"time"
)

// Spec 143 T020 / T021: the Releases tab's two reads. The deploy join itself
// is pinned on both drivers by the store's TestReportingReleasesDaily; here
// the routes, their query checks and the empty deploys of a hub that has no
// deploy recorded yet (row 4 not landed).

// reportDay is a random UTC day far from the other tests' notes: the table is
// estate-wide, so a shared Postgres holds them all.
func reportDay(t *testing.T) time.Time {
	t.Helper()
	n, err := rand.Int(rand.Reader, big.NewInt(300*365))
	if err != nil {
		t.Fatal(err)
	}
	return time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC).AddDate(0, 0, int(n.Int64()))
}

func reportSHA(t *testing.T) string {
	t.Helper()
	b := make([]byte, 20)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b)
}

func reportRow(sha, version, msg string, at time.Time) map[string]any {
	row := releaseRow(sha, version, msg)
	row["committed_at"] = at.Format(time.RFC3339)
	return row
}

func TestReportingReleasesDaily(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	d0 := reportDay(t)
	d1 := d0.AddDate(0, 0, 1)
	code, out := ingest(t, e, tid,
		reportRow(reportSHA(t), "v4.0.1", "feat(wui, SPL-1): the tab", d0.Add(time.Hour)),
		reportRow(reportSHA(t), "v4.0.1", "fix(api): the route", d0.Add(2*time.Hour)),
		reportRow(reportSHA(t), "v4.0.2", "fix(wui): the list", d1.Add(time.Hour)),
	)
	if code != http.StatusOK || out["stored"].(float64) != 3 {
		t.Fatalf("ingest: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/reporting/releases/daily?from="+d0.Format(time.DateOnly)+"&to="+d1.Format(time.DateOnly), hum, nil)
	if code != http.StatusOK {
		t.Fatalf("daily: %d %v", code, out)
	}
	days := out["days"].([]any)
	if out["total_commits"].(float64) != 3 || out["total_versions"].(float64) != 2 || len(days) != 2 {
		t.Fatalf("daily totals: %v", out)
	}
	newest, oldest := days[0].(map[string]any), days[1].(map[string]any)
	if newest["date"] != d1.Format(time.DateOnly) || oldest["date"] != d0.Format(time.DateOnly) {
		t.Fatalf("days not newest first: %v", days)
	}
	kinds, areas := oldest["kinds"].(map[string]any), oldest["areas"].(map[string]any)
	if oldest["commits_count"].(float64) != 2 || kinds["feat"].(float64) != 1 || kinds["fix"].(float64) != 1 ||
		areas["wui"].(float64) != 1 || areas["api"].(float64) != 1 {
		t.Fatalf("day %v", oldest)
	}
	// No deploy recorded: an empty list, never null and never an error.
	if dep, ok := oldest["deploys"].([]any); !ok || len(dep) != 0 {
		t.Fatalf("deploys of a day with none recorded: %#v", oldest["deploys"])
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/reporting/releases/daily?kind=fix&area=wui&from="+d0.Format(time.RFC3339)+"&to="+d1.AddDate(0, 0, 1).Format(time.RFC3339), hum, nil)
	if code != http.StatusOK || out["total_commits"].(float64) != 1 {
		t.Fatalf("kind+area filter: %d %v", code, out)
	}
}

func TestReportingReleasesCommits(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	d0 := reportDay(t)
	a, b := reportSHA(t), reportSHA(t)
	if code, out := ingest(t, e, tid,
		reportRow(a, "v5.0.1", "feat(wui): the releases tab", d0.Add(time.Hour)),
		reportRow(b, "v5.0.2", releaseFullMsg, d0.Add(2*time.Hour)),
	); code != http.StatusOK {
		t.Fatalf("ingest: %d %v", code, out)
	}
	win := "&from=" + d0.Format(time.DateOnly) + "&to=" + d0.Format(time.DateOnly)
	for search, want := range map[string]string{
		"RELEASES+TAB":           a, // subject, any case
		b[:10]:                   b, // sha prefix
		"v5.0.2":                 b, // version
		"marks+the+channel+read": b, // a Tech-* trailer
	} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/commits?search="+search+win, hum, nil)
		if code != http.StatusOK {
			t.Fatalf("search %s: %d %v", search, code, out)
		}
		notes := out["notes"].([]any)
		if out["total"].(float64) != 1 || len(notes) != 1 || notes[0].(map[string]any)["sha"] != want {
			t.Errorf("search %s: %v, want %s", search, out, want)
		}
	}
	code, out := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/commits?limit=1&offset=1"+win, hum, nil)
	if code != http.StatusOK || out["total"].(float64) != 2 || out["notes"].([]any)[0].(map[string]any)["sha"] != a {
		t.Fatalf("page 2 (newest first): %d %v", code, out)
	}
}

// CONTROLS: a bad date, a bad limit, a bad kind and a missing session.
func TestReportingReleasesRefusals(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	for _, path := range []string{
		"/v1/reporting/releases/daily?from=yesterday",
		"/v1/reporting/releases/daily?to=2026-13-40",
		"/v1/reporting/releases/daily?from=2026-10-10&to=2026-10-01",
		"/v1/reporting/releases/daily?from=2020-01-01&to=2026-01-01",
		"/v1/reporting/releases/daily?kind=FIX!",
		"/v1/reporting/releases/commits?limit=0",
		"/v1/reporting/releases/commits?limit=201",
		"/v1/reporting/releases/commits?offset=-1",
	} {
		code, out := call(t, e, tid, http.MethodGet, path, hum, nil)
		if code != http.StatusBadRequest || out["error"] != "bad_query" {
			t.Errorf("%s: %d %v, want 400 bad_query", path, code, out)
		}
	}
	for _, path := range []string{"/v1/reporting/releases/daily", "/v1/reporting/releases/commits"} {
		if code, _ := call(t, e, tid, http.MethodGet, path, "", nil); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("anonymous %s: %d", path, code)
		}
		if code, _ := call(t, e, tid, http.MethodGet, path, hum, nil); code != http.StatusOK {
			t.Errorf("member %s with the default window: %d", path, code)
		}
	}
}
