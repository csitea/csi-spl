package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
)

// Workspace documents (spec 113 T002, sections 3.3 and 3.5): one tree of items
// per document on rdb 0157, an adjacency list plus a sibling ordinal. Every
// structural op is ONE transaction under the document lock, the doc row FOR
// UPDATE, taken before any item row and reused by nested calls (wsDocTx). The
// DB holds the invariants too (0157's deferred workspace_doc_item_tree); the
// store's discipline is the first line, the trigger the backstop.
//
// Every op ends as exactly one outcome: committed (the workspace_doc.rev it
// produced), 412 (ErrDocStale), 404 (ErrDocNotFound / ErrDocItemNotFound) or
// refused (ErrDocRefused). The tables carry tenant_id, so every statement runs
// under inTenant (RLS); another tenant's doc reads as 0 rows, a 404.

// ErrDocNotFound: the document is gone, or is another tenant's (404).
var ErrDocNotFound = fmt.Errorf("%w: workspace doc", ErrNotFound)

// ErrDocItemNotFound: the item (or a target parent) is not in the doc (404).
var ErrDocItemNotFound = fmt.Errorf("%w: workspace doc item", ErrNotFound)

// ErrDocStale: the caller's rev is not the current one (412): the doc rev on a
// structural op, the item rev on a text edit.
var ErrDocStale = errors.New("precondition failed: stale rev")

// ErrDocRefused: the op breaks an invariant and is refused before any write
// (a move into its own subtree, a delete of the root, a field off the list).
var ErrDocRefused = errors.New("refused")

// DocWhere is where DocItemAdd puts the new item, relative to its anchor.
type DocWhere string

const (
	DocSibling DocWhere = "sibling" // right after the anchor, same parent
	DocParent  DocWhere = "parent"  // in the anchor's place; the anchor becomes its only child
	DocChild   DocWhere = "child"   // a child of the anchor, at Ord (0 = last)
)

// DocItem is one item of a document as a reader returns it. Outline is the
// derived number 1 / 1.1 / 1.1.1 (never stored, I6); the hidden root has "".
type DocItem struct {
	ID       string
	ParentID string // "" for the root
	Ord      int
	Outline  string
	Depth    int // 0 for the root
	Title    string
	Body     string
	Attrs    json.RawMessage
	Rev      int64
}

// DocItemAddReq is one DocItemAdd. Rev is the doc rev the caller read
// (0 = no precondition); Ord is used by DocChild only.
type DocItemAddReq struct {
	DocID  string
	Rev    int64
	Anchor string
	Where  DocWhere
	Ord    int
	Title  string
	Body   string
	Actor  string
}

// DocItemMoveReq moves ItemID with its subtree under Parent at Ord (0 = last).
type DocItemMoveReq struct {
	DocID  string
	Rev    int64
	ItemID string
	Parent string
	Ord    int
	Actor  string
}

// DocOpResult is a committed structural op: the doc rev it produced (unique
// per doc) and, for an add, the new item's id.
type DocOpResult struct {
	Rev    int64
	ItemID string
}

// wsDocPlant holds the T002 controls: planted bugs that the property and the
// concurrent tests must catch. Only tests set them (SPOOL_TEST_WSDOC_PLANT).
var wsDocPlant wsDocPlants

type wsDocPlants struct {
	skipGapClose        bool // a delete that leaves its sibling gap
	positionsBeforeLock bool // a move that reads positions before the lock
	ignoreLockRows      bool // a lock that goes on with 0 doc rows
}

// wsDocLockWaits, when a test sets it, counts the ops that found the doc row
// already locked (a NOWAIT probe in a savepoint first). nil in the hub.
var wsDocLockWaits *atomic.Int64

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func isUUID(s string) bool { return uuidRe.MatchString(s) }

// wsDocTx is one transaction's hold on one document: the lock is taken once
// and reused by every nested op in the same transaction (spec 3.3 lock order).
type wsDocTx struct {
	tx     pgx.Tx
	doc    string
	rev    int64
	locked bool
}

// lock takes the doc row FOR UPDATE, requiring exactly 1 row (0 = another
// tenant's or gone: 404, never go on unlocked), then checks want (0 = any).
func (d *wsDocTx) lock(ctx context.Context, want int64) error {
	if !d.locked {
		if !isUUID(d.doc) {
			return ErrDocNotFound
		}
		if err := d.probeWait(ctx); err != nil {
			return err
		}
		revs, err := collectInt64(ctx, d.tx, `SELECT rev FROM workspace_doc WHERE id = $1 FOR UPDATE`, d.doc)
		if err != nil {
			return err
		}
		switch {
		case len(revs) == 1:
			d.rev = revs[0]
		case !wsDocPlant.ignoreLockRows:
			return ErrDocNotFound
		default:
			d.rev = want
		}
		d.locked = true
	}
	if want != 0 && want != d.rev {
		return ErrDocStale
	}
	return nil
}

