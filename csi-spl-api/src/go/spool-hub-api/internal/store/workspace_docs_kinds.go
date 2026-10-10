package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// Spec 113 T006 follow-up (owner go 33ced864): renaming a document, and the
// two typed items the doc view shows, a code block and an image. A rename is
// a structural op (the doc row's title, under the doc lock, one doc rev and
// its rev-log entry); a typed item is an ordinary item whose attrs carry
// kind plus the sibling project's keys the WUI already reads:
//
//	kind "code"   src (the code, shown as <pre><code>), lang (optional)
//	kind "image"  img_http_path (the image src), img_name (caption and alt)
//
// docAttrsCheck is the one gate for attrs, run by DocItemAdd and by the attrs
// text edit, so no write path stores an image src the WUI would render from
// an arbitrary scheme (javascript:, data:).

// DocUntitled is a document's title when the caller gives none: a create
// with no title, or a rename that clears it.
const DocUntitled = "Untitled document"

// DocTitleMax is workspace_doc.title's limit (rdb 0157), in characters.
const DocTitleMax = 500

// DocImagePathPrefix is the hub's own image route; an img_http_path is a
// path under it or an https URL, nothing else.
const DocImagePathPrefix = "/v1/workspace/doctree/"

const (
	docCodeMax        = 1000000 // src, as body (rdb 0157)
	docLangMax        = 50
	docImgPathMax     = 2000
	docImgNameMax     = 1000
	docAttrsKindCode  = "code"
	docAttrsKindImage = "image"
)

// wsDocKindsPlant holds this file's controls, planted bugs the kinds test
// must catch (only tests set them, SPOOL_TEST_WSDOC_KINDS_PLANT): the old
// code's two gaps, a rename that moves no doc rev (so a stale rename is not
// refused) and attrs written unchecked; and a document delete that skips its
// rev precondition (so a stale delete is not refused), and one that leaves
// the document's gap in the rdb 0165 nested set (the commit check refuses it).
var wsDocKindsPlant struct {
	renameNoBump     bool
	attrsNoCheck     bool
	deleteNoRev      bool
	deleteNoGapClose bool
}

// DocTitle is title trimmed, DocUntitled when that leaves nothing.
func DocTitle(title string) string {
	if t := strings.TrimSpace(title); t != "" {
		return t
	}
	return DocUntitled
}

// docAttrsCheck refuses attrs that are not a JSON object, an unknown kind,
// or a typed key of the wrong type, size or scheme. An absent attrs is ok.
func docAttrsCheck(raw string) error {
	if raw == "" || wsDocKindsPlant.attrsNoCheck {
		return nil
	}
	var m map[string]any
	if !strings.HasPrefix(strings.TrimSpace(raw), "{") || json.Unmarshal([]byte(raw), &m) != nil {
		return fmt.Errorf("%w: attrs is not a JSON object", ErrDocRefused)
	}
	str := func(k string, max int) (string, error) {
		v, ok := m[k]
		if !ok {
			return "", nil
		}
		s, ok := v.(string)
		if !ok || utf8.RuneCountInString(s) > max {
			return "", fmt.Errorf("%w: attrs.%s is a string of at most %d characters", ErrDocRefused, k, max)
		}
		return s, nil
	}
	kind, err := str("kind", 20)
	if err != nil {
		return err
	}
	if kind != "" && kind != docAttrsKindCode && kind != docAttrsKindImage {
		return fmt.Errorf("%w: attrs.kind is code or image", ErrDocRefused)
	}
	_, e1 := str("src", docCodeMax)
	_, e2 := str("lang", docLangMax)
	_, e3 := str("img_name", docImgNameMax)
	p, e4 := str("img_http_path", docImgPathMax)
	if err := errors.Join(e1, e2, e3, e4); err != nil {
		return err
	}
	if p != "" && !strings.HasPrefix(p, "https://") && !strings.HasPrefix(p, DocImagePathPrefix) {
		return fmt.Errorf("%w: attrs.img_http_path is an https URL or a %s path", ErrDocRefused, DocImagePathPrefix)
	}
	return nil
}

// DocRename sets the document's title (DocTitle: "" is DocUntitled) under
// the doc lock: rev is the doc rev the caller read (0 = no precondition).
func (s *Postgres) DocRename(ctx context.Context, tenant, doc string, rev int64, title, actor string) (DocOpResult, error) {
	var res DocOpResult
	err := s.inDoc(ctx, tenant, doc, func(d *wsDocTx) (err error) {
		res, err = d.rename(ctx, rev, title, actor)
		return err
	})
	return res, err
}

