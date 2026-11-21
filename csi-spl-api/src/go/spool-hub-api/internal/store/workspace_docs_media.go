package store

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The media index of the Qto docs (spec 190 v1.0 section 5, row D1, rdb
// 0306): one workspace_doc_media row per (document, sha256) the upload route
// stored at qto-media/<doc>/<sha256>.<ext> in the workspace's own docs
// bucket. The doc's text stays the truth of what is shown; the row is what
// the issue door (C1), the sweep (C7) and the quota read. rdb 0306's
// human_lock hides the rows of a document locked to another human, so every
// read here answers as the document read does: ErrDocNotFound.
//
// The sweep (hub file_retention.go) asks three things: which rows no body of
// their document has carried for the grace (DocMediaSweep), which documents
// were deleted before the grace (DocGoneBefore, rdb 0306's
// workspace_doc_gone), and, for one stored object, whether its document is
// live, gone or hidden from it, and whether that document names it
// (DocMediaHold). A hidden document is one locked to a human: the sweep
// keeps its files.

// DocMedia is one row of the media index.
type DocMedia struct {
	Doc       string
	SHA256    string
	Ext       string
	Kind      string // image | video | audio | file
	Bytes     int64
	Name      string // the file name the uploader sent, "" = none
	CreatedBy string
	CreatedAt time.Time
}

// FileName is the row's name in the doc's token and its object key:
// <sha256>.<ext>.
func (m DocMedia) FileName() string { return m.SHA256 + "." + m.Ext }

// DocMediaKinds are the kinds rdb 0306 admits.
var DocMediaKinds = map[string]bool{"image": true, "video": true, "audio": true, "file": true}

var docMediaNameRe = regexp.MustCompile(`^([0-9a-f]{64})\.([a-z0-9]{1,16})$`)

// DocMediaName splits a media name <sha256>.<ext>; ok=false for anything else.
func DocMediaName(name string) (sha, ext string, ok bool) {
	m := docMediaNameRe.FindStringSubmatch(name)
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

const docMediaCols = `doc_id::text, sha256, ext, kind, bytes, name, created_by, created_at`

func scanDocMedia(r pgx.Row) (DocMedia, error) {
	var m DocMedia
	err := r.Scan(&m.Doc, &m.SHA256, &m.Ext, &m.Kind, &m.Bytes, &m.Name, &m.CreatedBy, &m.CreatedAt)
	return m, err
}

// DocMediaPut indexes m under its document, or answers the row already
// there for the same bytes (created=false; its ext and name win). Either way
// the row counts as named until the sweep reads the doc's bodies again: an
// upload restarts the grace. ErrDocNotFound when the doc is gone, another
// tenant's or hidden from ctx's reader.
func (s *Postgres) DocMediaPut(ctx context.Context, tenant string, m DocMedia) (DocMedia, bool, error) {
	if !isUUID(m.Doc) || !DocMediaKinds[m.Kind] {
		return DocMedia{}, false, ErrDocNotFound
	}
	if _, _, ok := DocMediaName(m.FileName()); !ok {
		return DocMedia{}, false, ErrDocRefused
	}
	var out DocMedia
	var created bool
	err := s.tenantBatch(ctx, tenant, `INSERT INTO workspace_doc_media
			(tenant_id, doc_id, sha256, ext, kind, bytes, name, created_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (tenant_id, doc_id, sha256) DO UPDATE SET unnamed_since = NULL
		RETURNING `+docMediaCols+`, (xmax = 0)`,
		[]any{tenant, m.Doc, m.SHA256, m.Ext, m.Kind, m.Bytes, m.Name, m.CreatedBy},
		func(br pgx.BatchResults) error {
			r := br.QueryRow()
			return r.Scan(&out.Doc, &out.SHA256, &out.Ext, &out.Kind, &out.Bytes, &out.Name, &out.CreatedBy, &out.CreatedAt, &created)
		})
	if docMediaHidden(err) {
		return DocMedia{}, false, ErrDocNotFound
	}
	return out, created, err
}

// docMediaHidden: the insert named a document that is gone (the FK) or that
// the statement cannot see (human_lock's WITH CHECK).
func docMediaHidden(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && (pe.Code == "23503" || pe.Code == "42501")
}

// DocMediaDrop removes doc's row for sha256 (an upload whose bytes did not
// reach the bucket). Gone already is no error.
func (s *Postgres) DocMediaDrop(ctx context.Context, tenant, doc, sha string) error {
	if !isUUID(doc) {
		return nil
	}
	_, err := s.execTenant(ctx, tenant, `DELETE FROM workspace_doc_media
		WHERE tenant_id = $1 AND doc_id = $2 AND sha256 = $3`, tenant, doc, sha)
	return err
}

// DocMediaNamed is doc's index row for name (<sha256>.<ext>): the one door
// to a media object (spec 190 C1). ErrDocNotFound when the name is not of
// that shape, not indexed for that doc, or the doc is gone, another
// tenant's or hidden from ctx's reader: one answer for all of them.
func (s *Postgres) DocMediaNamed(ctx context.Context, tenant, doc, name string) (DocMedia, error) {
	sha, ext, ok := DocMediaName(name)
	if !ok || !isUUID(doc) {
		return DocMedia{}, ErrDocNotFound
	}
	var m DocMedia
	err := s.tenantBatch(ctx, tenant, `SELECT `+docMediaCols+` FROM workspace_doc_media
		WHERE tenant_id = $1 AND doc_id = $2 AND sha256 = $3 AND ext = $4`,
		[]any{tenant, doc, sha, ext}, func(br pgx.BatchResults) (err error) {
			m, err = scanDocMedia(br.QueryRow())
			return err
		})
	if errors.Is(err, pgx.ErrNoRows) {
		return DocMedia{}, ErrDocNotFound
	}
	return m, err
}

// docMediaNamedBy is true when a section body or attrs of the row's document
// carries its token, /v1/workspace/doctree/<doc>/media/<sha256>.<ext> (spec
// 190 C6); attrs as DocMediaHold reads them, so the row grace and the
// backstop agree.
const docMediaNamedBy = `EXISTS (SELECT 1 FROM workspace_doc_item i
	WHERE i.tenant_id = m.tenant_id AND i.doc_id = m.doc_id
	AND (strpos(i.body, 'doctree/' || m.doc_id::text || '/media/' || m.sha256 || '.' || m.ext) > 0
	OR strpos(i.attrs::text, 'doctree/' || m.doc_id::text || '/media/' || m.sha256 || '.' || m.ext) > 0))`

// DocMediaSweep is one pass of the media grace over tenant's rows the sweep
// can see (a hidden document's rows are not seen, so they are kept): a row
// whose document's bodies carry its token is named again; one they do not
// carry is marked unnamed at now, unless it already was; then every row
// unnamed since now - grace or earlier is deleted, re-checked in the same
// statement, and returned: the caller deletes their objects. One
// transaction.
func (s *Postgres) DocMediaSweep(ctx context.Context, tenant string, now time.Time, grace time.Duration) ([]DocMedia, error) {
	var out []DocMedia
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE workspace_doc_media m
			SET unnamed_since = CASE WHEN `+docMediaNamedBy+` THEN NULL ELSE $2::timestamptz END
			WHERE m.tenant_id = $1 AND `+docMediaNamedBy+` = (m.unnamed_since IS NOT NULL)`, tenant, now); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `DELETE FROM workspace_doc_media m
			WHERE m.tenant_id = $1 AND m.unnamed_since <= $2 AND NOT `+docMediaNamedBy+`
			RETURNING `+docMediaCols, tenant, now.Add(-grace))
		if err != nil {
			return err
		}
		return scanRows(rows, func(r pgx.Rows) error {
			m, err := scanDocMedia(r)
			out = append(out, m)
			return err
		})
	})
	return out, err
}

// DocGoneBefore is the ids of tenant's documents deleted at or before
// cutoff (rdb 0306's workspace_doc_gone), oldest first, at most limit.
func (s *Postgres) DocGoneBefore(ctx context.Context, tenant string, cutoff time.Time, limit int) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT doc_id::text FROM workspace_doc_gone
		WHERE tenant_id = $1 AND gone_at <= $2 ORDER BY gone_at, doc_id LIMIT $3`,
		[]any{tenant, cutoff, limit}, func(r pgx.Rows) error {
			var id string
			err := r.Scan(&id)
			out = append(out, id)
			return err
		})
	return out, err
}

// DocGoneDrop forgets a deleted document once the sweep has removed its
// files.
func (s *Postgres) DocGoneDrop(ctx context.Context, tenant, doc string) error {
	if !isUUID(doc) {
		return nil
	}
	_, err := s.execTenant(ctx, tenant, `DELETE FROM workspace_doc_gone WHERE tenant_id = $1 AND doc_id = $2`, tenant, doc)
	return err
}

// DocMediaHold is what the sweep may do with one stored object of a doc.
type DocMediaHold struct {
	Live  bool // the doc is visible: Indexed and Named answer for it
	Gone  bool // the doc was deleted (workspace_doc_gone)
	Index bool // a media row names the object (qto-media/)
	Named bool // a section body or attrs of the doc names the object (.doctree/)
}

// Hidden: neither visible nor deleted, so locked to a human the sweep is
// not; its objects are kept.
func (h DocMediaHold) Hidden() bool { return !h.Live && !h.Gone }

// DocMediaHold answers for doc's object name (a qto-media/ <sha256>.<ext>
// or a .doctree/ picture name) in one round trip.
func (s *Postgres) DocMediaHold(ctx context.Context, tenant, doc, name string) (DocMediaHold, error) {
	var h DocMediaHold
	if !isUUID(doc) {
		return h, nil
	}
	sha, _, _ := DocMediaName(name)
	err := s.queryRowTenant(ctx, tenant, `SELECT
			EXISTS (SELECT 1 FROM workspace_doc d WHERE d.tenant_id = $1 AND d.id = $2),
			EXISTS (SELECT 1 FROM workspace_doc_gone g WHERE g.tenant_id = $1 AND g.doc_id = $2),
			EXISTS (SELECT 1 FROM workspace_doc_media m WHERE m.tenant_id = $1 AND m.doc_id = $2
				AND m.sha256 = $4 AND m.sha256 || '.' || m.ext = $3),
			EXISTS (SELECT 1 FROM workspace_doc_item i WHERE i.tenant_id = $1 AND i.doc_id = $2
				AND (strpos(i.body, $3) > 0 OR strpos(i.attrs::text, $3) > 0))`,
		[]any{tenant, doc, name, sha}, &h.Live, &h.Gone, &h.Index, &h.Named)
	return h, err
}
