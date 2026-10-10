package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 099 T002: rdb 0144's head tables, functions and triggers. The case
// table (topic_head_harness_test.go) asserts topic_head_diff is empty after
// every case; this file proves the parts the case table cannot: the file
// migrates (twice), one insert writes one head and one part, statements that
// touch no head column write nothing, the diff names every corrupted column,
// each trigger is needed, and the races of spec 7.3 that the mark-then-apply
// design exists for (C6, C7, C8). Postgres only (SPOOL_TEST_PG_DSN).

const topicHeadFile = "0144_topic_heads.sql"

// errRollback ends a test transaction without keeping what it wrote.
var errRollback = errors.New("rollback")

// lightHeadFix is an empty tenant with headFix's helpers (no seed).
func lightHeadFix(t *testing.T, pg *Postgres, t0 time.Time) *headFix {
	return &headFix{t: t, pg: pg, tn: newTenant(t, pg), t0: t0, now: t0, task: map[string]string{}, msg: map[string]string{}}
}

// txDiff is topic_head_diff(tenant) on tx: task id -> what differs.
func txDiff(ctx context.Context, tx pgx.Tx, tenant string) (map[string]string, error) {
	out := map[string]string{}
	err := eachRow(ctx, tx, `SELECT task_id::text, what FROM topic_head_diff($1)`, []any{tenant}, func(r pgx.Rows) error {
		var k, w string
		if err := r.Scan(&k, &w); err != nil {
			return err
		}
		out[k] = w
		return nil
	})
	return out, err
}

// headDiff is topic_head_diff for f's tenant, as operator.
func headDiff(f *headFix) map[string]string {
	f.t.Helper()
	var out map[string]string
	f.must("diff", f.pg.asOperator(context.Background(), func(tx pgx.Tx) (err error) {
		out, err = txDiff(context.Background(), tx, f.tn)
		return err
	}))
	return out
}

// diffNames fails unless the diff names exactly the topics want (task ids).
func diffNames(got map[string]string, want ...string) string {
	var g []string
	for k := range got {
		g = append(g, k)
	}
	sort.Strings(g)
	sort.Strings(want)
	if fmt.Sprint(g) != fmt.Sprint(want) {
		return fmt.Sprintf("diff names %v (%v), want %v", g, got, want)
	}
	return ""
}

