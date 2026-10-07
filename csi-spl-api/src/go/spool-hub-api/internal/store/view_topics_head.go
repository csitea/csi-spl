package store

import (
	"context"
	"sort"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
)

// Spec 099 phase 1, T005: the topic list read from the stored heads (rdb
// 0144) instead of the walk over messages (viewTopicsSQL). One head row per
// topic and one part row per channel or DM pair hold the walk key, so a list
// walks ONE index in key order and stops at LIMIT; today's summary() then
// reads messages for the listed topics only, so every column but the key is
// the walk's own code.
//
// SPOOL_HUB_TOPIC_HEADS (spec 5.1) is the hub's; the store only knows whether
// to serve the head read (SetTopicHeads: on). It serves it only when the
// tables exist (headTables) and the tenant's backfill mark is set
// (topic_head_tenants, spec 3.3), so a topic with no head row never vanishes:
// until then the read is the walk. The since= delta (TaskIDs) stays on the
// walk in phase 1 (Q5).

// topicHeads is the store half of the switch.
type topicHeads struct {
	on    atomic.Bool
	table seatsProbe // is rdb 0144 topic_heads there yet
}

// TopicHeadsTestAll is for tests only (SPOOL_TEST_TOPIC_HEADS=on): every
// Postgres store serves the head read and counts every tenant as backfilled,
// so the existing view tests run in `on`. A tenant created after rdb 0144
// has a head for every topic (the triggers keep them), so that is exact on a
// test database; never set it against a database that predates 0144.
var TopicHeadsTestAll bool

// SetTopicHeads switches the head read on (true) or back to the walk. The hub
// sets it from SPOOL_HUB_TOPIC_HEADS=on; off and shadow serve the walk.
func (s *Postgres) SetTopicHeads(on bool) { s.heads.on.Store(on) }

