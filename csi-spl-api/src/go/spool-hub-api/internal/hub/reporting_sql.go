package hub

import (
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Reporting SQL tab (spec 143 section 3, tasks T030 + T032, SPL-2789).
// Owner HUM-10 (t1 af25a1f3): "a simple sql tab, which provides a small
// 'run sql, get result set' functionality", for workspace admins (poll
// e804e13a), "read only" (msg 2295cba5).
//
//	POST /v1/reporting/sql  {"query": "SELECT ..."}
//	  200 {"columns": [{name, type}], "rows": [[text|null]], "row_count",
//	       "truncated", "duration_ms"}
//	  400 read_only_violation | single_statement_only | forbidden_function |
//	      forbidden_relation | syntax_error | query_error | bad_query |
//	      result_too_large
//	  403 admin_required      a member who is not an admin of the workspace
//	  408 query_timeout       past the 10 s statement budget
//
// Every attempt by a member, refused ones included, is one sql_query_audit
// row (rdb 0203); a result whose audit row is not written is not returned.
// This file is layers 1 (RBAC) and 2 (the lexical guard, checkReportingSQL);
// the executor (store/reporting_sql.go) is layers 3-5 and does not rely on
// this guard.

// reportingSQLMaxBody bounds the request: the query (rdb 0203: 100,000
// characters) plus its JSON.
const reportingSQLMaxBody = store.ReportingSQLMaxQuery + 1024

// reportingSQLRefusal is one guard refusal: the response token and why.
type reportingSQLRefusal struct{ code, detail string }

func (e *reportingSQLRefusal) Error() string { return e.detail }

func refuse(code, detail string) error { return &reportingSQLRefusal{code: code, detail: detail} }

// reportingSQLStarts are the words a query may begin with (after any
// opening parentheses): a read and nothing else.
var reportingSQLStarts = map[string]bool{"select": true, "with": true, "values": true, "table": true}

// reportingSQLDenied are the words that never belong in a read (spec 143
// 3.2): a write, DDL, a session or privilege change, procedural code, COPY,
// a transaction or cursor command, SELECT INTO. Matched as bare words
// outside literals; a quoted name ("set") is a name and passes.
var reportingSQLDenied = wordSet("insert update delete merge truncate upsert create alter drop rename grant revoke " +
	"set reset listen notify unlisten call do prepare execute deallocate copy into lock vacuum analyze cluster reindex " +
	"refresh discard begin commit rollback savepoint release checkpoint declare fetch move close import load security")

// reportingSQLCallWords are keywords written with a parenthesis after them
// that are not a function call (IN (, OVER (, a CTE's AS (, ...).
var reportingSQLCallWords = wordSet("in exists any all some over filter values as using from join on and or not where " +
	"select when then else by row array lateral within group partition is like ilike between distinct case union " +
	"intersect except limit offset having order with recursive materialized end returning only table cube rollup " +
	"grouping sets nulls first last asc desc fetch of interval varchar char character varying numeric decimal " +
	"timestamp time bit")

func wordSet(s string) map[string]bool {
	out := map[string]bool{}
	for _, w := range strings.Fields(s) {
		out[w] = true
	}
	return out
}

// sqlToken is one lexical token: a bare word (lower-cased), a quoted name,
// a literal, or one punctuation character.
type sqlToken struct {
	kind byte // 'w' word, 'q' quoted name, 's' literal, 'n' number, 'p' punctuation
	text string
}

// checkReportingSQL is the lexical guard (spec 143 3.2, T030): one SELECT
// statement, no denied word, no function off the store's list, no comment
// that names a denied word. It returns the text to run (one trailing
// semicolon dropped) or a refusal.
func checkReportingSQL(q string) (string, error) {
	q = strings.TrimSpace(q)
	if q == "" {
		return "", refuse("bad_query", "the query is empty")
	}
	if len(q) > store.ReportingSQLMaxQuery {
		return "", refuse("bad_query", "the query is longer than 100,000 characters")
	}
	toks, err := lexReportingSQL(q)
	if err != nil {
		return "", err
	}
	end := len(toks)
	if end > 0 && toks[end-1].kind == 'p' && toks[end-1].text == ";" {
		end--
	}
	toks = toks[:end]
	if err := checkSQLStart(toks); err != nil {
		return "", err
	}
	for i, tk := range toks {
		if err := checkSQLToken(toks, i, tk); err != nil {
			return "", err
		}
	}
	return strings.TrimRight(strings.TrimSpace(q), ";"), nil
}

// checkSQLStart: the first word, past opening parentheses, starts a read.
func checkSQLStart(toks []sqlToken) error {
	for _, tk := range toks {
		if tk.kind == 'p' && tk.text == "(" {
			continue
		}
		if tk.kind == 'w' && reportingSQLStarts[tk.text] {
			return nil
		}
		break
	}
	return refuse("read_only_violation", "only a SELECT (or WITH ... SELECT, VALUES, TABLE) runs here")
}

// checkSQLToken applies the per-token rules to toks[i].
func checkSQLToken(toks []sqlToken, i int, tk sqlToken) error {
	switch {
	case tk.kind == 'p' && tk.text == ";":
		return refuse("single_statement_only", "one statement only: nothing may follow a semicolon")
	case tk.kind == 'w' && reportingSQLDenied[tk.text]:
		return refuse("read_only_violation", strings.ToUpper(tk.text)+" is not allowed: the SQL tab is read only")
	case (tk.kind == 'w' || tk.kind == 'q') && i+1 < len(toks) && toks[i+1].kind == 'p' && toks[i+1].text == "(":
		return checkSQLCall(toks, i)
	}
	return nil
}

// checkSQLCall: a name followed by "(" is a function call unless it is a
// keyword, a type modifier (::numeric(10,2)), an alias column list
// (AS t(a, b)) or a CTE name (WITH x(a) AS); a call must be on the list,
// unqualified or in pg_catalog.
func checkSQLCall(toks []sqlToken, i int) error {
	tk := toks[i]
	if tk.kind == 'w' && reportingSQLCallWords[tk.text] {
		return nil
	}
	prev := sqlToken{}
	if i > 0 {
		prev = toks[i-1]
	}
	if prev.kind == 'p' && prev.text == "::" || prev.kind == 'w' && (prev.text == "as" || prev.text == "with" || prev.text == "recursive") {
		return nil
	}
	if prev.kind == 'p' && prev.text == "." {
		if i < 2 || toks[i-2].text != "pg_catalog" {
			return refuse("forbidden_function", "only functions of pg_catalog may be called by a qualified name")
		}
	}
	if !store.ReportingSQLFunctionAllowed(tk.text) {
		return refuse("forbidden_function", "function "+tk.text+" is not open to the SQL tab")
	}
	return nil
}

// lexReportingSQL splits q into tokens. It knows Postgres's literal and
// name forms (single-quoted, E-quoted, dollar-quoted, double-quoted, nested
// block comments, line comments) so a word inside one is never read as a
// keyword. A U& literal or name, a $n parameter and
// a backslash command are refused: none belongs in a report query.
func lexReportingSQL(q string) ([]sqlToken, error) {
	var toks []sqlToken
	for i := 0; i < len(q); {
		tk, next, err := lexOne(q, i)
		if err != nil {
			return nil, err
		}
		if tk.kind != 0 {
			toks = append(toks, tk)
		}
		i = next
	}
	return toks, nil
}

// lexOne reads the token at i; kind 0 = nothing to keep (space, comment).
func lexOne(q string, i int) (sqlToken, int, error) {
	c := q[i]
	switch {
	case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f':
		return sqlToken{}, i + 1, nil
	case c == '-' && strings.HasPrefix(q[i:], "--"):
		end := strings.IndexByte(q[i:], '\n')
		if end < 0 {
			end = len(q) - i
		}
		return sqlToken{}, i + end, checkSQLComment(q[i+2 : i+end])
	case c == '/' && strings.HasPrefix(q[i:], "/*"):
		return lexBlockComment(q, i)
	case c == '\'':
		end, err := lexQuoted(q, i, '\'', false)
		return sqlToken{kind: 's'}, end, err
	case (c == 'e' || c == 'E') && i+1 < len(q) && q[i+1] == '\'':
		end, err := lexQuoted(q, i+1, '\'', true)
		return sqlToken{kind: 's'}, end, err
	case (c == 'u' || c == 'U') && i+1 < len(q) && q[i+1] == '&':
		return sqlToken{}, 0, refuse("bad_query", "U& literals and names are not supported")
	case c == '"':
		end, err := lexQuoted(q, i, '"', false)
		if err != nil {
			return sqlToken{}, 0, err
		}
		return sqlToken{kind: 'q', text: strings.ReplaceAll(q[i+1:end-1], `""`, `"`)}, end, nil
	case c == '$':
		return lexDollar(q, i)
	case c == '\\':
		return sqlToken{}, 0, refuse("read_only_violation", "backslash commands (\\copy, ...) are not SQL")
	}
	return lexPlain(q, i)
}

// lexPlain reads a word, a number or one punctuation mark (:: is one).
func lexPlain(q string, i int) (sqlToken, int, error) {
	c := q[i]
	if isWordStart(c) {
		j := i
		for j < len(q) && (isWordStart(q[j]) || q[j] >= '0' && q[j] <= '9' || q[j] == '$') {
			j++
		}
		return sqlToken{kind: 'w', text: strings.ToLower(q[i:j])}, j, nil
	}
	if c >= '0' && c <= '9' {
		j := i
		for j < len(q) && (q[j] >= '0' && q[j] <= '9' || q[j] == '.' || q[j] == '_' || q[j] == 'e' || q[j] == 'E') {
			j++
		}
		return sqlToken{kind: 'n', text: q[i:j]}, j, nil
	}
	if c == ':' && strings.HasPrefix(q[i:], "::") {
		return sqlToken{kind: 'p', text: "::"}, i + 2, nil
	}
	return sqlToken{kind: 'p', text: string(c)}, i + 1, nil
}

func isWordStart(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80
}

// lexQuoted returns the index past the literal or name opened at i; a
// doubled quote is the quote itself, and in an E-quoted literal a
// backslash escapes the next byte.
func lexQuoted(q string, i int, quote byte, backslash bool) (int, error) {
	for j := i + 1; j < len(q); j++ {
		switch {
		case backslash && q[j] == '\\':
			j++
		case q[j] == quote && j+1 < len(q) && q[j+1] == quote:
			j++
		case q[j] == quote:
			return j + 1, nil
		}
	}
	return 0, refuse("bad_query", "a quoted literal or name is not closed")
}

// lexBlockComment skips a /* */ comment, nested as Postgres nests them.
func lexBlockComment(q string, i int) (sqlToken, int, error) {
	depth := 0
	for j := i; j+1 < len(q); j++ {
		switch {
		case q[j] == '/' && q[j+1] == '*':
			depth++
			j++
		case q[j] == '*' && q[j+1] == '/':
			depth--
			j++
			if depth == 0 {
				return sqlToken{}, j + 1, checkSQLComment(q[i : j+1])
			}
		}
	}
	return sqlToken{}, 0, refuse("bad_query", "a /* comment is not closed")
}

// checkSQLComment refuses a comment that names a denied word (spec 143 3.2:
// "comments containing command patterns"): a comment cannot run, but one
// that does hides what a query means from whoever reads the audit.
func checkSQLComment(text string) error {
	for _, w := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return r != '_' && (r < 'a' || r > 'z')
	}) {
		if reportingSQLDenied[w] {
			return refuse("read_only_violation", "a comment names "+strings.ToUpper(w)+": comments may not hold commands")
		}
	}
	return nil
}

