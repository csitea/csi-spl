package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The Qto document tree's folders (spec 120 v1.0, step 3: the hub that
// writes nodes; owner t1 3b8891e0 "+ New folder"). A folder and a document
// are rows of rdb 0165's workspace_doc_node, ONE nested set per workspace
// under a hidden root. This file holds the subset the explorer's + buttons
// need: create a folder or a document under a parent, and list one folder's
// children. Move, folder rename and delete are not here (spec 120 section 5).
//
// Every structural op locks the workspace's root row FOR UPDATE first (spec 5;
// a new workspace gets its root (1, 2) lazily, ON CONFLICT DO NOTHING on the
// one-root index), then appends as the parent's last child with ONE shift
// statement (lft and rgt together under CASE: 0165's immediate CHECKs refuse
// the two-step form). The deferred workspace_doc_node_ns check verifies the
// set at commit, the counter trigger enforces the caps.
//
// A document created by a hub before this one has no node (0165 numbered the
// documents that existed then; workspace_doc_node_required, spec 6.4, is not
// applied yet). The root listing shows such a document as a top-level row
// with an empty node id, so nothing goes missing from the explorer.

// Folder field limits (rdb 0165 workspace_doc_node_shape and its CHECKs).
const (
	DocFolderNameMax  = 255
	DocFolderTitleMax = 500
	DocFolderDescMax  = 1000
	// DocNodeListMax is one listing's row limit (spec 120 section 7).
	DocNodeListMax = 200
	// docNodeMaxDepth is the deepest a node may sit: the root is level 1,
	// 32 levels under it (0165 workspace_doc_node_ns).
	docNodeMaxDepth = 33
)

// The node refusals the hub answers as their own codes (spec 120 section 7).
var (
	// ErrDocNodeConflict is the 409 family.
	ErrDocNodeConflict = errors.New("conflict")
	// ErrDocFolderNameTaken: a sibling folder has the name (case-insensitive).
	ErrDocFolderNameTaken = fmt.Errorf("%w: name_taken", ErrDocNodeConflict)
	// ErrDocCapReached: the workspace holds 10,000 documents.
	ErrDocCapReached = fmt.Errorf("%w: doc_cap_reached", ErrDocNodeConflict)
	// ErrDocFolderCapReached: the workspace holds 1,000 folders.
	ErrDocFolderCapReached = fmt.Errorf("%w: folder_cap_reached", ErrDocNodeConflict)
	// ErrDocNodeTooDeep: the parent sits 32 levels down.
	ErrDocNodeTooDeep = fmt.Errorf("%w: depth", ErrDocNodeConflict)
	// ErrDocNodeParentDoc: the parent is a document, not a folder.
	ErrDocNodeParentDoc = fmt.Errorf("%w: the parent is a document, not a folder", ErrDocRefused)
	// ErrDocNodeNotFound: no such node, or another workspace's (RLS: 0 rows).
	ErrDocNodeNotFound = fmt.Errorf("%w: doc tree node", ErrNotFound)
)

// DocNode is one row of a folder's listing: a folder (Name, Title,
// Description its own) or a document (DocID; Title and Description its
// workspace_doc header's). Children counts a folder's direct children.
type DocNode struct {
	ID          string
	Kind        string
	Name        string
	Title       string
	Description string
	DocID       string
	Children    int
}

// DocFolder is a new folder's fields; Parent "" is the workspace's root.
type DocFolder struct {
	Parent      string
	Name        string
	Title       string
	Description string
	Actor       string
}

// docNodePlant is this file's control (SPOOL_TEST_WSDOC_NODE_PLANT, tests
// only): an append that inserts the new leaf without shifting the bounds
// right of it, so the commit check must refuse it.
var docNodePlant struct {
	noShift bool
}

// docNodeTable reports whether rdb 0165 is applied: a document create on a
// database without it writes no node, as before.
func docNodeTable(ctx context.Context, tx pgx.Tx) (bool, error) {
	var has bool
	err := tx.QueryRow(ctx, `SELECT to_regclass('workspace_doc_node') IS NOT NULL`).Scan(&has)
	return has, err
}

