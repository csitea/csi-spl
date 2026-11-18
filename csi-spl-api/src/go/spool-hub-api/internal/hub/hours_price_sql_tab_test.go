package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestCommitHumanTimeNotInSQLTab (Postgres only: the memory store has no
// SQL executor): a workspace's admin is refused the commit ledger (rdb 0295,
// SPL-5913) through the Reporting SQL tab, since a one-person commit's
// amount over its minutes is that person's price (spec 107 21.6, 21.7).
// RED CONTROL (c9d315194, R7 W1): the SQL tab answered 200 with the rows.
func TestCommitHumanTimeNotInSQLTab(t *testing.T) {
	e, _, other, _, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("Postgres only (hub-pg.tst.sh): the memory store has no SQL executor")
	}
	q := map[string]any{"query": "SELECT minutes, amount_micros, currency FROM commit_human_time"}
	if code, got := call(t, e, other, http.MethodPost, sqlPath, whoOther[rbac.Admin], q); code != http.StatusBadRequest || got["error"] != "forbidden_relation" {
		t.Errorf("admin's SQL-tab read of commit_human_time: %d %v, want 400 forbidden_relation", code, got)
	}
	if code, got := call(t, e, other, http.MethodPost, sqlPath, whoOther[rbac.Admin], map[string]any{"query": "SELECT 1"}); code != http.StatusOK {
		t.Errorf("CONTROL admin's SQL tab: %d %v, want 200", code, got)
	}
}
