package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

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

// sqlc accumulates bind parameters.
type sqlc struct{ args []any }

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
func (c *sqlc) tsq(t *search.Term) string {
	fn := "plainto_tsquery"
	if t.Phrase {
		fn = "phraseto_tsquery"
	}
	return fn + "('simple', " + c.arg(t.Value) + "::text)"
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
		return "m.search_tsv @@ " + c.tsq(t)
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
	const name = "lower(f.a->>'name')"
	const sized = "f.a->>'kind' = 'file' AND jsonb_typeof(f.a->'bytes') = 'number' AND (f.a->>'bytes')::bigint "
	switch t.Op {
	case search.OpText, search.OpName, search.OpFilename:
		return "strpos(" + name + ", lower(" + c.arg(t.Value) + "::text)) > 0"
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
		return "to_tsvector('simple', t.title) @@ " + c.tsq(t)
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
// (CLE-34985; it was inTenant's BEGIN / scope / budget / statement / COMMIT,
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

func (s *Postgres) SearchMessages(ctx context.Context, tenant string, q SearchQuery) ([]SearchMsgRow, error) {
	c := &sqlc{}
	t, now := c.arg(tenant), c.arg(q.Now)
	priv := "true"
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		// rdb 0028: a channel message is NOT automatically visible any more -
		// it must be a public default or one this reader belongs to.
		pub, mine := c.arg(DefaultChannels), c.arg(q.ViewerChannels)
		// A DM row is readable by ITS two ends (CLE-34986; it was: by an
		// end of any message of the task, so a search handed over another
		// member's DM that shared a task with one of yours).
		priv = `((m.channel IS NULL AND (m.from_id = ` + v + ` OR m.to_id = ` + v + `))
			OR m.channel = ANY(` + pub + `::text[]) OR m.channel = ANY(` + mine + `::text[]))`
	}
	where := c.cond(q.Q.Root, c.messageLeaf)
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
	var out []SearchMsgRow
	err := s.search(ctx, tenant, q, sql, c.args, func(rows pgx.Rows) error {
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

func (s *Postgres) SearchFiles(ctx context.Context, tenant string, q SearchQuery) ([]SearchFileRow, error) {
	c := &sqlc{}
	t, now := c.arg(tenant), c.arg(q.Now)
	priv := "true"
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		// rdb 0028: a channel message is NOT automatically visible any more -
		// it must be a public default or one this reader belongs to.
		pub, mine := c.arg(DefaultChannels), c.arg(q.ViewerChannels)
		// A DM row is readable by ITS two ends (CLE-34986; it was: by an
		// end of any message of the task, so a search handed over another
		// member's DM that shared a task with one of yours).
		priv = `((m.channel IS NULL AND (m.from_id = ` + v + ` OR m.to_id = ` + v + `))
			OR m.channel = ANY(` + pub + `::text[]) OR m.channel = ANY(` + mine + `::text[]))`
	}
	where := c.cond(q.Q.Root, c.fileLeaf)
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
	c := &sqlc{}
	t, now := c.arg(tenant), c.arg(q.Now)
	// The read door per MESSAGE, before the aggregate (CLE-34986): a topic's
	// title, parties, kinds and count come only from rows the viewer may read,
	// and a topic with none of them is not there. It was decided on the whole
	// topic, so a #lobby topic carrying a DM listed the DM's ends and count.
	door := ""
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		pub, mine := c.arg(DefaultChannels), c.arg(q.ViewerChannels)
		door = " AND ((channel IS NULL AND (from_id = " + v + " OR to_id = " + v + "))" +
			" OR channel = ANY(" + pub + "::text[]) OR channel = ANY(" + mine + "::text[]))"
	}
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

func (s *Postgres) TenantHumans(ctx context.Context, tenant string) ([]HumanEntry, error) {
	out := []HumanEntry{}
	err := s.queryTenant(ctx, tenant, `SELECT h.human_id, coalesce(h.display_name, ''), coalesce(h.avatar_file_id, '')
		FROM tenant_memberships m JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 AND h.disabled_at IS NULL`, []any{tenant}, func(rows pgx.Rows) error {
		var e HumanEntry
		if err := rows.Scan(&e.HumanID, &e.DisplayName, &e.AvatarFileID); err != nil {
			return err
		}
		out = append(out, e)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sortHumans(out)
	return out, nil
}
