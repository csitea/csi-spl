package store

import (
	"context"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// The readers of spec 113 T002: DocSubtree (one item and everything under it,
// in document order) and DocChildren (one item's children, the lazy route).
// The outline number is derived here from the ord path, never stored (I6).

// wsDocStartSQL resolves the start item: $2, or the doc's root when $2 is NULL.
const wsDocStartSQL = `s AS (SELECT coalesce($2::uuid,
		(SELECT id FROM workspace_doc_item WHERE doc_id = $1 AND parent_id IS NULL)) AS id),
	up AS (
		SELECT i.id, i.parent_id, i.ord, 0 AS lvl FROM workspace_doc_item i JOIN s ON i.id = s.id WHERE i.doc_id = $1
		UNION ALL
		SELECT p.id, p.parent_id, p.ord, up.lvl + 1 FROM workspace_doc_item p JOIN up ON p.id = up.parent_id
		WHERE p.doc_id = $1 AND up.lvl < 100000),
	base AS (SELECT coalesce(array_agg(ord ORDER BY lvl DESC) FILTER (WHERE parent_id IS NOT NULL), '{}') AS path,
		count(*) AS n FROM up)`

// wsDocSubtreeSQL is the recursive CTE down from the start item; ORDER BY the
// int[] ord path is document order (a prefix sorts first).
const wsDocSubtreeSQL = `WITH RECURSIVE ` + wsDocStartSQL + `,
	down AS (
		SELECT i.id, i.parent_id, i.ord, i.title, i.body, i.attrs, i.rev, b.path::int[] AS path
		FROM workspace_doc_item i JOIN s ON i.id = s.id CROSS JOIN base b WHERE i.doc_id = $1
		UNION ALL
		SELECT c.id, c.parent_id, c.ord, c.title, c.body, c.attrs, c.rev, d.path || c.ord
		FROM workspace_doc_item c JOIN down d ON c.parent_id = d.id
		WHERE c.doc_id = $1 AND cardinality(d.path) < 100000)
	SELECT id::text, coalesce(parent_id::text, ''), ord, title, body, attrs, rev, path FROM down ORDER BY path`

// wsDocChildrenSQL is one item's children, with the item's own ord path as
// the outline prefix (the ancestors' ord path of the lazy route).
const wsDocChildrenSQL = `WITH RECURSIVE ` + wsDocStartSQL + `
	SELECT c.id::text, coalesce(c.parent_id::text, ''), c.ord, c.title, c.body, c.attrs, c.rev, b.path::int[] || c.ord
	FROM workspace_doc_item c JOIN s ON c.parent_id = s.id CROSS JOIN base b
	WHERE c.doc_id = $1 ORDER BY c.ord`

// wsDocPathSQL is the start item's ord path and whether it (and the doc) exist.
const wsDocPathSQL = `WITH RECURSIVE ` + wsDocStartSQL + `
	SELECT EXISTS (SELECT 1 FROM workspace_doc WHERE id = $1), b.n > 0, b.path::int[] FROM base b`

// DocChildrenResult is DocChildren's answer: the parent's ord path (its
// outline is the prefix of every child's) and its children in order.
type DocChildrenResult struct {
	Path  []int
	Items []DocItem
}

// DocSubtree reads item ("" = the root) and its whole subtree in document
// order, each with its outline number.
func (s *Postgres) DocSubtree(ctx context.Context, tenant, doc, item string) ([]DocItem, error) {
	var out []DocItem
	_, err := s.docRead(ctx, tenant, doc, item, wsDocSubtreeSQL, func(it DocItem) { out = append(out, it) })
	return out, err
}

// DocChildren reads one item's children ("" = the root's: the top level).
func (s *Postgres) DocChildren(ctx context.Context, tenant, doc, parent string) (DocChildrenResult, error) {
	var res DocChildrenResult
	path, err := s.docRead(ctx, tenant, doc, parent, wsDocChildrenSQL, func(it DocItem) { res.Items = append(res.Items, it) })
	res.Path = path
	return res, err
}

// docRead runs the existence/path read and sql as one batch (one snapshot,
// one round trip), and answers 404 for a missing doc or start item.
func (s *Postgres) docRead(ctx context.Context, tenant, doc, item, sql string, each func(DocItem)) ([]int, error) {
	if !isUUID(doc) {
		return nil, ErrDocNotFound
	}
	var start any
	if item != "" {
		if !isUUID(item) {
			return nil, ErrDocItemNotFound
		}
		start = item
	}
	var docThere, itemThere bool
	var path []int32
	err := s.queryTenantBatch(ctx, tenant,
		tenantRead{sql: wsDocPathSQL, args: []any{doc, start}, each: func(r pgx.Rows) error {
			return r.Scan(&docThere, &itemThere, &path)
		}},
		tenantRead{sql: sql, args: []any{doc, start}, each: func(r pgx.Rows) error {
			it, err := scanDocItem(r)
			each(it)
			return err
		}})
	switch {
	case err != nil:
		return nil, err
	case !docThere:
		return nil, ErrDocNotFound
	case !itemThere:
		return nil, ErrDocItemNotFound
	}
	return intsOf(path), nil
}

func scanDocItem(r pgx.Rows) (DocItem, error) {
	var it DocItem
	var path []int32
	err := r.Scan(&it.ID, &it.ParentID, &it.Ord, &it.Title, &it.Body, &it.Attrs, &it.Rev, &path)
	it.Depth = len(path)
	it.Outline = outlineOf(path)
	return it, err
}

// outlineOf is the derived number: the ord path joined by dots.
func outlineOf(path []int32) string {
	parts := make([]string, len(path))
	for i, p := range path {
		parts[i] = strconv.Itoa(int(p))
	}
	return strings.Join(parts, ".")
}

func intsOf(p []int32) []int {
	out := make([]int, len(p))
	for i, v := range p {
		out[i] = int(v)
	}
	return out
}
