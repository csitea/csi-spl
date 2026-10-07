package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// Postgres side of search (search.go). The parsed query is compiled to SQL
// whose only variable parts are bind parameters: every user string reaches
// Postgres as $n of plainto_tsquery / phraseto_tsquery / = / strpos — never
// concatenated, never to_tsquery, never a LIKE pattern (search-v1 §2.2).
// Every statement runs inside inTenant (RLS, 0014) and also says
// WHERE tenant_id; the statement_timeout is transaction-local.

// sqlc accumulates bind parameters. sig: messages.search_sig (rdb 0135) is
// there to check before a text match.
type sqlc struct {
	args []any
	sig  bool
}

func (c *sqlc) arg(v any) string {
	c.args = append(c.args, v)
	return "$" + strconv.Itoa(len(c.args))
}

// cond compiles n; leaf returns one term's predicate. Each leaf is wrapped in
// COALESCE(…, false) so NULL columns negate the way the memory store does.
func (c *sqlc) cond(n *search.Node, leaf func(*search.Term) string) string {
	if n == nil {
		return "true"
	}
	switch n.Kind {
	case search.Leaf:
		return "COALESCE((" + leaf(n.Term) + "), false)"
	case search.Not:
		return "NOT " + c.cond(n.Kids[0], leaf)
	}
	op := " AND "
	if n.Kind == search.Or {
		op = " OR "
	}
	parts := make([]string, len(n.Kids))
	for i, k := range n.Kids {
		parts[i] = c.cond(k, leaf)
	}
	return "(" + strings.Join(parts, op) + ")"
}

// tsq is the tsquery of a text / title: term.
// searchConfig is the text search configuration of the message index and of
// every query against it: rdb 0048's spool_search, the 'simple' parser behind
// unaccent (lower-cased, accents removed, never stemmed; one config for all
// 19 WUI locales).
const searchConfig = "'spool_search'"

// folded is the accent- and case-folded form of a name for substring
// matching: search.Fold's Postgres side (unaccent, rdb 0048).
func folded(expr string) string { return "lower(unaccent(" + expr + "))" }

func (c *sqlc) tsq(t *search.Term) string {
	fn := "plainto_tsquery"
	if t.Phrase {
		fn = "phraseto_tsquery"
	}
	if t.Prefix && !t.Phrase {
		// "deplo*": the user text still reaches SQL only as a bind parameter
		// of plainto_tsquery; ':*' is appended to ITS output (quoted, escaped
		// lexemes), so the last lexeme matches as a prefix. An empty tsquery
		// stays empty (numnode 0) instead of casting ':*'.
		p := "plainto_tsquery(" + searchConfig + ", " + c.arg(t.Value) + "::text)"
		return "(CASE WHEN numnode(" + p + ") = 0 THEN " + p + " ELSE (" + p + "::text || ':*')::tsquery END)"
	}
	return fn + "(" + searchConfig + ", " + c.arg(t.Value) + "::text)"
}

// textMatch is a text term's match on alias a's search_tsv, read only when
// a's lexeme signature (rdb 0135, search_sig) holds every lexeme of the term.
// The GIN cannot serve @@ under FORCE RLS (0122), so each row of the scan
// pays for its match; on a long body search_tsv is TOASTed, and the
// signature in the heap row lets most rows skip that read. A Bloom check has
// no false negatives, so the @@ still decides: the rows are the same. A
// prefix term's last lexeme is partial and cannot be signed: plain @@. A NULL
// signature (a short body, whose search_tsv is inline, or a long one the
// sweep has not signed yet) always goes on to the @@.
func (c *sqlc) textMatch(a string, t *search.Term) string {
	match := a + ".search_tsv @@ " + c.tsq(t)
	if !c.sig || (t.Prefix && !t.Phrase) {
		return match
	}
	mask := "(SELECT spool_search_sig(to_tsvector(" + searchConfig + ", " + c.arg(t.Value) + "::text)))"
	return "CASE WHEN " + a + ".search_sig IS NULL OR (" + a + ".search_sig & " + mask + ") = " + mask +
		" THEN " + match + " ELSE false END"
}