// docNodeLockRoot creates the workspace's root on first use and takes it FOR
// UPDATE: the workspace lock every structural op takes first (spec 5).
func docNodeLockRoot(ctx context.Context, tx pgx.Tx, tenant string) (string, error) {
	if _, err := tx.Exec(ctx, `INSERT INTO workspace_doc_node (tenant_id, lft, rgt, kind)
		VALUES ($1, 1, 2, 'root') ON CONFLICT (tenant_id) WHERE kind = 'root' DO NOTHING`, tenant); err != nil {
		return "", err
	}
	var root string
	err := tx.QueryRow(ctx, `SELECT id::text FROM workspace_doc_node
		WHERE tenant_id = $1 AND kind = 'root' FOR UPDATE`, tenant).Scan(&root)
	return root, err
}

// docNodeParent resolves parent ("" = root) under the lock: its id, kind and
// rgt, and its level (the root is 1).
type docNodeParent struct {
	id    string
	kind  string
	rgt   int
	level int
}

func docNodeParentOf(ctx context.Context, tx pgx.Tx, tenant, root, parent string) (docNodeParent, error) {
	if parent == "" {
		parent = root
	}
	if !isUUID(parent) {
		return docNodeParent{}, ErrDocNodeNotFound
	}
	p := docNodeParent{id: parent}
	err := tx.QueryRow(ctx, `SELECT p.kind, p.rgt,
			(SELECT count(*) FROM workspace_doc_node a
			  WHERE a.tenant_id = p.tenant_id AND a.lft < p.lft AND a.rgt > p.rgt)::integer + 1
		FROM workspace_doc_node p WHERE p.tenant_id = $1 AND p.id = $2`, tenant, parent).Scan(&p.kind, &p.rgt, &p.level)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, ErrDocNodeNotFound
	}
	if err != nil {
		return p, err
	}
	if p.kind == "doc" {
		return p, ErrDocNodeParentDoc
	}
	if p.level+1 > docNodeMaxDepth {
		return p, ErrDocNodeTooDeep
	}
	return p, nil
}

// docNodeNew is one node to append: a folder (name, title, description) or
// a document (doc).
type docNodeNew struct {
	kind, name, title, description, doc, actor string
}

// docNodeAppend appends n as parent's last child (spec 5 "create"): ONE
// shift opens (r, r + 1) at the parent's rgt r, then the insert. The caller
// holds the root lock. It returns the new node's id.
func docNodeAppend(ctx context.Context, tx pgx.Tx, tenant string, p docNodeParent, n docNodeNew) (string, error) {
	if !docNodePlant.noShift {
		if _, err := tx.Exec(ctx, `UPDATE workspace_doc_node
			SET lft = lft + CASE WHEN lft > $2 THEN 2 ELSE 0 END, rgt = rgt + 2
			WHERE tenant_id = $1 AND rgt >= $2`, tenant, p.rgt); err != nil {
			return "", err
		}
	}
	var doc any
	if n.doc != "" {
		doc = n.doc
	}
	var id string
	err := tx.QueryRow(ctx, `INSERT INTO workspace_doc_node
			(tenant_id, lft, rgt, parent_id, parent_kind, kind, name, title, description, doc_id, created_by)
		VALUES ($1, $2, $2 + 1, $3, $4, $5, $6, $7, $8, $9::uuid, $10) RETURNING id::text`,
		tenant, p.rgt, p.id, p.kind, n.kind, n.name, n.title, n.description, doc, n.actor).Scan(&id)
	return id, docNodeErr(err)
}

// docNodeErr names the refusals 0165 raises on an append: the sibling name
// index and the two cap CHECKs on the root's counters.
func docNodeErr(err error) error {
	switch {
	case err == nil:
		return nil
	case isUniqueViolation(err) && constraintOf(err) == "workspace_doc_node_folder_name":
		return ErrDocFolderNameTaken
	case constraintOf(err) == "workspace_doc_node_cap":
		return ErrDocCapReached
	case constraintOf(err) == "workspace_doc_node_folder_cap":
		return ErrDocFolderCapReached
	}
	return err
}

// constraintOf is a Postgres error's constraint name, "" for any other.
func constraintOf(err error) string {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.ConstraintName
	}
	return ""
}

// DocFolderCheck trims f and checks its lengths (0165's CHECKs), so the hub
// answers 400 before it opens a transaction.
func DocFolderCheck(f DocFolder) (DocFolder, error) {
	f.Name, f.Title, f.Description = strings.TrimSpace(f.Name), strings.TrimSpace(f.Title), strings.TrimSpace(f.Description)
	switch {
	case f.Name == "" || utf8.RuneCountInString(f.Name) > DocFolderNameMax:
		return f, fmt.Errorf("%w: a folder name is 1 to %d characters", ErrDocRefused, DocFolderNameMax)
	case utf8.RuneCountInString(f.Title) > DocFolderTitleMax:
		return f, fmt.Errorf("%w: a folder title is at most %d characters", ErrDocRefused, DocFolderTitleMax)
	case utf8.RuneCountInString(f.Description) > DocFolderDescMax:
		return f, fmt.Errorf("%w: a folder description is at most %d characters", ErrDocRefused, DocFolderDescMax)
	}
	return f, nil
}

