// SPDX-License-Identifier: AGPL-3.0-only

package channelmove

import (
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 169 T8: the proofs of step P7 (section 5.1), the free-text scan (5.2,
// case C14) and the <SRC> diff (case C13). The Postgres cases run when
// $SPOOL_TEST_PG_DSN names a database (hub-pg.tst.sh); the rest run in plain
// `go test` on a fake Querier.

// ---- plain: the pieces -------------------------------------------------------

func TestWordRxMatchesWholeTokens(t *testing.T) {
	rx := regexp.MustCompile(wordRx("ops"))
	for text, want := range map[string]bool{"ops": true, "see #ops now": true, "/c/ops": true, "(ops)": true,
		"topsoil": false, "ops-team": false, "dev_ops": false, "OPS2": false} {
		if got := rx.MatchString(text); got != want {
			t.Errorf("wordRx(ops) on %q = %v, want %v", text, got, want)
		}
	}
	if regexp.MustCompile(wordRx("")).MatchString("") {
		t.Error(`wordRx("") matched the empty text; it must match nothing`)
	}
	if !regexp.MustCompile(wordRx("a.b")).MatchString("x a.b y") || regexp.MustCompile(wordRx("a.b")).MatchString("axb") {
		t.Error("wordRx does not quote the word's regexp characters")
	}
}

func TestProofPredicatesFollowTheClass(t *testing.T) {
	kinds := func(table string) string {
		e, ok := Lookup(table)
		if !ok {
			t.Fatalf("%s not in the catalogue", table)
		}
		var out []string
		for _, p := range proofPredicates(e) {
			out = append(out, p[0])
		}
		return strings.Join(out, ",")
	}
	for table, want := range map[string]string{"messages": "set,refs", "channels": "set", "tenant_memberships": "refs",
		"embed_visitors": "set", "message_period_counts": "", "tenants": ""} {
		if got := kinds(table); got != want {
			t.Errorf("%s proofs = %q, want %q", table, got, want)
		}
	}
	m, _ := Lookup("messages")
	if refs := proofPredicates(m)[1][1]; !strings.Contains(refs, "AND NOT coalesce((") {
		t.Errorf("messages refs proof must exclude the set's own rows: %s", refs)
	}
}

func TestMatchReadsEveryColumnType(t *testing.T) {
	for udt, want := range map[string]string{"uuid": `"c" = ANY(@uuids::uuid[])`, "_uuid": `"c" && @uuids::uuid[]`,
		"_text": `array_to_string("c", ' ')`, "jsonb": `"c"::text ~*`, "text": `"c" ~* @w_channel`} {
		if got := match(column{"c", udt}); !strings.Contains(got, want) {
			t.Errorf("match(%s) = %s, want it to contain %s", udt, got, want)
		}
	}
	sql := scanSQL(tableInfo{name: "hub_t", cols: []column{{"a", "text"}}})
	if strings.Contains(sql, "tenant_id") {
		t.Errorf("a hub-wide table is read whole: %s", sql)
	}
	if sql := scanSQL(tableInfo{name: "t", tenant: true, cols: []column{{"a", "text"}}}); !strings.HasSuffix(sql, "WHERE tenant_id = @src") {
		t.Errorf("a tenant table is read in <SRC> only: %s", sql)
	}
}

func TestTypedCastsEveryBind(t *testing.T) {
	if got := Typed(`a = @channel OR b = ANY(@tasks) OR c = @other`); got != `a = @channel::text OR b = ANY(@tasks::uuid[]) OR c = @other` {
		t.Errorf("Typed = %s", got)
	}
}

func TestArgsFillMissingBinds(t *testing.T) {
	a := ProofSet{Src: "s", Channel: "c", Binds: pgx.NamedArgs{"tasks": []string{"AA"}}}.args()
	for name := range Binds {
		if _, ok := a[name]; !ok {
			t.Errorf("bind %s missing", name)
		}
	}
	if a["src"] != "s" || a["channel"] != "c" || fmt.Sprint(a["uuids"]) != "[aa]" || fmt.Sprint(a["numbers"]) != "[]" {
		t.Errorf("args = %v", a)
	}
}

func TestFailedListsOnlyBrokenProofs(t *testing.T) {
	got := Failed([]Proof{{Name: "a"}, {Name: "b", Count: 2, Known: 2}, {Name: "c", Count: 1}})
	if len(got) != 1 || got[0].Name != "c" {
		t.Errorf("Failed = %v", got)
	}
}

// ---- plain: the diff (C13) ---------------------------------------------------

const keyA, keyB = `["k1"]`, `["k2"]`

func tenantSnap(rows map[string]snapRow) snapTable { return snapTable{tenant: true, rows: rows} }

func diffWhy(cs []Change) string {
	var out []string
	for _, c := range cs {
		out = append(out, c.Table+" "+c.What+" "+strings.Join(c.Cols, "+")+": "+c.Why)
	}
	return strings.Join(out, "; ")
}

func TestDiffAllowsOnlyTheMovesOwnWrites(t *testing.T) {
	s := ProofSet{Src: "t-src", Channel: "c-move", Name: "Move Me",
		Binds: pgx.NamedArgs{"tasks": []string{"11111111-1111-4111-8111-111111111111"}}}
	before := Snapshot{
		"channels":           tenantSnap(map[string]snapRow{keyA: {json: `{"x":1}`, inSet: true}, keyB: {json: `{"x":2}`}}),
		"messages":           tenantSnap(map[string]snapRow{keyA: {json: `{"moved_from_task":"1","body":"b"}`, inRefs: true}}),
		"channel_box_pins":   tenantSnap(map[string]snapRow{keyA: {json: `{}`, inRefs: true}}),
		"quota_counts":       tenantSnap(map[string]snapRow{keyA: {json: `{"n":1}`}}),
		"topic_heads":        tenantSnap(map[string]snapRow{keyA: {json: `{"a":1,"b":1}`, inRefs: true}}),
		"system_events":      {rows: map[string]snapRow{keyA: {json: `{"m":"c-move created"}`}}},
		"tenant_memberships": tenantSnap(map[string]snapRow{keyA: {json: `{"channel_order":["c-move"],"role":"admin"}`, inRefs: true}}),
	}
	after := Snapshot{
		"channels":           tenantSnap(map[string]snapRow{keyB: {json: `{"x":2}`}}),
		"messages":           tenantSnap(map[string]snapRow{keyA: {json: `{"moved_from_task":null,"body":"b"}`}}),
		"channel_box_pins":   tenantSnap(map[string]snapRow{}),
		"quota_counts":       tenantSnap(map[string]snapRow{keyA: {json: `{"n":0}`}, keyB: {json: `{}`}}),
		"topic_heads":        tenantSnap(map[string]snapRow{keyA: {json: `{"a":2,"b":2}`}}),
		"system_events":      {rows: map[string]snapRow{keyB: {json: `{"m":"move m-1 done"}`}}},
		"tenant_memberships": tenantSnap(map[string]snapRow{keyA: {json: `{"channel_order":[],"role":"admin"}`}}),
	}
	if cs := Diff(before, after, s, Rules{}); len(cs) != 0 {
		t.Fatalf("the move's own writes were named: %s", diffWhy(cs))
	}
	for _, c := range []struct {
		name  string
		table string
		row   snapRow
		key   string
		want  string
		rules Rules
	}{
		{"a <SRC> audit row", "operator_audit", snapRow{json: `{"detail":"c-move"}`}, keyA, "operator_audit insert : the move writes no <SRC> row", Rules{}},
		{"an extra UPDATE of a staying row", "channels", snapRow{json: `{"x":3}`}, keyB, "channels update x: a staying row no rewrite may change", Rules{}},
		{"a column no rewrite names", "messages", snapRow{json: `{"moved_from_task":null,"body":"edited"}`}, keyA, "messages update body+moved_from_task: a column no rewrite names", Rules{}},
		{"a hub row naming the channel", "system_events", snapRow{json: `{"m":"moved #c-move"}`}, keyB, "system_events insert : a hub-wide row names the channel id", Rules{}},
		{"a hub row naming the slug", "system_events", snapRow{json: `{"m":"from T-SRC"}`}, keyB, "a hub-wide row names the <SRC> slug", Rules{}},
		{"a hub row naming a task", "system_events", snapRow{json: `{"m":"11111111-1111-4111-8111-111111111111"}`}, keyB, "names the set's id", Rules{}},
		{"a hub row naming the name", "system_events", snapRow{json: `{"m":"move me"}`}, keyB, "names the channel name", Rules{}},
	} {
		t.Run(c.name, func(t *testing.T) {
			a := copySnap(after)
			tb := a[c.table]
			if tb.rows == nil {
				tb = tenantSnap(map[string]snapRow{})
			}
			tb.rows[c.key] = c.row
			a[c.table] = tb
			if got := diffWhy(Diff(before, a, s, c.rules)); !strings.Contains(got, c.want) {
				t.Errorf("RED CONTROL: diff = %q, want it to name %q", got, c.want)
			}
		})
	}
	// a delete outside the set is named; Rules.Extra allows a resolution
	a := copySnap(after)
	a["channels"] = tenantSnap(map[string]snapRow{})
	if got := diffWhy(Diff(before, a, s, Rules{})); !strings.Contains(got, "channels delete : not a row of the set") {
		t.Errorf("RED CONTROL: a delete of a staying channel was not named: %q", got)
	}
	a = copySnap(after)
	a["messages"].rows[keyA] = snapRow{json: `{"moved_from_task":null,"body":"resolved"}`}
	if cs := Diff(before, a, s, Rules{Extra: map[string][]string{"messages": {"body"}}}); len(cs) != 0 {
		t.Errorf("Rules.Extra did not allow the resolution: %s", diffWhy(cs))
	}
}

// <SRC> is the fleet's own workspace: M11's rewrite is a named <SRC> write.
func TestDiffFleetRewriteInSrc(t *testing.T) {
	before := Snapshot{"fleet_lanes": tenantSnap(map[string]snapRow{keyA: {json: `{"issue_key":"OLD-1","scope":"a"}`, inRefs: true}})}
	after := Snapshot{"fleet_lanes": tenantSnap(map[string]snapRow{keyA: {json: `{"issue_key":"NEW-1","scope":"a"}`}})}
	if cs := Diff(before, after, ProofSet{Src: "s"}, Rules{}); len(cs) != 0 {
		t.Errorf("the key rewrite was named: %s", diffWhy(cs))
	}
	after["fleet_lanes"].rows[keyA] = snapRow{json: `{"issue_key":"NEW-1","scope":"b"}`}
	if got := diffWhy(Diff(before, after, ProofSet{Src: "s"}, Rules{})); !strings.Contains(got, "a column no rewrite names") {
		t.Errorf("RED CONTROL: an edit of the lane's scope was not named: %q", got)
	}
}

func copySnap(s Snapshot) Snapshot {
	out := Snapshot{}
	for t, tb := range s {
		rows := map[string]snapRow{}
		for k, r := range tb.rows {
			rows[k] = r
		}
		out[t] = snapTable{tenant: tb.tenant, rows: rows}
	}
	return out
}

func TestChangedCols(t *testing.T) {
	if got := changedCols(`{"a":1,"b":2,"c":3}`, `{"a":1,"b":3,"d":4}`); strings.Join(got, ",") != "b,c,d" {
		t.Errorf("changedCols = %v", got)
	}
	if got := changedCols(`not json`, `{}`); len(got) != 1 || got[0] != "?" {
		t.Errorf("changedCols on bad json = %v", got)
	}
}

// ---- plain: the loops on a fake Querier -------------------------------------

type fakeRows struct {
	rows [][]any
	i    int
	err  error
}

func (r *fakeRows) Close()                                       {}
func (r *fakeRows) Err() error                                   { return r.err }
func (r *fakeRows) CommandTag() pgconn.CommandTag                { return pgconn.CommandTag{} }
func (r *fakeRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *fakeRows) Next() bool                                   { r.i++; return r.i <= len(r.rows) }
func (r *fakeRows) Values() ([]any, error)                       { return r.rows[r.i-1], nil }
func (r *fakeRows) RawValues() [][]byte                          { return nil }
func (r *fakeRows) Conn() *pgx.Conn                              { return nil }
func (r *fakeRows) Scan(dest ...any) error {
	row := r.rows[r.i-1]
	if len(dest) != len(row) {
		return fmt.Errorf("fake: scan %d into %d", len(row), len(dest))
	}
	for i, d := range dest {
		switch p := d.(type) {
		case *string:
			*p = row[i].(string)
		case *int64:
			*p = row[i].(int64)
		case *bool:
			*p = row[i].(bool)
		default:
			return fmt.Errorf("fake: scan into %T", d)
		}
	}
	return nil
}

// fakeDB answers the catalogue reads with a two-table schema: tenant table
// "messages" and hub-wide table "system_events".
type fakeDB struct {
	sqls []string
	fail string // a statement containing this fails
	// fleetRows are old issue keys in the fleet's own workspace, not in <SRC>:
	// a count of fleet_lanes or fleet_asks finds them only with no tenant filter.
	fleetRows int64
}

func (f *fakeDB) Query(_ context.Context, sql string, _ ...any) (pgx.Rows, error) {
	f.sqls = append(f.sqls, sql)
	if f.fail != "" && strings.Contains(sql, f.fail) {
		return nil, errors.New("fake: refused")
	}
	switch {
	case sql == pgColumnsSQL:
		return &fakeRows{rows: [][]any{{"messages", "tenant_id", "text"}, {"messages", "body", "text"},
			{"messages", "moved_from_task", "uuid"}, {"messages", "ts", "timestamptz"}, {"system_events", "message", "text"}}}, nil
	case sql == pgPrimaryKeysSQL:
		return &fakeRows{rows: [][]any{{"messages", "tenant_id"}, {"messages", "msg_id"}, {"gone", "x"}}}, nil
	case strings.HasPrefix(sql, "SELECT count(*) FROM"):
		n := int64(0)
		if (strings.Contains(sql, `"fleet_lanes"`) || strings.Contains(sql, `"fleet_asks"`)) && !strings.Contains(sql, "tenant_id") {
			n = f.fleetRows
		}
		return &fakeRows{rows: [][]any{{n}}}, nil
	case strings.HasPrefix(sql, "SELECT count(*) FILTER") && strings.Contains(sql, `"moved_from_task"`):
		return &fakeRows{rows: [][]any{{int64(0), int64(1)}}}, nil
	case strings.HasPrefix(sql, "SELECT count(*) FILTER"):
		return &fakeRows{rows: [][]any{{int64(0)}}}, nil
	case strings.HasPrefix(sql, "SELECT jsonb_build_array"), strings.HasPrefix(sql, "SELECT to_jsonb"):
		return &fakeRows{rows: [][]any{{keyA, `{"a":1}`, true, false}}}, nil
	}
	return nil, fmt.Errorf("fake: unexpected %s", sql)
}

func TestSetProofsCountEveryPredicate(t *testing.T) {
	db := &fakeDB{}
	ps, err := SetProofs(context.Background(), db, ProofSet{Src: "s", Known: map[string]int64{"channels set": 1}})
	if err != nil {
		t.Fatal(err)
	}
	want := 0
	for _, e := range Catalogue {
		want += len(proofPredicates(e))
	}
	if len(ps) != want || len(db.sqls) != want || len(Failed(ps)) != 0 {
		t.Fatalf("%d proofs, %d statements, want %d each; failed %v", len(ps), len(db.sqls), want, Failed(ps))
	}
	for _, p := range ps {
		if p.Name == "channels set" && p.Known != 1 {
			t.Errorf("Known not carried: %+v", p)
		}
	}
	if _, err := SetProofs(context.Background(), &fakeDB{fail: `"messages"`}, ProofSet{Src: "s"}); err == nil || !strings.Contains(err.Error(), "proof messages set") {
		t.Errorf("a failed count must name its proof, got %v", err)
	}
}

// M11's rows live in the fleet's own workspace (5.1): their proof must see
// them from any <SRC>, and no other proof may leave <SRC>.
func TestSetProofsFleetRowsOutsideSrc(t *testing.T) {
	db := &fakeDB{fleetRows: 3}
	ps, err := SetProofs(context.Background(), db, ProofSet{Src: "s"})
	if err != nil {
		t.Fatal(err)
	}
	if got := proofNames(ps); got != "fleet_lanes refs=3 fleet_asks refs=3" {
		t.Errorf("RED CONTROL: old keys in the fleet's workspace must fail the proof, got %q", got)
	}
	for _, sql := range db.sqls {
		fleet := strings.Contains(sql, `"fleet_lanes"`) || strings.Contains(sql, `"fleet_asks"`)
		if has := strings.Contains(sql, "tenant_id = @src"); has == fleet {
			t.Errorf("fleet table %v, <SRC> filter %v: %s", fleet, has, sql)
		}
	}
}

func TestScanReportsTracesAndColumnsRead(t *testing.T) {
	db := &fakeDB{}
	ps, err := Scan(context.Background(), db, ProofSet{Src: "s", Known: map[string]int64{"scan system_events.message": 2}})
	if err != nil {
		t.Fatal(err)
	}
	got := fmt.Sprint(ps)
	if got != "[{scan messages.moved_from_task 1 0} {scan system_events.message 0 2}]" {
		t.Errorf("Scan = %s", got)
	}
	if _, err := Scan(context.Background(), &fakeDB{}, ProofSet{Skip: []string{"messages", "system_events"}}); err == nil {
		t.Error("RED CONTROL: a scan that read no column passed for a clean one")
	}
	for _, fail := range []string{"information_schema", "pg_index", "FILTER"} {
		if _, err := Scan(context.Background(), &fakeDB{fail: fail}, ProofSet{}); err == nil {
			t.Errorf("a failed %s read was not returned", fail)
		}
	}
}

func TestTakeSnapshotReadsEveryTable(t *testing.T) {
	snap, err := TakeSnapshot(context.Background(), &fakeDB{}, ProofSet{Src: "s"})
	if err != nil {
		t.Fatal(err)
	}
	if !snap["messages"].tenant || snap["system_events"].tenant || !snap["messages"].rows[keyA].inSet {
		t.Errorf("snapshot = %+v", snap)
	}
	if _, err := TakeSnapshot(context.Background(), &fakeDB{fail: "to_jsonb"}, ProofSet{}); err == nil {
		t.Error("a failed snapshot read was not returned")
	}
	if _, err := TakeSnapshot(context.Background(), &fakeDB{fail: "information_schema"}, ProofSet{}); err == nil {
		t.Error("a failed schema read was not returned")
	}
	sql := snapSQL(tableInfo{name: "messages", tenant: true, pk: []string{"tenant_id", "msg_id"}})
	if !strings.Contains(sql, `jsonb_build_array(t."tenant_id", t."msg_id")`) || !strings.Contains(sql, "@tasks::uuid[]") {
		t.Errorf("snapSQL = %s", sql)
	}
}

// ---- Postgres: C13 and C14 ---------------------------------------------------

const (
	pfSrc, pfDst    = "t-src-169", "t-dst-169"
	pfFleet         = "t-fleet-169"
	pfOldKey        = "OLD-169"
	pfNewKey        = "NEW-169"
	pfMove, pfStay  = "c-move-169", "c-stay-169"
	pfName          = "Move Room 169"
	pfTask, pfReply = "16900000-0000-4000-8000-000000000001", "16900000-0000-4000-8000-000000000002"
	pfMsg1, pfMsg2  = "16900000-0000-4000-8000-0000000000a1", "16900000-0000-4000-8000-0000000000a2"
	pfStayTask      = "16900000-0000-4000-8000-0000000000b0"
	pfStayMsg       = "16900000-0000-4000-8000-0000000000b1"
	pfDMTask        = "16900000-0000-4000-8000-0000000000c0"
	pfDMMsg         = "16900000-0000-4000-8000-0000000000c1"
)

// pgTx opens one operator-scoped transaction on the test database; the test
// rolls it back, so nothing it seeds outlives it.
func pgTx(t *testing.T) (context.Context, pgx.Tx) {
	t.Helper()
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
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(ctx) })
	mustExec(t, ctx, tx, `SELECT set_config('app.rls_scope', 'operator', true)`)
	return ctx, tx
}