// headRevs is every head and part rev of f's tenant as one string per task.
func headRevs(f *headFix) map[string]string {
	f.t.Helper()
	out := map[string]string{}
	ctx := context.Background()
	f.must("revs", f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT h.task_id::text, h.rev || ' ' || coalesce((SELECT string_agg(p.part || '=' || p.rev, ',' ORDER BY p.part)
				FROM topic_head_parts p WHERE p.tenant_id = h.tenant_id AND p.task_id = h.task_id), '')
			FROM topic_heads h WHERE h.tenant_id = $1`, []any{f.tn}, func(r pgx.Rows) error {
			var k, v string
			if err := r.Scan(&k, &v); err != nil {
				return err
			}
			out[k] = v
			return nil
		})
	}))
	return out
}

// TestTopicHeadMigrate0144: the file applies a second time through Migrate
// and changes nothing, and the catalogue holds what spec 3 and 4.2 name.
func TestTopicHeadMigrate0144(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	if _, err := pg.pool.Exec(ctx, `DELETE FROM spool_schema_migrations WHERE filename = $1`, topicHeadFile); err != nil {
		t.Fatal(err)
	}
	applied, err := Migrate(ctx, pg.Pool(), sqlDir(t))
	if err != nil {
		t.Fatalf("second apply of %s: %v", topicHeadFile, err)
	}
	again := false
	for _, a := range applied {
		again = again || (a.File == topicHeadFile && !a.Skipped)
	}
	if !again {
		t.Fatalf("%s was not re-applied: %+v", topicHeadFile, applied)
	}
	pins := []struct{ what, q, want string }{
		// Permissive only: rdb 0169 adds the restrictive channel_scope on
		// topic_head_parts (specs/121), pinned by TestRLSChannelScopeCatalogue.
		{"FORCE RLS, 2 policies each", `SELECT string_agg(c.relname || ':' || (c.relrowsecurity AND c.relforcerowsecurity)
				|| ':' || (SELECT count(*) FROM pg_policies p WHERE p.tablename = c.relname AND p.schemaname = current_schema()
					AND p.permissive = 'PERMISSIVE'), ' ' ORDER BY c.relname)
			FROM pg_class c WHERE c.oid IN ('topic_heads'::regclass, 'topic_head_parts'::regclass, 'topic_head_tenants'::regclass)`,
			"topic_head_parts:true:2 topic_head_tenants:true:2 topic_heads:true:2"},
		{"triggers", `SELECT string_agg(tgname || ':' || tgenabled::text || ':' || (tgconstraint <> 0) || ':' || tgdeferrable || ':' || tginitdeferred, ' ' ORDER BY tgname)
			FROM pg_trigger WHERE tgrelid = 'messages'::regclass AND tgname LIKE 'topic_head%'`,
			"topic_head_apply:O:true:true:true topic_head_mark_del:O:false:false:false topic_head_mark_ins:O:false:false:false topic_head_mark_upd:O:false:false:false"},
		{"functions, none SECURITY DEFINER", `SELECT count(*) || ' definer=' || bool_or(prosecdef) FROM pg_proc WHERE oid IN (
				'topic_head_apply_marks(text)'::regprocedure, 'topic_head_add(text[], uuid[], uuid[])'::regprocedure,
				'topic_head_rebuild(text[], uuid[])'::regprocedure, 'topic_head_diff(text)'::regprocedure,
				'topic_head_backfill(integer, boolean, text)'::regprocedure)`, "5 definer=false"},
	}
	for _, p := range pins {
		var got string
		if err := pg.pool.QueryRow(ctx, p.q).Scan(&got); err != nil {
			t.Fatalf("%s: %v", p.what, err)
		}
		if got != p.want {
			t.Errorf("%s: got %q, want %q", p.what, got, p.want)
		}
	}
}

// storedHead is one topic_heads row and its parts, as stored.
type storedHead struct {
	lastAt, validUntil time.Time
	lastMsg, dmLastMsg string
	dmLastAt           *time.Time
	card               bool
	archived, rev      int
	parts              []storedPart
}

type storedPart struct {
	part, channel, dmA, dmB, lastMsg string
	lastAt, validUntil               time.Time
	rev                              int
}

// readHead reads task's head and parts as operator.
func readHead(f *headFix, task string) storedHead {
	f.t.Helper()
	ctx := context.Background()
	var h storedHead
	f.must("read head "+task, f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT last_at, last_msg_id::text, dm_last_at, coalesce(dm_last_msg_id::text, ''), valid_until,
				card_archived, archived_rows, rev FROM topic_heads WHERE tenant_id = $1 AND task_id = $2`, f.tn, f.task[task]).Scan(
			&h.lastAt, &h.lastMsg, &h.dmLastAt, &h.dmLastMsg, &h.validUntil, &h.card, &h.archived, &h.rev); err != nil {
			return err
		}
		return eachRow(ctx, tx, `SELECT part, coalesce(channel, ''), coalesce(dm_a, ''), coalesce(dm_b, ''), last_msg_id::text,
				last_at, valid_until, rev FROM topic_head_parts WHERE tenant_id = $1 AND task_id = $2 ORDER BY part`,
			[]any{f.tn, f.task[task]}, func(r pgx.Rows) error {
				var p storedPart
				err := r.Scan(&p.part, &p.channel, &p.dmA, &p.dmB, &p.lastMsg, &p.lastAt, &p.validUntil, &p.rev)
				h.parts = append(h.parts, p)
				return err
			})
	}))
	return h
}

