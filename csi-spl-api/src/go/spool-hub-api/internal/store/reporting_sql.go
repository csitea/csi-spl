package store

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The Reporting SQL tab's executor (spec 143 3.1-3.5, tasks T031, SPL-2789).
// Owner HUM-10 (t1 af25a1f3): "run sql queries and get up to 2000 rows";
// "admins may use it - but it will be read only". A workspace admin's own
// text runs here, so every layer below holds on its own; the hub's lexical
// guard (hub/reporting_sql.go) runs before it and is not relied on:
//
//  1. one transaction, BEGIN READ ONLY: Postgres refuses any write or DDL;
//  2. the workspace scope only (app.tenant_id), app.rls_scope cleared,
//     never the operator scope; statement_timeout 10 s;
//  3. the text goes to Postgres through the extended protocol only, which
//     refuses more than one statement in it;
//  4. EXPLAIN first: every relation the plan reads must be a FORCE-RLS
//     workspace table that holds no secret column and no per-member scope
//     (reportingSQLRelations), and every function the plan calls must be on
//     the hub's list (ReportingSQLFunctionAllowed). The plan is Postgres's
//     own reading of the text, so a quoting trick that fools the hub's
//     lexer does not fool this;
//  5. a cursor, FETCH 2,001: the 2,001st row only sets truncated.
//
// The audit row (rdb 0203) is written apart, in the workspace scope, by
// AuditReportingSQL: the read-only transaction can write nothing.

const (
	// ReportingSQLRowCap is the owner's cap (spec 143 B6, msg 581d5d66).
	ReportingSQLRowCap = 2000
	// ReportingSQLTimeout is spec 143 B8's statement budget.
	ReportingSQLTimeout = 10 * time.Second
	// ReportingSQLMaxBytes bounds the text of one result held by the hub.
	ReportingSQLMaxBytes = 8 << 20
	// ReportingSQLMaxQuery is rdb 0203's query_text bound.
	ReportingSQLMaxQuery = 100000
)

// pgScopeReportingSQL is the workspace scope, the operator scope cleared,
// and the budget, in one statement.
const pgScopeReportingSQL = `SELECT set_config('app.tenant_id', $1, true), set_config('app.rls_scope', '', true),
	set_config('statement_timeout', $2, true)`

// reportingSQLSecretColumn names the columns that keep a credential or a
// secret's derivative: a table holding one stays out of the SQL tab whole.
const reportingSQLSecretColumn = `(hash|cipher|secret|passw|sealed|private_key)`

// pgReportingSQLRelations lists the relations the tab may read: FORCE-RLS
// tables of the hub's schema with a tenant_id, minus those holding a secret
// column and those with a per-member or per-person policy (rdb 0176's hours
// tables read every member's rows when no member is set).
const pgReportingSQLRelations = `SELECT c.relname FROM pg_class c
	JOIN pg_namespace n ON n.oid = c.relnamespace
	WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') AND c.relrowsecurity AND c.relforcerowsecurity
	  AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
	  AND NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attname ~* $1)
	  AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid
	        AND coalesce(pg_get_expr(p.polqual, p.polrelid), '') || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ~ 'app\.(member_id|person_id)')`

// The SQL tab's refusals, each one a 4xx the admin reads.
var (
	ErrReportingSQLTimeout  = errors.New("query exceeded the 10 s statement budget")
	ErrReportingSQLReadOnly = errors.New("the SQL tab is read only")
	ErrReportingSQLTooLarge = errors.New("the result is larger than 8 MiB")
)

// ReportingSQLRefusal is a query the plan check refused: Code is the
// response token, Name the relation or function it names.
type ReportingSQLRefusal struct{ Code, Name string }

// Error names what was refused.
func (e *ReportingSQLRefusal) Error() string {
	if e.Code == "forbidden_relation" {
		return "relation " + e.Name + " is not open to the SQL tab (only this workspace's tables are)"
	}
	return "function " + e.Name + " is not open to the SQL tab"
}

// ReportingSQLQueryError is Postgres's own refusal of the admin's text
// (syntax, unknown column, a bad cast): its message is safe to show.
type ReportingSQLQueryError struct{ Code, SQLState, Message string }

