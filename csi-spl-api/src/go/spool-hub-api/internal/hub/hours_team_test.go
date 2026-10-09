package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 107 T008: the team routes GET /v1/hours and PUT /v1/hours/periods.
// The clock and weeks are hours_me_test.go's: Wed 2026-10-07 12:00 UTC, the
// week of 09-28 frozen, the week of 10-05 open. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

func teamHours(t *testing.T, e *env, tid, as, query string) map[string]any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/hours"+query, as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET /v1/hours%s as %s: %d %v", query, as, code, out)
	}
	return out
}

// teamMember is the members row of hum in a team answer, nil when none.
func teamMember(out map[string]any, hum string) map[string]any {
	ms, _ := out["members"].([]any)
	for _, x := range ms {
		if m := x.(map[string]any); m["member_id"] == hum {
			return m
		}
	}
	return nil
}

func decide(t *testing.T, e *env, tid, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPut, "/v1/hours/periods", as, body)
}

// freezePrevWeek writes the sweep's frozen row of the week of 09-28 for hums.
func freezePrevWeek(t *testing.T, e *env, tid string, hums ...string) {
	t.Helper()
	for _, h := range hums {
		if _, err := hoursStore(e).CreateHoursPeriod(context.Background(), tid, store.HoursPeriod{Member: h,
			Start: hoursPrevWeek, End: "2026-10-04", State: store.HoursFrozen, DecidedBy: store.HoursSweepBy,
			DecidedAt: hoursNow}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestTeamHoursPermissions(t *testing.T) {
	e, tid := hoursEnv(t)
	owner := seat(t, e, tid, rbac.BizOwner)
	freezePrevWeek(t, e, tid, owner)
	for _, role := range []string{rbac.Developer, rbac.Admin, rbac.ProductOwner} {
		hum := seat(t, e, tid, role)
		if code, out := call(t, e, tid, http.MethodGet, "/v1/hours", hum, nil); code != http.StatusForbidden || out["permission"] != rbac.HoursRead {
			t.Errorf("%s GET: %d %v", role, code, out)
		}
		code, out := decide(t, e, tid, hum, map[string]any{"period": hoursPrevWeek, "action": "approve"})
		if code != http.StatusForbidden || out["permission"] != rbac.HoursApprove {
			t.Errorf("%s PUT: %d %v", role, code, out)
		}
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/hours", "", nil); code < 400 {
		t.Fatalf("anonymous GET: %d", code)
	}
	// CONTROL: the biz owner holds both.
	out := teamHours(t, e, tid, owner, "?period="+hoursPrevWeek)
	if per := out["period"].(map[string]any); per["start"] != hoursPrevWeek || per["end"] != "2026-10-04" {
		t.Fatalf("period: %v", per)
	}
	if m := teamMember(out, owner); m == nil || m["state"] != "frozen" {
		t.Fatalf("owner row: %v", out["members"])
	}
	if code, out := decide(t, e, tid, owner, map[string]any{"period": hoursPrevWeek, "action": "approve", "members": []string{owner}}); code != http.StatusOK {
		t.Fatalf("CONTROL approve: %d %v", code, out)
	}
}

// Return reopens one member only, needs a note, is audited; the worker's
// Resubmit brings the row back to frozen; Approve and Approve all are final.
func TestTeamHoursReturnResubmitApprove(t *testing.T) {
	e, tid := hoursEnv(t)
	owner := seat(t, e, tid, rbac.BizOwner)
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	freezePrevWeek(t, e, tid, a, b)

	if code, out := decide(t, e, tid, owner, map[string]any{"period": "2026-09-30", "action": "return", "members": []string{a}}); code != http.StatusBadRequest {
		t.Fatalf("return without a note: %d %v", code, out)
	}
	code, out := decide(t, e, tid, owner, map[string]any{"period": "2026-09-30", "action": "return", "members": []string{a}, "note": "Tuesday is missing"})
	if code != http.StatusOK || out["changed"] != float64(1) {
		t.Fatalf("return a: %d %v", code, out)
	}
	if m := teamMember(out, a); m["state"] != "returned" || m["note"] != "Tuesday is missing" || m["decided_by"] != owner {
		t.Fatalf("a after return: %v", m)
	}
	if m := teamMember(out, b); m["state"] != "frozen" {
		t.Fatalf("b after a's return: %v", m)
	}
	// Only a frozen row moves: a returned row is 409, and nothing of the batch is written.
	if code, out := decide(t, e, tid, owner, map[string]any{"period": "2026-09-30", "action": "approve", "members": []string{b, a}}); code != http.StatusConflict || out["error"] != "period_state" {
		t.Fatalf("approve a returned row: %d %v", code, out)
	}
	if m := teamMember(teamHours(t, e, tid, owner, "?period=2026-09-30"), b); m["state"] != "frozen" {
		t.Fatalf("a refused batch moved b: %v", m)
	}
	// a can edit; b cannot.
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-09-29", "t:x", 60, "approved")}}); code != http.StatusOK {
		t.Fatalf("a edits a returned period: %d %v", code, out)
	}
	if code, out := putEntries(t, e, tid, b, map[string]any{"entries": []any{entry("2026-09-29", "t:x", 60, "approved")}}); code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("b edits a frozen period: %d %v", code, out)
	}
	assertHoursReturnedAudit(t, e, tid, a, owner)

	// Resubmit (T006): back to frozen, in the owner's list with the new total.
	if code, out := putEntries(t, e, tid, a, map[string]any{"resubmit": "2026-09-29"}); code != http.StatusOK {
		t.Fatalf("resubmit: %d %v", code, out)
	}
	out = teamHours(t, e, tid, owner, "?period=2026-09-30")
	if m := teamMember(out, a); m["state"] != "frozen" || m["period_minutes"] != float64(60) || m["minutes"] != float64(60) {
		t.Fatalf("a after resubmit: %v", m)
	}
	// Approve one, then Approve all takes the rest.
	if code, out := decide(t, e, tid, owner, map[string]any{"period": "2026-09-30", "action": "approve", "members": []string{a}}); code != http.StatusOK || teamMember(out, a)["state"] != "approved" {
		t.Fatalf("approve a: %d %v", code, out)
	}
	code, out = decide(t, e, tid, owner, map[string]any{"period": "2026-09-30", "action": "approve"})
	if code != http.StatusOK || out["changed"] != float64(1) || teamMember(out, b)["state"] != "approved" {
		t.Fatalf("approve all: %d %v", code, out)
	}
	// Final: no return of an approved row, and a cannot resubmit or edit.
	if code, _ := decide(t, e, tid, owner, map[string]any{"period": "2026-09-30", "action": "return", "members": []string{a}, "note": "x"}); code != http.StatusConflict {
		t.Fatalf("return an approved row: %d", code)
	}
	if code, _ := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-09-29", "t:x", 30, "approved")}}); code != http.StatusConflict {
		t.Fatalf("edit an approved period: %d", code)
	}
}