// TestTopicHeadOneInsert: one channel line writes exactly one head and one
// part, both rev 1, holding that line; a DM line keys its part on the two
// ids, lesser first, and sets the head's DM columns.
func TestTopicHeadOneInsert(t *testing.T) {
	pg := pgOnly(t)
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	f.line("x0", "X", time.Minute, lineOpt{})
	f.line("y0", "Y", 2*time.Minute, dmHumAgt)
	ttl := 30 * 24 * time.Hour
	for _, w := range []struct {
		task, msg, part, channel, dmA, dmB string
		ago                                time.Duration
	}{
		{"X", "x0", "c:" + ChannelLobby, ChannelLobby, "", "", time.Minute},
		{"Y", "y0", "d:AGT-1 HUM-1", "", "AGT-1", "HUM-1", 2 * time.Minute},
	} {
		h, at := readHead(f, w.task), f.t0.Add(-w.ago)
		dm := w.channel == ""
		if !h.lastAt.Equal(at) || h.lastMsg != f.msg[w.msg] || !h.validUntil.Equal(at.Add(ttl)) || h.card || h.archived != 0 || h.rev != 1 ||
			(h.dmLastAt != nil) != dm || (dm && (!h.dmLastAt.Equal(at) || h.dmLastMsg != f.msg[w.msg])) {
			t.Errorf("%s head %+v, want last %s %s, dm=%v, rev 1", w.task, h, at, f.msg[w.msg], dm)
		}
		if len(h.parts) != 1 {
			t.Fatalf("%s: %d parts, want 1: %+v", w.task, len(h.parts), h.parts)
		}
		p := h.parts[0]
		if p.part != w.part || p.channel != w.channel || p.dmA != w.dmA || p.dmB != w.dmB || p.lastMsg != f.msg[w.msg] ||
			!p.lastAt.Equal(at) || !p.validUntil.Equal(at.Add(ttl)) || p.rev != 1 {
			t.Errorf("%s part %+v, want %s %s/%s/%s", w.task, p, w.part, w.channel, w.dmA, w.dmB)
		}
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("diff after two inserts: %v", d)
	}
}

// nonHeadWrites are the statements that touch no head column (spec 7.1):
// the four claim UPDATEs (message_claim_postgres.go: dead, owned, renew,
// writeClaim), the replay's re-sign, the search_sig backfill, an edit and a
// kind change. Each runs on the line a1 of topic A.
func nonHeadWrites(f *headFix) map[string]func(ctx context.Context, tx pgx.Tx) (int64, error) {
	exec := func(sql string) func(ctx context.Context, tx pgx.Tx) (int64, error) {
		return func(ctx context.Context, tx pgx.Tx) (int64, error) {
			tag, err := tx.Exec(ctx, sql, f.tn, f.msg["a1"], f.t0)
			return tag.RowsAffected(), err
		}
	}
	return map[string]func(ctx context.Context, tx pgx.Tx) (int64, error){
		"claim dead": exec(`UPDATE messages SET handled_at = $3, handled_how = 'dead', locked_until = NULL,
			claim_state = 'done', touched_at = $3, offer_set = '{}', parked_until = NULL WHERE tenant_id = $1 AND msg_id = $2`),
		"claim owned": exec(`UPDATE messages SET responsible = 'CLE-1', locked_until = $3, responsible_gen = responsible_gen + 1,
			claim_n = claim_n + 1, claim_state = 'owned', accepted_at = $3, touched_at = $3 WHERE tenant_id = $1 AND msg_id = $2`),
		"claim renew": exec(`UPDATE messages SET locked_until = $3 WHERE tenant_id = $1 AND msg_id = $2`),
		"claim write": func(ctx context.Context, tx pgx.Tx) (int64, error) {
			return 1, writeClaim(ctx, tx, &Message{TenantID: f.tn, MsgID: f.msg["a1"], ClaimN: 1})
		},
		"search_sig":            exec(`UPDATE messages SET search_sig = B'0'::bit(1024) WHERE tenant_id = $1 AND msg_id = $2 AND $3::timestamptz IS NOT NULL`),
		"unsign (replay setup)": exec(`UPDATE messages SET env_sig = '' WHERE tenant_id = $1 AND msg_id = $2 AND $3::timestamptz IS NOT NULL`),
	}
}

