// SPDX-License-Identifier: AGPL-3.0-only

package channelmove

// The proofs of a channel move (spec 169 T8, step P7, sections 5.1, 5.2):
//
//   - SetProofs counts, in <SRC>, the rows every catalogue predicate still
//     finds: a Moved or Refuse entry's Set, a Moved or Rewritten entry's
//     Refs. After a move each must print 0 (section 5.1). M11's tables are
//     counted in every workspace: their rows live in the fleet's own.
//   - Scan is the free-text scan (5.2, case C14): every text, varchar, json,
//     jsonb, uuid and array column of every table, read from
//     information_schema at run time, is counted for the channel id, the
//     channel name and every task and msg UUID of the set. <SRC> rows of the
//     tenant tables, every row of the hub-wide ones.
//   - TakeSnapshot and Diff are case C13: a diff of <SRC> before and after
//     names every row the move changed that it may not change. The only
//     <SRC> writes it allows besides the deletes of the set are the named
//     rewrites (rewrites below, and Rules.Extra for the owner's shared-item
//     resolutions, 5.5) and the recomputed tables; a hub-wide row the move
//     wrote may not name the channel, a UUID of the set or the <SRC> slug.
//     A snapshot holds every row, so it is for the tests and a rehearsal on
//     a quiet workspace, not for a busy prd one.
//
// Every function reads through a Querier the caller scopes: a transaction
// asOperator (the store's rls.go) sees every tenant; each statement on a
// tenant table names `tenant_id = @src` itself, but for the fleetWide proofs.
// Scan and the diff stay in <SRC> on the fleet tables too: 5.2 and C13 read
// <SRC>, the fleet rows keep their topic ids (5.1), and M11's old keys are
// what the fleetWide proofs count. The scan proves only that those exact
// strings are absent, not that nobody paraphrased the channel (5.2).

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Querier is what the proofs read with: a pgx.Tx scoped asOperator.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// ProofSet is what the proofs look for: the journal's frozen id lists
// (section 8.3), read from <DST> after the move, never from <SRC>.
type ProofSet struct {
	Src     string           // the <SRC> tenant slug
	Channel string           // the channel id
	Name    string           // the channel name
	Binds   pgx.NamedArgs    // the Binds lists by name; a missing one is empty
	Known   map[string]int64 // proof name -> rows kept: by the owner's word (5.6, 5.1a), or the fleet topic ids when <SRC> holds the fleet rows (5.2)
	Skip    []string         // tables the scan does not read (by design they hold the ids, e.g. the redirect table)
}

// Proof is one count. A proof holds when Count <= Known.
type Proof struct {
	Name  string `json:"name"`
	Count int64  `json:"count"`
	Known int64  `json:"known,omitempty"`
}

// OK says whether the proof holds.
func (p Proof) OK() bool { return p.Count <= p.Known }

// Failed returns the proofs that do not hold.
func Failed(ps []Proof) []Proof {
	var out []Proof
	for _, p := range ps {
		if !p.OK() {
			out = append(out, p)
		}
	}
	return out
}

var bindName = regexp.MustCompile(`@([a-z_]+)`)

// Typed casts every @bind of pred to its Binds type, so a predicate is
// planned with the types the catalogue states.
func Typed(pred string) string {
	return bindName.ReplaceAllStringFunc(pred, func(m string) string {
		if typ, ok := Binds[m[1:]]; ok {
			return m + "::" + typ
		}
		return m
	})
}

// args are the binds of every statement here: s.Binds, a missing list empty,
// plus src, channel and the scan's patterns.
func (s ProofSet) args() pgx.NamedArgs {
	a := pgx.NamedArgs{}
	for name, typ := range Binds {
		switch {
		case typ == "text":
			a[name] = ""
		case typ == "int[]":
			a[name] = []int32{}
		default:
			a[name] = []string{}
		}
	}
	for k, v := range s.Binds {
		a[k] = v
	}
	a["src"], a["channel"] = s.Src, s.Channel
	a["w_channel"], a["w_name"] = wordRx(s.Channel), wordRx(s.Name)
	a["uuid_rx"], a["uuids"], a["uuid_texts"] = uuidRx, s.uuids(), s.uuids()
	return a
}