func mustExec(t *testing.T, ctx context.Context, tx pgx.Tx, sql string, args ...any) {
	t.Helper()
	if _, err := tx.Exec(ctx, sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

const pfMsgSQL = `INSERT INTO messages (tenant_id, msg_id, task_id, parent_task_id, channel, ts, from_box, from_id, to_box, to_id,
	kind, body, msg, env_sig, env, expires_at, moved_from_channel, moved_from_task, ref_task_id)
	VALUES ($1, $2, $3, $4, $5, now(), 'box-1', 'HUM-169', 'box-1', 'HUM-169', 'msg', $6, '{}', 'sig', '\x00',
	now() + interval '1 day', $7, $8, $9)`

// seedSource writes a <SRC> with the channel to move (a topic and a reply),
// a staying channel whose post spec 045 moved out of the channel (M6b), a DM
// about the moved topic (M9), a member whose channel_order names it, an
// event about the set, a <DST>, and a fleet workspace whose lane and ask name
// the moved topic and its old issue key (M11).
func seedSource(t *testing.T, ctx context.Context, tx pgx.Tx) {
	t.Helper()
	for _, ten := range []string{pfSrc, pfDst, pfFleet} {
		mustExec(t, ctx, tx, `INSERT INTO tenants (tenant_id, root_pubkey) VALUES ($1, $2)`, ten, make([]byte, 32))
	}
	mustExec(t, ctx, tx, `INSERT INTO humans (human_id) VALUES ('HUM-169')`)
	mustExec(t, ctx, tx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by, channel_order)
		VALUES ($1, 'HUM-169', 'admin', 'HUM-169', ARRAY[$2, $3])`, pfSrc, pfStay, pfMove)
	for id, name := range map[string]string{pfMove: pfName, pfStay: "Stay Room"} {
		mustExec(t, ctx, tx, `INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ($1, $2, $3, 'HUM-169')`, pfSrc, id, name)
	}
	null := (*string)(nil)
	stay := pfMove
	task := pfTask
	mustExec(t, ctx, tx, pfMsgSQL, pfSrc, pfMsg1, pfTask, null, pfMove, "the topic", null, null, null)
	mustExec(t, ctx, tx, pfMsgSQL, pfSrc, pfMsg2, pfReply, pfTask, pfMove, "a reply", null, null, null)
	mustExec(t, ctx, tx, pfMsgSQL, pfSrc, pfStayMsg, pfStayTask, null, pfStay, "moved out earlier", &stay, &task, null)
	mustExec(t, ctx, tx, pfMsgSQL, pfSrc, pfDMMsg, pfDMTask, null, null, "a DM about it", null, null, &task)
	mustExec(t, ctx, tx, `INSERT INTO workspace_events (tenant_id, kind, message, origin_kind, origin_ref)
		VALUES ($1, 'topic.created', 'opened', 'topic', $2)`, pfSrc, pfTask)
	mustExec(t, ctx, tx, `INSERT INTO workspace_events (tenant_id, kind, message) VALUES ($1, 'tenant.note', 'a staying event')`, pfSrc)
	mustExec(t, ctx, tx, `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, state, writer_box, topic, issue_key)
		VALUES ($1, 'fleet-169', 'c-169', 'box-1', 'live', 'box-1', $2, $3)`, pfFleet, pfTask, pfOldKey)
	mustExec(t, ctx, tx, `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, state, writer_box, topic, issue_key)
		VALUES ($1, 'fleet-169', $2, 'spawn', 'c-169', 'open', 'box-1', $3, $4)`, pfFleet, pfStayTask, pfTask, pfOldKey)
}

// runMove does the <SRC> half of a move with only the writes C13 allows:
// the set deleted, M6b and M9 nulled, the channel_order entry removed; the
// move's audit row goes to <DST>. M11 rewrites the keys in the fleet's own
// workspace, which is not a <SRC> write.
func runMove(t *testing.T, ctx context.Context, tx pgx.Tx) {
	t.Helper()
	mustExec(t, ctx, tx, `DELETE FROM messages WHERE tenant_id = $1 AND (channel = $2 OR task_id = $3 OR parent_task_id = $3)`, pfSrc, pfMove, pfTask)
	mustExec(t, ctx, tx, `DELETE FROM workspace_events WHERE tenant_id = $1 AND origin_ref = $2`, pfSrc, pfTask)
	mustExec(t, ctx, tx, `DELETE FROM channels WHERE tenant_id = $1 AND channel_id = $2`, pfSrc, pfMove)
	mustExec(t, ctx, tx, `UPDATE messages SET moved_from_channel = NULL, moved_from_task = NULL WHERE tenant_id = $1 AND msg_id = $2`, pfSrc, pfStayMsg)
	mustExec(t, ctx, tx, `UPDATE messages SET ref_task_id = NULL WHERE tenant_id = $1 AND msg_id = $2`, pfSrc, pfDMMsg)
	mustExec(t, ctx, tx, `UPDATE tenant_memberships SET channel_order = array_remove(channel_order, $2) WHERE tenant_id = $1`, pfSrc, pfMove)
	mustExec(t, ctx, tx, `INSERT INTO operator_audit (at, tenant_id, actor_tenant, actor_hum, action, detail)
		VALUES (now(), $1, $1, 'HUM-169', 'update', '{"move_id": "m-169"}')`, pfDst)
	for _, table := range []string{"fleet_lanes", "fleet_asks"} {
		mustExec(t, ctx, tx, `UPDATE `+table+` SET issue_key = $1 WHERE issue_key = $2`, pfNewKey, pfOldKey)
	}
}

func pfSet() ProofSet {
	ids := []string{pfMove, pfTask, pfReply, pfMsg1, pfMsg2}
	likes := make([]string, len(ids))
	for i, id := range ids {
		likes[i] = "%" + id + "%"
	}
	return ProofSet{Src: pfSrc, Channel: pfMove, Name: pfName, Binds: pgx.NamedArgs{
		"tasks": []string{pfTask, pfReply}, "msgs": []string{pfMsg1, pfMsg2},
		"mark_keys": []string{"ch:" + pfMove, "t:" + pfTask, "t:" + pfReply}, "ids": ids, "id_likes": likes,
		"issue_keys": []string{pfOldKey}}}
}

func proofNames(ps []Proof) string {
	var out []string
	for _, p := range Failed(ps) {
		out = append(out, fmt.Sprintf("%s=%d", p.Name, p.Count))
	}
	return strings.Join(out, " ")
}

// TestC14FreeTextScanPostgres: after the move the scan and the 5.1 proofs
// print 0; before it, and with each plant, they do not.
func TestC14FreeTextScanPostgres(t *testing.T) {
	ctx, tx := pgTx(t)
	seedSource(t, ctx, tx)
	s := pfSet()
	before, err := Scan(ctx, tx, s)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"scan channels.channel_id=1", "scan channels.name=1", "scan messages.task_id=2",
		"scan messages.moved_from_task=1", "scan messages.ref_task_id=1", "scan workspace_events.origin_ref=1"} {
		if !strings.Contains(proofNames(before), want) {
			t.Errorf("CONTROL: before the move the scan must find %s; got %s", want, proofNames(before))
		}
	}
	setBefore, err := SetProofs(ctx, tx, s)
	if err != nil {
		t.Fatal(err)
	}
	if got := proofNames(setBefore); !strings.Contains(got, "messages set=2 ") || !strings.Contains(got, "messages refs=2") ||
		!strings.Contains(got, "tenant_memberships refs=1") || !strings.Contains(got, "fleet_lanes refs=1") || !strings.Contains(got, "fleet_asks refs=1") {
		t.Errorf("CONTROL: before the move the 5.1 proofs must count the set; got %s", got)
	}
	runMove(t, ctx, tx)
	if got := scanFailures(t, ctx, tx, s); got != "" {
		t.Fatalf("after the move the scan must print 0, got %s", got)
	}
	after, err := SetProofs(ctx, tx, s)
	if err != nil {
		t.Fatal(err)
	}
	if got := proofNames(after); got != "" {
		t.Fatalf("after the move every 5.1 proof must print 0, got %s", got)
	}
	// RED CONTROL, M11: an old key left in the fleet's workspace, <SRC> being
	// another workspace, fails its proof
	for _, table := range []string{"fleet_lanes", "fleet_asks"} {
		t.Run("an old issue key left in "+table, func(t *testing.T) {
			mustExec(t, ctx, tx, `SAVEPOINT plant`)
			defer mustExec(t, ctx, tx, `ROLLBACK TO SAVEPOINT plant`)
			mustExec(t, ctx, tx, `UPDATE `+table+` SET issue_key = '`+pfOldKey+`' WHERE tenant_id = '`+pfFleet+`'`)
			ps, err := SetProofs(ctx, tx, s)
			if err != nil {
				t.Fatal(err)
			}
			if got, want := proofNames(ps), table+" refs=1"; got != want {
				t.Errorf("RED CONTROL: proofs = %q, want %q", got, want)
			}
		})
	}
	plants := []struct{ name, sql, want string }{
		{"the channel id in a staying event", `UPDATE workspace_events SET message = 'see #` + pfMove + `' WHERE tenant_id = '` + pfSrc + `'`, "scan workspace_events.message=1"},
		{"a moved task id in a staying post's uuid column", `UPDATE messages SET moved_from_task = '` + pfTask + `' WHERE tenant_id = '` + pfSrc + `' AND msg_id = '` + pfStayMsg + `'`, "scan messages.moved_from_task=1"},
		{"a msg id quoted upper case in a post", `UPDATE messages SET body = 'ref ` + strings.ToUpper(pfMsg2) + `' WHERE tenant_id = '` + pfSrc + `' AND msg_id = '` + pfDMMsg + `'`, "scan messages.body=1"},
		{"the channel name in jsonb", `UPDATE messages SET msg = '{"title": "` + strings.ToLower(pfName) + `"}' WHERE tenant_id = '` + pfSrc + `' AND msg_id = '` + pfDMMsg + `'`, "scan messages.msg=1"},
		{"a moved task id in a hub-wide event", `INSERT INTO system_events (kind, message) VALUES ('hub.note', '` + pfTask + `')`, "scan system_events.message=1"},
	}
	for _, p := range plants {
		t.Run(p.name, func(t *testing.T) {
			mustExec(t, ctx, tx, `SAVEPOINT plant`)
			defer mustExec(t, ctx, tx, `ROLLBACK TO SAVEPOINT plant`)
			mustExec(t, ctx, tx, p.sql)
			if got := scanFailures(t, ctx, tx, s); got != p.want {
				t.Errorf("RED CONTROL: scan = %q, want %q", got, p.want)
			}
		})
	}
	// Known: a row the owner chose to keep is reported, not failed (5.1a)
	mustExec(t, ctx, tx, plants[0].sql)
	k := s
	k.Known = map[string]int64{"scan workspace_events.message": 1}
	ps, err := Scan(ctx, tx, k)
	if err != nil || len(ps) != 1 || !ps[0].OK() {
		t.Errorf("a known row must be listed and hold: %v %v", ps, err)
	}
}

func scanFailures(t *testing.T, ctx context.Context, tx pgx.Tx, s ProofSet) string {
	t.Helper()
	ps, err := Scan(ctx, tx, s)
	if err != nil {
		t.Fatal(err)
	}
	return proofNames(ps)
}

// TestC13SourceDiffPostgres: the move's own writes leave an empty diff, M11's
// rewrite in the fleet's workspace among them; a <SRC> audit row, an extra
// <SRC> UPDATE and a hub row naming the channel are each named.
func TestC13SourceDiffPostgres(t *testing.T) {
	ctx, tx := pgTx(t)
	seedSource(t, ctx, tx)
	s := pfSet()
	before, err := TakeSnapshot(ctx, tx, s)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(before["messages"].rows); n != 4 {
		t.Fatalf("CONTROL: the snapshot holds %d <SRC> messages, want 4", n)
	}
	runMove(t, ctx, tx)
	diff := func() string {
		after, err := TakeSnapshot(ctx, tx, s)
		if err != nil {
			t.Fatal(err)
		}
		return diffWhy(Diff(before, after, s, Rules{}))
	}
	if got := diff(); got != "" {
		t.Fatalf("the move's own writes were named: %s", got)
	}
	for _, c := range []struct{ name, sql, want string }{
		{"the default audit writer", `INSERT INTO operator_audit (at, tenant_id, actor_tenant, actor_hum, action, detail)
			VALUES (now(), '` + pfSrc + `', '` + pfSrc + `', 'HUM-169', 'update', '{"channel": "` + pfMove + `"}')`,
			"operator_audit insert : the move writes no <SRC> row"},
		{"an extra <SRC> UPDATE", `UPDATE channels SET name = 'renamed' WHERE tenant_id = '` + pfSrc + `' AND channel_id = '` + pfStay + `'`,
			"channels update name: a staying row no rewrite may change"},
		{"an edit of a rewritten post", `UPDATE messages SET body = 'edited' WHERE tenant_id = '` + pfSrc + `' AND msg_id = '` + pfStayMsg + `'`,
			`messages update body\+\S*: a column no rewrite names`},
		{"a hub-wide row naming the channel", `INSERT INTO system_events (kind, message) VALUES ('hub.note', 'moved ` + pfMove + `')`,
			"a hub-wide row names the channel id"},
		{"a staying row deleted", `DELETE FROM workspace_events WHERE tenant_id = '` + pfSrc + `'`,
			"workspace_events delete : not a row of the set"},
	} {
		t.Run(c.name, func(t *testing.T) {
			mustExec(t, ctx, tx, `SAVEPOINT plant`)
			defer mustExec(t, ctx, tx, `ROLLBACK TO SAVEPOINT plant`)
			mustExec(t, ctx, tx, c.sql)
			if got := diff(); !regexp.MustCompile(c.want).MatchString(got) {
				t.Errorf("RED CONTROL: diff = %q, want it to name %q", got, c.want)
			}
		})
	}
}