// headTables is the rdb 0144 probe (seatsProbe: seen once, kept).
func (s *Postgres) headTables(ctx context.Context) bool {
	return s.heads.table.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT to_regclass('topic_heads') IS NOT NULL`).Scan(&ok)
		return ok, err
	}, s.now())
}

// headsServe: q is answered from the heads, once its tenant is marked.
func (s *Postgres) headsServe(ctx context.Context, q TopicQuery) bool {
	return (s.heads.on.Load() || TopicHeadsTestAll) && len(q.TaskIDs) == 0 && s.headTables(ctx)
}

// pgScopeTenantHeads is the head read's own batch header (spec 5.2): the
// tenant, jit off and a custom plan on every run, as pgScopeTenantNoJIT and
// for the same reasons. Sorts and bitmap scans stay allowed: the head walk is
// not recursive, so a misestimate costs at most one pass over the heads.
// T005's A/B (TestTopicHeadHeaderAB, n=20, 20k and 200k messages, swept):
// with sort off, children took 214 ms and a DM page of a reader in no DM
// 98 ms at 200k, against 11 and 15 ms with it on; prd's DM pages are mostly
// that shape (485 of 489 DM ends have fewer than 50 DM topics, spec 5.2).
// The channel walk is the exception, pgScopeTenantHeadsNoSort. Both are set
// explicitly: the shadow runs this header after the walk's in one
// transaction, where the walk's settings would otherwise still hold.
const pgScopeTenantHeads = pgScopeTenantHeadsBase + `, set_config('enable_sort', 'on', true)`

// pgScopeTenantHeadsNoSort is the channel walk's header: with sorts allowed
// the planner sorted the whole channel's parts (200k messages: 40 ms against
// 14 ms for the ordered scan of topic_head_parts_channel; equal at 20k).
const pgScopeTenantHeadsNoSort = pgScopeTenantHeadsBase + `, set_config('enable_sort', 'off', true)`

const pgScopeTenantHeadsBase = `SELECT set_config('app.tenant_id', $1, true), set_config('jit', 'off', true),
	set_config('plan_cache_mode', 'force_custom_plan', true), set_config('enable_bitmapscan', 'on', true)`

// headHeader is q's batch header (the A/B's choice per shape).
func headHeader(q TopicQuery) string {
	if q.Channel != "" {
		return pgScopeTenantHeadsNoSort
	}
	return pgScopeTenantHeads
}

// headMarkSQL: has the backfill passed all of the tenant (spec 3.3).
const headMarkSQL = `SELECT EXISTS (SELECT 1 FROM topic_head_tenants WHERE tenant_id = $1 AND backfilled_at IS NOT NULL)`

// headRead is one head read's statements, queued on a batch and read back.
type headRead struct {
	tenant          string
	marked          bool // skip the mark probe (TopicHeadsTestAll)
	limit           int
	header          string
	headSQL, dueSQL string
	headArgs        []any
	dueArgs         []any
	head, due       []TopicRow
}

func newHeadRead(tenant string, q TopicQuery, marked bool) *headRead {
	r := &headRead{tenant: tenant, marked: marked, header: headHeader(q), limit: pgLimit(q.Limit)}
	r.headSQL, r.headArgs = viewTopicsHeadSQL(tenant, q)
	r.dueSQL, r.dueArgs = viewTopicsDueSQL(tenant, q)
	return r
}

// queue adds the header, the mark probe, the head walk and the due statement.
func (r *headRead) queue(b *pgx.Batch) {
	b.Queue(r.header, r.tenant)
	if !r.marked {
		b.Queue(headMarkSQL, r.tenant)
	}
	b.Queue(r.headSQL, r.headArgs...)
	b.Queue(r.dueSQL, r.dueArgs...)
}

// read reads back what queue sent, in order. It reports whether the tenant is
// marked; if not, the rows are no answer and the caller walks.
func (r *headRead) read(br pgx.BatchResults) (bool, error) {
	if _, err := br.Exec(); err != nil {
		return false, err
	}
	marked := r.marked
	if !marked {
		if err := br.QueryRow().Scan(&marked); err != nil {
			return false, err
		}
	}
	for _, out := range []*[]TopicRow{&r.head, &r.due} {
		rows, err := br.Query()
		if err != nil {
			return false, err
		}
		if err := scanRows(rows, scanTopicRows(out)); err != nil {
			return false, err
		}
	}
	return marked, nil
}

// rows is the page: the head walk and the due heads merged in the list order
// (last_at DESC, task_id DESC; uuid text order is uuid order, spec 5.2), cut
// at the limit (spec 5.3).
func (r *headRead) rows() []TopicRow {
	if len(r.due) == 0 {
		return r.head
	}
	out := append(append([]TopicRow{}, r.head...), r.due...)
	sort.SliceStable(out, func(i, j int) bool {
		if !out[i].LastAt.Equal(out[j].LastAt) {
			return out[i].LastAt.After(out[j].LastAt)
		}
		return out[i].TaskID > out[j].TaskID
	})
	if len(out) > r.limit {
		out = out[:r.limit]
	}
	return out
}

// viewTopicsHeads is ViewTopics from the heads: one round trip once the
// tenant is marked; before that the head batch, then the walk.
func (s *Postgres) viewTopicsHeads(ctx context.Context, tenant string, q TopicQuery) ([]TopicRow, error) {
	rows, served, err := s.headTopics(ctx, tenant, q, TopicHeadsTestAll)
	if err != nil || served {
		return rows, err
	}
	return s.walkTopicRows(ctx, tenant, q)
}

// walkTopicRows is the walk alone (viewTopicsSQL), as ViewTopics runs it.
func (s *Postgres) walkTopicRows(ctx context.Context, tenant string, q TopicQuery) ([]TopicRow, error) {
	sql, args := viewTopicsSQL(tenant, q)
	var out []TopicRow
	err := s.queryTenantNoJIT(ctx, tenant, sql, args, scanTopicRows(&out))
	return out, err
}

// headTopics runs the head read alone; served false = the tenant has no
// backfill mark yet (marked skips that probe).
func (s *Postgres) headTopics(ctx context.Context, tenant string, q TopicQuery, marked bool) ([]TopicRow, bool, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, false, err
	}
	r := newHeadRead(tenant, q, marked)
	b := &pgx.Batch{}
	r.queue(b)
	br := s.pool.SendBatch(ctx, b)
	defer br.Close()
	served, err := r.read(br)
	if err != nil {
		return nil, false, err
	}
	if err := br.Close(); err != nil {
		return nil, false, err
	}
	return r.rows(), served, nil
}

// cloneGateSQL is ViewTopicsUnlessClone's gate: reader is a live act-as clone.
const cloneGateSQL = `SELECT EXISTS (SELECT 1 FROM member_clones
		WHERE tenant_id = $1 AND clone_hum = $2 AND ended_at IS NULL)`

// viewTopicsHeadsUnlessClone is ViewTopicsUnlessClone from the heads: the
// clone gate rides the head read's batch, as it rides the walk's.
func (s *Postgres) viewTopicsHeadsUnlessClone(ctx context.Context, tenant, reader string, q TopicQuery) ([]TopicRow, bool, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, false, err
	}
	r := newHeadRead(tenant, q, TopicHeadsTestAll)
	b := &pgx.Batch{}
	r.queue(b)
	b.Queue(cloneGateSQL, tenant, reader)
	br := s.pool.SendBatch(ctx, b)
	defer br.Close()
	served, err := r.read(br)
	if err != nil {
		return nil, false, err
	}
	var clone bool
	if err := br.QueryRow().Scan(&clone); err != nil {
		return nil, false, err
	}
	if err := br.Close(); err != nil {
		return nil, false, err
	}
	switch {
	case clone:
		return nil, true, nil
	case served:
		return r.rows(), false, nil
	}
	rows, err := s.walkTopicRows(ctx, tenant, q) // no backfill mark yet
	return rows, false, err
}

// ViewTopicsShadow is the shadow's pair (spec 5.1): the walk and the head
// read of q in ONE REPEATABLE READ READ ONLY transaction, so both see one
// snapshot and a send committed between them is no mismatch. ok false = the
// head read does not apply (no tables, no backfill mark, a since= delta):
// head is then nil and walk is the answer alone.
func (s *Postgres) ViewTopicsShadow(ctx context.Context, tenant string, q TopicQuery) (walk, head []TopicRow, ok bool, err error) {
	if err := checkTenant(tenant); err != nil {
		return nil, nil, false, err
	}
	if q.Parent != "" && !canonUUIDRe.MatchString(q.Parent) {
		return nil, nil, false, nil
	}
	if len(q.TaskIDs) > 0 || !s.headTables(ctx) {
		walk, err = s.walkTopicRows(ctx, tenant, q)
		return walk, nil, false, err
	}
	r := newHeadRead(tenant, q, false)
	err = pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly},
		func(tx pgx.Tx) error {
			walk, ok, err = shadowBatch(ctx, tx, tenant, q, r)
			return err
		})
	if err != nil || !ok {
		return walk, nil, false, err
	}
	return walk, r.rows(), true, nil
}

// shadowBatch sends the walk (its own header) and then r (the head header)
// as one batch inside tx; ok = the tenant is marked.
func shadowBatch(ctx context.Context, tx pgx.Tx, tenant string, q TopicQuery, r *headRead) (walk []TopicRow, ok bool, err error) {
	sql, args := viewTopicsSQL(tenant, q)
	b := &pgx.Batch{}
	b.Queue(pgScopeTenantNoJIT, tenant)
	b.Queue(sql, args...)
	r.queue(b)
	br := tx.SendBatch(ctx, b)
	defer br.Close()
	if _, err := br.Exec(); err != nil {
		return nil, false, err
	}
	rows, err := br.Query()
	if err != nil {
		return nil, false, err
	}
	if err := scanRows(rows, scanTopicRows(&walk)); err != nil {
		return nil, false, err
	}
	if ok, err = r.read(br); err != nil {
		return nil, false, err
	}
	return walk, ok, br.Close()
}

// headShape is the walked index of q (spec 5.2): the channel's parts, the DM
// heads, or every head. from is the table (alias l), key the order column,
// where the tenant, shape and "not due" filters, dueSrc the due set's ids.
type headShape struct {
	from, key, where, dueSrc string
}

// shape builds q's walk source on b (b.tn, b.now: the tenant and clock). A
// part whose latest line has not expired keeps its key and its door (spec
// 3.2); a head with valid_until > now has every part so. A channel list needs
// its own part only; DM and all need the whole head.
func (b *topicsSQL) shape() headShape {
	due := " AND h.valid_until <= " + b.now
	switch {
	case b.q.Channel != "":
		ch := b.c.arg(b.q.Channel)
		where := "l.tenant_id = " + b.tn + " AND l.channel = " + ch
		if b.q.DM { // channel and DM: no line passes both
			where += " AND false"
		}
		return headShape{from: "topic_head_parts", key: "l.last_at", where: where + " AND l.valid_until > " + b.now,
			dueSrc: "SELECT h.task_id FROM topic_head_parts h WHERE h.tenant_id = " + b.tn + " AND h.channel = " + ch + due}
	case b.q.DM:
		return headShape{from: "topic_heads", key: "l.dm_last_at",
			where:  "l.tenant_id = " + b.tn + " AND l.dm_last_at IS NOT NULL AND l.valid_until > " + b.now,
			dueSrc: "SELECT h.task_id FROM topic_heads h WHERE h.tenant_id = " + b.tn + " AND h.dm_last_at IS NOT NULL" + due}
	}
	return headShape{from: "topic_heads", key: "l.last_at", where: "l.tenant_id = " + b.tn + " AND l.valid_until > " + b.now,
		dueSrc: "SELECT h.task_id FROM topic_heads h WHERE h.tenant_id = " + b.tn + due}
}

// headArchived is the archived hide on the head (spec 2): the card rule and
// any archived row outside the lobby, expired or not, as
// archivedTopicHideSQL reads it from messages. The channel walk reads the
// head by its primary key (claude-2 F10).
func (b *topicsSQL) headArchived(sh headShape, lobby string) string {
	keep := func(a string) string {
		return "NOT " + a + ".card_archived AND (" + a + ".archived_rows = 0 OR " + a + ".task_id::text = " + lobby + ")"
	}
	if sh.from == "topic_heads" {
		return " AND " + keep("l")
	}
	return " AND (SELECT " + keep("h") + " FROM topic_heads h WHERE h.tenant_id = " + b.tn + " AND h.task_id = l.task_id)"
}

// headDoor is the read door over the topic's parts (spec 2: a part is all
// visible or all hidden, so the door per part is the door per line), and
// aggDoor the same rule per line for summary(), as readerDoor's.
func (b *topicsSQL) headDoor(sh headShape) (walk, aggDoor string) {
	if b.q.Reader == "" {
		return "", ""
	}
	rd, pub, mine := b.c.arg(b.q.Reader), b.c.arg(PublicChannels), b.c.arg(b.q.ReaderChannels)
	aggDoor = " AND (m.channel = ANY(" + pub + "::text[]) OR m.channel = ANY(" + mine + "::text[]) OR " +
		"(m.channel IS NULL AND (m.from_id = " + rd + " OR m.to_id = " + rd + ")))"
	if sh.from == "topic_head_parts" {
		return " AND (l.channel = ANY(" + pub + "::text[]) OR l.channel = ANY(" + mine + "::text[]))", aggDoor
	}
	dm := "(d.channel IS NULL AND (d.dm_a = " + rd + " OR d.dm_b = " + rd + "))"
	door := "d.channel = ANY(" + pub + "::text[]) OR d.channel = ANY(" + mine + "::text[]) OR " + dm
	if b.q.DM {
		door = dm
	}
	return " AND EXISTS (SELECT 1 FROM topic_head_parts d WHERE d.tenant_id = " + b.tn +
		" AND d.task_id = l.task_id AND (" + door + "))", aggDoor
}

// headViewer answers dm=true + Viewer from the DM parts' ends (spec 2: some
// DM line is from or to v exactly when some DM part has v as an end) and
// clears b.q.Viewer so walkParties adds no messages probe for it. When the
// reader is the viewer (the hub's dm=true), headDoor already says the same.
func (b *topicsSQL) headViewer() string {
	v := b.q.Viewer
	if !b.q.DM || v == "" {
		return ""
	}
	b.q.Viewer = ""
	if v == b.q.Reader {
		return ""
	}
	a := b.c.arg(v)
	return " AND EXISTS (SELECT 1 FROM topic_head_parts e WHERE e.tenant_id = " + b.tn +
		" AND e.task_id = l.task_id AND e.channel IS NULL AND (e.dm_a = " + a + " OR e.dm_b = " + a + "))"
}

// viewTopicsHeadSQL is the head walk (spec 5.2) plus today's summary(): one
// ordered index scan of the shape's heads, filtered by the door, the archived
// hide, today's per-topic probes (agent, viewer, roots, parent, NoIssues) and
// the cursor, stopped at LIMIT. A due head (a key line expired) is not
// walked: viewTopicsDueSQL reads it the exact old way. The cursor's index
// condition is the key alone; the (key, task_id::text) pair is a filter, so a
// non-canonical before= id never meets a ::uuid cast.
func viewTopicsHeadSQL(tenant string, q TopicQuery) (string, []any) {
	b := &topicsSQL{c: &sqlc{}, q: q}
	b.tn, b.now = b.c.arg(tenant), b.c.arg(q.Now)
	sh := b.shape()
	door, aggDoor := b.headDoor(sh)
	walk := sh.where + door + b.headArchived(sh, b.c.arg(q.Lobby))
	walk += b.headViewer() // before walkParties: it takes the DM viewer off b.q
	walk += b.walkParties() + b.walkTree()
	if !q.BeforeAt.IsZero() {
		at := b.c.arg(q.BeforeAt)
		walk += " AND " + sh.key + " <= " + at + " AND (" + sh.key + ", l.task_id::text) < (" + at + ", " + b.c.arg(q.BeforeTask) + ")"
	}
	return `WITH w (task_id, received_at) AS (
			SELECT l.task_id, ` + sh.key + ` FROM ` + sh.from + ` l
			WHERE ` + walk + `
			ORDER BY ` + sh.key + ` DESC, l.task_id DESC LIMIT ` + b.c.arg(pgLimit(q.Limit)) + `
		)` + b.summary(aggDoor), b.c.args
}

// viewTopicsDueSQL is the due heads' second statement (spec 5.3): today's
// listed() walk - every filter and the cursor, on each topic's own
// messages_task_received range - fed by the shape's due heads instead of the
// since= ids, cut to the page's limit BEFORE summary(), so the aggregate runs
// for at most one page of due topics (the A/B seed, 798 due heads at 200k
// messages: 49 ms without the cut). About no topic on prd today (a flat
// ~30 d TTL); exact whatever expired.
func viewTopicsDueSQL(tenant string, q TopicQuery) (string, []any) {
	b := &topicsSQL{c: &sqlc{}, q: q}
	b.tn, b.now = b.c.arg(tenant), b.c.arg(q.Now)
	src := b.shape().dueSrc
	walk := b.walkLatest() + b.walkParties()
	door, aggDoor := b.readerDoor()
	walk += door + b.walkTree() + archivedTopicHideSQL("l", b.tn, b.c.arg(q.Lobby))
	return `WITH d (task_id, received_at) AS (
			SELECT l.task_id, l.received_at FROM (` + src + `) AS t (id) CROSS JOIN LATERAL (
				SELECT l.task_id, l.received_at FROM messages l
				WHERE ` + walk + ` AND l.task_id = t.id ORDER BY l.received_at DESC LIMIT 1
			) l
		), w (task_id, received_at) AS (
			SELECT d.task_id, d.received_at FROM d
			ORDER BY d.received_at DESC, d.task_id::text DESC LIMIT ` + b.c.arg(pgLimit(q.Limit)) + `
		)` + b.summary(aggDoor), b.c.args
}