// TestTopicHeadNonHeadUpdatesKeepRev: no statement above writes a head or a
// part (every rev stays), and the control - an UPDATE of a head column -
// does.
func TestTopicHeadNonHeadUpdatesKeepRev(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	f := seedHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	before := headRevs(f)
	if len(before) < 6 {
		t.Fatalf("only %d heads after the seed: %v", len(before), before)
	}
	writes := nonHeadWrites(f)
	names := make([]string, 0, len(writes))
	for n := range writes {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		var rows int64
		f.must(n, pg.inTenant(ctx, f.tn, func(tx pgx.Tx) (err error) {
			rows, err = writes[n](ctx, tx)
			return err
		}))
		if rows != 1 {
			t.Fatalf("%s wrote %d rows, want 1", n, rows)
		}
	}
	ok, err := pg.ResignMessage(ctx, f.tn, f.msg["a1"], []byte(`{"re":"signed"}`), "sig2")
	f.must("resign", err)
	_, err = pg.ApplyEdit(ctx, f.tn, f.msg["a1"], f.edit("an edit"))
	f.must("edit", err)
	_, err = pg.SetKind(ctx, f.tn, f.msg["a1"], "note", "HUM-1", f.t0)
	f.must("kind", err)
	if !ok {
		t.Fatal("ResignMessage re-signed nothing: the replay statement did not run")
	}
	if after := headRevs(f); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Fatalf("a statement that touches no head column wrote a head:\n before %v\n after  %v", before, after)
	}
	_, err = pg.execTenant(ctx, f.tn, `UPDATE messages SET expires_at = expires_at + interval '1 second' WHERE tenant_id = $1 AND msg_id = $2`,
		f.tn, f.msg["a2"])
	f.must("control", err)
	if after := headRevs(f); after[f.task["A"]] == before[f.task["A"]] {
		t.Fatalf("CONTROL: an expires_at update left A's revs at %s", after[f.task["A"]])
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("diff: %v", d)
	}
}

// headCorruptions breaks one stored column (or row) each, as operator; $1
// is the tenant, $2 the task the diff must then name.
var headCorruptions = []struct{ what, task, sql string }{
	{"head last_at", "A", `UPDATE topic_heads SET last_at = last_at + interval '1 ms' WHERE tenant_id = $1 AND task_id = $2`},
	{"head last_msg_id", "A", `UPDATE topic_heads SET last_msg_id = gen_random_uuid() WHERE tenant_id = $1 AND task_id = $2`},
	{"head dm_last_at", "D", `UPDATE topic_heads SET dm_last_at = dm_last_at - interval '1 ms' WHERE tenant_id = $1 AND task_id = $2`},
	{"head dm_last_msg_id", "D", `UPDATE topic_heads SET dm_last_msg_id = gen_random_uuid() WHERE tenant_id = $1 AND task_id = $2`},
	{"head dm on a channel topic", "A", `UPDATE topic_heads SET dm_last_at = last_at, dm_last_msg_id = last_msg_id WHERE tenant_id = $1 AND task_id = $2`},
	{"head valid_until", "A", `UPDATE topic_heads SET valid_until = valid_until - interval '1 ms' WHERE tenant_id = $1 AND task_id = $2`},
	{"head card_archived", "A", `UPDATE topic_heads SET card_archived = NOT card_archived WHERE tenant_id = $1 AND task_id = $2`},
	{"head archived_rows", "A", `UPDATE topic_heads SET archived_rows = archived_rows + 1 WHERE tenant_id = $1 AND task_id = $2`},
	{"part part", "A", `UPDATE topic_head_parts SET part = 'c:zzz' WHERE tenant_id = $1 AND task_id = $2`},
	{"part channel", "A", `UPDATE topic_head_parts SET channel = 'zzz' WHERE tenant_id = $1 AND task_id = $2`},
	{"part dm_a", "D", `UPDATE topic_head_parts SET dm_a = 'AAA-0' WHERE tenant_id = $1 AND task_id = $2`},
	{"part dm_b", "D", `UPDATE topic_head_parts SET dm_b = 'ZZZ-0' WHERE tenant_id = $1 AND task_id = $2`},
	{"part last_at", "A", `UPDATE topic_head_parts SET last_at = last_at + interval '1 ms' WHERE tenant_id = $1 AND task_id = $2`},
	{"part last_msg_id", "A", `UPDATE topic_head_parts SET last_msg_id = gen_random_uuid() WHERE tenant_id = $1 AND task_id = $2`},
	{"part valid_until", "A", `UPDATE topic_head_parts SET valid_until = valid_until + interval '1 ms' WHERE tenant_id = $1 AND task_id = $2`},
	{"missing head", "A", `DELETE FROM topic_heads WHERE tenant_id = $1 AND task_id = $2`},
	{"missing part", "A", `DELETE FROM topic_head_parts WHERE tenant_id = $1 AND task_id = $2`},
	{"orphan part", "A", `INSERT INTO topic_head_parts (tenant_id, task_id, part, channel, last_at, last_msg_id, valid_until, rev)
		VALUES ($1, $2, 'c:ghost', 'ghost', now(), gen_random_uuid(), now(), 1)`},
	{"orphan head", "", `INSERT INTO topic_heads (tenant_id, task_id, last_at, last_msg_id, valid_until, card_archived, archived_rows, rev, changed_at)
		VALUES ($1, $2, now(), gen_random_uuid(), now(), false, 0, 1, now())`},
}

