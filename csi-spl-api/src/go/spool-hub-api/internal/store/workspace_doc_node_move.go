package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The Qto explorer's move (spec 120 section 5 "move X under P", section 7
// POST /v1/workspace/doctree/nodes/{node}/move): a folder with its subtree,
// or a document, becomes the last child of another folder or of the root.
// Gap topic t1 b67d5dc7: no route could move a document into a folder.
//
// ONE UPDATE sets lft, rgt, and X's parent_id / parent_kind together (the
// immediate CHECKs refuse the two-step and negate forms; the deferred
// workspace_doc_node_ns checks the whole set at commit). A move changes no
// counter.

// ErrDocNodeMoveIntoSelf: the new parent is the node or inside its subtree.
var ErrDocNodeMoveIntoSelf = fmt.Errorf("%w: move_into_own_subtree", ErrDocNodeConflict)

// docNodeMovePlant is the move's control (SPOOL_TEST_WSDOC_NODE_PLANT=
// movekeepparent, tests only): the shift runs but X keeps its old
// parent_id, so the commit check must refuse it.
var docNodeMovePlant struct {
	keepParent bool
}

// docNodeMoving is the node to move, read under the root lock: its bounds,
// its parent and the height of its subtree (1 = a leaf).
type docNodeMoving struct {
	lft, rgt, height int
	parent, kind     string
}

func docNodeMovingOf(ctx context.Context, tx pgx.Tx, tenant, node string) (docNodeMoving, error) {
	var x docNodeMoving
	if !isUUID(node) {
		return x, ErrDocNodeNotFound
	}
	err := tx.QueryRow(ctx, `SELECT x.lft, x.rgt, coalesce(x.parent_id::text, ''), x.kind,
			(SELECT coalesce(max((SELECT count(*) FROM workspace_doc_node a
				WHERE a.tenant_id = d.tenant_id AND a.lft BETWEEN x.lft AND x.rgt
				  AND a.lft < d.lft AND a.rgt > d.rgt)), 0)::integer + 1
			   FROM workspace_doc_node d
			  WHERE d.tenant_id = x.tenant_id AND d.lft BETWEEN x.lft AND x.rgt)
		FROM workspace_doc_node x WHERE x.tenant_id = $1 AND x.id = $2`, tenant, node).
		Scan(&x.lft, &x.rgt, &x.parent, &x.kind, &x.height)
	if errors.Is(err, pgx.ErrNoRows) {
		return x, ErrDocNodeNotFound
	}
	if err == nil && x.kind == "root" {
		return x, fmt.Errorf("%w: the root does not move", ErrDocRefused)
	}
	return x, err
}

// docNodeMoveSQL is spec 5's shift for both directions: right when the
// parent's rgt r lies past X ($5 > $3), left otherwise. $2/$3 are X's bounds,
// $4 the width, $5 r; $6 X's id, $7/$8 its new parent and parent kind; $9
// is the control plant (true keeps the old parent).
const docNodeMoveSQL = `UPDATE workspace_doc_node SET
	lft = CASE WHEN $5::integer > $3::integer THEN
		CASE WHEN lft BETWEEN $2 AND $3 THEN lft + ($5 - $3 - 1) WHEN lft > $3 AND lft < $5 THEN lft - $4 ELSE lft END
	ELSE
		CASE WHEN lft BETWEEN $2 AND $3 THEN lft - ($2 - $5) WHEN lft >= $5 AND lft < $2 THEN lft + $4 ELSE lft END
	END,
	rgt = CASE WHEN $5::integer > $3::integer THEN
		CASE WHEN rgt BETWEEN $2 AND $3 THEN rgt + ($5 - $3 - 1) WHEN rgt > $3 AND rgt < $5 THEN rgt - $4 ELSE rgt END
	ELSE
		CASE WHEN rgt BETWEEN $2 AND $3 THEN rgt - ($2 - $5) WHEN rgt >= $5 AND rgt < $2 THEN rgt + $4 ELSE rgt END
	END,
	parent_id = CASE WHEN id = $6::uuid AND NOT $9::boolean THEN $7::uuid ELSE parent_id END,
	parent_kind = CASE WHEN id = $6::uuid AND NOT $9::boolean THEN $8::text ELSE parent_kind END
	WHERE tenant_id = $1 AND (CASE WHEN $5::integer > $3::integer
		THEN lft BETWEEN $2 AND $5 - 1 OR rgt BETWEEN $2 AND $5 - 1
		ELSE lft BETWEEN $5 AND $3 OR rgt BETWEEN $5 AND $3 END)`

// DocNodeMove makes node the last child of parent ("" = the workspace's
// root). Moving a node under its current parent is a no-op. Refused: the
// root, a parent inside the node's own subtree (409 move_into_own_subtree),
// a document as parent, a result deeper than 32 levels, a sibling folder of
// the same name (409 name_taken).
func (s *Postgres) DocNodeMove(ctx context.Context, tenant, node, parent string) error {
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		root, err := docNodeLockRoot(ctx, tx, tenant)
		if err != nil {
			return err
		}
		x, err := docNodeMovingOf(ctx, tx, tenant, node)
		if err != nil {
			return err
		}
		p, err := docNodeParentOf(ctx, tx, tenant, root, parent)
		if err != nil && !errors.Is(err, ErrDocNodeTooDeep) { // depth: the subtree's height, below
			return err
		}
		var plft int
		if err := tx.QueryRow(ctx, `SELECT lft FROM workspace_doc_node WHERE tenant_id = $1 AND id = $2`, tenant, p.id).Scan(&plft); err != nil {
			return err
		}
		switch {
		case x.lft <= plft && plft <= x.rgt:
			return ErrDocNodeMoveIntoSelf
		case p.id == x.parent:
			return nil
		case p.level+x.height > docNodeMaxDepth:
			return ErrDocNodeTooDeep
		}
		_, err = tx.Exec(ctx, docNodeMoveSQL, tenant, x.lft, x.rgt, x.rgt-x.lft+1, p.rgt,
			node, p.id, p.kind, docNodeMovePlant.keepParent)
		return err
	})
	return docNodeErr(err)
}