// uuids are the set's task and msg ids, lower case.
func (s ProofSet) uuids() []string {
	var out []string
	for _, k := range []string{"tasks", "msgs"} {
		ids, _ := s.Binds[k].([]string)
		for _, id := range ids {
			out = append(out, strings.ToLower(id))
		}
	}
	return out
}

func (s ProofSet) proof(name string, n int64) Proof {
	return Proof{Name: name, Count: n, Known: s.Known[name]}
}

// fleetWide are the tables whose 5.1 proof has no <SRC> filter (M11): their
// rows live in the fleet's own workspace, not in <SRC>, unless <SRC> is it.
var fleetWide = map[string]bool{"fleet_lanes": true, "fleet_asks": true}

// proofSQL counts the rows of table that pred still finds.
func proofSQL(table, pred string) string {
	where := "tenant_id = @src AND (" + Typed(pred) + ")"
	if fleetWide[table] {
		where = Typed(pred)
	}
	return "SELECT count(*) FROM " + pgx.Identifier{table}.Sanitize() + " WHERE " + where
}

// SetProofs is section 5.1: one count per catalogue predicate.
func SetProofs(ctx context.Context, q Querier, s ProofSet) ([]Proof, error) {
	var out []Proof
	for _, e := range Catalogue {
		for _, pp := range proofPredicates(e) {
			n, err := countOne(ctx, q, proofSQL(e.Table, pp[1]), s.args())
			if err != nil {
				return nil, fmt.Errorf("proof %s %s: %w", e.Table, pp[0], err)
			}
			out = append(out, s.proof(e.Table+" "+pp[0], n))
		}
	}
	return out, nil
}

// proofPredicates are the {kind, predicate} pairs of one entry that must
// count 0 in <SRC> after a move.
func proofPredicates(e Entry) [][2]string {
	var out [][2]string
	if e.Set != "" && (e.Class == Moved || e.Class == Refuse) {
		out = append(out, [2]string{"set", e.Set})
	}
	if e.Refs != "" && (e.Class == Moved || e.Class == Rewritten) {
		refs := e.Refs
		if e.Set != "" {
			// coalesce: a Set over a NULL column (a DM's channel) is NULL, and
			// NOT NULL would drop the staying row the refs proof must count
			refs = "(" + e.Refs + ") AND NOT coalesce((" + e.Set + "), false)"
		}
		out = append(out, [2]string{"refs", refs})
	}
	return out
}

func countOne(ctx context.Context, q Querier, sql string, args pgx.NamedArgs) (int64, error) {
	rows, err := q.Query(ctx, sql, args)
	if err != nil {
		return 0, err
	}
	n, err := pgx.CollectExactlyOneRow(rows, pgx.RowTo[int64])
	return n, err
}

// ---- the free-text scan (5.2) ----------------------------------------------

// uuidRx finds a UUID inside free text; the scan compares each, lower case,
// with the set's ids.
const uuidRx = `([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})`

// wordRx matches word as a whole token: "ops" is found in "#ops" and
// "/c/ops", not in "topsoil" or "ops-team". "" matches nothing.
func wordRx(word string) string {
	if word == "" {
		return `.^` // never matches, in Go and in Postgres
	}
	return `(^|[^[:alnum:]_-])` + regexp.QuoteMeta(word) + `($|[^[:alnum:]_-])`
}

// tableInfo is one base table of the schema.
type tableInfo struct {
	name   string
	tenant bool     // has tenant_id: only <SRC> rows are read
	cols   []column // the columns the scan reads
	pk     []string // primary key columns, in key order
}

type column struct{ name, udt string }

// scanUDTs are the column types the scan reads (5.2).
var scanUDTs = map[string]bool{"text": true, "varchar": true, "bpchar": true, "json": true, "jsonb": true,
	"uuid": true, "_text": true, "_varchar": true, "_uuid": true}

const pgColumnsSQL = `SELECT c.table_name::text, c.column_name::text, c.udt_name::text
	FROM information_schema.columns c
	JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
	WHERE c.table_schema = current_schema() AND t.table_type = 'BASE TABLE'
	ORDER BY c.table_name, c.ordinal_position`

const pgPrimaryKeysSQL = `SELECT c.relname::text, a.attname::text
	FROM pg_index i
	JOIN pg_class c ON c.oid = i.indrelid
	JOIN pg_namespace n ON n.oid = c.relnamespace
	JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
	WHERE i.indisprimary AND n.nspname = current_schema()
	ORDER BY c.relname, array_position(i.indkey::int2[], a.attnum)`