// Error is Postgres's message.
func (e *ReportingSQLQueryError) Error() string { return e.Message }

// ReportingSQLColumn is one result column, its type as Postgres names it.
type ReportingSQLColumn struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// ReportingSQLResult is one query's answer, each value in Postgres's text
// form (nil = NULL), at most ReportingSQLRowCap rows.
type ReportingSQLResult struct {
	Columns   []ReportingSQLColumn
	Rows      [][]*string
	Truncated bool
}

// ReportingSQLAudit is one rdb 0203 row.
type ReportingSQLAudit struct {
	Tenant, Human, Query string
	At                   time.Time
	Duration             time.Duration
	Rows                 int
	Truncated            bool
	Error, ClientIP      string
}

// ReportingSQLStore is the store side of POST /v1/reporting/sql; only the
// Postgres store has it (the memory store answers 501 through the hub).
type ReportingSQLStore interface {
	RunReportingSQL(ctx context.Context, tenant, query string) (ReportingSQLResult, error)
	AuditReportingSQL(ctx context.Context, a ReportingSQLAudit) error
}

var _ ReportingSQLStore = (*Postgres)(nil)

// reportingSQLBudget is the statement_timeout the envelope sets (a test
// shortens it; ReportingSQLTimeout is the product's).
var reportingSQLBudget = ReportingSQLTimeout

// RunReportingSQL runs one admin query in tenant's scope, read only.
func (s *Postgres) RunReportingSQL(ctx context.Context, tenant, query string) (ReportingSQLResult, error) {
	var out ReportingSQLResult
	err := s.reportingSQLTx(ctx, tenant, func(tx pgx.Tx) error {
		if err := reportingSQLPlanCheck(ctx, tx, query); err != nil {
			return err
		}
		var err error
		out, err = reportingSQLFetch(ctx, tx, query)
		return err
	})
	return out, reportingSQLErr(err)
}

// reportingSQLTx is the envelope: a READ ONLY transaction in tenant's scope
// alone, under the budget, always rolled back.
func (s *Postgres) reportingSQLTx(ctx context.Context, tenant string, fn func(pgx.Tx) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	budget := strconv.FormatInt(max(reportingSQLBudget.Milliseconds(), 1), 10)
	if _, err := tx.Exec(ctx, pgScopeReportingSQL, tenant, budget); err != nil {
		return err
	}
	return fn(tx)
}

// reportingSQLErr turns Postgres's refusals into the tab's errors.
func reportingSQLErr(err error) error {
	var pe *pgconn.PgError
	if !errors.As(err, &pe) {
		return err
	}
	switch {
	case pe.Code == "57014": // query_canceled: statement_timeout
		return ErrReportingSQLTimeout
	case pe.Code == "25006": // read_only_sql_transaction
		return ErrReportingSQLReadOnly
	case pe.Code == "42601" || pe.Code == "42P01" || pe.Code == "42703" || pe.Code == "42883":
		return &ReportingSQLQueryError{Code: "syntax_error", SQLState: pe.Code, Message: pe.Message}
	case pe.Code == "42P02": // undefined_parameter: $1 in the text
		return &ReportingSQLQueryError{Code: "syntax_error", SQLState: pe.Code, Message: "parameters ($1) are not supported"}
	case strings.HasPrefix(pe.Code, "42") || strings.HasPrefix(pe.Code, "22") || strings.HasPrefix(pe.Code, "0A"):
		return &ReportingSQLQueryError{Code: "query_error", SQLState: pe.Code, Message: pe.Message}
	}
	return err
}

// reportingSQLPlanCheck reads EXPLAIN's plan of query and refuses a relation
// or a function the tab does not open.
func reportingSQLPlanCheck(ctx context.Context, tx pgx.Tx, query string) error {
	var raw []byte
	if err := tx.QueryRow(ctx, "EXPLAIN (VERBOSE, FORMAT JSON) "+query, pgx.QueryExecModeExec).Scan(&raw); err != nil {
		return err
	}
	var plan any
	if err := json.Unmarshal(raw, &plan); err != nil {
		return err
	}
	open, err := reportingSQLRelations(ctx, tx)
	if err != nil {
		return err
	}
	return planWalk(plan, open)
}

