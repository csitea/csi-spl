package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

// The structural ops of spec 113 section 3.3 and the text edit. Each public op
// is one transaction; its wsDocTx method is the nested form a multi-op caller
// (T005's import) runs on a doc lock it already holds.

// DocItemAdd adds one item next to r.Anchor (sibling | parent | child).
func (s *Postgres) DocItemAdd(ctx context.Context, tenant string, r DocItemAddReq) (DocOpResult, error) {
	var res DocOpResult
	err := s.inDoc(ctx, tenant, r.DocID, func(d *wsDocTx) (err error) {
		res, err = d.add(ctx, r)
		return err
	})
	return res, err
}

// DocItemMove moves r.ItemID and its subtree under r.Parent at r.Ord.
func (s *Postgres) DocItemMove(ctx context.Context, tenant string, r DocItemMoveReq) (DocOpResult, error) {
	var res DocOpResult
	err := s.inDoc(ctx, tenant, r.DocID, func(d *wsDocTx) (err error) {
		res, err = d.move(ctx, r)
		return err
	})
	return res, err
}

// DocItemDeleteSubtree deletes item and everything under it; never the root.
func (s *Postgres) DocItemDeleteSubtree(ctx context.Context, tenant, doc string, rev int64, item, actor string) (DocOpResult, error) {
	var res DocOpResult
	err := s.inDoc(ctx, tenant, doc, func(d *wsDocTx) (err error) {
		res, err = d.deleteSubtree(ctx, rev, item, actor)
		return err
	})
	return res, err
}

// add: lock, anchor position, the new slot, the shift, the insert, the bump.
func (d *wsDocTx) add(ctx context.Context, r DocItemAddReq) (DocOpResult, error) {
	if err := d.lock(ctx, r.Rev); err != nil {
		return DocOpResult{}, err
	}
	parent, ord, err := d.addSlot(ctx, r)
	if err != nil {
		return DocOpResult{}, err
	}
	if r.Where == DocParent {
		err = d.deferSiblingOrd(ctx)
	} else {
		err = d.shift(ctx, parent, ord, 1, "")
	}
	if err != nil {
		return DocOpResult{}, err
	}
	var id string
	err = d.tx.QueryRow(ctx, `INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title, body)
		SELECT tenant_id, id, $2, $3, $4, $5 FROM workspace_doc WHERE id = $1 RETURNING id::text`,
		d.doc, parent, ord, r.Title, r.Body).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return DocOpResult{}, ErrDocNotFound
	}
	if err != nil {
		return DocOpResult{}, err
	}
	if r.Where == DocParent {
		if _, err = d.tx.Exec(ctx, `UPDATE workspace_doc_item SET parent_id = $3, ord = 1
			WHERE doc_id = $1 AND id = $2`, d.doc, r.Anchor, id); err != nil {
			return DocOpResult{}, err
		}
	}
	rev, err := d.bump(ctx, r.Actor, map[string]any{"kind": "add", "where": string(r.Where),
		"item": id, "anchor": r.Anchor, "to_parent": parent, "to_ord": ord})
	return DocOpResult{Rev: rev, ItemID: id}, err
}

// addSlot is the new item's parent and ord, read after the lock.
func (d *wsDocTx) addSlot(ctx context.Context, r DocItemAddReq) (string, int, error) {
	ap, ao, err := d.pos(ctx, r.Anchor)
	if err != nil {
		return "", 0, err
	}
	switch r.Where {
	case DocChild:
		last, err := d.maxOrd(ctx, r.Anchor)
		if err != nil {
			return "", 0, err
		}
		return r.Anchor, clampOrd(r.Ord, last+1), nil
	case DocSibling, DocParent:
		if ap == "" {
			return "", 0, fmt.Errorf("%w: the root has no %s", ErrDocRefused, r.Where)
		}
		if r.Where == DocSibling {
			return ap, ao + 1, nil
		}
		return ap, ao, nil
	}
	return "", 0, fmt.Errorf("%w: add where %q", ErrDocRefused, r.Where)
}

// clampOrd is ord within 1..top; 0 or out of range is top (append).
func clampOrd(ord, top int) int {
	if ord < 1 || ord > top {
		return top
	}
	return ord
}

// move: refusals first (the root, a target in its own subtree, I3), then the
// old gap closed and the new one opened under the deferred overlap key.
func (d *wsDocTx) move(ctx context.Context, r DocItemMoveReq) (DocOpResult, error) {
	var early movePlan
	if wsDocPlant.positionsBeforeLock {
		early, _ = d.planMove(ctx, r)
	}
	if err := d.lock(ctx, r.Rev); err != nil {
		return DocOpResult{}, err
	}
	p, err := d.planMove(ctx, r)
	if err != nil {
		return DocOpResult{}, err
	}
	if wsDocPlant.positionsBeforeLock && early.fromParent != "" {
		p = early
	}
	if err := d.deferSiblingOrd(ctx); err != nil {
		return DocOpResult{}, err
	}
	if err := d.shift(ctx, p.fromParent, p.fromOrd+1, -1, r.ItemID); err != nil {
		return DocOpResult{}, err
	}
	if err := d.shift(ctx, r.Parent, p.toOrd, 1, r.ItemID); err != nil {
		return DocOpResult{}, err
	}
	if _, err := d.tx.Exec(ctx, `UPDATE workspace_doc_item SET parent_id = $3, ord = $4
		WHERE doc_id = $1 AND id = $2`, d.doc, r.ItemID, r.Parent, p.toOrd); err != nil {
		return DocOpResult{}, err
	}
	rev, err := d.bump(ctx, r.Actor, map[string]any{"kind": "move", "item": r.ItemID,
		"from_parent": p.fromParent, "from_ord": p.fromOrd, "to_parent": r.Parent, "to_ord": p.toOrd})
	return DocOpResult{Rev: rev, ItemID: r.ItemID}, err
}

