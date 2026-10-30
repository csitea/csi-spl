// SPDX-License-Identifier: AGPL-3.0-only

package channelmove

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The gate C2 (spec 169 section 9): every table with tenant_id is classified
// in Catalogue. The tables are read from the migrations themselves by the
// small DDL reader below, so the gate runs in plain `go test` with no
// database; TestCatalogueSchemaMatchesPostgres proves the reader against a
// migrated Postgres when $SPOOL_TEST_PG_DSN names one.

func sqlDir(t testing.TB) string {
	if d := os.Getenv("SPOOL_TEST_SQL_DIR"); d != "" {
		return d
	}
	// go test runs in the package dir (internal/channelmove), as store's sqlDir
	return filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
}

// ---- the DDL reader ---------------------------------------------------------

// table is what the migrations leave of one table: its columns and its
// foreign keys (constraint name -> referenced table).
type table struct {
	cols map[string]bool
	fks  map[string]string
}

func newTable() *table { return &table{cols: map[string]bool{}, fks: map[string]string{}} }

// refs is the set of tables the foreign keys reference.
func (tb *table) refs() map[string]bool {
	out := map[string]bool{}
	for _, parent := range tb.fks {
		out[parent] = true
	}
	return out
}

type schema map[string]*table

func (s schema) tenantTables() []string {
	var out []string
	for name, tb := range s {
		if tb.cols["tenant_id"] {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// readSchema applies every migration of dir in file order.
func readSchema(t testing.TB, dir string) schema {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no migrations under %s (err %v)", dir, err)
	}
	sort.Strings(files)
	s := schema{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := s.apply(string(b)); err != nil {
			t.Fatalf("%s: %v (teach the reader in catalogue_test.go this DDL form)", filepath.Base(f), err)
		}
	}
	return s
}

// apply reads the CREATE TABLE, ALTER TABLE and DROP TABLE statements of one
// SQL file. A function or DO body ($$ ... $$) is skipped whole.
func (s schema) apply(src string) error {
	toks, err := lexSQL(src)
	if err != nil {
		return err
	}
	for _, st := range splitTop(toks, ";") {
		if err := s.statement(st); err != nil {
			return err
		}
	}
	return nil
}

func (s schema) statement(st []string) error {
	switch {
	case len(st) > 1 && st[0] == "create":
		return s.create(st)
	case len(st) > 2 && st[0] == "alter" && st[1] == "table":
		return s.alter(st)
	case len(st) > 2 && st[0] == "drop" && st[1] == "table":
		return s.drop(st)
	}
	return nil
}

var constraintWords = map[string]bool{"constraint": true, "primary": true, "unique": true,
	"foreign": true, "check": true, "exclude": true}

func (s schema) create(st []string) error {
	i, temp := 1, false
	for i < len(st) && map[string]bool{"global": true, "local": true, "temp": true, "temporary": true, "unlogged": true}[st[i]] {
		temp = temp || st[i] == "temp" || st[i] == "temporary"
		i++
	}
	if i >= len(st) || st[i] != "table" {
		return nil // an index, view, function, policy ...
	}
	i = skipWords(st, i+1, "if", "not", "exists")
	name, i, public := qualName(st, i)
	if temp || !public {
		return nil
	}
	if i >= len(st) || st[i] != "(" {
		return fmt.Errorf("CREATE TABLE %s: only the (column, ...) form is read", name)
	}
	end := closeParen(st, i)
	for _, w := range st[end+1:] {
		if w == "inherits" || w == "partition" {
			return fmt.Errorf("CREATE TABLE %s: %s is not read", name, w)
		}
	}
	if _, ok := s[name]; ok {
		return nil // CREATE TABLE IF NOT EXISTS of a table already made
	}
	tb := newTable()
	for _, item := range splitTop(st[i+1:end], ",") {
		if len(item) == 0 {
			continue
		}
		if item[0] == "like" {
			return fmt.Errorf("CREATE TABLE %s (LIKE ...) is not read", name)
		}
		if !constraintWords[item[0]] {
			tb.cols[item[0]] = true
		}
		addFK(tb, name, item)
	}
	s[name] = tb
	return nil
}

func (s schema) alter(st []string) error {
	i := skipWords(st, 2, "if", "exists")
	i = skipWords(st, i, "only")
	name, i, public := qualName(st, i)
	if !public {
		return nil
	}
	tb, ok := s[name]
	if !ok {
		return fmt.Errorf("ALTER TABLE %s before its CREATE TABLE", name)
	}
	for _, act := range splitTop(st[i:], ",") {
		if err := s.alterAction(name, tb, act); err != nil {
			return err
		}
	}
	return nil
}

func (s schema) alterAction(name string, tb *table, act []string) error {
	if len(act) < 2 {
		return nil
	}
	switch act[0] {
	case "add":
		if constraintWords[act[1]] {
			addFK(tb, name, act[1:])
			return nil
		}
		j := skipWords(act, skipWords(act, 1, "column"), "if", "not", "exists")
		tb.cols[act[j]] = true
		addFK(tb, name, act[j:])
	case "drop":
		if act[1] == "constraint" {
			delete(tb.fks, act[skipWords(act, 2, "if", "exists")])
			return nil
		}
		j := skipWords(act, skipWords(act, 1, "column"), "if", "exists")
		delete(tb.cols, act[j])
	case "rename":
		return s.rename(name, tb, act)
	}
	return nil
}

func (s schema) rename(name string, tb *table, act []string) error {
	switch {
	case act[1] == "to" && len(act) > 2:
		s[act[2]] = tb
		delete(s, name)
	case act[1] == "constraint":
	case len(act) > 4 && act[1] == "column" && act[3] == "to":
		delete(tb.cols, act[2])
		tb.cols[act[4]] = true
	case len(act) > 3 && act[2] == "to":
		delete(tb.cols, act[1])
		tb.cols[act[3]] = true
	default:
		return fmt.Errorf("ALTER TABLE %s RENAME: form not read", name)
	}
	return nil
}

func (s schema) drop(st []string) error {
	i := skipWords(st, 2, "if", "exists")
	for _, n := range splitTop(st[i:], ",") {
		if len(n) == 0 {
			continue
		}
		if name, _, public := qualName(n, 0); public {
			delete(s, name)
		}
	}
	return nil
}

// addFK records the foreign key of a column definition or a table
// constraint, under the name Postgres gives it (<table>_<cols>_fkey unless
// named), so a later DROP CONSTRAINT removes it.
func addFK(tb *table, tableName string, item []string) {
	k := 0
	for k < len(item) && item[k] != "references" {
		k++
	}
	parent, _, public := qualName(item, k+1)
	if k >= len(item) || !public {
		return
	}
	switch {
	case item[0] == "constraint" && len(item) > 1:
		tb.fks[item[1]] = parent
	case item[0] == "foreign":
		open := skipWords(item, 1, "key")
		cols := splitTop(item[open+1:closeParen(item, open)], ",")
		names := make([]string, 0, len(cols))
		for _, c := range cols {
			names = append(names, strings.Join(c, ""))
		}
		tb.fks[autoName(tb, tableName+"_"+strings.Join(names, "_")+"_fkey")] = parent
	default:
		tb.fks[autoName(tb, tableName+"_"+item[0]+"_fkey")] = parent
	}
}

// autoName is Postgres's choice for an unnamed key: base, else base1, base2 ...
func autoName(tb *table, base string) string {
	name := base
	for n := 1; ; n++ {
		if _, taken := tb.fks[name]; !taken {
			return name
		}
		name = fmt.Sprintf("%s%d", base, n)
	}
}

// qualName reads [schema.]name at i; public is false for a schema other
// than public (the personal schema holds no tenant table).
func qualName(toks []string, i int) (name string, next int, public bool) {
	if i >= len(toks) {
		return "", i, false
	}
	if i+2 < len(toks) && toks[i+1] == "." {
		return toks[i+2], i + 3, toks[i] == "public"
	}
	return toks[i], i + 1, true
}

func skipWords(toks []string, i int, words ...string) int {
	for k, w := range words {
		if i+k >= len(toks) || toks[i+k] != w {
			return i
		}
	}
	return i + len(words)
}

func closeParen(toks []string, open int) int {
	depth := 0
	for k := open; k < len(toks); k++ {
		switch toks[k] {
		case "(":
			depth++
		case ")":
			depth--
			if depth == 0 {
				return k
			}
		}
	}
	return len(toks) - 1
}

// splitTop splits toks on sep outside parentheses.
func splitTop(toks []string, sep string) [][]string {
	var out [][]string
	depth, start := 0, 0
	for k, w := range toks {
		switch {
		case w == "(":
			depth++
		case w == ")":
			depth--
		case w == sep && depth == 0:
			out = append(out, toks[start:k])
			start = k + 1
		}
	}
	return append(out, toks[start:])
}

// lexSQL turns SQL into lower-case words and one-character punctuation.
// Comments go; a string literal becomes one empty-string token and a
// dollar-quoted body one $$ token.
func lexSQL(src string) ([]string, error) {
	var toks []string
	for i := 0; i < len(src); {
		c := src[i]
		n, tok, err := lexOne(src, i)
		if err != nil {
			return nil, err
		}
		if tok != "" {
			toks = append(toks, tok)
		}
		if n == i {
			return nil, fmt.Errorf("lexer stuck at %q", c)
		}
		i = n
	}
	return toks, nil
}

func lexOne(src string, i int) (next int, tok string, err error) {
	c := src[i]
	switch {
	case c == ' ' || c == '\t' || c == '\n' || c == '\r':
		return i + 1, "", nil
	case strings.HasPrefix(src[i:], "--"):
		return endAt(src, i, "\n"), "", nil
	case strings.HasPrefix(src[i:], "/*"):
		return endAt(src, i+2, "*/"), "", nil
	case c == '\'':
		return quoted(src, i, '\''), "''", nil
	case c == '"':
		e := quoted(src, i, '"')
		return e, src[i+1 : e-1], nil
	case c == '$':
		return dollar(src, i)
	case isWord(c):
		e := i
		for e < len(src) && isWord(src[e]) {
			e++
		}
		return e, strings.ToLower(src[i:e]), nil
	}
	return i + 1, string(c), nil
}

func isWord(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

func endAt(src string, from int, end string) int {
	k := strings.Index(src[from:], end)
	if k < 0 {
		return len(src)
	}
	return from + k + len(end)
}

// quoted returns the index after a q-quoted literal starting at i (qq escapes q).
func quoted(src string, i int, q byte) int {
	for k := i + 1; k < len(src); k++ {
		if src[k] == q {
			if k+1 < len(src) && src[k+1] == q {
				k++
				continue
			}
			return k + 1
		}
	}
	return len(src)
}

// dollar skips a $tag$ ... $tag$ body; a $1 placeholder is one token.
func dollar(src string, i int) (int, string, error) {
	k := i + 1
	for k < len(src) && (src[k] == '_' || src[k] >= 'a' && src[k] <= 'z' || src[k] >= 'A' && src[k] <= 'Z') {
		k++
	}
	if k >= len(src) || src[k] != '$' {
		return i + 1, "$", nil
	}
	tag := src[i : k+1]
	e := strings.Index(src[k+1:], tag)
	if e < 0 {
		return 0, "", fmt.Errorf("unterminated %s body", tag)
	}
	return k + 1 + e + len(tag), "$$", nil
}

// ---- the checks -------------------------------------------------------------

// coverageGaps is C2: a tenant table with no entry, an entry for a table that
// does not carry tenant_id, and a table listed twice.
func coverageGaps(s schema, cat []Entry) []string {
	var gaps []string
	seen := map[string]bool{}
	for _, e := range cat {
		if seen[e.Table] {
			gaps = append(gaps, e.Table+": listed twice")
		}
		seen[e.Table] = true
		if tb, ok := s[e.Table]; !ok || !tb.cols["tenant_id"] {
			gaps = append(gaps, e.Table+": in the catalogue but not a tenant_id table in the migrations (drop the entry)")
		}
	}
	for _, name := range s.tenantTables() {
		if !seen[name] {
			gaps = append(gaps, name+": carries tenant_id but has no entry in channelmove.Catalogue (classify it: "+
				"moved / rewritten / recomputed / not-channel, with its reason)")
		}
	}
	return gaps
}

// shapeIssues: each class carries exactly the predicates it needs.
func shapeIssues(e Entry) []string {
	var out []string
	want := map[Class][2]bool{Moved: {true, false}, Rewritten: {false, true}, Recomputed: {false, false}, Refuse: {true, false}, NotChannel: {false, false}}
	w, ok := want[e.Class]
	switch {
	case !ok:
		out = append(out, fmt.Sprintf("%s: unknown class %q", e.Table, e.Class))
	case (e.Set != "") != w[0]:
		out = append(out, fmt.Sprintf("%s: class %s wants Set=%v", e.Table, e.Class, w[0]))
	case e.Class != Moved && (e.Refs != "") != w[1]:
		out = append(out, fmt.Sprintf("%s: class %s wants Refs=%v", e.Table, e.Class, w[1]))
	}
	if strings.TrimSpace(e.Reason) == "" {
		out = append(out, e.Table+": no reason")
	}
	if len(e.Needs) > 0 && e.Class != Moved {
		out = append(out, e.Table+": Needs is for a moved table only")
	}
	return out
}

var predicateWords = map[string]bool{"and": true, "or": true, "not": true, "any": true, "is": true,
	"null": true, "in": true, "like": true, "true": true, "false": true}

// predicateIssues: a predicate names only its table's columns and declared
// binds, never tenant_id (the caller scopes it).
func predicateIssues(table string, pred string, cols map[string]bool) []string {
	toks, err := lexSQL(pred)
	if err != nil {
		return []string{table + ": " + err.Error()}
	}
	var out []string
	for k := 0; k < len(toks); k++ {
		w := toks[k]
		switch {
		case w == "@" && k+1 < len(toks):
			k++
			if _, ok := Binds[toks[k]]; !ok {
				out = append(out, fmt.Sprintf("%s: bind @%s is not in Binds", table, toks[k]))
			}
		case w == ":" && k+2 < len(toks) && toks[k+1] == ":":
			k += 2 // the type of a cast
		case !isWord(w[0]) || w[0] >= '0' && w[0] <= '9' || predicateWords[w]:
		case w == "tenant_id":
			out = append(out, table+": a predicate never names tenant_id (the caller scopes it)")
		case !cols[w]:
			out = append(out, fmt.Sprintf("%s: column %s is not in the table", table, w))
		}
	}
	return out
}

// orderIssues: a moved table comes after every tenant table it references
// (the inserts run in catalogue order, the deletes in reverse, F5), unless
// that parent is the workspace itself or listed in Needs; and a staying
// table that references a moved one must be Rewritten (or Refuse, whose
// rows stop the move), since the <SRC> delete reaches it through the FK.
func orderIssues(s schema, cat []Entry) []string {
	pos, byName := map[string]int{}, map[string]Entry{}
	for k, e := range cat {
		pos[e.Table], byName[e.Table] = k, e
	}
	var out []string
	for _, child := range s.tenantTables() {
		ce := byName[child]
		for parent := range s[child].refs() {
			pe, isTenant := byName[parent]
			if parent == child || !isTenant || parent == "tenants" {
				continue
			}
			out = append(out, edgeIssue(ce, pe, pos)...)
		}
	}
	sort.Strings(out)
	return out
}

func edgeIssue(ce, pe Entry, pos map[string]int) []string {
	needs := map[string]bool{}
	for _, n := range ce.Needs {
		needs[n] = true
	}
	switch {
	case ce.Class == Moved && pe.Class == Moved && pos[pe.Table] > pos[ce.Table]:
		return []string{fmt.Sprintf("%s references %s: move %s before it in the catalogue", ce.Table, pe.Table, pe.Table)}
	case ce.Class == Moved && pe.Class != Moved && !needs[pe.Table]:
		return []string{fmt.Sprintf("%s references %s, which does not move: list it in %s's Needs", ce.Table, pe.Table, ce.Table)}
	case ce.Class != Moved && ce.Class != Rewritten && ce.Class != Refuse && pe.Class == Moved:
		return []string{fmt.Sprintf("%s references the moved %s: the <SRC> delete reaches it; class it moved or rewritten", ce.Table, pe.Table)}
	}
	return nil
}

func allIssues(s schema, cat []Entry) []string {
	issues := coverageGaps(s, cat)
	for _, e := range cat {
		issues = append(issues, shapeIssues(e)...)
		tb, ok := s[e.Table]
		if !ok {
			continue
		}
		for _, p := range []string{e.Set, e.Refs} {
			if p != "" {
				issues = append(issues, predicateIssues(e.Table, p, tb.cols)...)
			}
		}
		refs := tb.refs()
		for _, n := range e.Needs {
			if !refs[n] {
				issues = append(issues, fmt.Sprintf("%s: Needs %s but has no FK to it", e.Table, n))
			}
		}
	}
	return append(issues, orderIssues(s, cat)...)
}

// ---- the tests --------------------------------------------------------------

// TestCatalogueCoversEveryTenantTable is the gate C2.
func TestCatalogueCoversEveryTenantTable(t *testing.T) {
	s := readSchema(t, sqlDir(t))
	n := len(s.tenantTables())
	if n < 100 {
		t.Fatalf("the reader found %d tenant tables; the hub has over 100 (reader broken?)", n)
	}
	for _, g := range allIssues(s, Catalogue) {
		t.Error(g)
	}
	t.Logf("%d tenant tables, %d entries", n, len(Catalogue))
}

// TestCatalogueGateRedControls: each planted defect is reported.
func TestCatalogueGateRedControls(t *testing.T) {
	base := readSchema(t, sqlDir(t))
	cases := []struct {
		name, ddl string
		cat       func() []Entry
		want      string
	}{
		{"new tenant table, no entry", `CREATE TABLE c2_planted (tenant_id text NOT NULL, x int);`, nil,
			"c2_planted: carries tenant_id but has no entry"},
		{"tenant_id added by ALTER", `CREATE TABLE c2_alter (x int); ALTER TABLE c2_alter ADD COLUMN IF NOT EXISTS tenant_id text;`, nil,
			"c2_alter: carries tenant_id"},
		{"stale entry", `DROP TABLE IF EXISTS hours_terminals;`, nil, "hours_terminals: in the catalogue but not"},
		{"listed twice", "", func() []Entry { return append(clone(), Entry{Table: "channels", Class: NotChannel, Reason: "x"}) },
			"channels: listed twice"},
		{"unknown column", "", func() []Entry { return edit("channels", func(e *Entry) { e.Set = `chan_id = @channel` }) },
			"channels: column chan_id is not in the table"},
		{"undeclared bind", "", func() []Entry { return edit("channels", func(e *Entry) { e.Set = `channel_id = @chan` }) },
			"bind @chan is not in Binds"},
		{"tenant_id in a predicate", "", func() []Entry { return edit("channels", func(e *Entry) { e.Set = `tenant_id = @channel` }) },
			"never names tenant_id"},
		{"child before its parent", "", func() []Entry { return swap("messages", "deliveries") },
			"deliveries references messages: move messages before it"},
		{"moved child of a staying parent", "", func() []Entry { return edit("channel_invites", func(e *Entry) { e.Needs = nil }) },
			"channel_invites references tenant_invites, which does not move"},
		{"refuse without a predicate", "", func() []Entry { return edit("embed_visitors", func(e *Entry) { e.Set = "" }) },
			"embed_visitors: class refuse wants Set=true"},
		{"cascade into an unclassified stayer", "", func() []Entry {
			return edit("gcal_event_map", func(e *Entry) { e.Class, e.Refs = NotChannel, "" })
		}, "gcal_event_map references the moved calendar_events"},
		{"moved without a predicate", "", func() []Entry { return edit("channels", func(e *Entry) { e.Set = "" }) },
			"channels: class moved wants Set=true"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := copySchema(base)
			if err := s.apply(c.ddl); err != nil {
				t.Fatal(err)
			}
			cat := Catalogue
			if c.cat != nil {
				cat = c.cat()
			}
			got := strings.Join(allIssues(s, cat), "\n")
			if !strings.Contains(got, c.want) {
				t.Fatalf("planted defect not reported: want %q, got:\n%s", c.want, got)
			}
		})
	}
}

func clone() []Entry { return append([]Entry(nil), Catalogue...) }

func edit(table string, f func(*Entry)) []Entry {
	cat := clone()
	for k := range cat {
		if cat[k].Table == table {
			f(&cat[k])
		}
	}
	return cat
}

func swap(a, b string) []Entry {
	cat := clone()
	ia, ib := -1, -1
	for k, e := range cat {
		if e.Table == a {
			ia = k
		}
		if e.Table == b {
			ib = k
		}
	}
	if ia >= 0 && ib >= 0 {
		cat[ia], cat[ib] = cat[ib], cat[ia]
	}
	return cat
}

func copySchema(s schema) schema {
	out := schema{}
	for name, tb := range s {
		c := newTable()
		for k := range tb.cols {
			c.cols[k] = true
		}
		for k, v := range tb.fks {
			c.fks[k] = v
		}
		out[name] = c
	}
	return out
}

// TestCatalogueFollowsSpec pins the classes spec 169 sections 4 and 5.1
// name (v0.5 for 5.1a, 5.1b and M6c).
func TestCatalogueFollowsSpec(t *testing.T) {
	want := map[Class][]string{
		Moved: {"channels", "messages", "hours_jobs", "message_revisions", "message_reactions", "message_kind_changes",
			"message_moderation", "message_answers", "deliveries", "delivery_live_acks", "fallback_deliveries",
			"channel_humans", "channel_invites", "channel_subscriptions", "dedicated_agents", "read_marks",
			"topic_heads", "topic_head_parts", "topic_priorities", "flow_watches", "flow_events", "calendar_events",
			"issues", "issue_events", "issue_opens", "issue_discussions", "spec_sync_map", "workspace_doc",
			"workspace_doc_item", "workspace_doc_node", "workspace_doc_acl", "workspace_doc_rev_log",
			"usage_events", "token_budgets", "hours_plan", "hours_minutes", "hours_entries", "hours_entry_spans",
			"hours_adjustments", "calendar_guests"},
		Refuse:     {"embed_visitors"},
		Rewritten:  {"tenant_memberships", "fleet_lanes", "fleet_asks", "gcal_event_map"},
		Recomputed: {"message_period_counts", "quota_counts", "topic_head_tenants", "tenant_change_stamps"},
		NotChannel: {"marketing_channels", "marketing_posts", "gcal_connections", "issue_labels", "repo_doc_edits"},
	}
	for class, tables := range want {
		for _, tb := range tables {
			if e, ok := Lookup(tb); !ok || e.Class != class {
				t.Errorf("%s: spec 169 says %s, catalogue has %q (found %v)", tb, class, e.Class, ok)
			}
		}
	}
	if _, ok := Lookup("no_such_table"); ok {
		t.Error("Lookup found a table that is not listed")
	}
}

// TestCatalogueSchemaMatchesPostgres proves the DDL reader: on a migrated
// Postgres the tenant tables, their columns and their FK parents equal what
// the reader found, and every predicate plans with its binds.
func TestCatalogueSchemaMatchesPostgres(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	pg, err := store.OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	if _, err := store.Migrate(ctx, pg.Pool(), sqlDir(t)); err != nil {
		t.Fatal(err)
	}
	read := readSchema(t, sqlDir(t))
	live := liveSchema(t, pg)
	if got, want := describe(read), describe(live); got != want {
		t.Errorf("the DDL reader and Postgres disagree:\nreader:\n%s\npostgres:\n%s", got, want)
	}
	for _, e := range Catalogue {
		for _, p := range []string{e.Set, e.Refs} {
			if p == "" {
				continue
			}
			q := "EXPLAIN SELECT 1 FROM " + e.Table + " WHERE tenant_id = @src AND (" + p + ")"
			if _, err := pg.Pool().Exec(ctx, q, sampleBinds()); err != nil {
				t.Errorf("%s: %s: %v", e.Table, p, err)
			}
		}
	}
}

func liveSchema(t *testing.T, pg *store.Postgres) schema {
	t.Helper()
	ctx := context.Background()
	s := schema{}
	rows, err := pg.Pool().Query(ctx, `SELECT c.relname, a.attname FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
		WHERE n.nspname = current_schema() AND c.relkind = 'r'
		  AND EXISTS (SELECT 1 FROM pg_attribute t WHERE t.attrelid = c.oid AND t.attname = 'tenant_id' AND NOT t.attisdropped)`)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range collectPairs(t, rows) {
		if s[r[0]] == nil {
			s[r[0]] = newTable()
		}
		s[r[0]].cols[r[1]] = true
	}
	rows, err = pg.Pool().Query(ctx, `SELECT c.conrelid::regclass::text || ' ' || c.conname, c.confrelid::regclass::text
		FROM pg_constraint c WHERE c.contype = 'f'`)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range collectPairs(t, rows) {
		child, name, _ := strings.Cut(r[0], " ")
		if s[child] != nil {
			s[child].fks[name] = r[1]
		}
	}
	return s
}

func collectPairs(t *testing.T, rows pgx.Rows) [][2]string {
	t.Helper()
	defer rows.Close()
	var out [][2]string
	for rows.Next() {
		var a, b string
		if err := rows.Scan(&a, &b); err != nil {
			t.Fatal(err)
		}
		out = append(out, [2]string{a, b})
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// describe prints the tenant tables of s, one line each, for a diff.
func describe(s schema) string {
	var b strings.Builder
	for _, name := range s.tenantTables() {
		fmt.Fprintf(&b, "%s cols=%s refs=%s\n", name, keys(s[name].cols), fkList(s[name].fks))
	}
	return b.String()
}

func fkList(fks map[string]string) string {
	var out []string
	for name, parent := range fks {
		out = append(out, name+">"+parent)
	}
	sort.Strings(out)
	return strings.Join(out, ",")
}

func keys(m map[string]bool) string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return strings.Join(out, ",")
}

func sampleBinds() pgx.NamedArgs {
	id := "00000000-0000-4000-8000-000000000169"
	args := pgx.NamedArgs{"src": "t-src"}
	for name, typ := range Binds {
		switch typ {
		case "text":
			args[name] = "c-169"
		case "int[]":
			args[name] = []int32{169}
		case "uuid[]":
			args[name] = []string{id}
		default:
			args[name] = []string{"%" + id + "%"}
		}
	}
	return args
}
