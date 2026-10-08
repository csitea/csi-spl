package store

import (
	"context"
	"crypto/ed25519"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of the read-only viewer queries (view.go). SELECT only.

// optTime is NULL for the zero time (no cursor).
func optTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func pgLimit(n int) int {
	if n <= 0 {
		return 1_000_000
	}
	return n
}

func (s *Postgres) ViewBoxes(ctx context.Context, tenant string) ([]ViewBox, error) {
	var out []ViewBox
	r := viewBoxesRead(tenant, &out, s.hasAgentSeats(ctx), s.hasAgentRun(ctx))
	err := s.queryTenant(ctx, tenant, r.sql, r.args, r.each)
	return out, err
}

// viewBoxesSQL is the boxes read; with seats it also aggregates each roster
// agent's agent_seats.seated_at (rdb 0107), without it never names that table;
// with run it also aggregates roster.running (rdb 0153) in the agents' order.
func viewBoxesSQL(seats, run bool) string {
	cols, join := "", ""
	if run {
		cols = `,
			COALESCE(array_agg(r.running ORDER BY r.agent_id) FILTER (WHERE r.agent_id IS NOT NULL), '{}')`
	}
	if seats {
		cols += `,
			COALESCE(array_agg(s.agent_id ORDER BY s.agent_id) FILTER (WHERE s.agent_id IS NOT NULL), '{}'),
			COALESCE(array_agg(s.seated_at ORDER BY s.agent_id) FILTER (WHERE s.agent_id IS NOT NULL), '{}')`
		join = `
		LEFT JOIN agent_seats s ON s.tenant_id = r.tenant_id AND s.box_id = r.box_id AND s.agent_id = r.agent_id`
	}
	return `SELECT p.box_id, p.pubkey, p.revoked_at IS NOT NULL, b.last_hello_at,
			COALESCE(array_agg(r.agent_id ORDER BY r.agent_id) FILTER (WHERE r.agent_id IS NOT NULL), '{}')` + cols + `
		FROM pins p
		LEFT JOIN boxes b ON b.tenant_id = p.tenant_id AND b.box_id = p.box_id
		LEFT JOIN roster r ON r.tenant_id = p.tenant_id AND r.box_id = p.box_id` + join + `
		WHERE p.tenant_id = $1
		GROUP BY p.box_id, p.pubkey, p.revoked_at, b.last_hello_at
		ORDER BY p.box_id`
}

// viewBoxesRead is ViewBoxes' statement, shared with ViewRoster's batch.
func viewBoxesRead(tenant string, out *[]ViewBox, seats, run bool) tenantRead {
	return tenantRead{sql: viewBoxesSQL(seats, run), args: []any{tenant}, each: func(rows pgx.Rows) error {
		var v ViewBox
		var pub []byte
		var hello *time.Time
		var seatIDs []string
		var seatAts []time.Time
		var runs []*bool
		dst := []any{&v.BoxID, &pub, &v.Revoked, &hello, &v.Agents}
		if run {
			dst = append(dst, &runs)
		}
		if seats {
			dst = append(dst, &seatIDs, &seatAts)
		}
		if err := rows.Scan(dst...); err != nil {
			return err
		}
		for i, id := range seatIDs { // rdb 0107: one entry per seated agent
			if v.SeatedAt == nil {
				v.SeatedAt = map[string]time.Time{}
			}
			v.SeatedAt[id] = seatAts[i]
		}
		v.Running = agentRuns(v.Agents, runs)
		v.PubKey = ed25519.PublicKey(pub)
		if hello != nil {
			v.LastHelloAt = *hello
		}
		*out = append(*out, v)
		return nil
	}}
}

// agentRuns pairs roster.running (rdb 0153, aggregated in the agents' order)
// with the agents; a NULL is "not reported" and gets no entry. nil = none.
func agentRuns(agents []string, runs []*bool) map[string]bool {
	var out map[string]bool
	for i, r := range runs {
		if r == nil || i >= len(agents) {
			continue
		}
		if out == nil {
			out = map[string]bool{}
		}
		out[agents[i]] = *r
	}
	return out
}

// canonUUIDRe is a uuid as Postgres prints it (uuid::text). A task or parent
// filter that is not in this form matches no row, so it never reaches a
// ::uuid cast (which would fail) and the uuid indexes stay usable.
var canonUUIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// ViewTopics (027 T030) costs the page, not the tenant. It walks the tenant's
// messages newest first (rdb 0022 messages_received / messages_dm_received,
// or 0008 messages_channel for a channel) and keeps each topic's LATEST message only (no later one in the
// same topic passes the same filters: messages_task_received), so that walk
// yields each topic once, in (last_at DESC, task_id DESC) order. The walk is
// a recursive CTE whose every step is "the next such message below the
// previous one" (ORDER BY ... LIMIT 1, an ordered index scan whatever the
// planner estimates), and it stops after Limit topics; only those topics are
// aggregated (LATERAL).
// Message filters (expiry, channel, DM) apply to the walk, the latest check
// and the aggregate alike; topic filters (agent, viewer, roots, parent)
// apply to the aggregate. Rows are those of the pre-027 whole-tenant CTE,
// which view_topics_test.go keeps as the oracle.
func (s *Postgres) ViewTopics(ctx context.Context, tenant string, q TopicQuery) ([]TopicRow, error) {
	if q.Parent != "" && !canonUUIDRe.MatchString(q.Parent) {
		return nil, nil
	}
	if s.headsServe(ctx, q) { // spec 099 T005: SPOOL_HUB_TOPIC_HEADS=on
		return s.viewTopicsHeads(ctx, tenant, q)
	}
	sql, args := viewTopicsSQL(tenant, q)
	var out []TopicRow
	err := s.queryTenantNoJIT(ctx, tenant, sql, args, scanTopicRows(&out))
	return out, err
}

// scanTopicRows appends each row of viewTopicsSQL's statement to out.
func scanTopicRows(out *[]TopicRow) func(pgx.Rows) error {
	return func(rows pgx.Rows) error {
		var r TopicRow
		if err := rows.Scan(&r.TaskID, &r.Channel, &r.Parent, &r.FirstAt, &r.LastAt, &r.Count,
			&r.Kinds, &r.Parties, &r.FirstMsg); err != nil {
			return err
		}
		*out = append(*out, r)
		return nil
	}
}

// pgScopeTenantNoJIT is pgScopeTenant plus jit off for the same implicit
// transaction. The topic walk's cost estimate is the whole tenant's (the
// planner cannot see that LIMIT stops the walk early), which is above
// jit_above_cost: measured on pg 16.14 at 200k messages, JIT compiled for
// 311 ms around a 22 ms execution.
//
// Bitmap scans are off for the same reason (SPL-984): each recursive step is
// ORDER BY .. LIMIT 1 behind boolean probes rated rows=1, so the planner took
// a Bitmap Heap Scan of every older message per step plus a top-N sort. prd
// t1 2026-09-26: 3 488 rows and ~3 400 probe runs per step, 1.0-1.6 s per
// page. Without bitmap scans each step is an ordered index scan that stops
// at its first passing row (lab: 1 977 -> 21.5 ms at 11.7k messages). Local
// to this batch's implicit transaction: no other statement sees it.
//
// And a custom plan on every run: pgx prepares the walk once per
// pooled connection, and after five runs Postgres may keep a GENERIC plan,
// built without the tenant, the time or the reader's channels. prd t1
// 2026-09-27 (do_spl_db_hot_measure, n=15, execution only): generic 71 ms
// p50, custom 27 ms (plus ~4 ms planning). plan_cache_mode is read at every
// Bind, so a transaction-local setting sent first in the batch applies.
//
// And no explicit Sort (CLE-77914, owner topic 73c9704c "the clicking on
// the flow ... is really slow"): since rdb 0083 made messages_task_received
// covering, the recursive step took an Index ONLY Scan of that index over
// every older message of the tenant (received_at is not its leading column,
// so no range) plus a Sort for its LIMIT 1, instead of the ordered backward
// scan of messages_received - the same rows=1 misestimate as above. prd t1
// 2026-10-01: ~9 900 rows per step, 60 ms x 50 steps; the Flow read
// (limit=40, per_topic=3) answered p50 4.5 s / p95 30.5 s with 35 of 181
// 5xx. With enable_sort off the step is the ordered scan again (its
// Incremental Sort on the task_id tie-break is a separate setting and stays):
// do_spl_db_hot_measure walk_all, prd t1, reader HUM-10, n=10:
// p50 2 900 -> 22 ms, p95 42 002 -> 250 ms.
const pgScopeTenantNoJIT = `SELECT set_config('app.tenant_id', $1, true), set_config('jit', 'off', true),
	set_config('enable_bitmapscan', 'off', true), set_config('plan_cache_mode', 'force_custom_plan', true),
	set_config('enable_sort', 'off', true)`

// queryTenantNoJIT is queryTenant (one round trip, rls.go) with JIT off.
func (s *Postgres) queryTenantNoJIT(ctx context.Context, tenant, sql string, args []any, each func(pgx.Rows) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	b := &pgx.Batch{}
	b.Queue(pgScopeTenantNoJIT, tenant)
	b.Queue(sql, args...)
	br := s.pool.SendBatch(ctx, b)
	defer br.Close()
	if _, err := br.Exec(); err != nil {
		return err
	}
	rows, err := br.Query()
	if err != nil {
		return err
	}
	if err := scanRows(rows, each); err != nil {
		return err
	}
	return br.Close()
}

// viewTopicsSQL builds the statement for q. Only the filters q sets reach the
// SQL, so the planner sees concrete predicates (a channel walk takes
// messages_channel) instead of "$n is empty OR ..." shapes. Every topic filter
// is a probe on that one topic inside the walk step. The steps below ask for
// their arguments in a fixed order, which is the $n numbering.
func viewTopicsSQL(tenant string, q TopicQuery) (string, []any) {
	b := &topicsSQL{c: &sqlc{}, q: q}
	b.tn, b.now = b.c.arg(tenant), b.c.arg(q.Now)
	walk := b.walkLatest() + b.walkParties()
	door, aggDoor := b.readerDoor()
	walk += door + b.walkTree() + archivedTopicHideSQL("l", b.tn, b.c.arg(q.Lobby)) // specs/041
	if len(q.TaskIDs) > 0 {
		return b.listed(walk) + b.summary(aggDoor), b.c.args
	}
	return b.statement(walk, aggDoor, b.c.arg(pgLimit(q.Limit))), b.c.args
}

// topicsSQL builds viewTopicsSQL's statement; tn and now are the tenant and
// clock placeholders.
type topicsSQL struct {
	c       *sqlc
	q       TopicQuery
	tn, now string
}

// msgs is the message filters on alias a (each call binds the channel anew).
func (b *topicsSQL) msgs(a string) string {
	w := a + ".tenant_id = " + b.tn + " AND " + a + ".expires_at > " + b.now
	if b.q.Channel != "" {
		w += " AND " + a + ".channel = " + b.c.arg(b.q.Channel)
	}
	if b.q.DM {
		w += " AND " + a + ".channel IS NULL"
	}
	return w
}

// topic is a's messages in l's topic.
func (b *topicsSQL) topic(a string) string {
	return b.msgs(a) + " AND " + a + ".task_id = l.task_id"
}

// first: the topic's first message's parent passes test.
func (b *topicsSQL) first(test string) string {
	return " AND (SELECT f.parent_task_id " + test + " FROM messages f WHERE " + b.topic("f") +
		" ORDER BY f.received_at, f.msg_id::text LIMIT 1)"
}

// walkLatest: l is its topic's latest message (the cheapest probe, run
// first), before the page cursor. Every probe is a boolean scalar subquery on
// l's topic: it is never pulled up into a (hash) join over the whole tenant,
// and the planner rates a boolean qual at 1/2, not at the 1/rows of an
// equality on a unique column, so each LIMIT 1 step stays an ordered index
// scan.
func (b *topicsSQL) walkLatest() string {
	walk := b.msgs("l") + ` AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE ` + b.topic("x") + `
			ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1)`
	if !b.q.BeforeAt.IsZero() {
		at := b.c.arg(b.q.BeforeAt)
		walk += " AND l.received_at <= " + at + " AND (l.received_at, l.task_id::text) < (" + at + ", " + b.c.arg(b.q.BeforeTask) + ")"
	}
	return walk
}

// walkParties: the topic has a message from or to the agent (on its box) and
// from or to the viewer.
func (b *topicsSQL) walkParties() string {
	walk := ""
	if b.q.Agent != "" {
		id, fromBox, toBox := b.c.arg(b.q.Agent), "", ""
		if b.q.AgentBox != "" {
			box := b.c.arg(b.q.AgentBox)
			fromBox, toBox = " AND g.from_box = "+box, " AND g.to_box = "+box
		}
		walk += " AND (SELECT true FROM messages g WHERE " + b.topic("g") +
			" AND ((g.from_id = " + id + fromBox + ") OR (g.to_id = " + id + toBox + ")) LIMIT 1)"
	}
	if b.q.Viewer != "" {
		v := b.c.arg(b.q.Viewer)
		walk += " AND (SELECT true FROM messages v WHERE " + b.topic("v") +
			" AND (v.from_id = " + v + " OR v.to_id = " + v + ") LIMIT 1)"
	}
	return walk
}

// readerDoor is the read door (rdb 0028): the topic must hold at least one
// message this reader may see - one in a public channel, one in a channel
// they belong to, or a DM they are an end of. Same probe shape as Viewer, so
// it stays a LIMIT 1 index step inside the walk rather than a join. aggDoor
// is the same rule PER MESSAGE for the summary: the door only decides
// whether a topic is listed, so without it a topic mixing a DM with a #lobby
// reply was listed with the DM's first line as its subject and the DM's ends
// among its parties.
func (b *topicsSQL) readerDoor() (walk, aggDoor string) {
	if b.q.Reader == "" {
		return "", ""
	}
	rd, pub, mine := b.c.arg(b.q.Reader), b.c.arg(PublicChannels), b.c.arg(b.q.ReaderChannels)
	walk = " AND (SELECT true FROM messages d WHERE " + b.topic("d") + " AND (" +
		"d.channel = ANY(" + pub + "::text[]) OR d.channel = ANY(" + mine + "::text[]) OR " +
		"(d.channel IS NULL AND (d.from_id = " + rd + " OR d.to_id = " + rd + "))) LIMIT 1)"
	aggDoor = " AND (m.channel = ANY(" + pub + "::text[]) OR m.channel = ANY(" + mine + "::text[]) OR " +
		"(m.channel IS NULL AND (m.from_id = " + rd + " OR m.to_id = " + rd + ")))"
	return walk, aggDoor
}

// walkTree: roots only, no issue discussions (rdb 0047: a probe on the
// (tenant_id, task_id) unique index), children of one parent.
func (b *topicsSQL) walkTree() string {
	walk := ""
	if b.q.Roots {
		walk += b.first("IS NULL")
	}
	if b.q.NoIssues {
		walk += " AND (SELECT true FROM issues i WHERE i.tenant_id = " + b.tn + " AND i.task_id = l.task_id LIMIT 1) IS NULL"
	}
	if b.q.Parent != "" {
		p := b.c.arg(b.q.Parent)
		walk += " AND l.task_id IN (SELECT p.task_id FROM messages p WHERE p.tenant_id = " + b.tn +
			" AND p.parent_task_id = " + p + "::uuid)" + b.first("IS NOT DISTINCT FROM "+p+"::uuid")
	}
	return walk
}

// statement is the recursive walk over topics newest first, lim of them,
// with each topic's summary. The topic's first message (subject, channel,
// parent) is ONE ordered row, f, not (array_agg(m.msg ...))[1] in a: that
// read and copied every body of the topic to keep one (prd t1 2026-09-27,
// custom plan, n=15: 27 -> 13 ms a page).
//
// And only what the summary prints (CLE-77960, payload audit 2026-10-02 cut
// 2): parties come back DISTINCT (the hub dedups and sorts them anyway), and
// first_msg is {"body": <the subject's source>} instead of the whole inner
// message - see subjectSQL. The hub's JSON is byte-identical.
func (b *topicsSQL) statement(walk, aggDoor, lim string) string {
	order := " ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1"
	return `WITH RECURSIVE w (task_id, received_at, n) AS (
			(SELECT l.task_id, l.received_at, 1 FROM messages l WHERE ` + walk + order + `)
			UNION ALL
			SELECT s.task_id, s.received_at, w.n + 1 FROM w CROSS JOIN LATERAL (
				SELECT l.task_id, l.received_at FROM messages l
				WHERE ` + walk + ` AND l.received_at <= w.received_at
					AND (l.received_at, l.task_id::text) < (w.received_at, w.task_id::text)` + order + `
			) s
			WHERE w.n < ` + lim + `
		)` + b.summary(aggDoor)
}

// listed is w for q.TaskIDs (the since= delta): each listed topic's latest
// message passing walk, read on that topic's own messages_task_received
// range, so a listed topic that fails a filter costs one short probe instead
// of a walk to the end of the tenant.
func (b *topicsSQL) listed(walk string) string {
	return `WITH w (task_id, received_at) AS (
			SELECT l.task_id, l.received_at FROM unnest(` + b.c.arg(b.q.TaskIDs) + `::uuid[]) AS t (id) CROSS JOIN LATERAL (
				SELECT l.task_id, l.received_at FROM messages l
				WHERE ` + walk + ` AND l.task_id = t.id ORDER BY l.received_at DESC LIMIT 1
			) l
		)`
}

// summary is each walked topic's row: count, kinds, parties and its first
// message, newest topic first.
func (b *topicsSQL) summary(aggDoor string) string {
	return `
		SELECT w.task_id::text, f.channel, f.parent, f.first_at, w.received_at, a.n, a.kinds, a.parties, f.first_msg
		FROM w CROSS JOIN LATERAL (
			SELECT count(*)::int AS n,
				array_agg(m.kind ORDER BY m.received_at, m.msg_id::text) AS kinds,
				(SELECT array_agg(DISTINCT p ORDER BY p) FROM unnest(array_agg(m.from_id || '@' || m.from_box)
					|| array_agg(m.to_id || '@' || m.to_box)) p) AS parties
			FROM messages m
			WHERE ` + b.msgs("m") + ` AND m.task_id = w.task_id` + aggDoor + `
		) a LEFT JOIN LATERAL (
			SELECT COALESCE(m.channel, '') AS channel, COALESCE(m.parent_task_id::text, '') AS parent,
				m.received_at AS first_at, ` + subjectSQL + ` AS first_msg
			FROM messages m
			WHERE ` + b.msgs("m") + ` AND m.task_id = w.task_id` + aggDoor + `
			ORDER BY m.received_at, m.msg_id::text LIMIT 1
		) f ON true
		ORDER BY w.received_at DESC, w.task_id::text DESC`
}

// goSpaceSQL is Go's unicode.IsSpace set, which strings.TrimSpace trims, as
// a Postgres escape-string literal (ltrim takes a set of characters).
const goSpaceSQL = `E'\t\n\u000B\f\r \u0085\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u2028\u2029\u202F\u205F\u3000'`

// subjectSQL is the first message m cut to what the hub's subject() (hub
// view.go: first line, TrimSpace, at most subjectMax = 140 runes) reads, as
// {"body": s} with subject(s) == subject(m.msg body). s is the first line
// without its leading space, cut after 140 runes - plus, when more text
// follows, the space run up to the next non-space rune, so that subject()'s
// TrimSpace trims s exactly as it trims the whole line (a cut inside a space
// run would otherwise lose spaces the subject keeps). A body that is not a
// string reads as no subject, as the hub's json.Unmarshal then fails: {}.
const subjectSQL = `(SELECT CASE WHEN jsonb_typeof(m.msg -> 'body') = 'string' THEN jsonb_build_object('body', left(s.a, 140) ||
		CASE WHEN ltrim(substr(s.a, 141), ` + goSpaceSQL + `) = '' THEN ''
			ELSE left(substr(s.a, 141), char_length(substr(s.a, 141)) - char_length(ltrim(substr(s.a, 141), ` + goSpaceSQL + `)) + 1) END)
		ELSE '{}'::jsonb END
		FROM (SELECT ltrim(split_part(m.msg ->> 'body', E'\n', 1), ` + goSpaceSQL + `) AS a) s)`

// ViewTopic reads one topic by task_id = $2::uuid (027 T030: the pre-027
// task_id::text = $2 could not use an index and scanned every message of the
// tenant). A task id that is not a canonical uuid matched no row then and
// matches none now.
func (s *Postgres) ViewTopic(ctx context.Context, tenant string, q TopicMsgQuery) ([]ViewMsg, error) {
	if !canonUUIDRe.MatchString(q.TaskID) {
		return nil, nil
	}
	// Two single-statement batches, two round trips (it was a
	// BEGIN .. COMMIT transaction, five). Under READ COMMITTED each statement
	// of that transaction already took its own snapshot, so the answer is the
	// same: a delivery row is read at least as late as its message.
	p := newTopicPage(tenant, q)
	if err := s.queryTenant(ctx, tenant, p.read.sql, p.read.args, p.read.each); err != nil {
		return nil, err
	}
	return p.finish(ctx, s, tenant)
}

// topicPage is ViewTopic's page read as a tenantRead, so another read can
// ride its batch (perf round 4 G7, ViewTopicDoor), plus the rows it fills.
type topicPage struct {
	read tenantRead
	out  []ViewMsg
	idx  map[string]int
	ids  []string
}

// newTopicPage builds the page statement of q (a canonical task id).
func newTopicPage(tenant string, q TopicMsgQuery) *topicPage {
	order := "ORDER BY received_at, msg_id::text"
	if q.Desc {
		order = "ORDER BY received_at DESC, msg_id::text DESC"
	}
	// The per-message read door (rdb 0028). In the statement, not after it,
	// so LIMIT counts only messages this reader may see and a page is never
	// short because the rest of it was filtered away afterwards.
	door, doorArgs := "true", []any{}
	if q.Reader != "" {
		door = `((channel IS NULL AND (from_id = $9 OR to_id = $9))
			OR channel = ANY($10::text[]) OR channel = ANY($11::text[]))`
		doorArgs = []any{q.Reader, PublicChannels, q.ReaderChannels}
	}
	archived := ""
	if q.HideArchived { // specs/041: the lobby feed
		archived = " AND archived_at IS NULL"
	}
	p := &topicPage{idx: map[string]int{}}
	p.read = tenantRead{sql: `SELECT msg_id::text, received_at, env, edited_at, edited_by,
				CASE WHEN edited_at IS NULL THEN 0 ELSE COALESCE((SELECT MAX(revision)
					FROM message_revisions r WHERE r.tenant_id = messages.tenant_id AND r.msg_id = messages.msg_id), 0) END,
				is_parent, typed_by, responsible, ref_task_id::text, mirror_of::text, kind, kind_set_at, kind_set_by, ` + moveCols("") + `
			FROM messages
			WHERE tenant_id = $1 AND task_id = $2::uuid AND expires_at > $3
				AND ($4::timestamptz IS NULL OR (received_at, msg_id::text) > ($4::timestamptz, $5::text))
				AND ($7::timestamptz IS NULL OR (received_at, msg_id::text) < ($7::timestamptz, $8::text))
				AND ` + door + archived + `
			` + order + `
			LIMIT $6`, args: append([]any{tenant, q.TaskID, q.Now, optTime(q.AfterAt), q.AfterID, pgLimit(q.Limit), optTime(q.BeforeAt), q.BeforeID}, doorArgs...),
		each: func(rows pgx.Rows) error {
			v, err := scanViewMsg(rows)
			if err != nil {
				return err
			}
			p.idx[v.MsgID] = len(p.out)
			p.ids = append(p.ids, v.MsgID)
			p.out = append(p.out, v)
			return nil
		}}
	return p
}

// finish reads the page's deliveries (and, with a memo, its reactions).
func (p *topicPage) finish(ctx context.Context, s *Postgres, tenant string) ([]ViewMsg, error) {
	if len(p.ids) == 0 {
		return p.out, nil
	}
	if err := s.viewTopicDeliveries(ctx, tenant, p.ids, p.idx, p.out); err != nil {
		return nil, err
	}
	return p.out, nil
}

// viewTopicDeliveries fills out's delivery lists (idx: msg_id -> row). A view
// request (it carries the memo) reads the same messages' reactions in the
// same batch (SPL-1121), and ReactionsFor then answers from the memo.
func (s *Postgres) viewTopicDeliveries(ctx context.Context, tenant string, ids []string, idx map[string]int, out []ViewMsg) error {
	deliveries := tenantRead{sql: `SELECT msg_id::text, to_box, state FROM deliveries
		WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) ORDER BY msg_id, to_box`, args: []any{tenant, ids},
		each: func(rows pgx.Rows) error {
			var id string
			var d ViewDelivery
			if err := rows.Scan(&id, &d.ToBox, &d.State); err != nil {
				return err
			}
			if i, ok := idx[id]; ok {
				out[i].Deliveries = append(out[i].Deliveries, d)
			}
			return nil
		}}
	if memoFrom(ctx) == nil {
		return s.queryTenant(ctx, tenant, deliveries.sql, deliveries.args, deliveries.each)
	}
	reacts := map[string][]StoredReaction{}
	if err := s.queryTenantBatch(ctx, tenant, deliveries, reactionsRead(tenant, ids, reacts)); err != nil {
		return err
	}
	memoPutReactions(ctx, tenant, ids, reacts)
	return nil
}

// scanViewMsg reads one view row: msg_id, received_at, env, edited_at,
// edited_by, the revision, is_parent, typed_by, responsible, ref_task_id,
// mirror_of, the kind override and
// moveCols, after any lead columns (the batch's task_id). The register probe
// behind the revision is paid only by an edited row: an unedited one (the
// overwhelming majority) short-circuits on the NULL and costs nothing.
func scanViewMsg(rows pgx.Rows, lead ...any) (ViewMsg, error) {
	v := ViewMsg{Deliveries: []ViewDelivery{}}
	var editedBy, typedBy, responsible, refTask, mirrorOf, kindSetBy, mvBy, mvCh, mvTask, ch, task, parent *string
	var editedAt, kindSetAt, mvAt *time.Time
	var kind string
	dest := append(lead, &v.MsgID, &v.ReceivedAt, &v.Env, &editedAt, &editedBy, &v.Revision, &v.IsParent, &typedBy, &responsible,
		&refTask, &mirrorOf, &kind, &kindSetAt, &kindSetBy, &mvAt, &mvBy, &mvCh, &mvTask, &ch, &task, &parent)
	if err := rows.Scan(dest...); err != nil {
		return v, err
	}
	scanMove(&v.Move, mvAt, mvBy, mvCh, mvTask, ch, task, parent)
	v.RowChannel = deref(ch)
	v.TypedBy, v.EditedBy, v.Responsible = deref(typedBy), deref(editedBy), deref(responsible)
	v.RefTaskID, v.MirrorOf = deref(refTask), deref(mirrorOf)
	if kindSetAt != nil { // SPL-952: an override only once someone changed it
		v.Kind, v.KindSetAt, v.KindSetBy = kind, *kindSetAt, deref(kindSetBy)
	}
	if editedAt != nil {
		v.EditedAt = *editedAt
	}
	return v, nil
}

func (s *Postgres) ViewChannels(ctx context.Context, tenant string, now time.Time) ([]ChannelRow, error) {
	out := []ChannelRow{}
	err := s.queryTenant(ctx, tenant, `SELECT channel, count(*)::int, max(received_at) FROM messages
		WHERE tenant_id = $1 AND channel IS NOT NULL AND expires_at > $2
		GROUP BY channel ORDER BY channel`, []any{tenant, now}, func(rows pgx.Rows) error {
		var r ChannelRow
		if err := rows.Scan(&r.Channel, &r.Count, &r.LastAt); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