// lexDollar reads a $tag$...$tag$ literal; $1 (a parameter) is refused.
func lexDollar(q string, i int) (sqlToken, int, error) {
	j := i + 1
	for j < len(q) && (isWordStart(q[j]) || q[j] >= '0' && q[j] <= '9') {
		j++
	}
	if j >= len(q) || q[j] != '$' || (j > i+1 && q[i+1] >= '0' && q[i+1] <= '9') {
		return sqlToken{}, 0, refuse("bad_query", "parameters ($1) are not supported")
	}
	tag := q[i : j+1]
	end := strings.Index(q[j+1:], tag)
	if end < 0 {
		return sqlToken{}, 0, refuse("bad_query", "a dollar-quoted literal is not closed")
	}
	return sqlToken{kind: 's'}, j + 1 + end + len(tag), nil
}

// reportingSQLBody is the 200 answer.
type reportingSQLBody struct {
	Columns    []store.ReportingSQLColumn `json:"columns"`
	Rows       [][]*string                `json:"rows"`
	RowCount   int                        `json:"row_count"`
	Truncated  bool                       `json:"truncated"`
	DurationMS int64                      `json:"duration_ms"`
}

// POST /v1/reporting/sql
func (s *Server) handleReportingSQL(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TopicsRead)
	if !ok {
		return
	}
	rs, hasSQL := s.o.Store.(store.ReportingSQLStore)
	if !a.Has(rbac.Admin) {
		s.refuseReportingSQL(w, r, rs, hasSQL, store.ReportingSQLAudit{Tenant: t.ID, Human: a.HumanID, At: s.o.Now(), ClientIP: s.edge.ClientIP(r)})
		return
	}
	if !hasSQL {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store runs no SQL tab")
		return
	}
	q, ok := decodeReportingSQL(w, r)
	if !ok {
		return
	}
	audit := store.ReportingSQLAudit{Tenant: t.ID, Human: a.HumanID, Query: q, At: s.o.Now(), ClientIP: s.edge.ClientIP(r)}
	run, err := checkReportingSQL(q)
	start := time.Now()
	var res store.ReportingSQLResult
	if err == nil {
		res, err = rs.RunReportingSQL(r.Context(), t.ID, run)
	}
	audit.Duration, audit.Rows, audit.Truncated = time.Since(start), len(res.Rows), res.Truncated
	if err != nil {
		status, code, detail := reportingSQLError(err)
		audit.Error = code + ": " + detail
		s.answerReportingSQL(w, r, rs, audit, func() { writeErrCause(w, status, code, detail, err) })
		return
	}
	s.answerReportingSQL(w, r, rs, audit, func() {
		writeJSON(w, http.StatusOK, reportingSQLBody{Columns: res.Columns, Rows: res.Rows, RowCount: len(res.Rows),
			Truncated: res.Truncated, DurationMS: audit.Duration.Milliseconds()})
	})
}

