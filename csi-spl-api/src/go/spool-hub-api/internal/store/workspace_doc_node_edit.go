package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// The Qto explorer's folder rename and delete (spec 120 section 5 "edit
// folder", "delete folder"; section 7 PATCH / DELETE
// /v1/workspace/doctree/folders/{folder}): the folder row's right-click menu
// (owner HUM-10, t1 ed2e3583 msg 407fc16f: a right click on a directory of
// the Qto file system brings a menu for it too).
//
// An edit changes no bounds. A delete is the spec's recursive form: (1) the
// subtree is lft BETWEEN X.lft AND X.rgt, (2) its documents' workspace_doc
// rows go (0157 cascades items and rev log, the doc nodes cascade by doc_id),
// (3) the folders go in ONE statement (the NO ACTION parent FK passes at
// statement end), (4) ONE UPDATE closes the gap of width w. A folder with
// anything under it is refused (409 folder_not_empty with its counts) unless
// the caller asked for recursive. The counter trigger decrements the root's
// counters; the deferred workspace_doc_node_ns checks the set at commit.

// ErrDocFolderNotEmpty: a delete without recursive of a folder that holds
// folders or documents.
var ErrDocFolderNotEmpty = fmt.Errorf("%w: folder_not_empty", ErrDocNodeConflict)

// DocFolderNotEmptyError is ErrDocFolderNotEmpty with what the folder holds,
// for the WUI's confirm.
type DocFolderNotEmptyError struct{ Folders, Documents int }

func (e *DocFolderNotEmptyError) Error() string { return ErrDocFolderNotEmpty.Error() }
func (e *DocFolderNotEmptyError) Unwrap() error { return ErrDocFolderNotEmpty }

// DocFolderPatch is an edit's fields; nil keeps the field as it is.
type DocFolderPatch struct {
	Name, Title, Description *string
}

// DocFolderDeleted is what a delete removed, the folder itself included.
type DocFolderDeleted struct{ Folders, Documents int }

// docNodeEditPlant is this file's control (SPOOL_TEST_WSDOC_NODE_PLANT=
// delnogap, tests only): a folder delete that leaves its gap open, so the
// commit check must refuse it.
var docNodeEditPlant struct {
	noGapClose bool
}

// DocFolderPatchCheck trims p and checks its lengths (0165's CHECKs), so the
// hub answers 400 before it opens a transaction. An empty patch is refused.
func DocFolderPatchCheck(p DocFolderPatch) (DocFolderPatch, error) {
	trim := func(v *string) *string {
		if v == nil {
			return nil
		}
		t := strings.TrimSpace(*v)
		return &t
	}
	p = DocFolderPatch{Name: trim(p.Name), Title: trim(p.Title), Description: trim(p.Description)}
	switch {
	case p.Name == nil && p.Title == nil && p.Description == nil:
		return p, fmt.Errorf("%w: name, title or description", ErrDocRefused)
	case p.Name != nil && (*p.Name == "" || utf8.RuneCountInString(*p.Name) > DocFolderNameMax):
		return p, fmt.Errorf("%w: a folder name is 1 to %d characters", ErrDocRefused, DocFolderNameMax)
	case p.Title != nil && utf8.RuneCountInString(*p.Title) > DocFolderTitleMax:
		return p, fmt.Errorf("%w: a folder title is at most %d characters", ErrDocRefused, DocFolderTitleMax)
	case p.Description != nil && utf8.RuneCountInString(*p.Description) > DocFolderDescMax:
		return p, fmt.Errorf("%w: a folder description is at most %d characters", ErrDocRefused, DocFolderDescMax)
	}
	return p, nil
}

// docNodeFolderOf reads a folder's bounds under the root lock: 404 for no
// such node (or another workspace's), refused for the root or a document.
func docNodeFolderOf(ctx context.Context, tx pgx.Tx, tenant, folder string) (lft, rgt int, err error) {
	if !isUUID(folder) {
		return 0, 0, ErrDocNodeNotFound
	}
	var kind string
	err = tx.QueryRow(ctx, `SELECT lft, rgt, kind FROM workspace_doc_node WHERE tenant_id = $1 AND id = $2`,
		tenant, folder).Scan(&lft, &rgt, &kind)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return 0, 0, ErrDocNodeNotFound
	case err == nil && kind != "folder":
		return 0, 0, fmt.Errorf("%w: the node is a %s, not a folder", ErrDocRefused, kind)
	}
	return lft, rgt, err
}

// DocFolderEdit renames a folder (and sets its title or description): 409
// name_taken when a sibling folder has the name.
func (s *Postgres) DocFolderEdit(ctx context.Context, tenant, folder string, p DocFolderPatch) error {
	p, err := DocFolderPatchCheck(p)
	if err != nil {
		return err
	}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := docNodeLockRoot(ctx, tx, tenant); err != nil {
			return err
		}
		if _, _, err := docNodeFolderOf(ctx, tx, tenant, folder); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE workspace_doc_node SET name = coalesce($3, name),
				title = coalesce($4, title), description = coalesce($5, description), updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenant, folder, p.Name, p.Title, p.Description)
		return err
	})
	return docNodeErr(err)
}

// DocFolderDelete deletes a folder. One that holds anything is refused with a
// *DocFolderNotEmptyError unless recursive, which deletes its whole subtree:
// the folders and the documents with their items and rev logs.
func (s *Postgres) DocFolderDelete(ctx context.Context, tenant, folder string, recursive bool) (DocFolderDeleted, error) {
	var out DocFolderDeleted
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := docNodeLockRoot(ctx, tx, tenant); err != nil {
			return err
		}
		lft, rgt, err := docNodeFolderOf(ctx, tx, tenant, folder)
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE kind = 'folder')::integer,
				count(*) FILTER (WHERE kind = 'doc')::integer
			FROM workspace_doc_node WHERE tenant_id = $1 AND lft BETWEEN $2 AND $3`, tenant, lft, rgt).
			Scan(&out.Folders, &out.Documents); err != nil {
			return err
		}
		if !recursive && (out.Folders > 1 || out.Documents > 0) {
			return &DocFolderNotEmptyError{Folders: out.Folders - 1, Documents: out.Documents}
		}
		return docNodeSubtreeDelete(ctx, tx, tenant, lft, rgt)
	})
	if err != nil {
		return DocFolderDeleted{}, docNodeErr(err)
	}
	return out, nil
}

// docNodeSubtreeDelete removes (lft, rgt) and everything in it: the
// documents first (their nodes cascade), then the folders in one statement,
// then the gap closes in one UPDATE.
func docNodeSubtreeDelete(ctx context.Context, tx pgx.Tx, tenant string, lft, rgt int) error {
	if _, err := tx.Exec(ctx, `DELETE FROM workspace_doc WHERE tenant_id = $1 AND id IN (
			SELECT doc_id FROM workspace_doc_node
			 WHERE tenant_id = $1 AND kind = 'doc' AND lft BETWEEN $2 AND $3)`, tenant, lft, rgt); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM workspace_doc_node WHERE tenant_id = $1 AND lft BETWEEN $2 AND $3`,
		tenant, lft, rgt); err != nil {
		return err
	}
	if docNodeEditPlant.noGapClose {
		return nil
	}
	_, err := tx.Exec(ctx, `UPDATE workspace_doc_node
		SET lft = lft - CASE WHEN lft > $2 THEN $3 ELSE 0 END, rgt = rgt - $3
		WHERE tenant_id = $1 AND rgt > $2`, tenant, rgt, rgt-lft+1)
	return err
}