// loadTables reads every base table, its scanned columns and its key.
func loadTables(ctx context.Context, q Querier) ([]tableInfo, error) {
	cols, err := pairs(ctx, q, pgColumnsSQL, 3)
	if err != nil {
		return nil, fmt.Errorf("read columns: %w", err)
	}
	byName := map[string]*tableInfo{}
	var order []string
	for _, c := range cols {
		tb := byName[c[0]]
		if tb == nil {
			tb = &tableInfo{name: c[0]}
			byName[c[0]] = tb
			order = append(order, c[0])
		}
		switch {
		case c[1] == "tenant_id":
			tb.tenant = true
		case scanUDTs[c[2]]:
			tb.cols = append(tb.cols, column{c[1], c[2]})
		}
	}
	keys, err := pairs(ctx, q, pgPrimaryKeysSQL, 2)
	if err != nil {
		return nil, fmt.Errorf("read primary keys: %w", err)
	}
	for _, k := range keys {
		if tb := byName[k[0]]; tb != nil {
			tb.pk = append(tb.pk, k[1])
		}
	}
	out := make([]tableInfo, len(order))
	for i, n := range order {
		out[i] = *byName[n]
	}
	return out, nil
}

// pairs reads rows of n text columns.
func pairs(ctx context.Context, q Querier, sql string, n int) ([][]string, error) {
	rows, err := q.Query(ctx, sql)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) ([]string, error) {
		out := make([]string, n)
		ptrs := make([]any, n)
		for i := range out {
			ptrs[i] = &out[i]
		}
		return out, r.Scan(ptrs...)
	})
}

// match is the scan predicate of one column.
func match(c column) string {
	col := pgx.Identifier{c.name}.Sanitize()
	switch c.udt {
	case "uuid":
		return col + " = ANY(@uuids::uuid[])"
	case "_uuid":
		return col + " && @uuids::uuid[]"
	case "_text", "_varchar":
		return textMatch("array_to_string(" + col + ", ' ')")
	case "json", "jsonb":
		return textMatch(col + "::text")
	}
	return textMatch(col)
}

func textMatch(expr string) string {
	return "(" + expr + " ~* @w_channel::text OR " + expr + " ~* @w_name::text OR EXISTS (SELECT 1 FROM regexp_matches(" +
		expr + ", @uuid_rx::text, 'gi') AS m(a) WHERE lower(m.a[1]) = ANY(@uuid_texts::text[])))"
}

// scanSQL counts every scanned column of tb in one pass over its rows.
func scanSQL(tb tableInfo) string {
	parts := make([]string, len(tb.cols))
	for i, c := range tb.cols {
		parts[i] = "count(*) FILTER (WHERE " + match(c) + ")"
	}
	sql := "SELECT " + strings.Join(parts, ", ") + " FROM " + pgx.Identifier{tb.name}.Sanitize()
	if tb.tenant {
		sql += " WHERE tenant_id = @src"
	}
	return sql
}

// Scan is the free-text scan (5.2): one proof "scan <table>.<column>" per
// column that holds a trace, and one "scan columns" with the number of
// columns read, so an empty answer cannot pass for a clean one.
func Scan(ctx context.Context, q Querier, s ProofSet) ([]Proof, error) {
	tables, err := loadTables(ctx, q)
	if err != nil {
		return nil, err
	}
	skip := map[string]bool{}
	for _, t := range s.Skip {
		skip[t] = true
	}
	var out []Proof
	read := 0
	for _, tb := range tables {
		if skip[tb.name] || len(tb.cols) == 0 {
			continue
		}
		counts, err := scanTable(ctx, q, tb, s.args())
		if err != nil {
			return nil, fmt.Errorf("scan %s: %w", tb.name, err)
		}
		read += len(counts)
		for i, n := range counts {
			if name := "scan " + tb.name + "." + tb.cols[i].name; n > 0 || s.Known[name] > 0 {
				out = append(out, s.proof(name, n))
			}
		}
	}
	if read == 0 {
		return nil, fmt.Errorf("scan: no column read")
	}
	return out, nil
}

