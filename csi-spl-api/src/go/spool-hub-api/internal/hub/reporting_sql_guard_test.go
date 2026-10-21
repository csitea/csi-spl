package hub

import (
	"errors"
	"strings"
	"testing"
)

// Spec 143 T030 (SPL-2789): the SQL tab's lexical guard. GATE: every
// forbidden variant below is refused with its code. RED CONTROL:
// "SELECT 1; DROP TABLE messages;" passing the guard fails this test.

func guardCode(q string) string {
	_, err := checkReportingSQL(q)
	var r *reportingSQLRefusal
	if errors.As(err, &r) {
		return r.code
	}
	if err != nil {
		return "error:" + err.Error()
	}
	return ""
}

func TestSQLStaticGuard(t *testing.T) {
	refused := map[string]string{
		// the red control
		"SELECT 1; DROP TABLE messages;": "single_statement_only",
		"SELECT 1;DELETE FROM messages":  "single_statement_only",
		"SELECT 1; SELECT 2":             "single_statement_only",
		// writes and DDL, leading or inside
		"INSERT INTO messages VALUES (1)":                              "read_only_violation",
		"update messages set body = 'x'":                               "read_only_violation",
		"DELETE FROM messages":                                         "read_only_violation",
		"MERGE INTO messages USING x ON true WHEN MATCHED THEN DELETE": "read_only_violation",
		"TRUNCATE messages":                                            "read_only_violation",
		"DROP TABLE messages":                                          "read_only_violation",
		"CREATE TABLE x (a int)":                                       "read_only_violation",
		"ALTER TABLE messages NO FORCE ROW LEVEL SECURITY":             "read_only_violation",
		"COMMENT ON TABLE messages IS 'x'":                             "read_only_violation",
		"WITH d AS (DELETE FROM messages RETURNING 1) SELECT * FROM d": "read_only_violation",
		"SELECT * INTO new_table FROM messages":                        "read_only_violation",
		"SELECT * FROM messages FOR UPDATE":                            "read_only_violation",
		// session, privilege, procedural, import/export, transactions
		"SET ROLE spool_hub":                    "read_only_violation",
		"SET SESSION AUTHORIZATION spool_hub":   "read_only_violation",
		"RESET app.tenant_id":                   "read_only_violation",
		"SET TRANSACTION READ WRITE":            "read_only_violation",
		"LISTEN x":                              "read_only_violation",
		"NOTIFY x":                              "read_only_violation",
		"CALL p()":                              "read_only_violation",
		"DO $$ BEGIN END $$":                    "read_only_violation",
		"PREPARE p AS SELECT 1":                 "read_only_violation",
		"EXECUTE p":                             "read_only_violation",
		"COPY messages TO STDOUT":               "read_only_violation",
		"\\copy messages to '/tmp/x'":           "read_only_violation",
		"BEGIN":                                 "read_only_violation",
		"COMMIT":                                "read_only_violation",
		"EXPLAIN ANALYZE DELETE FROM messages":  "read_only_violation",
		"SHOW ALL":                              "read_only_violation",
		"/* DROP TABLE messages */ SELECT 1":    "read_only_violation",
		"SELECT 1 -- then DELETE FROM messages": "read_only_violation",
		// functions off the list, however written
		"SELECT set_config('app.rls_scope', 'operator', true)":     "forbidden_function",
		"SELECT \"set_config\"('app.rls_scope', 'operator', true)": "forbidden_function",
		"SELECT pg_catalog.set_config('x', 'y', true)":             "forbidden_function",
		"SELECT public.embed_visitor_channel('a', 'b')":            "forbidden_function",
		"SELECT query_to_xml('select 1', true, true, '')":          "forbidden_function",
		"SELECT current_setting('app.tenant_id')":                  "forbidden_function",
		"SELECT pg_sleep(20)":                                      "forbidden_function",
		"SELECT repeat('x', 1000000000)":                           "forbidden_function",
		"SELECT * FROM dblink('x', 'select 1')":                    "forbidden_function",
		"SELECT lo_import('/etc/passwd')":                          "forbidden_function",
		"SELECT nextval('s')":                                      "forbidden_function",
		// what no report query needs
		"SELECT U&\"\\0073et_config\"('x', 'y', true)": "bad_query",
		"SELECT * FROM messages WHERE msg_id = $1":     "bad_query",
		"SELECT 'unclosed":                             "bad_query",
		"SELECT /* unclosed":                           "bad_query",
		"   ":                                          "bad_query",
		"SELECT $q$ unclosed":                          "bad_query",
	}
	for q, want := range refused {
		if got := guardCode(q); got != want {
			t.Errorf("%q: %q, want %q", q, got, want)
		}
	}
	if n := len(refused); n < 20 {
		t.Fatalf("%d variants, spec 143 T030 asks for 20+", n)
	}
	if got := guardCode(strings.Repeat("x", 100001)); got != "bad_query" {
		t.Errorf("a 100,001-character query: %q, want bad_query", got)
	}
}

// TestSQLStaticGuardAllows: the reads an admin writes pass, and a keyword
// inside a literal, a quoted name or a comment that names no command is
// not read as one.
func TestSQLStaticGuardAllows(t *testing.T) {
	for _, q := range []string{
		"SELECT channel_id, name FROM channels ORDER BY 1",
		"select count(*) from messages;",
		"SELECT 'DROP TABLE messages; DELETE' AS s",
		"SELECT E'it\\'s; DROP' AS s",
		"SELECT $tag$; DELETE FROM x $tag$ AS s",
		`SELECT "update", "set" FROM (VALUES (1, 2)) AS t("update", "set")`,
		"WITH x(a) AS (SELECT 1) SELECT a FROM x",
		"WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r",
		"SELECT date_trunc('day', received_at) AS day, count(*) FROM messages GROUP BY 1 ORDER BY 1 DESC",
		"SELECT 1::numeric(10,2), CAST(2 AS varchar(5)), pg_catalog.lower('X')",
		"SELECT row_number() OVER (PARTITION BY channel ORDER BY received_at) FROM messages",
		"SELECT count(*) FILTER (WHERE kind = 'note') FROM messages WHERE channel IN ('a', 'b')",
		"(SELECT 1) UNION (SELECT 2)",
		"VALUES (1), (2)",
		"TABLE channels",
		"/* weekly count */ SELECT 1 -- per day",
		"SELECT * FROM generate_series(1, 3) g",
	} {
		if got := guardCode(q); got != "" {
			t.Errorf("%q refused: %q", q, got)
		}
	}
	if run, _ := checkReportingSQL("  SELECT 1 ;  "); run != "SELECT 1 " {
		t.Errorf("trailing semicolon: run %q, want %q", run, "SELECT 1 ")
	}
}
