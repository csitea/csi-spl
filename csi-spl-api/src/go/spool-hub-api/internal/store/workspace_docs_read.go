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
// Spec 137 T012a: an item whose attrs.numbered is false has no outline and
// does not count among its siblings; the items under it have no outline.

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

// wsDocNumSQL is every item's number among its siblings (spec 137 T012a):
// 0 when its attrs.numbered is false, else the count of its numbered
// siblings up to it; bnum is the start item's number path (the ancestors').
const wsDocNumSQL = `nums AS (SELECT id, CASE WHEN coalesce(attrs->>'numbered', '') = 'false' THEN 0
		ELSE count(*) FILTER (WHERE coalesce(attrs->>'numbered', '') <> 'false')
			OVER (PARTITION BY parent_id ORDER BY ord) END AS n
		FROM workspace_doc_item WHERE doc_id = $1),
	bnum AS (SELECT coalesce(array_agg(n.n ORDER BY up.lvl DESC) FILTER (WHERE up.parent_id IS NOT NULL), '{}') AS np
		FROM up JOIN nums n ON n.id = up.id)`

// wsDocSubtreeSQL is the recursive CTE down from the start item; ORDER BY the
// int[] ord path is document order (a prefix sorts first); np, the number
// path beside it, is what the outline is made of.
const wsDocSubtreeSQL = `WITH RECURSIVE ` + wsDocStartSQL + `, ` + wsDocNumSQL + `,
	down AS (
		SELECT i.id, i.parent_id, i.ord, i.title, i.body, i.attrs, i.rev, b.path::int[] AS path, bn.np::int[] AS np
		FROM workspace_doc_item i JOIN s ON i.id = s.id CROSS JOIN base b CROSS JOIN bnum bn WHERE i.doc_id = $1
		UNION ALL
		SELECT c.id, c.parent_id, c.ord, c.title, c.body, c.attrs, c.rev, d.path || c.ord, d.np || n.n::int
		FROM workspace_doc_item c JOIN down d ON c.parent_id = d.id JOIN nums n ON n.id = c.id
		WHERE c.doc_id = $1 AND cardinality(d.path) < 100000)
	SELECT id::text, coalesce(parent_id::text, ''), ord, title, body, attrs, rev, np FROM down ORDER BY path`

// wsDocChildrenSQL is one item's children, with the item's own number path
// as the outline prefix (the ancestors' of the lazy route).
const wsDocChildrenSQL = `WITH RECURSIVE ` + wsDocStartSQL + `, ` + wsDocNumSQL + `
	SELECT c.id::text, coalesce(c.parent_id::text, ''), c.ord, c.title, c.body, c.attrs, c.rev, bn.np::int[] || n.n::int
	FROM workspace_doc_item c JOIN s ON c.parent_id = s.id JOIN nums n ON n.id = c.id CROSS JOIN bnum bn
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

// outlineOf is the derived number: the number path joined by dots; "" when
// the item or one above it is unnumbered (a 0 in the path).
func outlineOf(path []int32) string {
	parts := make([]string, len(path))
	for i, p := range path {
		if p == 0 {
			return ""
		}
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
