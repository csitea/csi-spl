package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// SPL-4757: a query Postgres ends for its temp files (53400 over
// temp_file_limit, 53100 disk full) is the tab's ErrReportingSQLTempSpace,
// not an unmapped error the hub answers 500. Postgres only (hub-pg.tst.sh
// grants the test role SET on temp_file_limit).

// sqlSpill materialises a million-row function scan to a temp file (~14 MB).
const sqlSpill = `SELECT count(*) FROM generate_series(1, 1000000::int8)`

// tempLimitedStore opens a second pool on the test database whose sessions
// start with temp_file_limit = limit (a DSN runtime parameter).
func tempLimitedStore(t *testing.T, limit string) *Postgres {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn+sep+"temp_file_limit="+limit)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	var got string
	if err := pg.Pool().QueryRow(ctx, `SHOW temp_file_limit`).Scan(&got); err != nil {
		t.Fatalf("temp_file_limit=%s refused (%v): hub-pg.tst.sh grants SET ON PARAMETER temp_file_limit to the test role", limit, err)
	}
	if got != limit {
		t.Fatalf("temp_file_limit = %s, want %s", got, limit)
	}
	return pg
}

// TestSQLExecutorTempSpace (red control "temp space"): the spilling query
// runs without a limit (CONTROL: the limit, not the text, refuses it); under
// a 1 MB limit it is ErrReportingSQLTempSpace, and a query that spills
// nothing still runs.
func TestSQLExecutorTempSpace(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	r, err := runSQL(t, pg, a, sqlSpill)
	if err != nil || one(t, r) != "1000000" {
		t.Fatalf("control, no limit: %v %v, want 1000000", r.Rows, err)
	}
	lim := tempLimitedStore(t, "1MB")
	if _, err := runSQL(t, lim, a, sqlSpill); !errors.Is(err, ErrReportingSQLTempSpace) {
		t.Fatalf("spill under 1 MB: %v, want ErrReportingSQLTempSpace", err)
	}
	r, err = runSQL(t, lim, a, `SELECT count(*) FROM messages`)
	if err != nil || one(t, r) != "1" {
		t.Fatalf("plain query under 1 MB: %v %v, want 1", r.Rows, err)
	}
}

// TestSQLErrTempSpaceCodes: 53100 (a disk no test fills) maps as 53400
// does; the other class-53 codes keep their path (unmapped).
func TestSQLErrTempSpaceCodes(t *testing.T) {
	for code, want := range map[string]bool{"53100": true, "53400": true, "53200": false, "53300": false} {
		err := reportingSQLErr(&pgconn.PgError{Code: code, Message: "x"})
		if errors.Is(err, ErrReportingSQLTempSpace) != want {
			t.Errorf("%s: %v, want temp space = %v", code, err, want)
		}
	}
}