// reportingSQLRelations is the set of relations the tab may read, read
// from the catalogue in the query's own transaction.
func reportingSQLRelations(ctx context.Context, tx pgx.Tx) (map[string]bool, error) {
	open := map[string]bool{}
	err := eachRow(ctx, tx, pgReportingSQLRelations, []any{reportingSQLSecretColumn}, func(r pgx.Rows) error {
		var name string
		if err := r.Scan(&name); err != nil {
			return err
		}
		open[name] = true
		return nil
	})
	return open, err
}

// planWalk checks every node of an EXPLAIN (VERBOSE, FORMAT JSON) plan:
// each node's relation and function, and every expression text in it.
func planWalk(v any, open map[string]bool) error {
	switch x := v.(type) {
	case string:
		return planExprCheck(x)
	case []any:
		for _, e := range x {
			if err := planWalk(e, open); err != nil {
				return err
			}
		}
	case map[string]any:
		if err := planNode(x, open); err != nil {
			return err
		}
		for k, e := range x {
			if planNameKeys[k] {
				continue
			}
			if err := planWalk(e, open); err != nil {
				return err
			}
		}
	}
	return nil
}

// planNameKeys hold names, not expressions (planNode checks the first two).
var planNameKeys = map[string]bool{"Relation Name": true, "Function Name": true, "Schema": true, "Alias": true,
	"Node Type": true, "Strategy": true, "Join Type": true, "Parent Relationship": true, "Subplan Name": true,
	"CTE Name": true, "Index Name": true, "Scan Direction": true, "Partial Mode": true, "Sort Method": true}

// planNode checks one node: no write, an open relation, a listed function.
func planNode(n map[string]any, open map[string]bool) error {
	if _, ok := n["Operation"]; ok { // a ModifyTable node: INSERT, UPDATE, DELETE, MERGE
		return ErrReportingSQLReadOnly
	}
	if rel, ok := n["Relation Name"].(string); ok {
		schema, _ := n["Schema"].(string)
		if !open[rel] || (schema != "" && schema != "public") {
			return &ReportingSQLRefusal{Code: "forbidden_relation", Name: qualified(schema, rel)}
		}
	}
	if fn, ok := n["Function Name"].(string); ok && !ReportingSQLFunctionAllowed(fn) {
		schema, _ := n["Schema"].(string)
		return &ReportingSQLRefusal{Code: "forbidden_function", Name: qualified(schema, fn)}
	}
	return nil
}

func qualified(schema, name string) string {
	if schema == "" {
		return name
	}
	return schema + "." + name
}

// planExprCheck refuses a function call in a deparsed plan expression that
// is not on the list. Postgres deparses a call as name( with no space, so a
// keyword with a parenthesis after a space (ANY (, OVER () is not a call;
// quoted literals and quoted names are read as such.
func planExprCheck(expr string) error {
	for i := 0; i < len(expr); {
		c := expr[i]
		switch {
		case c == '\'':
			i = skipQuoted(expr, i, '\'')
		case c == '"' || isIdentStart(c):
			name, qual, end := planIdent(expr, i)
			if end < len(expr) && expr[end] == '(' && !planCallAllowed(qual, name) {
				return &ReportingSQLRefusal{Code: "forbidden_function", Name: qualified(qual, name)}
			}
			i = end
		default:
			i++
		}
	}
	return nil
}

// planIdent reads a possibly qualified, possibly quoted name at i.
func planIdent(s string, i int) (name, qual string, end int) {
	name, end = oneIdent(s, i)
	for end+1 < len(s) && s[end] == '.' && (s[end+1] == '"' || isIdentStart(s[end+1])) {
		qual = name
		name, end = oneIdent(s, end+1)
	}
	return name, qual, end
}

func oneIdent(s string, i int) (string, int) {
	if s[i] == '"' {
		end := skipQuoted(s, i, '"')
		return strings.ReplaceAll(s[i+1:max(end-1, i+1)], `""`, `"`), end
	}
	j := i
	for j < len(s) && isIdentPart(s[j]) {
		j++
	}
	return strings.ToLower(s[i:j]), j
}

