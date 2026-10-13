package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Owner bug (t1 d5d00918, msg c74e95d4): "the issues listing picks all of
// the issues. It shouldn't list more than 30 issues, and then it should have
// the "Load more" control". GET /v1/view/issues?limit=30 answers a page of
// 30 and a keyset next_cursor in the current sort; counts and epics stay
// over the whole filtered list. No limit is still the whole list.

// pageOf reads one page: its keys, its next_cursor and the whole body.
func pageOf(t *testing.T, e *env, tid, who, q string) ([]string, string, map[string]any) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues"+q, who, nil)
	if code != http.StatusOK {
		t.Fatalf("GET %s: %d %v", q, code, out)
	}
	next, _ := out["next_cursor"].(string)
	return issueKeys(out), next, out
}

// withQ joins a base query (no leading "?") and one more parameter.
func withQ(base, more string) string {
	switch {
	case base == "" && more == "":
		return ""
	case base == "":
		return "?" + more
	case more == "":
		return "?" + base
	}
	return "?" + base + "&" + more
}

// walk reads every page of base and returns the keys in order.
func walk(t *testing.T, e *env, tid, who, base string, pages int) []string {
	t.Helper()
	var all []string
	cursor := ""
	for k := 0; k < pages; k++ {
		more := ""
		if cursor != "" {
			more = "cursor=" + url.QueryEscape(cursor)
		}
		keys, next, _ := pageOf(t, e, tid, who, withQ(base, more))
		all = append(all, keys...)
		if next == "" {
			return all
		}
		cursor = next
	}
	t.Fatalf("%q: still a next_cursor after %d pages", base, pages)
	return nil
}

func seedPagedIssues(t *testing.T, e *env, tid, dev string, n int) {
	t.Helper()
	for k := 1; k <= n; k++ {
		body := map[string]any{"title": fmt.Sprintf("row %02d", k), "priority": 1 + k%5}
		if k%7 == 0 {
			body["deadline"] = fmt.Sprintf("2026-11-%02dT12:00:00Z", 1+k%28)
		}
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, body); code != http.StatusCreated {
			t.Fatalf("create %d: %d %v", k, code, out)
		}
	}
}

func TestIssuesPaged(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	const n = 65
	seedPagedIssues(t, e, tid, dev, n)

	// The first page: 30 rows, a cursor, and counts over all 65.
	if keys, next, _ := pageOf(t, e, tid, dev, ""); len(keys) != n || next != "" {
		t.Fatalf("no limit: %d rows, next %q, want the whole list", len(keys), next)
	}
	keys, next, out := pageOf(t, e, tid, dev, "?limit=30")
	if len(keys) != 30 || next == "" {
		t.Fatalf("page 1: %d rows, next %q", len(keys), next)
	}
	if out["total"] != float64(n) {
		t.Fatalf("total %v, want %d", out["total"], n)
	}
	sum := 0.0
	for _, v := range out["counts"].(map[string]any) {
		sum += v.(float64)
	}
	if sum != n {
		t.Fatalf("counts sum %v, want %d (whole list, not the page)", sum, n)
	}

	// Every sort, both directions: the pages join into the unpaged order,
	// no row twice, none missing.
	for _, q := range []string{"", "sort=priority", "sort=updated", "sort=created", "sort=deadline", "sort=level",
		"sort=number&dir=asc", "sort=title&dir=desc", "sort=priority&dir=desc", "sort=deadline&dir=asc", "sort=default",
		"sort=status&dir=asc", "status=eval&sort=updated&dir=asc", "sort=assignee", "sort=label&dir=desc"} {
		whole, _, _ := pageOf(t, e, tid, dev, withQ(q, "limit=500"))
		paged := walk(t, e, tid, dev, withQ(q, "limit=8")[1:], 20)
		if !sameKeys(paged, whole...) || len(whole) < 10 {
			t.Fatalf("%q: paged %v\nwhole %v", q, paged, whole)
		}
	}

	// limit is honoured, and the last page has no cursor.
	keys, next, _ = pageOf(t, e, tid, dev, "?limit=7")
	if len(keys) != 7 || next == "" {
		t.Fatalf("limit=7: %d rows, next %q", len(keys), next)
	}
	if got := walk(t, e, tid, dev, "limit=30", 5); len(got) != n {
		t.Fatalf("walk: %d rows", len(got))
	}

	// The cursor is a key, not an offset: a row created at the top after
	// page 1 does not shift page 2 (no row repeats, none skipped).
	p1, c1, _ := pageOf(t, e, tid, dev, "?limit=10")
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "late urgent", "priority": 1}); code != http.StatusCreated {
		t.Fatalf("late create: %d %v", code, out)
	}
	p2, _, _ := pageOf(t, e, tid, dev, "?limit=10&cursor="+url.QueryEscape(c1))
	whole, _, _ := pageOf(t, e, tid, dev, "?limit=500")
	at := -1
	for k, key := range whole {
		if key == p1[len(p1)-1] {
			at = k
		}
	}
	if at < 0 || !sameKeys(p2, whole[at+1:at+11]...) {
		t.Fatalf("cursor moved: p1 %v p2 %v whole %v", p1, p2, whole)
	}

	// Refusals: a bad limit or cursor, or a cursor from another sort.
	for _, q := range []string{"?limit=0", "?limit=x", "?limit=501", "?cursor=nope", "?dir=up", "?sort=updated&cursor=" + url.QueryEscape(c1)} {
		if code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues"+q, dev, nil); code != http.StatusBadRequest || out["error"] != "bad_issue" {
			t.Fatalf("%s: %d %v", q, code, out)
		}
	}
}

// The agent list (`spool issue list`, the MCP tool) keeps its whole answer
// unless it asks for a page.
func TestAgentIssuesWholeList(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	do := func(in action.IssueArgs) map[string]any {
		in.Hub = a.c
		in.Issue = withDefaultDiscussion(tid, in.Op, in.Issue)
		raw, err := action.Issue(ctx, a.cfg, in)
		if err != nil {
			t.Fatalf("%+v: %v", in, err)
		}
		out := map[string]any{}
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("reply %s: %v", raw, err)
		}
		return out
	}
	for k := 0; k < 33; k++ {
		do(action.IssueArgs{Op: "create", As: "CLE-07", Issue: json.RawMessage(fmt.Sprintf(`{"title":"a%d"}`, k))})
	}
	if got := issueKeys(do(action.IssueArgs{Op: "list", As: "CLE-07"})); len(got) != 33 {
		t.Fatalf("agent list: %d rows, want all 33", len(got))
	}
	out := do(action.IssueArgs{Op: "list", As: "CLE-07", Query: "limit=30"})
	if len(issueKeys(out)) != 30 || out["next_cursor"] == "" {
		t.Fatalf("agent limit=30: %d rows, next %v", len(issueKeys(out)), out["next_cursor"])
	}
}
