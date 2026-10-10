package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 121 T101 (sections 4.1, 4.2): rdb 0169's restrictive channel_scope
// policy and the two embed tables. The negative cases run as the hub's
// runtime login (DML grants only, FORCE RLS binds it) with the GUC
// app.channel_scope set directly, the setting T102's store.inChannel will
// set. A scoped session reads and writes its one channel and nothing else
// (no other channel, no DM, no lobby / tasks / alerts, no other tenant's
// channel of the same id); a session without the scope is unchanged.
// Postgres only (SPOOL_TEST_PG_DSN, SPOOL_TEST_PG_RUNTIME_DSN).

// channelScopeTables is every table rdb 0169 puts channel_scope on, with
// the column that names its channel ("" = through its message, msgCol).
var channelScopeTables = []struct{ name, chanCol, msgCol string }{
	{"messages", "channel", ""}, {"channels", "channel_id", ""}, {"channel_humans", "channel_id", ""},
	{"channel_subscriptions", "channel_id", ""}, {"topic_head_parts", "channel", ""}, {"embed_visitors", "channel_id", ""},
	{"message_reactions", "", "msg_id"}, {"message_revisions", "", "msg_id"}, {"message_kind_changes", "", "msg_id"},
	{"message_moderation", "", "msg_id"}, {"message_answers", "", "answers"},
}

// channelScopeExempt: the tables that name a channel or a message but are
// no channel reader's, each with why. A new one fails the catalogue gate
// until it is listed here or given the policy.
var channelScopeExempt = map[string]string{
	"deliveries":          "the per-box delivery queue: hub fan-out, no reader route",
	"fallback_deliveries": "the fallback fan-out record: hub-internal, no reader route",
	"flow_events":         "a member's own mention / poke feed, written by a trigger on every post",
	"demo_post_audit":     "the demo's operator audit (specs/077), read by the operator only",
}

// seedEmbedVisitor writes one embed and one visitor (a channel_guest HUM)
// bound to channel, under tenant's scope. No store API yet (T102).
func seedEmbedVisitor(ctx context.Context, pg *Postgres, tenant, channel string) error {
	var hum string
	if err := pg.pool.QueryRow(ctx, `INSERT INTO humans (kind) VALUES ('channel_guest') RETURNING human_id`).Scan(&hum); err != nil {
		return err
	}
	embed := uid("e-")
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO embed_customers (tenant_id, embed_id, allowed_origins) VALUES ($1, $2, '{https://example.com}')`,
			tenant, embed); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO embed_visitors (tenant_id, embed_id, visitor_id, token_hash, human_id, channel_id, expires_at)
			VALUES ($1, $2, $3::uuid, sha256(convert_to($3::text, 'UTF8')), $4, $5, now() + interval '30 days')`, tenant, embed, uuid4(), hum, channel)
		return err
	})
}

// scopeFix is one tenant (a) with a visitor channel and every other kind of
// conversation, and a second tenant (b) holding a channel of the same id.
type scopeFix struct {
	a, b, visit, other string
	msgs               map[string]string // label -> msg_id: visit, other, dm, lobby, tasks, alerts, b
}

