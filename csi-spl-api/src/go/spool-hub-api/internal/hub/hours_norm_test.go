package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 107 FR-41 (SPL-5440): the workspace's average hours per day. The biz
// owner, the product owner and the admin set it (hours.norm, rdb 0279); a
// developer and a tester may not. A member reads it on GET /v1/me/hours, and
// a day above it is kept: a soft norm, never a cap. Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full), where the grants are rdb
// 0279's rows.

func putNorm(t *testing.T, e *env, tid, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPut, "/v1/hours/norm", as, body)
}

func TestHoursNormWho(t *testing.T) {
	e, tid := hoursEnv(t)
	for i, role := range []string{rbac.BizOwner, rbac.ProductOwner, rbac.Admin} {
		hum := seat(t, e, tid, role)
		n := 420 + 15*i
		if code, out := putNorm(t, e, tid, hum, map[string]any{"norm_day_minutes": n}); code != http.StatusOK ||
			out["norm_day_minutes"] != float64(n) || out["max_minutes"] != float64(store.HoursNormDayMax) {
			t.Fatalf("%s PUT %d: %d %v", role, n, code, out)
		}
		if code, out := call(t, e, tid, http.MethodGet, "/v1/hours/norm", hum, nil); code != http.StatusOK || out["norm_day_minutes"] != float64(n) {
			t.Fatalf("%s GET: %d %v", role, code, out)
		}
	}
	for _, role := range []string{rbac.Developer, rbac.Tester} {
		hum := seat(t, e, tid, role)
		if code, out := putNorm(t, e, tid, hum, map[string]any{"norm_day_minutes": 60}); code != http.StatusForbidden || out["permission"] != rbac.HoursNorm {
			t.Errorf("%s PUT: %d %v", role, code, out)
		}
		if code, out := call(t, e, tid, http.MethodGet, "/v1/hours/norm", hum, nil); code != http.StatusForbidden || out["permission"] != rbac.HoursNorm {
			t.Errorf("%s GET: %d %v", role, code, out)
		}
	}
	if code, _ := putNorm(t, e, tid, "", map[string]any{"norm_day_minutes": 60}); code < 400 {
		t.Fatalf("anonymous PUT: %d", code)
	}
	// The refused writes left the admin's value (the last one set).
	owner := seat(t, e, tid, rbac.BizOwner)
	if _, out := call(t, e, tid, http.MethodGet, "/v1/hours/norm", owner, nil); out["norm_day_minutes"] != float64(450) {
		t.Fatalf("after refusals: %v", out)
	}
}

func TestHoursNormBadValues(t *testing.T) {
	e, tid := hoursEnv(t)
	po := seat(t, e, tid, rbac.ProductOwner)
	for _, body := range []map[string]any{{}, {"norm_day_minutes": -1}, {"norm_day_minutes": 1441},
		{"norm_day_minutes": 7.5}, {"norm_day_minutes": "450"}, {"norm_day_minutes": 450, "other": 1}} {
		if code, out := putNorm(t, e, tid, po, body); code != http.StatusBadRequest {
			t.Errorf("%v: %d %v", body, code, out)
		}
	}
	// 0 switches the norm off; 1440 is a whole day.
	for _, n := range []int{1440, 0} {
		if code, out := putNorm(t, e, tid, po, map[string]any{"norm_day_minutes": n}); code != http.StatusOK || out["norm_day_minutes"] != float64(n) {
			t.Fatalf("PUT %d: %d %v", n, code, out)
		}
	}
}

func memberNormPath(hum string) string { return "/v1/members/" + hum + "/hours/norm" }

// teamNorm is the member's norm_day_minutes on GET /v1/hours.
func teamNorm(t *testing.T, e *env, tid, as, member string) any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/hours?period="+hoursThisWeek, as, nil)
	if code != http.StatusOK {
		t.Fatalf("team read: %d %v", code, out)
	}
	ms, _ := out["members"].([]any)
	for _, m := range ms {
		if mm, _ := m.(map[string]any); mm["member_id"] == member {
			return mm["norm_day_minutes"]
		}
	}
	t.Fatalf("member %s not in the team read: %v", member, out)
	return nil
}