// Return all returns every frozen row of the period with one note.
func TestTeamHoursReturnAll(t *testing.T) {
	e, tid := hoursEnv(t)
	owner := seat(t, e, tid, rbac.BizOwner)
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	freezePrevWeek(t, e, tid, a, b)
	code, out := decide(t, e, tid, owner, map[string]any{"period": hoursPrevWeek, "action": "return", "note": "wrong rates"})
	if code != http.StatusOK || out["changed"] != float64(2) {
		t.Fatalf("return all: %d %v", code, out)
	}
	for _, h := range []string{a, b} {
		if m := teamMember(out, h); m["state"] != "returned" || m["note"] != "wrong rates" {
			t.Fatalf("%s: %v", h, m)
		}
	}
}

// assertHoursReturnedAudit: a member_activity hours_returned row for a, by
// owner, where the store keeps the audit (Postgres; memory has none).
func assertHoursReturnedAudit(t *testing.T, e *env, tid, a, owner string) {
	t.Helper()
	l, ok := e.st.(interface {
		ListMemberActivity(ctx context.Context, tenant, subject string) ([]store.MemberActivity, error)
	})
	if !ok {
		return
	}
	rows, err := l.ListMemberActivity(context.Background(), tid, a)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.Kind == "hours_returned" && r.ActorHum == owner && r.Detail == hoursPrevWeek+"..2026-10-04" {
			return
		}
	}
	t.Fatalf("no hours_returned audit row for %s: %+v", a, rows)
}

// The no-leak test (spec 1.7): a hours.read holder never receives a raw
// minute, a rejected row or an unapproved suggestion.
func TestTeamHoursNoLeak(t *testing.T) {
	e, tid := hoursEnv(t)
	owner := seat(t, e, tid, rbac.BizOwner)
	a := seat(t, e, tid, rbac.Developer)
	mon := time.Date(2026, 10, 5, 9, 0, 0, 0, time.UTC)
	call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon, 20, "t:approved-task"))
	call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon.Add(2*time.Hour), 15, "t:rejected-task"))
	call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon.Add(4*time.Hour), 12, "t:open-suggestion"))
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{
		entry("2026-10-05", "t:approved-task", 20, "approved"), entry("2026-10-05", "t:rejected-task", 0, "rejected")}}); code != http.StatusOK {
		t.Fatalf("a approves: %d %v", code, out)
	}
	// The member sees the suggestion (CONTROL: it exists).
	if hoursRow(t, myHours(t, e, tid, a, "2026-10-05"), "2026-10-05", "t:open-suggestion") == nil {
		t.Fatal("CONTROL: a has no open suggestion")
	}
	for _, q := range []string{"", "?period=2026-10-05", "?period=2026-10-05&member=" + a, "?period=2026-10-05&target=t"} {
		out := teamHours(t, e, tid, owner, q)
		raw, _ := json.Marshal(out)
		for _, leak := range []string{"t:rejected-task", "t:open-suggestion", "blocks", `"src"`, "suggested\""} {
			if strings.Contains(string(raw), leak) {
				t.Fatalf("GET /v1/hours%s leaks %s: %s", q, leak, raw)
			}
		}
		es, _ := out["entries"].([]any)
		if len(es) != 1 || es[0].(map[string]any)["target"] != "t:approved-task" || es[0].(map[string]any)["minutes"] != float64(20) {
			t.Fatalf("GET /v1/hours%s entries: %v", q, es)
		}
		if m := teamMember(out, a); m == nil || m["minutes"] != float64(20) || m["state"] != "open" {
			t.Fatalf("GET /v1/hours%s a: %v", q, m)
		}
	}
	// The filters narrow: another member, another target type.
	if es, _ := teamHours(t, e, tid, owner, "?period=2026-10-05&member="+owner)["entries"].([]any); len(es) != 0 {
		t.Fatalf("member filter: %v", es)
	}
	if es, _ := teamHours(t, e, tid, owner, "?period=2026-10-05&target=ch")["entries"].([]any); len(es) != 0 {
		t.Fatalf("target filter: %v", es)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/hours?period=last-week", owner, nil); code != http.StatusBadRequest {
		t.Fatalf("bad period: %d", code)
	}
}