func seedScopeFix(t *testing.T, pg *Postgres) scopeFix {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	f := scopeFix{a: newTenant(t, pg), b: newTenant(t, pg), visit: uid("v-"), other: uid("o-"), msgs: map[string]string{}}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct{ tenant, ch string }{{f.a, f.visit}, {f.a, f.other}, {f.b, f.visit}} {
		must(pg.CreateChannel(ctx, Channel{TenantID: c.tenant, ChannelID: c.ch, Name: c.ch, CreatedBy: "HUM-1", CreatedAt: now}))
		must(pg.AddChannelHumans(ctx, c.tenant, c.ch, []string{"HUM-1"}, "HUM-1", now))
		must(pg.InviteChannelAgent(ctx, c.tenant, c.ch, "box-a", "CLE-07", now))
		must(seedEmbedVisitor(ctx, pg, c.tenant, c.ch))
	}
	for _, c := range []struct{ label, tenant, ch string }{
		{"visit", f.a, f.visit}, {"other", f.a, f.other}, {"dm", f.a, ""},
		{"lobby", f.a, "lobby"}, {"tasks", f.a, "tasks"}, {"alerts", f.a, "alerts"}, {"b", f.b, f.visit},
	} {
		m := msgFor(c.tenant, uuid4(), "box-a", now, now, "env-"+c.label)
		m.Channel = c.ch
		_, err := pg.InsertMessage(ctx, m)
		must(err)
		f.msgs[c.label] = m.MsgID
		_, err = pg.ApplyEdit(ctx, c.tenant, m.MsgID, Edit{Body: "edited", Msg: m.Msg, Env: m.Env, EditedBy: "CLE-07", EditedAt: now.Add(time.Second)})
		must(err)
		_, err = pg.SetKind(ctx, c.tenant, m.MsgID, "note", "CLE-07", now.Add(time.Second))
		must(err)
		must(pg.AddReaction(ctx, c.tenant, m.MsgID, "HUM-1", "👍", now.Add(time.Second)))
		must(pg.SetHidden(ctx, c.tenant, m.MsgID, false, "HUM-1", now.Add(time.Second)))
		must(pg.asOperator(ctx, func(tx pgx.Tx) error { // message_answers: the row ClaimAnswer writes
			_, err := tx.Exec(ctx, `INSERT INTO message_answers (tenant_id, answers, answer_msg_id, seat, gen) VALUES ($1, $2, $3, 'CLE-07@box-a', 0)`,
				c.tenant, m.MsgID, uuid4())
			return err
		}))
	}
	return f
}

// inScope runs fn as s in one transaction with app.tenant_id and
// app.channel_scope set directly; channel "" sets the scope to the empty string (what a
// pooled connection reads after an earlier set_config: no scope). fn's
// error is returned; the transaction always rolls back.
func inScope(ctx context.Context, s *Postgres, tenant, channel string, fn func(pgx.Tx) error) error {
	rolledBack := errors.New("rollback")
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true), set_config('app.channel_scope', $2, true)`, tenant, channel); err != nil {
			return err
		}
		if err := fn(tx); err != nil {
			return err
		}
		return rolledBack
	})
	if errors.Is(err, rolledBack) {
		return nil
	}
	return err
}

// offChannel counts the rows of tb this transaction sees, and those outside
// channel (by its channel column, or by its message not being visitMsg).
func offChannel(ctx context.Context, tx pgx.Tx, tb struct{ name, chanCol, msgCol string }, channel, visitMsg string) (all, off int, err error) {
	id := pgx.Identifier{tb.name}.Sanitize()
	q := `SELECT count(*), count(*) FILTER (WHERE ` + pgx.Identifier{tb.chanCol}.Sanitize() + ` IS DISTINCT FROM $1) FROM ` + id
	arg := channel
	if tb.chanCol == "" {
		q = `SELECT count(*), count(*) FILTER (WHERE ` + pgx.Identifier{tb.msgCol}.Sanitize() + ` IS DISTINCT FROM $1::uuid) FROM ` + id
		arg = visitMsg
	}
	err = tx.QueryRow(ctx, q, arg).Scan(&all, &off)
	return all, off, err
}

// cloneMessageSQL is an INSERT that posts a copy of message $1 into channel
// $2 (NULL = a DM) under a new msg_id; the generated columns are left out.
func cloneMessageSQL(t *testing.T, pg *Postgres) string {
	t.Helper()
	var cols string
	if err := pg.pool.QueryRow(context.Background(), `SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute
		WHERE attrelid = 'messages'::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = ''`).Scan(&cols); err != nil {
		t.Fatal(err)
	}
	return `INSERT INTO messages (` + cols + `) SELECT ` + cols + ` FROM (SELECT (jsonb_populate_record(m,
		jsonb_build_object('msg_id', gen_random_uuid(), 'channel', $2::text))).* FROM messages m WHERE m.msg_id = $1) AS r`
}

// TestRLSChannelScopeReads: tenant A's session scoped to its visitor
// channel sees, in every channel_scope table, only that channel's rows:
// no other channel, no DM, no lobby / tasks / alerts message, nothing of
// tenant B's channel of the same id. A session of A without the scope
// (unset, or the empty string) sees every row of A, exactly as the operator counts them.
func TestRLSChannelScopeReads(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx := context.Background()
	f := seedScopeFix(t, pg)
	err := inScope(ctx, rt, f.a, f.visit, func(tx pgx.Tx) error {
		for _, tb := range channelScopeTables {
			all, off, err := offChannel(ctx, tx, tb, f.visit, f.msgs["visit"])
			if err != nil {
				return err
			}
			if all == 0 || off != 0 {
				t.Errorf("%s: the scoped session sees %d rows, %d outside its channel (want >0, 0)", tb.name, all, off)
			}
		}
		for _, label := range []string{"other", "dm", "lobby", "tasks", "alerts", "b"} {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM messages WHERE msg_id = $1`, f.msgs[label]).Scan(&n); err != nil {
				return err
			}
			if n != 0 {
				t.Errorf("the scoped session reads the %s message", label)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// Unscoped: '' and unset (inTenant never sets the GUC) read every row of A.
	for _, tb := range channelScopeTables {
		want := countOf(t, pg, tb.name, f.a)
		got := map[string]int{}
		count := func(tx pgx.Tx) error {
			var n int
			err := tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{tb.name}.Sanitize()).Scan(&n)
			got[tb.name] = n
			return err
		}
		if err := inScope(ctx, rt, f.a, "", count); err != nil || got[tb.name] != want {
			t.Errorf("%s: an empty scope reads %d rows of A, want %d (%v)", tb.name, got[tb.name], want, err)
		}
		if err := rt.inTenant(ctx, f.a, count); err != nil || got[tb.name] != want {
			t.Errorf("%s: a staff session reads %d rows of A, want %d (%v)", tb.name, got[tb.name], want, err)
		}
	}
}