// DocFolderCreate makes a folder as the last child of f.Parent ("" = the
// workspace's root) and returns its node id.
func (s *Postgres) DocFolderCreate(ctx context.Context, tenant string, f DocFolder) (string, error) {
	f, err := DocFolderCheck(f)
	if err != nil {
		return "", err
	}
	var id string
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		root, err := docNodeLockRoot(ctx, tx, tenant)
		if err != nil {
			return err
		}
		p, err := docNodeParentOf(ctx, tx, tenant, root, f.Parent)
		if err != nil {
			return err
		}
		id, err = docNodeAppend(ctx, tx, tenant, p, docNodeNew{kind: "folder", name: f.Name,
			title: f.Title, description: f.Description, actor: f.Actor})
		return err
	})
	return id, docNodeErr(err)
}

// docNodeSelect reads a listing's rows: the folders first, then the
// documents (the file system view, spec 5 "order"), each in the folder's
// own order, its bounds (the re-order of DocNodeMoveAt, owner t1 1a9a14b6
// msg 32d5ea87); a document an older hub made without a node goes last,
// by title.
const docNodeSelect = `SELECT n.id::text, n.kind, n.name, n.title, n.description, coalesce(n.doc_id::text, ''),
		coalesce(d.title, ''), coalesce(d.description, ''),
		(SELECT count(*) FROM workspace_doc_node c WHERE c.tenant_id = n.tenant_id AND c.parent_id = n.id)::integer,
		n.lft
	FROM workspace_doc_node n LEFT JOIN workspace_doc d ON d.id = n.doc_id
	WHERE n.tenant_id = $1 AND n.parent_id = $2
	UNION ALL
	SELECT '', 'doc', '', '', '', d.id::text, d.title, d.description, 0, NULL
	FROM workspace_doc d
	WHERE $3 AND d.tenant_id = $1
	  AND NOT EXISTS (SELECT 1 FROM workspace_doc_node x WHERE x.doc_id = d.id)
	ORDER BY 2 DESC, 10 NULLS LAST, 7, 6, 1
	LIMIT $4`

// DocNodes lists one folder's children (parent "" = the workspace's root),
// at most DocNodeListMax, and returns the parent's node id ("" while the
// workspace has no root yet). A parent that is a document is refused.
func (s *Postgres) DocNodes(ctx context.Context, tenant, parent string) (string, []DocNode, error) {
	var out []DocNode
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		atRoot := parent == ""
		if atRoot {
			err := tx.QueryRow(ctx, `SELECT id::text FROM workspace_doc_node WHERE tenant_id = $1 AND kind = 'root'`, tenant).Scan(&parent)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		} else if err := docNodeIsFolder(ctx, tx, tenant, parent); err != nil {
			return err
		}
		var pid any
		if parent != "" {
			pid = parent
		}
		rows, err := tx.Query(ctx, docNodeSelect, tenant, pid, atRoot, DocNodeListMax)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (DocNode, error) {
			var n DocNode
			var docTitle, docDesc string
			var lft *int
			err := r.Scan(&n.ID, &n.Kind, &n.Name, &n.Title, &n.Description, &n.DocID, &docTitle, &docDesc, &n.Children, &lft)
			if n.Kind == "doc" {
				n.Title, n.Description = docTitle, docDesc
			}
			return n, err
		})
		return err
	})
	return parent, out, err
}

// docNodeIsFolder: parent is a folder or the root of this workspace.
func docNodeIsFolder(ctx context.Context, tx pgx.Tx, tenant, parent string) error {
	if !isUUID(parent) {
		return ErrDocNodeNotFound
	}
	var kind string
	err := tx.QueryRow(ctx, `SELECT kind FROM workspace_doc_node WHERE tenant_id = $1 AND id = $2`, tenant, parent).Scan(&kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrDocNodeNotFound
	}
	if err == nil && kind == "doc" {
		return ErrDocNodeParentDoc
	}
	return err
}
