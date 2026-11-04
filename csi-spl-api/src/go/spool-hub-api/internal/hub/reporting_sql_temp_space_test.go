package hub_test

import (
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// TestReportingSQLTempSpace (SPL-4757): an admin's query that Postgres ends
// over temp_file_limit is answered 400 temp_space_exceeded and audited with
// that code, not 500 internal; a plain query on the same hub still runs.
// Postgres only: hub-pg.tst.sh grants the test role SET on temp_file_limit,
// and the hub's store opens with a 1 MB limit (a DSN runtime parameter).
func TestReportingSQLTempSpace(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("needs the real executor under temp_file_limit (hub-pg.tst.sh)")
	}
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	t.Setenv("SPOOL_TEST_PG_DSN", dsn+sep+"temp_file_limit=1MB")
	x := newSQLEnv(t)
	admin := x.whoA[rbac.Admin]
	x.sqlRefused(t, admin, "SELECT count(*) FROM generate_series(1, 1000000::int8)", http.StatusBadRequest, "temp_space_exceeded")
	code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, admin, map[string]any{"query": "SELECT tenant_id FROM tenants"})
	if code != http.StatusOK || body["row_count"] != float64(1) {
		t.Fatalf("plain query under the limit: %d %v, want 200 with 1 row", code, body)
	}
}