// refuseReportingSQL answers a member who is not an admin: 403
// admin_required, the attempt audited with the query it sent (best effort:
// a body that does not decode is audited empty; nothing is withheld).
func (s *Server) refuseReportingSQL(w http.ResponseWriter, r *http.Request, rs store.ReportingSQLStore, hasSQL bool, a store.ReportingSQLAudit) {
	if hasSQL {
		var req struct {
			Query string `json:"query"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, reportingSQLMaxBody)).Decode(&req)
		a.Query, a.Error = req.Query, "admin_required"
		if err := rs.AuditReportingSQL(r.Context(), a); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", a.Tenant).Str("by", a.Human).Msg("reporting.sql audit of a refusal failed")
		}
	}
	writeErr(w, http.StatusForbidden, "admin_required", "the SQL tab is for the workspace's admins")
}

// answerReportingSQL writes the audit row, then the answer; no audit row,
// no answer (500).
func (s *Server) answerReportingSQL(w http.ResponseWriter, r *http.Request, rs store.ReportingSQLStore, a store.ReportingSQLAudit, answer func()) {
	if err := rs.AuditReportingSQL(r.Context(), a); err != nil {
		writeErrCause(w, http.StatusInternalServerError, "audit_failed", "the query was not audited, so its result is withheld", err)
		return
	}
	s.o.Log.Info().Str("tenant", a.Tenant).Str("by", a.Human).Int("rows", a.Rows).Bool("truncated", a.Truncated).
		Int64("ms", a.Duration.Milliseconds()).Str("error", a.Error).Msg("reporting.sql")
	answer()
}

// reportingSQLError maps a guard or executor refusal to its answer.
func reportingSQLError(err error) (int, string, string) {
	var gr *reportingSQLRefusal
	var sr *store.ReportingSQLRefusal
	var qe *store.ReportingSQLQueryError
	switch {
	case errors.As(err, &gr):
		return http.StatusBadRequest, gr.code, gr.detail
	case errors.As(err, &sr):
		return http.StatusBadRequest, sr.Code, sr.Error()
	case errors.As(err, &qe):
		return http.StatusBadRequest, qe.Code, qe.Message
	case errors.Is(err, store.ErrReportingSQLReadOnly):
		return http.StatusBadRequest, "read_only_violation", err.Error()
	case errors.Is(err, store.ErrReportingSQLTooLarge):
		return http.StatusBadRequest, "result_too_large", err.Error()
	case errors.Is(err, store.ErrReportingSQLTimeout):
		return http.StatusRequestTimeout, "query_timeout", err.Error()
	}
	return http.StatusInternalServerError, "internal", "the query did not run"
}

// decodeReportingSQL reads {"query": "..."} (application/json only, as
// every member write: a text/plain form post needs no preflight).
func decodeReportingSQL(w http.ResponseWriter, r *http.Request) (string, bool) {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return "", false
	}
	var req struct {
		Query string `json:"query"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, reportingSQLMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", `body must be {"query": "SELECT ..."}`)
		return "", false
	}
	return req.Query, true
}

func (s *Server) reportingSQLPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// routeReportingSQL mounts the SQL tab's one route.
func (s *Server) routeReportingSQL(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/reporting/sql", s.handleReportingSQL)
	mux.HandleFunc("OPTIONS /v1/reporting/sql", s.reportingSQLPreflight)
}
