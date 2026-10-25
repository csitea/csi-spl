package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// The doc section of search (spec 100 section 14, SPL-3337; owner HUM-10 t1
// 4e06a219: "If the search does not include the QTO documents, it must start
// including them"): the sections of the workspace's own Qto documents (rdb
// 0157), matched on their index entries (rdb 0226, search_tsv). A hit is one
// section; the root section stands for the document itself, so it also
// carries the document's title. Who may see a hit is the hub's (the reader's
// docs.read, the open rule of the doctree routes); this statement is pinned
// to the tenant: never another workspace's rows, and never the system
// tenant's repository docs, which RLS lets every scope SELECT (rdb 0191)
// and the WUI has no address for.

// SearchDocRow is one matching document section.
type SearchDocRow struct {
	DocID     string
	ItemID    string
	Top       bool   // the root section: the document itself
	DocTitle  string // the document's title
	Title     string // the section's heading ("" for the root)
	Body      string
	UpdatedAt time.Time
}

// DocSearcher is the doc section's store. Postgres only: the memory store
// keeps no Qto documents, so a hub on it answers the section empty.
type DocSearcher interface {
	SearchDocs(ctx context.Context, tenant string, q SearchQuery) ([]SearchDocRow, error)
}

var _ DocSearcher = (*Postgres)(nil)

// hasDocSearchTSV is the catalogue probe for rdb 0226. The hub may roll
// before the migration reaches its database, so until the column is there a
// doc match computes the entry from the text, the statement 0226 replaces.
func (s *Postgres) hasDocSearchTSV(ctx context.Context) bool {
	return s.docTSV.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('workspace_doc_item') AND attname = 'search_tsv' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, time.Now())
}

// docItemTSV and docTitleTSV are the index entries of section alias i and
// document alias d: the stored column (rdb 0226), or the same expression
// computed per row before it.
func docItemTSV(stored bool) string {
	if stored {
		return "i.search_tsv"
	}
	return "to_tsvector(" + searchConfig + ", i.title || ' ' || i.body)"
}

func docTitleTSV(stored bool) string {
	if stored {
		return "d.search_tsv"
	}
	return "to_tsvector(" + searchConfig + ", d.title)"
}

// docLeaf is one term on section i of document d. Text: the section's entry;
// the root's also holds the document's title. title: the section heading,
// the document's title for the root. name: the document's title, a hit on
// its root only (one row per document). before: / after: / on: the last edit
// of the section. Every other operator never reaches a doc section (the
// grammar narrows the types), so it matches nothing.
func (c *sqlc) docLeaf(stored bool) func(*search.Term) string {
	return func(t *search.Term) string {
		switch t.Op {
		case search.OpText:
			return "(CASE WHEN i.parent_id IS NULL THEN " + docItemTSV(stored) + " || " + docTitleTSV(stored) +
				" ELSE " + docItemTSV(stored) + " END) @@ " + c.tsq(t)
		case search.OpTitle:
			return "to_tsvector(" + searchConfig + ", CASE WHEN i.parent_id IS NULL THEN d.title ELSE i.title END) @@ " + c.tsq(t)
		case search.OpName:
			return "i.parent_id IS NULL AND strpos(" + folded("d.title") + ", " + folded(c.arg(t.Value)+"::text") + ") > 0"
		case search.OpBefore, search.OpAfter, search.OpOn:
			return c.timeRange("i.updated_at", t)
		}
		return "false"
	}
}

// searchDocsSQL is SearchDocs' statement: the tenant's sections matching q,
// last edited first, keyset by (updated_at, item id).
func searchDocsSQL(tenant string, q SearchQuery, stored bool) (string, []any) {
	c := &sqlc{}
	t := c.arg(tenant)
	where := c.cond(q.Q.Root, c.docLeaf(stored))
	page := ""
	if !q.AfterAt.IsZero() {
		page = " AND (i.updated_at, i.id::text) < (" + c.arg(q.AfterAt) + "::timestamptz, " + c.arg(q.AfterID) + "::text)"
	}
	sql := `SELECT i.doc_id::text, i.id::text, i.parent_id IS NULL, d.title, i.title, i.body, i.updated_at
		FROM workspace_doc_item i
		JOIN workspace_doc d ON d.tenant_id = i.tenant_id AND d.id = i.doc_id
		WHERE i.tenant_id = ` + t + ` AND d.tenant_id = ` + t + ` AND ` + where + page + `
		ORDER BY i.updated_at DESC, i.id::text DESC LIMIT ` + c.arg(pgLimit(q.Limit))
	return sql, c.args
}

// SearchDocs is the doc section's page: one statement in the tenant scope
// under the search budget.
func (s *Postgres) SearchDocs(ctx context.Context, tenant string, q SearchQuery) ([]SearchDocRow, error) {
	sql, args := searchDocsSQL(tenant, q, s.hasDocSearchTSV(ctx))
	out := []SearchDocRow{}
	err := s.search(ctx, tenant, q, sql, args, func(rows pgx.Rows) error {
		var r SearchDocRow
		if err := rows.Scan(&r.DocID, &r.ItemID, &r.Top, &r.DocTitle, &r.Title, &r.Body, &r.UpdatedAt); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	return out, err
}