func scanTable(ctx context.Context, q Querier, tb tableInfo, args pgx.NamedArgs) ([]int64, error) {
	rows, err := q.Query(ctx, scanSQL(tb), args)
	if err != nil {
		return nil, err
	}
	return pgx.CollectExactlyOneRow(rows, func(r pgx.CollectableRow) ([]int64, error) {
		out := make([]int64, len(tb.cols))
		ptrs := make([]any, len(out))
		for i := range out {
			ptrs[i] = &out[i]
		}
		return out, r.Scan(ptrs...)
	})
}

// ---- the <SRC> diff (C13) ----------------------------------------------------

// rewrites are the columns a move may change on a staying <SRC> row that its
// entry's Refs finds (C13, 5.1): M6b moved_from_*, M9 ref_task_id, the
// channel_order entry, the rewritten issue keys; "*" = the topic-head
// recompute, any column.
var rewrites = map[string][]string{
	"messages":           {"moved_from_channel", "moved_from_task", "moved_from_parent", "ref_task_id"},
	"tenant_memberships": {"channel_order"},
	"fleet_lanes":        {"issue_key"},
	"fleet_asks":         {"issue_key"},
	"topic_heads":        {"*"},
	"topic_head_parts":   {"*"},
}

// Rules widen the diff for one move: Extra[table] are columns the owner's
// shared-item resolutions (5.5) may change on a staying row of that table.
type Rules struct {
	Extra map[string][]string
}

// Snapshot is every <SRC> row of the tenant tables and every row of the
// hub-wide ones, by table and primary key.
type Snapshot map[string]snapTable

type snapTable struct {
	tenant bool
	rows   map[string]snapRow
}

type snapRow struct {
	json          string
	inSet, inRefs bool // the entry's Set / Refs found it when the snapshot was taken
}

// Change is one row the diff names.
type Change struct {
	Table string   `json:"table"`
	Key   string   `json:"key"`
	What  string   `json:"what"` // insert, delete, update
	Cols  []string `json:"cols,omitempty"`
	Why   string   `json:"why"`
}

// TakeSnapshot reads the snapshot; the catalogue predicates are evaluated
// on every row, so Diff knows which deletes and updates the move may make.
func TakeSnapshot(ctx context.Context, q Querier, s ProofSet) (Snapshot, error) {
	tables, err := loadTables(ctx, q)
	if err != nil {
		return nil, err
	}
	snap := Snapshot{}
	for _, tb := range tables {
		rows, err := snapRows(ctx, q, tb, s.args())
		if err != nil {
			return nil, fmt.Errorf("snapshot %s: %w", tb.name, err)
		}
		snap[tb.name] = snapTable{tenant: tb.tenant, rows: rows}
	}
	return snap, nil
}

// snapSQL reads key, row and the two predicates of each row of tb.
func snapSQL(tb tableInfo) string {
	key := "to_jsonb(t)::text"
	if len(tb.pk) > 0 {
		cols := make([]string, len(tb.pk))
		for i, c := range tb.pk {
			cols[i] = "t." + pgx.Identifier{c}.Sanitize()
		}
		key = "jsonb_build_array(" + strings.Join(cols, ", ") + ")::text"
	}
	set, refs := "false", "false"
	if e, ok := Lookup(tb.name); ok && tb.tenant {
		if e.Set != "" {
			set = Typed(e.Set)
		}
		if e.Refs != "" {
			refs = Typed(e.Refs)
		}
	}
	sql := "SELECT " + key + ", to_jsonb(t)::text, coalesce((" + set + "), false), coalesce((" + refs + "), false) FROM " +
		pgx.Identifier{tb.name}.Sanitize() + " t"
	if tb.tenant {
		sql += " WHERE tenant_id = @src"
	}
	return sql
}

func snapRows(ctx context.Context, q Querier, tb tableInfo, args pgx.NamedArgs) (map[string]snapRow, error) {
	rows, err := q.Query(ctx, snapSQL(tb), args)
	if err != nil {
		return nil, err
	}
	out := map[string]snapRow{}
	var key string
	var r snapRow
	_, err = pgx.ForEachRow(rows, []any{&key, &r.json, &r.inSet, &r.inRefs}, func() error {
		out[key] = r
		return nil
	})
	return out, err
}