// TestHoursMemberNormWho (SPL-5558): the hours.norm roles set a member's own
// norm on the People card; a developer and a tester may neither read nor set
// it, not even their own; an unknown member is 404.
func TestHoursMemberNormWho(t *testing.T) {
	e, tid := hoursEnv(t)
	dev := seat(t, e, tid, rbac.Developer)
	for i, role := range []string{rbac.BizOwner, rbac.ProductOwner, rbac.Admin} {
		hum := seat(t, e, tid, role)
		n := 300 + 15*i
		code, out := call(t, e, tid, http.MethodPut, memberNormPath(dev), hum, map[string]any{"norm_day_minutes": n})
		if code != http.StatusOK || out["member_id"] != dev || out["norm_day_minutes"] != float64(n) ||
			out["effective_norm_day_minutes"] != float64(n) || out["max_minutes"] != float64(store.HoursNormDayMax) {
			t.Fatalf("%s PUT %d: %d %v", role, n, code, out)
		}
		if code, out := call(t, e, tid, http.MethodGet, memberNormPath(dev), hum, nil); code != http.StatusOK || out["norm_day_minutes"] != float64(n) {
			t.Fatalf("%s GET: %d %v", role, code, out)
		}
	}
	for _, role := range []string{rbac.Developer, rbac.Tester} {
		hum := seat(t, e, tid, role)
		for _, target := range []string{dev, hum} {
			if code, out := call(t, e, tid, http.MethodPut, memberNormPath(target), hum, map[string]any{"norm_day_minutes": 60}); code != http.StatusForbidden || out["permission"] != rbac.HoursNorm {
				t.Errorf("%s PUT %s: %d %v", role, target, code, out)
			}
			if code, out := call(t, e, tid, http.MethodGet, memberNormPath(target), hum, nil); code != http.StatusForbidden || out["permission"] != rbac.HoursNorm {
				t.Errorf("%s GET %s: %d %v", role, target, code, out)
			}
		}
	}
	owner := seat(t, e, tid, rbac.BizOwner)
	if code, out := call(t, e, tid, http.MethodGet, memberNormPath(dev), owner, nil); out["norm_day_minutes"] != float64(330) {
		t.Fatalf("after refusals: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPut, memberNormPath("h-nobody-here"), owner, map[string]any{"norm_day_minutes": 60}); code != http.StatusNotFound {
		t.Fatalf("unknown member: %d %v", code, out)
	}
}

func TestHoursMemberNormBadValues(t *testing.T) {
	e, tid := hoursEnv(t)
	po, dev := seat(t, e, tid, rbac.ProductOwner), seat(t, e, tid, rbac.Developer)
	for _, body := range []map[string]any{{}, {"norm_day_minutes": -1}, {"norm_day_minutes": 1441},
		{"norm_day_minutes": 7.5}, {"norm_day_minutes": "450"}, {"norm_day_minutes": 450, "other": 1}} {
		if code, out := call(t, e, tid, http.MethodPut, memberNormPath(dev), po, body); code != http.StatusBadRequest {
			t.Errorf("%v: %d %v", body, code, out)
		}
	}
}

// TestHoursMemberNormEffective (SPL-5558): the member's own norm is the one
// /v1/me/hours and the team read answer; null clears it and the workspace's
// is back; a peer keeps the workspace's all along.
func TestHoursMemberNormEffective(t *testing.T) {
	e, tid := hoursEnv(t)
	po, dev, peer := seat(t, e, tid, rbac.ProductOwner), seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	owner := seat(t, e, tid, rbac.BizOwner) // hours.read
	if code, out := putNorm(t, e, tid, po, map[string]any{"norm_day_minutes": 450}); code != http.StatusOK {
		t.Fatalf("workspace PUT: %d %v", code, out)
	}
	for _, own := range []any{360, 0} {
		code, out := call(t, e, tid, http.MethodPut, memberNormPath(dev), po, map[string]any{"norm_day_minutes": own})
		if code != http.StatusOK || out["workspace_norm_day_minutes"] != float64(450) || out["effective_norm_day_minutes"] != float64(own.(int)) {
			t.Fatalf("PUT %v: %d %v", own, code, out)
		}
		if got := myHours(t, e, tid, dev, hoursThisWeek)["norm_day_minutes"]; got != float64(own.(int)) {
			t.Fatalf("own %v: /v1/me/hours norm %v", own, got)
		}
		if got := teamNorm(t, e, tid, owner, dev); got != float64(own.(int)) {
			t.Fatalf("own %v: team norm %v", own, got)
		}
	}
	if got := myHours(t, e, tid, peer, hoursThisWeek)["norm_day_minutes"]; got != float64(450) {
		t.Fatalf("peer: %v", got)
	}
	if got := teamNorm(t, e, tid, owner, peer); got != float64(450) {
		t.Fatalf("peer team norm: %v", got)
	}
	code, out := call(t, e, tid, http.MethodPut, memberNormPath(dev), po, map[string]any{"norm_day_minutes": nil})
	if code != http.StatusOK || out["norm_day_minutes"] != nil || out["effective_norm_day_minutes"] != float64(450) {
		t.Fatalf("clear: %d %v", code, out)
	}
	if got := myHours(t, e, tid, dev, hoursThisWeek)["norm_day_minutes"]; got != float64(450) {
		t.Fatalf("cleared: /v1/me/hours norm %v", got)
	}
}

// TestHoursNormMemberSees: a developer reads the norm on its own period and
// registers a day above it; the entry is kept (soft norm, owner Q2 = A).
func TestHoursNormMemberSees(t *testing.T) {
	e, tid := hoursEnv(t)
	dev := seat(t, e, tid, rbac.Developer)
	if out := myHours(t, e, tid, dev, hoursThisWeek); out["norm_day_minutes"] != float64(0) {
		t.Fatalf("default norm: %v", out["norm_day_minutes"])
	}
	po := seat(t, e, tid, rbac.ProductOwner)
	if code, out := putNorm(t, e, tid, po, map[string]any{"norm_day_minutes": 450}); code != http.StatusOK {
		t.Fatalf("PUT: %d %v", code, out)
	}
	code, out := putEntries(t, e, tid, dev, map[string]any{"entries": []any{entry("2026-10-06", "t:task-a", 600, store.HoursApproved)}})
	if code != http.StatusOK {
		t.Fatalf("a day above the norm is refused: %d %v", code, out)
	}
	got := myHours(t, e, tid, dev, hoursThisWeek)
	if got["norm_day_minutes"] != float64(450) {
		t.Fatalf("member norm: %v", got["norm_day_minutes"])
	}
	if d := hoursDay(t, got, "2026-10-06"); d["approved_minutes"] != float64(600) {
		t.Fatalf("the day above the norm: %v", d)
	}
}