// TestTopicHeadDiffDetectsEveryColumn: each corruption of spec 3.1 / 3.2's
// columns, and a missing or orphan head or part, makes topic_head_diff name
// exactly that topic. rev and changed_at are write counters, not derived
// from messages, so no rebuild can check them. Each runs in a rolled-back
// transaction on the case table's seed.
func TestTopicHeadDiffDetectsEveryColumn(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	f := seedHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("diff before any corruption: %v", d)
	}
	for _, c := range headCorruptions {
		task := f.task[c.task]
		if c.task == "" {
			task = uuid4()
		}
		err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, c.sql, f.tn, task)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return fmt.Errorf("the corruption wrote no row")
			}
			d, err := txDiff(ctx, tx, f.tn)
			if err != nil {
				return err
			}
			if msg := diffNames(d, task); msg != "" {
				return errors.New(msg)
			}
			t.Logf("%s: %s", c.what, d[task])
			return errRollback
		})
		if !errors.Is(err, errRollback) {
			t.Errorf("%s: %v", c.what, err)
		}
	}
}

// txInsert inserts m on tx with InsertMessage's own statement.
func txInsert(ctx context.Context, tx pgx.Tx, m Message) error {
	sql, args := insertMessageArgs(m, time.Time{})
	var inserted bool
	var old []byte
	var notified int64
	if err := tx.QueryRow(ctx, sql, args...).Scan(&inserted, &old, &notified); err != nil {
		return err
	}
	if !inserted {
		return fmt.Errorf("line %s not inserted", m.MsgID)
	}
	return nil
}

// triggerControl disables one trigger (or none) for one transaction, runs
// the write of the case it guards, fires the deferred apply, and returns
// the topics topic_head_diff then names; the transaction is rolled back,
// the DISABLE with it.
func triggerControl(t *testing.T, pg *Postgres, trigger string, write func(context.Context, pgx.Tx, *headFix) error) (*headFix, map[string]string) {
	t.Helper()
	ctx := context.Background()
	f := seedHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	var d map[string]string
	err := pg.inTenant(ctx, f.tn, func(tx pgx.Tx) error {
		if trigger != "" {
			if _, err := tx.Exec(ctx, `ALTER TABLE messages DISABLE TRIGGER `+pgx.Identifier{trigger}.Sanitize()); err != nil {
				return err
			}
		}
		if err := write(ctx, tx, f); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `SET CONSTRAINTS topic_head_apply IMMEDIATE`); err != nil {
			return err
		}
		var err error
		if d, err = txDiff(ctx, tx, f.tn); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("trigger %q: %v", trigger, err)
	}
	return f, d
}

// TestTopicHeadTriggerControls (spec 7.1): with one trigger disabled, the
// case it guards leaves a wrong head - mark_ins on E01 (insert), mark_upd on
// E07 (move a line to B), mark_del on E16 (delete a line), the apply on E01
// - and with none disabled the same write leaves none.
func TestTopicHeadTriggerControls(t *testing.T) {
	pg := pgOnly(t)
	insert := func(ctx context.Context, tx pgx.Tx, f *headFix) error {
		return txInsert(ctx, tx, f.lineMsg("a3", "A", 0, lineOpt{}))
	}
	move := func(ctx context.Context, tx pgx.Tx, f *headFix) error {
		_, err := tx.Exec(ctx, `UPDATE messages SET task_id = $3, channel = 'crew' WHERE tenant_id = $1 AND msg_id = $2`,
			f.tn, f.msg["a2"], f.task["B"])
		return err
	}
	del := func(ctx context.Context, tx pgx.Tx, f *headFix) error {
		_, err := tx.Exec(ctx, `DELETE FROM messages WHERE tenant_id = $1 AND msg_id = $2`, f.tn, f.msg["a2"])
		return err
	}
	for _, c := range []struct {
		trigger, caseID string
		write           func(context.Context, pgx.Tx, *headFix) error
		wrong           []string
	}{
		{"topic_head_mark_ins", "E01", insert, []string{"A"}},
		{"topic_head_mark_upd", "E07", move, []string{"A"}}, // a2 is older than B's latest: only A changes
		{"topic_head_mark_del", "E16", del, []string{"A"}},
		{"topic_head_apply", "E01", insert, []string{"A"}},
		{"", "E01", insert, nil},
		{"", "E07", move, nil},
		{"", "E16", del, nil},
	} {
		f, d := triggerControl(t, pg, c.trigger, c.write)
		var want []string
		for _, w := range c.wrong {
			want = append(want, f.task[w])
		}
		if msg := diffNames(d, want...); msg != "" {
			t.Errorf("trigger %q disabled, case %s: %s", c.trigger, c.caseID, msg)
			continue
		}
		t.Logf("trigger %q disabled, case %s: %d wrong heads %v", c.trigger, c.caseID, len(d), d)
	}
}