// TestRLSChannelScopeWrites: the scoped session writes only its channel.
// A post, a reaction and a membership in it are admitted (the post through
// every messages trigger); the same rows for another channel, a DM or
// lobby are refused by WITH CHECK (42501); moving its message out is
// refused; an UPDATE or DELETE without WHERE reaches its channel only.
func TestRLSChannelScopeWrites(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx := context.Background()
	f := seedScopeFix(t, pg)
	clone := cloneMessageSQL(t, pg)
	write := func(sql string, args ...any) error {
		return inScope(ctx, rt, f.a, f.visit, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, sql, args...)
			return err
		})
	}
	for _, c := range []struct {
		what, sql string
		args      []any
		refused   bool
	}{
		{"a post in its channel", clone, []any{f.msgs["visit"], f.visit}, false},
		{"a post in another channel", clone, []any{f.msgs["visit"], f.other}, true},
		{"a DM", clone, []any{f.msgs["visit"], nil}, true},
		{"a lobby post", clone, []any{f.msgs["visit"], "lobby"}, true},
		{"moving its message out", `UPDATE messages SET channel = $2 WHERE msg_id = $1`, []any{f.msgs["visit"], f.other}, true},
		{"a reaction in its channel", `INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji) VALUES ($1, $2, 'HUM-9', '👀')`, []any{f.a, f.msgs["visit"]}, false},
		{"a reaction on another channel's message", `INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji) VALUES ($1, $2, 'HUM-9', '👀')`, []any{f.a, f.msgs["other"]}, true},
		{"a reaction on a DM", `INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji) VALUES ($1, $2, 'HUM-9', '👀')`, []any{f.a, f.msgs["dm"]}, true},
		{"a member of its channel", `INSERT INTO channel_humans (tenant_id, channel_id, human_id) VALUES ($1, $2, 'HUM-9')`, []any{f.a, f.visit}, false},
		{"a member of another channel", `INSERT INTO channel_humans (tenant_id, channel_id, human_id) VALUES ($1, $2, 'HUM-9')`, []any{f.a, f.other}, true},
		{"a new channel", `INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ($1, $2, 'x', 'HUM-9')`, []any{f.a, uid("n-")}, true},
		{"an agent in another channel", `INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id) VALUES ($1, $2, 'CLE-09', 'box-a')`, []any{f.a, f.other}, true},
	} {
		err := write(c.sql, c.args...)
		if c.refused && pgCode(err) != "42501" {
			t.Errorf("%s: %v, want the WITH CHECK refusal (42501)", c.what, err)
		}
		if !c.refused && err != nil {
			t.Errorf("%s: %v, want admitted", c.what, err)
		}
	}
	for _, tb := range channelScopeTables {
		id := pgx.Identifier{tb.name}.Sanitize()
		for _, w := range []string{`UPDATE ` + id + ` SET tenant_id = tenant_id RETURNING *`, `DELETE FROM ` + id + ` RETURNING *`} {
			err := inScope(ctx, rt, f.a, f.visit, func(tx pgx.Tx) error {
				var all, off int
				col, arg := tb.chanCol, f.visit
				if col == "" {
					col, arg = tb.msgCol, f.msgs["visit"]
				}
				if err := tx.QueryRow(ctx, `WITH w AS (`+w+`) SELECT count(*), count(*) FILTER (WHERE `+pgx.Identifier{col}.Sanitize()+`::text IS DISTINCT FROM $1) FROM w`, arg).Scan(&all, &off); err != nil {
					return err
				}
				if all == 0 || off != 0 {
					t.Errorf("%s: %q reached %d rows, %d outside the channel (want >0, 0)", tb.name, w, all, off)
				}
				return nil
			})
			if err != nil && !strings.Contains(err.Error(), "append-only") {
				t.Errorf("%s: %s: %v", tb.name, w, err)
			}
		}
	}
}