// sigAll is one signature check for every text term the whole query ANDs
// (the root, and AND groups under it): a row goes on to its matches only when
// its signature holds the lexemes of ALL of them. textMatch checks one term
// at a time, so a row that has the first word's bit (a common word: prd t1,
// "example" passed 705 of 3 277 signed rows) was read for that word's @@;
// all five of the owner's words pass 29. pred is wrapped, so the check runs
// first. pred unchanged when there is no signature, or fewer than two terms
// (textMatch already guards one).
func (c *sqlc) sigAll(a string, root *search.Node, pred string, ops ...string) string {
	if !c.sig {
		return pred
	}
	var words []string
	var walk func(n *search.Node)
	walk = func(n *search.Node) {
		switch {
		case n == nil:
		case n.Kind == search.And:
			for _, k := range n.Kids {
				walk(k)
			}
		case n.Kind == search.Leaf && slices.Contains(ops, n.Term.Op) && (n.Term.Phrase || !n.Term.Prefix):
			words = append(words, n.Term.Value)
		}
	}
	walk(root)
	if len(words) < 2 {
		return pred
	}
	mask := "(SELECT spool_search_sig(to_tsvector(" + searchConfig + ", " + c.arg(strings.Join(words, " ")) + "::text)))"
	return "CASE WHEN " + a + ".search_sig IS NULL OR (" + a + ".search_sig & " + mask + ") = " + mask +
		" THEN " + pred + " ELSE false END"
}

// candidateQuery is the tsquery the candidate probe (spec 100 section 5.1,
// spool_search_candidates($q, cap)) is called with: the text terms of the
// root's AND chain, the same walk as sigAll (never under an Or or a Not, never
// from Query.Positive, which holds both sides of an OR), joined with &&. A
// phrase keeps phraseto_tsquery; a prefix term carries ':*' (tsq). The values
// reach SQL only as bind parameters. false when the root has no such term
// (from:-only, OR-only, NOT-only): the caller keeps today's path. The outer
// @@ still decides, so the candidates only ever narrow the rows.
func (c *sqlc) candidateQuery(root *search.Node, ops ...string) (string, bool) {
	var tq []string
	var walk func(n *search.Node)
	walk = func(n *search.Node) {
		switch {
		case n == nil:
		case n.Kind == search.And:
			for _, k := range n.Kids {
				walk(k)
			}
		case n.Kind == search.Leaf && slices.Contains(ops, n.Term.Op):
			tq = append(tq, c.tsq(n.Term))
		}
	}
	walk(root)
	if len(tq) == 0 {
		return "", false
	}
	return "(" + strings.Join(tq, " && ") + ")", true
}

func (c *sqlc) party(idCol, boxCol string, t *search.Term) string {
	if t.Box != "" {
		return fmt.Sprintf("%s = %s AND %s = %s", idCol, c.arg(t.ID), boxCol, c.arg(t.Box))
	}
	a := c.arg(t.ID)
	return fmt.Sprintf("%s = %s OR %s = %s", idCol, a, boxCol, a)
}

func (c *sqlc) timeRange(col string, t *search.Term) string {
	var p []string
	if !t.From.IsZero() {
		p = append(p, col+" >= "+c.arg(t.From))
	}
	if !t.Until.IsZero() {
		p = append(p, col+" < "+c.arg(t.Until))
	}
	return strings.Join(p, " AND ")
}

// msgLeaf: the message-level predicates on alias m (messages, files).
func (c *sqlc) msgLeaf(t *search.Term) (string, bool) {
	switch t.Op {
	case search.OpFrom:
		return c.party("m.from_id", "m.from_box", t), true
	case search.OpTo:
		return c.party("m.to_id", "m.to_box", t), true
	case search.OpBox:
		a := c.arg(t.Box)
		return "m.from_box = " + a + " OR m.to_box = " + a, true
	case search.OpIn:
		if t.DM {
			return "m.channel IS NULL", true
		}
		return "m.channel = " + c.arg(t.Channel), true
	case search.OpTopic:
		return "m.task_id = " + c.arg(t.Value) + "::uuid", true
	case search.OpBefore, search.OpAfter, search.OpOn:
		return c.timeRange("m.received_at", t), true
	}
	return "", false
}