type movePlan struct {
	fromParent string
	fromOrd    int
	toOrd      int
}

// planMove reads the positions a move needs and refuses what it must.
func (d *wsDocTx) planMove(ctx context.Context, r DocItemMoveReq) (movePlan, error) {
	fromParent, fromOrd, err := d.pos(ctx, r.ItemID)
	if err != nil {
		return movePlan{}, err
	}
	if fromParent == "" {
		return movePlan{}, fmt.Errorf("%w: the root does not move", ErrDocRefused)
	}
	if _, _, err := d.pos(ctx, r.Parent); err != nil {
		return movePlan{}, err
	}
	var inside bool
	if err := d.tx.QueryRow(ctx, `WITH RECURSIVE up AS (
			SELECT id, parent_id, 0 AS n FROM workspace_doc_item WHERE doc_id = $1 AND id = $2
			UNION ALL
			SELECT p.id, p.parent_id, up.n + 1 FROM workspace_doc_item p JOIN up ON p.id = up.parent_id
			WHERE p.doc_id = $1 AND up.n < 100000)
		SELECT EXISTS (SELECT 1 FROM up WHERE id = $3)`, d.doc, r.Parent, r.ItemID).Scan(&inside); err != nil {
		return movePlan{}, err
	}
	if inside {
		return movePlan{}, fmt.Errorf("%w: a move into its own subtree", ErrDocRefused)
	}
	last, err := d.maxOrd(ctx, r.Parent)
	if err != nil {
		return movePlan{}, err
	}
	if r.Parent == fromParent {
		last-- // the item leaves this list before it re-enters it
	}
	return movePlan{fromParent: fromParent, fromOrd: fromOrd, toOrd: clampOrd(r.Ord, last+1)}, nil
}

// deleteSubtree deletes item's subtree in one statement, then closes its gap.
func (d *wsDocTx) deleteSubtree(ctx context.Context, rev int64, item, actor string) (DocOpResult, error) {
	if err := d.lock(ctx, rev); err != nil {
		return DocOpResult{}, err
	}
	parent, ord, err := d.pos(ctx, item)
	if err != nil {
		return DocOpResult{}, err
	}
	if parent == "" {
		return DocOpResult{}, fmt.Errorf("%w: the root is not deleted", ErrDocRefused)
	}
	tag, err := d.tx.Exec(ctx, `WITH RECURSIVE sub AS (
			SELECT id, 0 AS n FROM workspace_doc_item WHERE doc_id = $1 AND id = $2
			UNION ALL
			SELECT c.id, sub.n + 1 FROM workspace_doc_item c JOIN sub ON c.parent_id = sub.id
			WHERE c.doc_id = $1 AND sub.n < 100000)
		DELETE FROM workspace_doc_item WHERE doc_id = $1 AND id IN (SELECT id FROM sub)`, d.doc, item)
	if err != nil {
		return DocOpResult{}, err
	}
	if !wsDocPlant.skipGapClose {
		if err := d.shift(ctx, parent, ord+1, -1, ""); err != nil {
			return DocOpResult{}, err
		}
	}
	rev, err = d.bump(ctx, actor, map[string]any{"kind": "delete", "item": item,
		"from_parent": parent, "from_ord": ord, "items": tag.RowsAffected()})
	return DocOpResult{Rev: rev, ItemID: item}, err
}

// docFieldSQL is the text-edit allow-list: one fixed statement per column,
// never a column name from the caller in the SQL (spec 3.6 D7).
var docFieldSQL = map[string]string{
	"title": `UPDATE workspace_doc_item SET title = $3, rev = rev + 1, updated_at = now()
		WHERE doc_id = $1 AND id = $2 AND rev = $4 RETURNING rev`,
	"body": `UPDATE workspace_doc_item SET body = $3, rev = rev + 1, updated_at = now()
		WHERE doc_id = $1 AND id = $2 AND rev = $4 RETURNING rev`,
	"attrs": `UPDATE workspace_doc_item SET attrs = $3::jsonb, rev = rev + 1, updated_at = now()
		WHERE doc_id = $1 AND id = $2 AND rev = $4 RETURNING rev`,
}

// DocItemUpdateField is a text edit: one allow-listed column, WHERE id AND
// rev, the item's rev bumped, no doc lock (it changes no structure). 0 rows is
// 404 when the item is gone and 412 when only its rev differs. It returns the
// item's new rev.
func (s *Postgres) DocItemUpdateField(ctx context.Context, tenant, doc, item, field, value string, rev int64) (int64, error) {
	sql, ok := docFieldSQL[field]
	if !ok {
		return 0, fmt.Errorf("%w: field %q is not editable", ErrDocRefused, field)
	}
	if field == "attrs" && (!json.Valid([]byte(value)) || !strings.HasPrefix(strings.TrimSpace(value), "{")) {
		return 0, fmt.Errorf("%w: attrs is not a JSON object", ErrDocRefused)
	}
	if !isUUID(doc) || !isUUID(item) {
		return 0, ErrDocItemNotFound
	}
	var next int64
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, sql, doc, item, value, rev).Scan(&next)
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var there bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM workspace_doc_item
			WHERE doc_id = $1 AND id = $2)`, doc, item).Scan(&there); err != nil {
			return err
		}
		if there {
			return ErrDocStale
		}
		return ErrDocItemNotFound
	})
	return next, err
}
