package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// The file_line section of search (spec 160 3.6, row B4, SPL-3888): the lines
// of the workspace's own box file streams (rdb 0237), matched with the same
// spool_search entry as a message body. Who may see a hit is the hub's (the
// owner or an admin, the read routes' gate, hub/file_streams_view.go); this
// statement is pinned to the tenant on both tables, so it never reads another
// workspace's lines.

// SearchFileLineRow is one matching file stream line.
type SearchFileLineRow struct {
	StreamID  string
	BoxID     string
	StreamKey string
	Seq       int64
	At        time.Time
	Text      string
}

// FileLineSearcher is the file_line section's store. Postgres only, as the
// doc section: a hub on the memory store answers the section empty.
type FileLineSearcher interface {
	SearchFileLines(ctx context.Context, tenant string, q SearchQuery) ([]SearchFileLineRow, error)
}

var _ FileLineSearcher = (*Postgres)(nil)

// fileLineLeaf is one term on line l of stream s. Text: the line's words.
// in:file-streams: every line (it only picks the section). box: the stream's
// box. name: the stream key contains the value. before: / after: / on: the
// line's time. Every other operator never reaches this section (the grammar
// narrows the types), so it matches nothing.
func (c *sqlc) fileLineLeaf(t *search.Term) string {
	switch t.Op {
	case search.OpText:
		return "to_tsvector(" + searchConfig + ", l.text) @@ " + c.tsq(t)
	case search.OpIn:
		if t.FileStreams {
			return "true"
		}
	case search.OpBox:
		return "s.box_id = " + c.arg(t.Box)
	case search.OpName:
		return "strpos(" + folded("s.stream_key") + ", " + folded(c.arg(t.Value)+"::text") + ") > 0"
	case search.OpBefore, search.OpAfter, search.OpOn:
		return c.timeRange("l.at", t)
	}
	return "false"
}

// searchFileLinesSQL is SearchFileLines' statement: the tenant's lines
// matching q, newest first, keyset by (at, stream id, seq).
func searchFileLinesSQL(tenant string, q SearchQuery) (string, []any) {
	c := &sqlc{}
	t := c.arg(tenant)
	where := c.cond(q.Q.Root, c.fileLineLeaf)
	page := ""
	if !q.AfterAt.IsZero() {
		page = " AND (l.at, l.stream_id::text, l.seq) < (" + c.arg(q.AfterAt) + "::timestamptz, " +
			c.arg(q.AfterID) + "::text, " + c.arg(int64(q.AfterIdx)) + "::bigint)"
	}
	sql := `SELECT l.stream_id::text, s.box_id, s.stream_key, l.seq, l.at, l.text
		FROM file_stream_lines l
		JOIN file_streams s ON s.tenant_id = l.tenant_id AND s.id = l.stream_id
		WHERE l.tenant_id = ` + t + ` AND s.tenant_id = ` + t + ` AND NOT l.marker AND ` + where + page + `
		ORDER BY l.at DESC, l.stream_id::text DESC, l.seq DESC LIMIT ` + c.arg(pgLimit(q.Limit))
	return sql, c.args
}

// SearchFileLines is the file_line section's page: one statement in the
// tenant scope under the search budget.
func (s *Postgres) SearchFileLines(ctx context.Context, tenant string, q SearchQuery) ([]SearchFileLineRow, error) {
	sql, args := searchFileLinesSQL(tenant, q)
	out := []SearchFileLineRow{}
	err := s.search(ctx, tenant, q, sql, args, func(rows pgx.Rows) error {
		var r SearchFileLineRow
		if err := rows.Scan(&r.StreamID, &r.BoxID, &r.StreamKey, &r.Seq, &r.At, &r.Text); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	return out, err
}