func (c *sqlc) messageLeaf(t *search.Term) string {
	if s, ok := c.msgLeaf(t); ok {
		return s
	}
	switch t.Op {
	case search.OpText:
		return c.textMatch("m", t)
	case search.OpIs:
		return "m.kind = " + c.arg(t.Enum)
	case search.OpHas:
		if t.Enum == "code" {
			return "left(m.body, 3) = '```' OR strpos(m.body, E'\\n```') > 0"
		}
		return "jsonb_array_length(m.files) > 0"
	}
	return "false"
}

func (c *sqlc) fileLeaf(t *search.Term) string {
	if s, ok := c.msgLeaf(t); ok {
		return s
	}
	name := folded("f.a->>'name'")
	const sized = "f.a->>'kind' = 'file' AND jsonb_typeof(f.a->'bytes') = 'number' AND (f.a->>'bytes')::bigint "
	switch t.Op {
	case search.OpText, search.OpName, search.OpFilename:
		return "strpos(" + name + ", " + folded(c.arg(t.Value)+"::text") + ") > 0"
	case search.OpExt:
		a := c.arg("." + t.Value)
		return "right(" + name + ", length(" + a + "::text)) = " + a + "::text"
	case search.OpLarger:
		return sized + "> " + c.arg(t.Size)
	case search.OpSmaller:
		return sized + "< " + c.arg(t.Size)
	}
	return "false"
}

// topicLeaf on alias t (the per-task aggregate) with live x for parties.
func (c *sqlc) topicLeaf(t *search.Term) string {
	exists := func(pred string) string {
		return "EXISTS (SELECT 1 FROM live x WHERE x.task_id = t.task_id AND (" + pred + "))"
	}
	switch t.Op {
	case search.OpText, search.OpTitle:
		return "to_tsvector(" + searchConfig + ", t.title) @@ " + c.tsq(t)
	case search.OpName:
		return "strpos(" + folded("t.title") + ", " + folded(c.arg(t.Value)+"::text") + ") > 0"
	case search.OpFrom:
		return exists(c.party("x.from_id", "x.from_box", t))
	case search.OpTo:
		return exists(c.party("x.to_id", "x.to_box", t))
	case search.OpBox:
		a := c.arg(t.Box)
		return exists("x.from_box = " + a + " OR x.to_box = " + a)
	case search.OpIn:
		if t.DM {
			return "t.channel = ''"
		}
		return "t.channel = " + c.arg(t.Channel)
	case search.OpIs:
		return "t.parent = ''"
	case search.OpTopic:
		return "t.task_id = " + c.arg(t.Value)
	case search.OpBefore, search.OpAfter, search.OpOn:
		return c.timeRange("t.last_at", t)
	}
	return "false"
}

// pgScopeTenantBudget is pgScopeTenant plus a transaction-local
// statement_timeout, in one statement.
const pgScopeTenantBudget = `SELECT set_config('app.tenant_id', $1, true), set_config('statement_timeout', $2, true)`

// search runs one statement in the tenant scope under the time budget: the
// scope, the budget and the statement go as ONE batch, so one round trip
// (it was inTenant's BEGIN / scope / budget / statement / COMMIT,
// five). A batch is one implicit transaction, so both settings end with it,
// exactly as they ended at inTenant's COMMIT.
func (s *Postgres) search(ctx context.Context, tenant string, q SearchQuery, sql string, args []any, each func(pgx.Rows) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	b := &pgx.Batch{}
	if q.Budget > 0 {
		b.Queue(pgScopeTenantBudget, tenant, strconv.FormatInt(max(q.Budget.Milliseconds(), 1), 10))
	} else {
		b.Queue(pgScopeTenant, tenant)
	}
	b.Queue(sql, args...)
	br := s.pool.SendBatch(ctx, b)
	_, err := br.Exec()
	if err == nil {
		var rows pgx.Rows
		if rows, err = br.Query(); err == nil {
			err = scanRows(rows, each)
		}
	}
	if cerr := br.Close(); err == nil {
		err = cerr
	}
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "57014" { // query_canceled: statement_timeout
		return ErrSearchBudget
	}
	return err
}