// Diff names every change from before to after the move may not make.
func Diff(before, after Snapshot, s ProofSet, rules Rules) []Change {
	d := differ{s: s, rules: rules, words: wordMatchers(s)}
	var out []Change
	for _, table := range tableNames(before, after) {
		e, _ := Lookup(table)
		b, a := before[table], after[table]
		if e.Class == Recomputed && (b.tenant || a.tenant) {
			continue
		}
		hub := !b.tenant && !a.tenant
		for _, k := range sortedKeys(b.rows) {
			out = append(out, d.row(table, k, b.rows[k], a.rows, e, hub)...)
		}
		for _, k := range sortedKeys(a.rows) {
			if _, ok := b.rows[k]; !ok {
				out = append(out, d.insert(table, k, a.rows[k], hub)...)
			}
		}
	}
	return out
}

type differ struct {
	s     ProofSet
	rules Rules
	words []wordMatcher
}

type wordMatcher struct {
	label string
	rx    *regexp.Regexp
}

func wordMatchers(s ProofSet) []wordMatcher {
	var out []wordMatcher
	for _, w := range []struct{ label, word string }{{"the channel id", s.Channel}, {"the channel name", s.Name}, {"the <SRC> slug", s.Src}} {
		if w.word != "" {
			out = append(out, wordMatcher{w.label, regexp.MustCompile(`(?i)` + wordRx(w.word))})
		}
	}
	return out
}

// row judges one row that existed before.
func (d differ) row(table, k string, br snapRow, after map[string]snapRow, e Entry, hub bool) []Change {
	ar, ok := after[k]
	switch {
	case !ok && (hub || deleteAllowed(e, br)):
		return nil
	case !ok:
		return []Change{{Table: table, Key: k, What: "delete", Why: "not a row of the set"}}
	case ar.json == br.json:
		return nil
	case hub:
		return d.hubRow(table, k, "update", ar)
	}
	cols := changedCols(br.json, ar.json)
	if br.inRefs && allowed(cols, append(append([]string(nil), rewrites[table]...), d.rules.Extra[table]...)) {
		return nil
	}
	why := "a staying row no rewrite may change"
	if br.inRefs {
		why = "a column no rewrite names"
	}
	return []Change{{Table: table, Key: k, What: "update", Cols: cols, Why: why}}
}

func deleteAllowed(e Entry, r snapRow) bool {
	switch e.Class {
	case Moved:
		return r.inSet
	case Rewritten:
		return r.inRefs
	}
	return false
}

func (d differ) insert(table, k string, r snapRow, hub bool) []Change {
	if hub {
		return d.hubRow(table, k, "insert", r)
	}
	return []Change{{Table: table, Key: k, What: "insert", Why: "the move writes no <SRC> row"}}
}

// hubRow: a hub-wide row the move wrote may not name the channel, a UUID of
// the set or the <SRC> slug (C13).
func (d differ) hubRow(table, k, what string, r snapRow) []Change {
	if why := d.names(r.json); why != "" {
		return []Change{{Table: table, Key: k, What: what, Why: "a hub-wide row names " + why}}
	}
	return nil
}

// names says what of the set text names, "" if nothing.
func (d differ) names(text string) string {
	for _, w := range d.words {
		if w.rx.MatchString(text) {
			return w.label
		}
	}
	low := strings.ToLower(text)
	for _, id := range d.s.uuids() {
		if strings.Contains(low, id) {
			return "the set's id " + id
		}
	}
	return ""
}

func allowed(cols, ok []string) bool {
	for _, c := range cols {
		found := false
		for _, o := range ok {
			found = found || o == "*" || o == c
		}
		if !found {
			return false
		}
	}
	return true
}

// changedCols are the top-level keys whose values differ between two rows.
func changedCols(a, b string) []string {
	var ma, mb map[string]json.RawMessage
	if json.Unmarshal([]byte(a), &ma) != nil || json.Unmarshal([]byte(b), &mb) != nil {
		return []string{"?"}
	}
	var out []string
	for k, v := range mb {
		if string(ma[k]) != string(v) {
			out = append(out, k)
		}
	}
	for k := range ma {
		if _, ok := mb[k]; !ok {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func tableNames(a, b Snapshot) []string {
	seen := map[string]bool{}
	for t := range a {
		seen[t] = true
	}
	for t := range b {
		seen[t] = true
	}
	return sortedKeys(seen)
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