// skipQuoted returns the index past the quoted run opened at i (the quote
// written twice inside it is the quote itself).
func skipQuoted(s string, i int, q byte) int {
	for j := i + 1; j < len(s); j++ {
		if s[j] != q {
			continue
		}
		if j+1 < len(s) && s[j+1] == q {
			j++
			continue
		}
		return j + 1
	}
	return len(s)
}

func isIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

func isIdentPart(c byte) bool { return isIdentStart(c) || (c >= '0' && c <= '9') || c == '$' }

// planCallAllowed: a call in the plan text is allowed when it is on the
// hub's list, a type name with a modifier, or a policy's own read of the
// scope (current_setting, which the RLS policies deparse into Filter).
func planCallAllowed(qual, name string) bool {
	if qual != "" && qual != "pg_catalog" {
		return false
	}
	return ReportingSQLFunctionAllowed(name) || planTypeNames[name] || name == "current_setting"
}

// planTypeNames are the types the deparser prints with a modifier.
var planTypeNames = map[string]bool{
	"varying": true, "character": true, "numeric": true, "bit": true, "timestamp": true,
	"time": true, "interval": true, "varchar": true, "char": true, "decimal": true,
}

// reportingSQLFetch runs query through a cursor and reads at most
// ReportingSQLRowCap + 1 rows, every value as text.
func reportingSQLFetch(ctx context.Context, tx pgx.Tx, query string) (ReportingSQLResult, error) {
	if _, err := tx.Exec(ctx, "DECLARE reporting_sql NO SCROLL CURSOR FOR "+query, pgx.QueryExecModeExec); err != nil {
		return ReportingSQLResult{}, err
	}
	fetch := "FETCH " + strconv.Itoa(ReportingSQLRowCap+1) + " FROM reporting_sql"
	rows, err := tx.Query(ctx, fetch, pgx.QueryExecModeSimpleProtocol)
	if err != nil {
		return ReportingSQLResult{}, err
	}
	out, oids, err := reportingSQLRows(rows)
	if err != nil {
		return ReportingSQLResult{}, err
	}
	if len(out.Rows) > ReportingSQLRowCap {
		out.Rows, out.Truncated = out.Rows[:ReportingSQLRowCap], true
	}
	return out, reportingSQLTypes(ctx, tx, out.Columns, oids)
}

// reportingSQLRows reads every fetched row as text within the byte budget.
func reportingSQLRows(rows pgx.Rows) (ReportingSQLResult, []uint32, error) {
	defer rows.Close()
	fds := rows.FieldDescriptions()
	out := ReportingSQLResult{Columns: make([]ReportingSQLColumn, len(fds)), Rows: [][]*string{}}
	oids := make([]uint32, len(fds))
	for i, fd := range fds {
		out.Columns[i].Name, oids[i] = fd.Name, fd.DataTypeOID
	}
	size := 0
	for rows.Next() {
		raw := rows.RawValues()
		row := make([]*string, len(raw))
		for i, b := range raw {
			if b != nil {
				v := string(b)
				row[i], size = &v, size+len(b)
			}
		}
		if size > ReportingSQLMaxBytes {
			return ReportingSQLResult{}, nil, ErrReportingSQLTooLarge
		}
		out.Rows = append(out.Rows, row)
	}
	return out, oids, rows.Err()
}

// reportingSQLTypes names each column's type as format_type does.
func reportingSQLTypes(ctx context.Context, tx pgx.Tx, cols []ReportingSQLColumn, oids []uint32) error {
	if len(oids) == 0 {
		return nil
	}
	names := map[uint32]string{}
	err := eachRow(ctx, tx, `SELECT oid::int8, format_type(oid, NULL) FROM pg_type WHERE oid = ANY($1::oid[])`, []any{oids}, func(r pgx.Rows) error {
		var oid int64
		var name string
		if err := r.Scan(&oid, &name); err != nil {
			return err
		}
		names[uint32(oid)] = name
		return nil
	})
	for i := range cols {
		cols[i].Type = names[oids[i]]
	}
	return reportingSQLErr(err)
}