// hasSearchSig is the catalogue probe for rdb 0135. The hub may roll before
// the migration reaches its database (a trunk push deploys dev and prd
// together), so until the column is there a text match is the plain @@.
func (s *Postgres) hasSearchSig(ctx context.Context) bool {
	return s.sig.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('messages') AND attname = 'search_sig' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, time.Now())
}

// hasSearchIndex is the catalogue probe for rdb 0143: spool_search_candidates
// is there and this login may EXECUTE it (roles/runtime-grants.sql). Until
// then the message section takes the 0135 path.
func (s *Postgres) hasSearchIndex(ctx context.Context) bool {
	return s.idx.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT COALESCE(has_function_privilege(
			to_regprocedure('public.spool_search_candidates(tsquery, integer)'), 'EXECUTE'), false)`).Scan(&ok)
		return ok, err
	}, time.Now())
}

// searchIndexCap is the candidate probe's cap (spec 100 section 5.1, to be
// tuned in P4): at most cap ids filter the statement; cap + 1 means a common
// word, and today's backward scan fills a page fast exactly then.
const searchIndexCap = 500

// candidateProbeSQL is the probe of one message page: the candidate ids of
// the root's AND-chain text terms, at most cap + 1 of them. false: no probe,
// today's path (the kill switch, or no such term).
func candidateProbeSQL(q SearchQuery, limit int) (string, []any, bool) {
	if q.ScanOnly || q.Q == nil {
		return "", nil, false
	}
	c := &sqlc{}
	tq, ok := c.candidateQuery(q.Q.Root, search.OpText)
	if !ok {
		return "", nil, false
	}
	return "SELECT msg_id::text FROM spool_search_candidates(" + tq + ", " + c.arg(limit) + ")", c.args, true
}

// searchCandidates runs the probe once for the page and returns the ids the
// statement filters by; nil keeps today's statement unchanged: no probe, or
// cap + 1 ids (a truncated set, an arbitrary subset: the id filter is never
// applied to it).
func (s *Postgres) searchCandidates(ctx context.Context, tenant string, q SearchQuery, limit int) ([]string, error) {
	sql, args, ok := candidateProbeSQL(q, limit)
	if !ok || !s.hasSearchIndex(ctx) {
		return nil, nil
	}
	ids := []string{}
	err := s.search(ctx, tenant, q, sql, args, func(rows pgx.Rows) error {
		var id string
		if err := rows.Scan(&id); err != nil {
			return err
		}
		ids = append(ids, id)
		return nil
	})
	if err != nil || len(ids) > limit {
		return nil, err
	}
	return ids, nil
}

// SearchMessages is one probe, then one statement (spec 100 section 5.1):
// the hub branches between the two, so a write in between cannot switch the
// path mid-page. Order, keyset, LIMIT and every predicate stay in the
// statement; the candidate ids only narrow it, and the outer @@ decides.
func (s *Postgres) SearchMessages(ctx context.Context, tenant string, q SearchQuery) ([]SearchMsgRow, error) {
	ids, err := s.searchCandidates(ctx, tenant, q, searchIndexCap)
	if err != nil {
		return nil, err
	}
	sql, args := searchMessagesSQL(tenant, q, s.hasSearchSig(ctx), ids)
	var out []SearchMsgRow
	err = s.search(ctx, tenant, q, sql, args, func(rows pgx.Rows) error {
		var r SearchMsgRow
		if err := rows.Scan(&r.MsgID, &r.TaskID, &r.Parent, &r.Channel, &r.Kind, &r.Body, &r.FromID, &r.FromBox,
			&r.ToID, &r.ToBox, &r.TS, &r.ReceivedAt, &r.Files); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	return out, err
}

// searchMessagesSQL is SearchMessages' statement and its bind parameters;
// sig: check search_sig before each text match; ids (non-nil): the candidate
// ids of the probe, at most cap of them, which the statement adds as
// AND m.msg_id = ANY(ids) and nothing else changes.
func searchMessagesSQL(tenant string, q SearchQuery, sig bool, ids []string) (string, []any) {
	c := &sqlc{sig: sig}
	t, now := c.arg(tenant), c.arg(q.Now)
	priv := "true"
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		// rdb 0028: a channel message is NOT automatically visible any more -
		// it must be a public default or one this reader belongs to.
		pub, mine := c.arg(PublicChannels), c.arg(q.ViewerChannels)
		// A DM row is readable by ITS two ends (it was: by an
		// end of any message of the task, so a search handed over another
		// member's DM that shared a task with one of yours).
		priv = `((m.channel IS NULL AND (m.from_id = ` + v + ` OR m.to_id = ` + v + `))
			OR m.channel = ANY(` + pub + `::text[]) OR m.channel = ANY(` + mine + `::text[]))`
	}
	where := "(" + c.sigAll("m", q.Q.Root, c.cond(q.Q.Root, c.messageLeaf), search.OpText) + ")" + archivedHideSQL("m", t, c.arg(q.Lobby))
	if ids != nil {
		where += " AND m.msg_id = ANY(" + c.arg(ids) + "::uuid[])"
	}
	order, page := "ORDER BY m.received_at DESC, m.msg_id::text DESC", ""
	if q.Relevance {
		var tq []string
		for _, term := range q.Q.Positive {
			if term.Op == search.OpText {
				tq = append(tq, c.tsq(term))
			}
		}
		rank := "0"
		if len(tq) > 0 {
			rank = "ts_rank_cd(m.search_tsv, " + strings.Join(tq, " || ") + ")"
		}
		order = "ORDER BY " + rank + " DESC, m.received_at DESC, m.msg_id::text DESC OFFSET " + c.arg(q.Offset)
	} else if !q.AfterAt.IsZero() {
		page = " AND (m.received_at, m.msg_id::text) < (" + c.arg(q.AfterAt) + "::timestamptz, " + c.arg(q.AfterID) + "::text)"
	}
	sql := `SELECT m.msg_id::text, m.task_id::text, COALESCE(m.parent_task_id::text, ''), COALESCE(m.channel, ''),
			m.kind, m.body, m.from_id, m.from_box, m.to_id, m.to_box, m.ts, m.received_at, jsonb_array_length(m.files)
		FROM messages m
		WHERE m.tenant_id = ` + t + ` AND m.expires_at > ` + now + ` AND ` + priv + ` AND ` + where + page + `
		` + order + ` LIMIT ` + c.arg(pgLimit(q.Limit))
	return sql, c.args
}

func (s *Postgres) SearchFiles(ctx context.Context, tenant string, q SearchQuery) ([]SearchFileRow, error) {
	c := &sqlc{}
	t, now := c.arg(tenant), c.arg(q.Now)
	priv := "true"
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		// rdb 0028: a channel message is NOT automatically visible any more -
		// it must be a public default or one this reader belongs to.
		pub, mine := c.arg(PublicChannels), c.arg(q.ViewerChannels)
		// A DM row is readable by ITS two ends (it was: by an
		// end of any message of the task, so a search handed over another
		// member's DM that shared a task with one of yours).
		priv = `((m.channel IS NULL AND (m.from_id = ` + v + ` OR m.to_id = ` + v + `))
			OR m.channel = ANY(` + pub + `::text[]) OR m.channel = ANY(` + mine + `::text[]))`
	}
	where := "(" + c.cond(q.Q.Root, c.fileLeaf) + ")" + archivedHideSQL("m", t, c.arg(q.Lobby))
	page := ""
	if !q.AfterAt.IsZero() {
		at, id := c.arg(q.AfterAt), c.arg(q.AfterID)
		page = " AND ((m.received_at, m.msg_id::text) < (" + at + "::timestamptz, " + id + "::text) OR (m.received_at = " + at +
			"::timestamptz AND m.msg_id::text = " + id + "::text AND f.i > " + c.arg(q.AfterIdx) + "))"
	}
	sql := `SELECT m.msg_id::text, m.task_id::text, COALESCE(m.parent_task_id::text, ''), COALESCE(m.channel, ''),
			m.kind, m.from_id, m.from_box, m.to_id, m.to_box, m.received_at, jsonb_array_length(m.files), f.i::int, f.a
		FROM messages m CROSS JOIN LATERAL jsonb_array_elements(
			CASE WHEN jsonb_typeof(m.files) = 'array' THEN m.files ELSE '[]'::jsonb END) WITH ORDINALITY AS f(a, i)
		WHERE m.tenant_id = ` + t + ` AND m.expires_at > ` + now + ` AND ` + priv + ` AND ` + where + page + `
		ORDER BY m.received_at DESC, m.msg_id::text DESC, f.i
		LIMIT ` + c.arg(pgLimit(q.Limit))
	var out []SearchFileRow
	err := s.search(ctx, tenant, q, sql, c.args, func(rows pgx.Rows) error {
		var r SearchFileRow
		var raw []byte
		m := &r.File.Msg
		if err := rows.Scan(&m.MsgID, &m.TaskID, &m.Parent, &m.Channel, &m.Kind, &m.FromID, &m.FromBox,
			&m.ToID, &m.ToBox, &m.ReceivedAt, &m.Files, &r.Idx, &raw); err != nil {
			return err
		}
		var f fileRef
		if err := json.Unmarshal(raw, &f); err != nil {
			return err
		}
		r.Name, r.Kind, r.FileID, r.Mode = f.Name, f.Kind, f.FileID, f.Mode
		if f.Bytes != nil {
			r.Bytes, r.HasBytes = *f.Bytes, true
		}
		out = append(out, r)
		return nil
	})
	return out, err
}

func (s *Postgres) SearchTopics(ctx context.Context, tenant string, q SearchQuery) ([]SearchTopicRow, error) {
	c := &sqlc{sig: s.hasSearchSig(ctx)}
	t, now := c.arg(tenant), c.arg(q.Now)
	// The read door per MESSAGE, before the aggregate: a topic's
	// title, parties, kinds and count come only from rows the viewer may read,
	// and a topic with none of them is not there. It was decided on the whole
	// topic, so a #lobby topic carrying a DM listed the DM's ends and count.
	door := ""
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		pub, mine := c.arg(PublicChannels), c.arg(q.ViewerChannels)
		door = " AND ((channel IS NULL AND (from_id = " + v + " OR to_id = " + v + "))" +
			" OR channel = ANY(" + pub + "::text[]) OR channel = ANY(" + mine + "::text[]))"
	}
	door += archivedHideSQL("messages", t, c.arg(q.Lobby)) // specs/041
	door += c.topicCandidates(q.Q.Root, t, now)
	where := c.cond(q.Q.Root, c.topicLeaf)
	page := ""
	if !q.AfterAt.IsZero() {
		page = " AND (t.last_at, t.task_id) < (" + c.arg(q.AfterAt) + "::timestamptz, " + c.arg(q.AfterID) + "::text)"
	}
	const first = " ORDER BY received_at, msg_id)"
	sql := `WITH live AS (
			SELECT task_id::text AS task_id, msg_id::text AS msg_id, received_at, kind, from_id, from_box, to_id, to_box,
				COALESCE(channel, '') AS channel, COALESCE(parent_task_id::text, '') AS parent, body, msg
			FROM messages WHERE tenant_id = ` + t + ` AND expires_at > ` + now + door + `
		), t AS (
			SELECT task_id,
				(array_agg(channel` + first + `)[1] AS channel,
				(array_agg(parent` + first + `)[1] AS parent,
				left(btrim(split_part((array_agg(body` + first + `)[1], E'\n', 1)), 140) AS title,
				min(received_at) AS first_at, max(received_at) AS last_at, count(*)::int AS n,
				array_agg(kind` + first + ` AS kinds,
				array_agg(from_id || '@' || from_box) || array_agg(to_id || '@' || to_box) AS parties,
				(array_agg(msg` + first + `)[1] AS first_msg
			FROM live GROUP BY task_id
		)
		SELECT task_id, channel, parent, title, first_at, last_at, n, kinds, parties, first_msg FROM t
		WHERE ` + where + page + `
		ORDER BY last_at DESC, task_id DESC
		LIMIT ` + c.arg(pgLimit(q.Limit))
	var out []SearchTopicRow
	err := s.search(ctx, tenant, q, sql, c.args, func(rows pgx.Rows) error {
		var r SearchTopicRow
		if err := rows.Scan(&r.TaskID, &r.Channel, &r.Parent, &r.Title, &r.FirstAt, &r.LastAt, &r.Count,
			&r.Kinds, &r.Parties, &r.FirstMsg); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	return out, err
}

// topicCandidates narrows the topic aggregate to the tasks the message index
// can name (specs/022 §9 measures it). A topic's title and channel
// are its FIRST message's, so a topic matching a top-level positive text /
// title: / in: term has one message matching all of them: only those tasks
// are aggregated, not every live message of the tenant. The final WHERE still
// decides on the aggregate, so this only drops rows it would have dropped
// (bar a word cut at the 140-character title edge). "" when the query has no
// such term (an OR, a negation, from: only): the full aggregate, as before.
func (c *sqlc) topicCandidates(root *search.Node, tenant, now string) string {
	kids := []*search.Node{root}
	if root != nil && root.Kind == search.And {
		kids = root.Kids
	}
	var preds []string
	for _, k := range kids {
		if k == nil || k.Kind != search.Leaf {
			continue
		}
		switch t := k.Term; t.Op {
		case search.OpText, search.OpTitle:
			preds = append(preds, c.textMatch("k", t))
		case search.OpIn:
			if t.DM {
				preds = append(preds, "k.channel IS NULL")
			} else {
				preds = append(preds, "k.channel = "+c.arg(t.Channel))
			}
		}
	}
	if len(preds) == 0 {
		return ""
	}
	return " AND task_id IN (SELECT k.task_id FROM messages k WHERE k.tenant_id = " + tenant +
		" AND k.expires_at > " + now + " AND " + c.sigAll("k", root, "("+strings.Join(preds, " AND ")+")", search.OpText, search.OpTitle) + ")"
}

func (s *Postgres) TenantHumans(ctx context.Context, tenant string) ([]HumanEntry, error) {
	out := []HumanEntry{}
	cols, join, args := "", "", []any{tenant}
	if s.hasHumanStatus(ctx) { // spec 096: the live status in the same statement
		cols = ", st.status, coalesce(st.note, ''), st.until_at"
		join = ` LEFT JOIN human_status st ON st.tenant_id = m.tenant_id AND st.human_id = m.human_id
			AND (st.until_at IS NULL OR st.until_at > $2)`
		args = append(args, s.now())
	}
	err := s.queryTenant(ctx, tenant, `SELECT h.human_id, coalesce(h.display_name, ''), coalesce(h.avatar_file_id, '')`+cols+`
		FROM tenant_memberships m JOIN humans h ON h.human_id = m.human_id`+join+`
		WHERE m.tenant_id = $1 AND h.disabled_at IS NULL AND NOT h.technical`, args, func(rows pgx.Rows) error {
		var e HumanEntry
		if cols == "" {
			if err := rows.Scan(&e.HumanID, &e.DisplayName, &e.AvatarFileID); err != nil {
				return err
			}
			out = append(out, e)
			return nil
		}
		return scanHumanEntryStatus(rows, &e, &out)
	})
	if err != nil {
		return nil, err
	}
	sortHumans(out)
	return out, nil
}

// scanHumanEntryStatus scans a TenantHumans row that carries the status
// columns; a NULL status is available.
func scanHumanEntryStatus(rows pgx.Rows, e *HumanEntry, out *[]HumanEntry) error {
	var state *string
	var note string
	var until *time.Time
	if err := rows.Scan(&e.HumanID, &e.DisplayName, &e.AvatarFileID, &state, &note, &until); err != nil {
		return err
	}
	if state != nil {
		e.Status = &HumanStatus{HumanID: e.HumanID, State: *state, Note: note}
		if until != nil {
			e.Status.Until = until.UTC()
		}
	}
	*out = append(*out, *e)
	return nil
}