// DocDelete deletes the whole document under the doc lock: rev is the doc rev
// the caller read (0 = no precondition); 412 when it moved, 404 when the doc
// is gone or another tenant's (RLS reads it as 0 rows). Its items and its rev
// log go with the doc row by the FK cascade (rdb 0157 ON DELETE CASCADE, run
// as the table owner, so the runtime login's missing DELETE on the rev log
// does not stop it); the 0157 I1/I3 triggers skip a doc deleted in the
// transaction. Nothing records the delete: the log is the doc's own and goes
// with it. Its rdb 0165 node goes by the cascade too, and the gap it leaves
// in the workspace's nested set is closed in the same transaction
// (docNodeGap). It returns the rev the doc had.
func (s *Postgres) DocDelete(ctx context.Context, tenant, doc string, rev int64) (DocOpResult, error) {
	if !isUUID(doc) {
		return DocOpResult{}, ErrDocNotFound
	}
	var res DocOpResult
	err := s.inDoc(ctx, tenant, doc, func(d *wsDocTx) error {
		if wsDocKindsPlant.deleteNoRev {
			rev = 0
		}
		gap, err := docNodeGapOpen(ctx, d.tx, tenant, d.doc)
		if err != nil {
			return err
		}
		if err := d.lock(ctx, rev); err != nil {
			return err
		}
		tag, err := d.tx.Exec(ctx, `DELETE FROM workspace_doc WHERE id = $1`, d.doc)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrDocNotFound
		}
		res = DocOpResult{Rev: d.rev}
		return gap.close(ctx, d.tx)
	})
	return res, err
}

// docNodeGap is a document's place in its workspace's nested set (rdb 0165,
// spec 120 section 5 "delete document"): the doc node's rgt, read under the
// workspace lock. on is false when the doc has no node (0165 not applied, or
// a document created after it by a hub that writes no node yet): nothing to
// close.
type docNodeGap struct {
	tenant string
	rgt0   int64
	on     bool
}

// docNodeGapOpen takes the workspace lock (the root node FOR UPDATE, spec 120
// section 5, before the doc lock) and reads the doc node's rgt. The table
// check keeps it a no-op on a database without 0165, so this lands before it.
func docNodeGapOpen(ctx context.Context, tx pgx.Tx, tenant, doc string) (docNodeGap, error) {
	var has bool
	if err := tx.QueryRow(ctx, `SELECT to_regclass('workspace_doc_node') IS NOT NULL`).Scan(&has); err != nil || !has {
		return docNodeGap{}, err
	}
	if _, err := tx.Exec(ctx, `SELECT 1 FROM workspace_doc_node WHERE tenant_id = $1 AND kind = 'root' FOR UPDATE`, tenant); err != nil {
		return docNodeGap{}, err
	}
	rgts, err := collectInt64(ctx, tx, `SELECT rgt FROM workspace_doc_node WHERE tenant_id = $1 AND doc_id = $2`, tenant, doc)
	if err != nil || len(rgts) != 1 {
		return docNodeGap{}, err
	}
	return docNodeGap{tenant: tenant, rgt0: rgts[0], on: true}, nil
}

// close shifts every bound right of the deleted leaf (lft, rgt) = (rgt0 - 1,
// rgt0) left by 2, in ONE UPDATE (0165's immediate CHECKs refuse the
// two-step forms): an ancestor keeps its lft and shrinks, a node after it
// moves. The deferred workspace_doc_node_ns check verifies it at commit.
func (g docNodeGap) close(ctx context.Context, tx pgx.Tx) error {
	if !g.on || wsDocKindsPlant.deleteNoGapClose {
		return nil
	}
	_, err := tx.Exec(ctx, `UPDATE workspace_doc_node
		SET lft = lft - CASE WHEN lft > $2 THEN 2 ELSE 0 END, rgt = rgt - 2
		WHERE tenant_id = $1 AND rgt > $2`, g.tenant, g.rgt0)
	return err
}

// rename: the refusal first (too long), then the lock, the write with the
// old title, the bump.
func (d *wsDocTx) rename(ctx context.Context, rev int64, title, actor string) (DocOpResult, error) {
	title = DocTitle(title)
	if utf8.RuneCountInString(title) > DocTitleMax {
		return DocOpResult{}, fmt.Errorf("%w: a title is at most %d characters", ErrDocRefused, DocTitleMax)
	}
	if wsDocKindsPlant.renameNoBump {
		rev = 0
	}
	if err := d.lock(ctx, rev); err != nil {
		return DocOpResult{}, err
	}
	var old string
	err := d.tx.QueryRow(ctx, `UPDATE workspace_doc n SET title = $2 FROM workspace_doc o
		WHERE n.id = $1 AND o.id = n.id RETURNING o.title`, d.doc, title).Scan(&old)
	if errors.Is(err, pgx.ErrNoRows) {
		return DocOpResult{}, ErrDocNotFound
	}
	if err != nil {
		return DocOpResult{}, err
	}
	if wsDocKindsPlant.renameNoBump {
		return DocOpResult{Rev: d.rev}, nil
	}
	next, err := d.bump(ctx, actor, map[string]any{"kind": "rename", "from": old, "to": title})
	return DocOpResult{Rev: next}, err
}