// TestTopicHeadNeedsReadCommitted: the drain reads messages in a fresh
// snapshot after it locks the heads, so a write under REPEATABLE READ is
// refused at COMMIT rather than writing a head from a stale snapshot.
func TestTopicHeadNeedsReadCommitted(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	m := f.lineMsg("x0", "X", 0, lineOpt{})
	err := pgx.BeginTxFunc(ctx, pg.pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead}, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgScopeTenant, f.tn); err != nil {
			return err
		}
		return txInsert(ctx, tx, m)
	})
	if err == nil || !strings.Contains(err.Error(), "READ COMMITTED") {
		t.Fatalf("a REPEATABLE READ insert committed: %v", err)
	}
}

// together runs a and b each in its own tenant transaction; both do their
// writes, wait for each other, then COMMIT at once, so the two drains race.
func together(ctx context.Context, pg *Postgres, tenant string, a, b func(pgx.Tx) error) (error, error) {
	var wrote sync.WaitGroup
	wrote.Add(2)
	commit := make(chan struct{})
	errs := make([]error, 2)
	var done sync.WaitGroup
	for i, fn := range []func(pgx.Tx) error{a, b} {
		done.Add(1)
		go func(i int, fn func(pgx.Tx) error) {
			defer done.Done()
			once := sync.OnceFunc(wrote.Done)
			defer once()
			errs[i] = pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
				err := fn(tx)
				once()
				<-commit
				return err
			})
		}(i, fn)
	}
	wrote.Wait()
	close(commit)
	done.Wait()
	return errs[0], errs[1]
}