// AuditReportingSQL writes one rdb 0203 row in the workspace's own scope.
func (s *Postgres) AuditReportingSQL(ctx context.Context, a ReportingSQLAudit) error {
	q, e, ip := clip(a.Query, ReportingSQLMaxQuery), clip(a.Error, 2000), clip(a.ClientIP, 64)
	_, err := s.execTenant(ctx, a.Tenant, `INSERT INTO sql_query_audit
		(audit_id, tenant_id, human_id, query_text, executed_at, duration_ms, row_count, truncated, error_message, client_ip)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
		uuid.NewString(), a.Tenant, a.Human, q, a.At.UTC(), max(a.Duration.Milliseconds(), 0), a.Rows, a.Truncated, e, ip)
	return err
}

// clip cuts s to at most n bytes, never inside a UTF-8 sequence.
func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && s[n]&0xC0 == 0x80 {
		n--
	}
	return s[:n]
}

// reportingSQLFunctions is the list a SQL tab query may call: aggregates,
// window functions and pure value functions. Nothing that runs SQL from a
// string (query_to_xml, ts_stat), changes a setting (set_config), touches a
// file, a large object, a sequence or another session (pg_*), sleeps, or
// builds a value of any size from a number (repeat, lpad, rpad).
var reportingSQLFunctions = map[string]bool{}

func init() {
	for _, group := range []string{
		// aggregates
		"count sum avg min max string_agg array_agg bool_and bool_or every stddev stddev_pop stddev_samp variance var_pop var_samp " +
			"percentile_cont percentile_disc mode json_agg jsonb_agg json_object_agg jsonb_object_agg corr covar_pop covar_samp",
		// window functions
		"row_number rank dense_rank percent_rank cume_dist ntile lag lead first_value last_value nth_value",
		// conditionals and grouping
		"coalesce nullif greatest least grouping rollup cube",
		// text
		"lower upper initcap length char_length character_length octet_length bit_length substr substring left right trim btrim " +
			"ltrim rtrim concat concat_ws replace split_part position strpos starts_with reverse translate format quote_ident " +
			"quote_literal quote_nullable md5 regexp_replace regexp_match regexp_matches regexp_split_to_array regexp_count " +
			"regexp_like regexp_substr regexp_instr similar_to_escape to_hex ascii chr encode decode normalize unistr",
		// numbers
		"abs ceil ceiling floor round trunc mod power pow sqrt cbrt exp ln log log10 sign div width_bucket random scale",
		// dates and times
		"now date_trunc date_part extract age to_char to_date to_timestamp to_number make_date make_time make_timestamp " +
			"make_timestamptz make_interval justify_days justify_hours justify_interval date_bin timezone overlaps isfinite " +
			"clock_timestamp statement_timestamp transaction_timestamp",
		// json and arrays
		"to_json to_jsonb row_to_json array_to_json json_build_object jsonb_build_object json_build_array jsonb_build_array " +
			"json_extract_path json_extract_path_text jsonb_extract_path jsonb_extract_path_text json_array_length " +
			"jsonb_array_length json_typeof jsonb_typeof jsonb_pretty json_object_keys jsonb_object_keys json_each jsonb_each " +
			"json_each_text jsonb_each_text json_array_elements jsonb_array_elements json_array_elements_text " +
			"jsonb_array_elements_text jsonb_path_query jsonb_path_query_array jsonb_path_query_first jsonb_path_exists " +
			"jsonb_strip_nulls array_length array_lower array_upper array_position array_positions array_remove array_append " +
			"array_prepend array_cat array_to_string string_to_array cardinality unnest generate_series",
		// casts written as calls, and row values
		"cast row text int4 int8 numeric float8 bool date",
	} {
		for _, f := range strings.Fields(group) {
			reportingSQLFunctions[f] = true
		}
	}
}

// ReportingSQLFunctionAllowed reports whether the SQL tab may call name
// (lower case, unqualified or pg_catalog).
func ReportingSQLFunctionAllowed(name string) bool { return reportingSQLFunctions[name] }
