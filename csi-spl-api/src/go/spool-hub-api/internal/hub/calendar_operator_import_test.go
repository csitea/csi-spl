package hub_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// spec 180 FR-2, FR-3, FR-11, cases 1-4 and 6-8: PUT
// /v1/operator/calendar/import/outlook. A first import creates the owner's
// private events (read by the owner, not by another member); the same batch
// again is all unchanged (case 2); a moved meeting is one created and one
// deleted (case 3); a cancelled one is deleted (case 4). CONTROLS, each
// writing nothing: a 06.30.00 time is 400 naming the event (case 6), an
// owner who is not a member is 403 (case 7), the switch off is 404 (case 8),
// a wrong format and no token. Memory, and Postgres under SPOOL_TEST_PG_DSN.

func outlookEnv(t *testing.T, on bool) *env {
	return rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.CalendarOutlookImportEnabled = on
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
}

func outlookOcc(id, title, start, end string) map[string]any {
	return map[string]any{"source_id": id, "title": title, "starts_at": start, "ends_at": end, "all_day": false,
		"day": "", "end_day": "", "location": "Room 1", "busy_status": "Busy", "private": false, "recurring": false}
}

func outlookFile(events ...map[string]any) map[string]any {
	evs := make([]any, 0, len(events))
	for _, e := range events {
		evs = append(evs, e)
	}
	return map[string]any{"format": "spool-hub-outlook-export/1", "exported_at": "2027-02-01T05:00:00Z",
		"time_zone": "Europe/Helsinki", "from": "2027-01-31T22:00:00Z", "to": "2027-02-14T22:00:00Z",
		"count": len(evs), "events": evs}
}

func TestOperatorCalendarImportOutlook(t *testing.T) {
	e := outlookEnv(t, true)
	ta, _ := e.tenant()
	boss, other := seat(t, e, ta, rbac.Developer), seat(t, e, ta, rbac.Developer)
	path := func(owner string) string {
		return "/v1/operator/calendar/import/outlook?tenant=" + ta + "&owner=" + owner
	}
	put := func(owner, token string, body any) (int, map[string]any) {
		return opCall(t, e, ta, http.MethodPut, path(owner), token, body)
	}
	const week = "/v1/calendar/events?start=2027-01-31T00:00:00Z&end=2027-02-15T00:00:00Z"
	titles := func(as string) map[string]string {
		t.Helper()
		code, out := call(t, e, ta, http.MethodGet, week, as, nil)
		if code != http.StatusOK {
			t.Fatalf("list as %s: %d %v", as, code, out)
		}
		got := map[string]string{}
		for _, x := range out["events"].([]any) {
			ev := x.(map[string]any)
			got[ev["title"].(string)] = ev["starts_at"].(string) + " " + ev["audience"].(string)
			got["key:"+ev["title"].(string)] = ev["source_key"].(string)
		}
		return got
	}
	counts := func(what string, code int, out map[string]any, c, u, n, d float64) {
		t.Helper()
		if code != http.StatusOK || out["created"] != c || out["updated"] != u || out["unchanged"] != n || out["deleted"] != d {
			t.Fatalf("%s: %d %v, want created %v updated %v unchanged %v deleted %v", what, code, out, c, u, n, d)
		}
	}
	stand := outlookOcc("G1@2027-02-01 09:00", "Standup", "2027-02-01T07:00:00Z", "2027-02-01T07:15:00Z")
	review := outlookOcc("G2@2027-02-02 13:00", "Review", "2027-02-02T11:00:00Z", "2027-02-02T12:00:00Z")
	allDay := outlookOcc("G3@2027-02-03 00:00", "Offsite", "", "")
	allDay["all_day"], allDay["day"], allDay["end_day"] = true, "2027-02-03", "2027-02-04"

	code, out := put(boss, "good", outlookFile(stand, review, allDay))
	counts("first import", code, out, 3, 0, 0, 0)
	sum := sha256.Sum256([]byte("G1@2027-02-01 09:00"))
	if got := titles(boss); got["Standup"] != "2027-02-01T07:00:00Z private" || got["Offsite"] != "2027-02-03T00:00:00Z private" ||
		got["key:Standup"] != "outlook:"+boss+":"+hex.EncodeToString(sum[:])[:24] || len(got) != 6 {
		t.Fatalf("the owner reads %v", got)
	}
	if got := titles(other); len(got) != 0 {
		t.Fatalf("another member reads the owner's import: %v", got)
	}
	code, out = put(boss, "good", outlookFile(stand, review, allDay))
	counts("case 2: the same batch twice", code, out, 0, 0, 3, 0)

	moved := outlookOcc("G1@2027-02-01 10:00", "Standup", "2027-02-01T08:00:00Z", "2027-02-01T08:15:00Z")
	code, out = put(boss, "good", outlookFile(moved, review, allDay))
	counts("case 3: a moved meeting", code, out, 1, 0, 2, 1)
	if got := titles(boss); got["Standup"] != "2027-02-01T08:00:00Z private" || len(got) != 6 {
		t.Fatalf("after the move the owner reads %v", got)
	}
	code, out = put(boss, "good", outlookFile(moved, allDay))
	counts("case 4: a cancelled meeting", code, out, 0, 0, 2, 1)
	before := titles(boss)

	finnish := outlookOcc("G4@x", "Late", "2027-02-05T06.30.00Z", "2027-02-05T07:00:00Z")
	wrong := outlookFile(moved)
	wrong["format"] = "spool-hub-outlook-export/2"
	for _, c := range []struct {
		name, owner, token string
		body               any
		code               int
		errCode            string
	}{
		{"case 6: a 06.30.00 time", boss, "good", outlookFile(moved, finnish), http.StatusBadRequest, "bad_event"},
		{"case 7: an owner who is not a member", "HUM-99999", "good", outlookFile(moved), http.StatusForbidden, "not_a_member"},
		{"another format", boss, "good", wrong, http.StatusBadRequest, "bad_event"},
		{"no source_id", boss, "good", outlookFile(outlookOcc("", "x", "2027-02-05T06:30:00Z", "2027-02-05T07:00:00Z")), http.StatusBadRequest, "bad_event"},
		{"no operator token", boss, "bad", outlookFile(moved), http.StatusUnauthorized, ""},
	} {
		code, out := put(c.owner, c.token, c.body)
		if code != c.code || (c.errCode != "" && out["error"] != c.errCode) {
			t.Fatalf("%s: %d %v, want %d %s", c.name, code, out, c.code, c.errCode)
		}
		if c.name == "case 6: a 06.30.00 time" && out["detail"] != "event 1: starts_at is not an RFC 3339 time" {
			t.Fatalf("case 6 does not name the event: %v", out)
		}
	}
	if got := titles(boss); len(got) != len(before) || got["Late"] != "" {
		t.Fatalf("a refused import wrote: %v", got)
	}

	off := outlookEnv(t, false)
	tb, _ := off.tenant()
	hum := seat(t, off, tb, rbac.Developer)
	code, out = opCall(t, off, tb, http.MethodPut, "/v1/operator/calendar/import/outlook?tenant="+tb+"&owner="+hum, "good", outlookFile(moved))
	if code != http.StatusNotFound {
		t.Fatalf("case 8: the switch off: %d %v, want 404", code, out)
	}
	if code, got := call(t, off, tb, http.MethodGet, week, hum, nil); code != http.StatusOK || len(got["events"].([]any)) != 0 {
		t.Fatalf("case 8 wrote: %d %v", code, got)
	}
}