// TestTopicHeadRaceFirstInsertVsMove is C6: a topic's first insert commits
// at the same time as a move of another line into that new task. Under v0.1
// the head lost one of them (claude-1 F1, 5 of 5); here the placeholder head
// makes the second drain wait for the first.
func TestTopicHeadRaceFirstInsertVsMove(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	for r := 0; r < 10; r++ {
		f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
		f.line("a0", "A", 10*time.Minute, lineOpt{card: true})
		f.line("a1", "A", 5*time.Minute, lineOpt{})
		first := f.lineMsg("n0", "N", 3*time.Minute, lineOpt{card: true})
		e1, e2 := together(ctx, pg, f.tn, func(tx pgx.Tx) error {
			return txInsert(ctx, tx, first)
		}, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE messages SET task_id = $3 WHERE tenant_id = $1 AND msg_id = $2`, f.tn, f.msg["a1"], f.task["N"])
			return err
		})
		if e1 != nil || e2 != nil {
			t.Fatalf("round %d: insert %v, move %v", r, e1, e2)
		}
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("round %d: a head lost a write: %v", r, d)
		}
		if h := readHead(f, "N"); !h.lastAt.Equal(f.t0.Add(-3*time.Minute)) || len(h.parts) != 1 {
			t.Fatalf("round %d: N's head %+v", r, h)
		}
	}
}

// TestTopicHeadRaceMirroredVsMerge is C7: InsertMirrored (a DM line into P
// and its channel copy into Q) commits against a merge of Q into P (or P
// into Q), 50 rounds. Under v0.1's immediate triggers this deadlocked 3 of 3
// (claude-1 F2); the drain locks every head last, sorted, so 0 40P01.
func TestTopicHeadRaceMirroredVsMerge(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	deadlocks := 0
	for r := 0; r < 50; r++ {
		f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
		f.line("p0", "P", 10*time.Minute, lineOpt{card: true})
		f.line("q0", "Q", 9*time.Minute, lineOpt{card: true})
		dm := f.lineMsg("dm", "P", time.Minute, dmHumAgt)
		cp := f.lineMsg("cp", "Q", time.Minute, lineOpt{from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a", mirror: "dm"})
		src, dst := "Q", "P"
		if r%2 == 1 {
			src, dst = "P", "Q"
		}
		start := make(chan struct{})
		errs := make([]error, 2)
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, errs[0] = pg.InsertMirrored(ctx, dm, time.Time{}, cp, time.Time{})
		}()
		go func() {
			defer wg.Done()
			<-start
			_, errs[1] = pg.MergeTopic(ctx, f.tn, f.msg[strings.ToLower(src)+"0"], f.task[src], f.task[dst], ChannelLobby, "HUM-1", f.t0)
		}()
		close(start)
		wg.Wait()
		for _, err := range errs {
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "40P01" {
				deadlocks++
			} else if err != nil {
				t.Fatalf("round %d: %v", r, err)
			}
		}
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("round %d: %v", r, d)
		}
	}
	if deadlocks != 0 {
		t.Fatalf("%d of 50 rounds deadlocked (40P01)", deadlocks)
	}
}

// backfillTenant walks topic_head_backfill from just before f's tenant until
// the walk has passed it (its mark is set); it returns the chunks run.
func backfillTenant(f *headFix, rebuildAll bool) int {
	f.t.Helper()
	ctx := context.Background()
	cur := f.tn + "/00000000-0000-0000-0000-000000000000"
	for chunks := 1; chunks <= 50; chunks++ {
		var next *string
		var marked bool
		f.must("backfill", f.pg.asOperator(ctx, func(tx pgx.Tx) error {
			if err := tx.QueryRow(ctx, `SELECT topic_head_backfill(chunk => 100, rebuild_all => $1, after => $2)`, rebuildAll, cur).Scan(&next); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM topic_head_tenants WHERE tenant_id = $1 AND backfilled_at IS NOT NULL)`, f.tn).Scan(&marked)
		}))
		if marked {
			return chunks
		}
		if next == nil {
			f.t.Fatal("the backfill walk ended without marking the tenant")
		}
		cur = *next
	}
	f.t.Fatal("the backfill did not pass the tenant in 50 chunks")
	return 0
}

// TestTopicHeadRacePreDDLThenBackfill is C8: topics written before the DDL
// (their heads deleted) are listed by the diff as missing; an insert into
// one is a head miss and rebuilds it whole, not as a 1-line head; the
// backfill then rebuilds the other and marks the tenant; with rebuild_all it
// also deletes a head whose topic has no row.
func TestTopicHeadRacePreDDLThenBackfill(t *testing.T) {
	pg := pgOnly(t)
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	f.line("a0", "A", 10*time.Minute, lineOpt{card: true})
	f.line("a1", "A", 9*time.Minute, lineOpt{ch: "-", from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a"})
	f.line("b0", "B", 8*time.Minute, lineOpt{card: true})
	f.line("b1", "B", 7*time.Minute, lineOpt{})
	dropHeads(f, "A")
	dropHeads(f, "B")
	if msg := diffNames(headDiff(f), f.task["A"], f.task["B"]); msg != "" {
		t.Fatalf("pre-DDL topics: %s", msg)
	}
	f.line("a2", "A", 6*time.Minute, lineOpt{})
	if msg := diffNames(headDiff(f), f.task["B"]); msg != "" {
		t.Fatalf("after the insert into A (a head miss): %s", msg)
	}
	if h := readHead(f, "A"); len(h.parts) != 2 || h.dmLastAt == nil {
		t.Fatalf("A rebuilt as a 1-line head: %+v", h)
	}
	n := backfillTenant(f, false)
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the backfill (%d chunks): %v", n, d)
	}
	ghost := uuid4()
	f.must("orphan", pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), headCorruptions[len(headCorruptions)-1].sql, f.tn, ghost)
		return err
	}))
	if msg := diffNames(headDiff(f), ghost); msg != "" {
		t.Fatalf("orphan head: %s", msg)
	}
	backfillTenant(f, true)
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the rebuild_all backfill: %v", d)
	}
}