// TestRLSChannelScopeControl: in an owner transaction (rolled back) with
// channel_scope dropped from messages and message_reactions, the same
// scoped session reads A's other channels and writes lobby: the zeros and
// refusals above are the policy's, not the seed's.
func TestRLSChannelScopeControl(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	f := seedScopeFix(t, pg)
	clone := cloneMessageSQL(t, pg)
	var msgs, reactions int
	err := inScope(ctx, pg, f.a, f.visit, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DROP POLICY channel_scope ON messages; DROP POLICY channel_scope ON message_reactions`); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM messages WHERE channel IS DISTINCT FROM $1`, f.visit).Scan(&msgs); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM message_reactions WHERE msg_id <> $1::uuid`, f.msgs["visit"]).Scan(&reactions); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, clone, f.msgs["visit"], "lobby")
		return err
	})
	if err != nil {
		t.Fatalf("CONTROL: without the policy a lobby post is still refused: %v", err)
	}
	if msgs != 5 || reactions != 5 {
		t.Fatalf("CONTROL: without the policy the scoped session reads %d messages and %d reactions off its channel, want 5 and 5", msgs, reactions)
	}
}

// TestRLSChannelScopePlannerNeutral: without a channel scope the policy
// leaves the planner's row estimate of messages where it was, so a staff
// session plans as it did before rdb 0169 (the store E04 unread budgets
// turned on the first spelling). In one transaction, rolled back: 5,000
// copies of a message of A, ANALYZE, then EXPLAIN as A with the scope the
// empty string. CONTROL: the plain NULLIF(...) IS NULL spelling, swapped
// in, cuts the estimate more than tenfold.
func TestRLSChannelScopePlannerNeutral(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	f := seedScopeFix(t, pg)
	clone := cloneMessageSQL(t, pg)
	bulk := strings.Replace(strings.Replace(clone, "'channel', $2::text", "'channel', m.channel", 1),
		"FROM messages m WHERE", "FROM messages m, generate_series(1, 5000) WHERE", 1)
	planRows := func(tx pgx.Tx) (float64, error) {
		var plan []map[string]map[string]any
		if err := tx.QueryRow(ctx, `EXPLAIN (FORMAT JSON) SELECT * FROM messages`).Scan(&plan); err != nil {
			return 0, err
		}
		rows, _ := plan[0]["Plan"]["Plan Rows"].(float64)
		return rows, nil
	}
	var with, without, red float64
	err := inScope(ctx, pg, f.a, "", func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, bulk, f.msgs["other"]); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `ANALYZE messages`); err != nil {
			return err
		}
		var err error
		if with, err = planRows(tx); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DROP POLICY channel_scope ON messages`); err != nil {
			return err
		}
		if without, err = planRows(tx); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `CREATE POLICY channel_scope ON messages AS RESTRICTIVE
			USING (NULLIF(current_setting('app.channel_scope', true), '') IS NULL OR channel = current_setting('app.channel_scope', true))`); err != nil {
			return err
		}
		red, err = planRows(tx)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("messages estimate: policy %.0f, no policy %.0f, plain spelling %.0f", with, without, red)
	if without < 1000 || with < 0.9*without {
		t.Errorf("channel_scope moves the unscoped estimate: %.0f rows with it, %.0f without", with, without)
	}
	if red*10 > without {
		t.Fatalf("CONTROL: the plain spelling estimates %.0f of %.0f rows: the pin cannot tell", red, without)
	}
}