// probeWait counts a lock wait for the concurrent test: NOWAIT in a savepoint;
// a lock held elsewhere is 55P03, then lock blocks as usual.
func (d *wsDocTx) probeWait(ctx context.Context) error {
	if wsDocLockWaits == nil {
		return nil
	}
	sp, err := d.tx.Begin(ctx)
	if err != nil {
		return err
	}
	_, err = sp.Exec(ctx, `SELECT 1 FROM workspace_doc WHERE id = $1 FOR UPDATE NOWAIT`, d.doc)
	if sqlState(err) == "55P03" {
		wsDocLockWaits.Add(1)
		return sp.Rollback(ctx)
	}
	if err != nil {
		_ = sp.Rollback(ctx)
		return err
	}
	return sp.Commit(ctx)
}

func collectInt64(ctx context.Context, tx pgx.Tx, sql string, args ...any) ([]int64, error) {
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int64])
}

// bump is step 4: the doc rev + 1 and its rev-log entry, in one statement of
// the op's transaction. It returns the rev it produced.
func (d *wsDocTx) bump(ctx context.Context, actor string, op map[string]any) (int64, error) {
	if actor == "" {
		actor = "hub"
	}
	body, err := json.Marshal(op)
	if err != nil {
		return 0, err
	}
	err = d.tx.QueryRow(ctx, `WITH b AS (
		UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = $1 RETURNING tenant_id, id, rev)
		INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
		SELECT tenant_id, id, rev, $2, $3 FROM b RETURNING rev`, d.doc, body, actor).Scan(&d.rev)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrDocNotFound
	}
	return d.rev, err
}

// pos is an item's parent ("" for the root) and ord, read under the lock.
func (d *wsDocTx) pos(ctx context.Context, item string) (string, int, error) {
	if !isUUID(item) {
		return "", 0, ErrDocItemNotFound
	}
	var parent string
	var ord int
	err := d.tx.QueryRow(ctx, `SELECT coalesce(parent_id::text, ''), ord FROM workspace_doc_item
		WHERE doc_id = $1 AND id = $2`, d.doc, item).Scan(&parent, &ord)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", 0, ErrDocItemNotFound
	}
	return parent, ord, err
}

// maxOrd is the append position - 1 under parent: one probe of the
// (doc_id, parent_id, ord) key, never count(*).
func (d *wsDocTx) maxOrd(ctx context.Context, parent string) (int, error) {
	var n int
	err := d.tx.QueryRow(ctx, `SELECT coalesce(max(ord), 0) FROM workspace_doc_item
		WHERE doc_id = $1 AND parent_id = $2`, d.doc, parent).Scan(&n)
	return n, err
}

// shift moves the siblings under parent with from <= ord <= to by delta, in
// ONE statement (the deferrable UNIQUE is checked at its end), never parking.
// skip is an item the statement leaves alone ("" = none).
func (d *wsDocTx) shift(ctx context.Context, parent string, from, to, delta int, skip string) error {
	var skipID any
	if skip != "" {
		skipID = skip
	}
	_, err := d.tx.Exec(ctx, `UPDATE workspace_doc_item SET ord = ord + $5
		WHERE doc_id = $1 AND parent_id = $2 AND ord BETWEEN $3 AND $4 AND id IS DISTINCT FROM $6::uuid`,
		d.doc, parent, from, to, delta, skipID)
	return err
}

// wsOrdTop is "to the end of the list" for shift.
const wsOrdTop = math.MaxInt32

// deferSiblingOrd defers the I4 overlap key to commit for an op that writes
// one sibling list in more than one statement (a move, an add parent).
func (d *wsDocTx) deferSiblingOrd(ctx context.Context) error {
	_, err := d.tx.Exec(ctx, `SET CONSTRAINTS workspace_doc_item_sibling_ord DEFERRED`)
	return err
}

// inDoc runs op in one tenant transaction holding doc's lock state.
func (s *Postgres) inDoc(ctx context.Context, tenant, doc string, op func(*wsDocTx) error) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return op(&wsDocTx{tx: tx, doc: doc})
	})
}

// DocCreate makes a document with its hidden root item (I1) at rev 1, and
// returns the doc id and the root id.
func (s *Postgres) DocCreate(ctx context.Context, tenant, title, actor string) (string, string, error) {
	var doc, root string
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `WITH d AS (
			INSERT INTO workspace_doc (tenant_id, title, rev, created_by) VALUES ($1, $2, 0, $3) RETURNING tenant_id, id),
			r AS (INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord)
				SELECT tenant_id, id, NULL, 1 FROM d RETURNING id)
			SELECT d.id::text, r.id::text FROM d, r`, tenant, title, actor).Scan(&doc, &root)
		if err != nil {
			return err
		}
		d := &wsDocTx{tx: tx, doc: doc, locked: true}
		_, err = d.bump(ctx, actor, map[string]any{"kind": "create", "item": root})
		return err
	})
	return doc, root, err
}