// channelScopeGaps lists the tables that name a channel (a channel /
// channel_id column) or a message (a foreign key to messages) and hold
// neither a restrictive channel_scope policy (FOR ALL, USING and WITH CHECK
// on app.channel_scope) nor an entry in channelScopeExempt.
func channelScopeGaps(ctx context.Context, tx pgx.Tx) ([]string, error) {
	rows, err := tx.Query(ctx, `SELECT DISTINCT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') AND (
			EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND NOT a.attisdropped AND a.attname IN ('channel', 'channel_id'))
			OR EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f' AND k.confrelid = 'messages'::regclass))
		AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = n.nspname AND p.tablename = c.relname
			AND p.policyname = 'channel_scope' AND p.permissive = 'RESTRICTIVE' AND p.cmd = 'ALL'
			AND p.qual LIKE '%app.channel_scope%' AND p.with_check LIKE '%app.channel_scope%')
		ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	var gaps []string
	err = scanRows(rows, func(r pgx.Rows) error {
		var name string
		if err := r.Scan(&name); err != nil {
			return err
		}
		if channelScopeExempt[name] == "" {
			gaps = append(gaps, name)
		}
		return nil
	})
	return gaps, err
}

// TestRLSChannelScopeCatalogue: every table a channel reader reaches holds
// the policy (read from the catalogue, so a new channel table cannot ship
// without it or a reason), and the ones rdb 0169 names are exactly those.
// CONTROL: a scratch table with a channel column, in a transaction rolled
// back, is reported.
func TestRLSChannelScopeCatalogue(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		gaps, err := channelScopeGaps(ctx, tx)
		if err != nil {
			return err
		}
		for _, g := range gaps {
			t.Errorf("%s names a channel or a message but holds no restrictive channel_scope policy", g)
		}
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM pg_policies WHERE schemaname = current_schema() AND policyname = 'channel_scope'`).Scan(&n); err != nil {
			return err
		}
		if n != len(channelScopeTables) {
			t.Errorf("%d channel_scope policies, want the %d of channelScopeTables", n, len(channelScopeTables))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var red []string
	err = inScope(ctx, pg, "t-none", "", func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `CREATE TABLE scratch_channel_reader (tenant_id text, channel text)`); err != nil {
			return err
		}
		red, err = channelScopeGaps(ctx, tx)
		return err
	})
	found := false
	for _, g := range red {
		found = found || g == "scratch_channel_reader"
	}
	if err != nil || !found {
		t.Fatalf("CONTROL: a scratch channel table is not reported: gaps %v (%v)", red, err)
	}
}

// TestRLSEmbedTablesInFailClosedGate: the catalogue gate of
// rls_failclosed_test.go reads embed_customers and embed_visitors (both
// ENABLE + FORCE, tenant_scope in the NULLIF shape: no gap). CONTROL: with
// FORCE lifted on both (rolled back) the gate names each.
func TestRLSEmbedTablesInFailClosedGate(t *testing.T) {
	rlsStore(t)
	ctx := context.Background()
	gaps, err := tenantPolicyGaps(ctx, os.Getenv("SPOOL_TEST_PG_DSN"), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, g := range gaps {
		if strings.HasPrefix(g, "embed_") {
			t.Error(g)
		}
	}
	red, err := tenantPolicyGaps(ctx, os.Getenv("SPOOL_TEST_PG_DSN"), func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `ALTER TABLE embed_customers NO FORCE ROW LEVEL SECURITY; ALTER TABLE embed_visitors NO FORCE ROW LEVEL SECURITY`)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, tb := range []string{"embed_customers", "embed_visitors"} {
		want := tb + ": carries tenant_id but row security is enable=true force=false"
		found := false
		for _, g := range red {
			found = found || g == want
		}
		if !found {
			t.Errorf("CONTROL: the gate did not name %s with FORCE lifted: %v", tb, red)
		}
	}
}
