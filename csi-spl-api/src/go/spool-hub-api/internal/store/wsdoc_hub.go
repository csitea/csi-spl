package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
)

// The reads the hub API of spec 113 (T004) needs beside T002's ops: the
// document list, one document's head (its rev, item count and root, the
// grid's 20,000-item gate), the item search (spec 100) and the topic link,
// which lives in the hidden root item's attrs.topic_id, written through
// T002's DocItemUpdateField. Read-only, under RLS, one tenant batch each;
// T002's ops in workspace_docs*.go stay unchanged.

// DocHead is one document as the list and the head read return it.
type DocHead struct {
	ID        string
	Title     string
	Rev       int64
	TopicID   string // the linked topic, "" = none
	UpdatedAt time.Time
	Items     int // the item count, the hidden root included
	RootID    string
	RootRev   int64
	RootAttrs json.RawMessage
}

// DocHit is one search match.
type DocHit struct {
	DocID  string
	ItemID string
	Title  string
	Rank   float32
}

// wsDocHeadSQL reads document heads; $1 = one doc id or NULL, $2 = a topic
// id or NULL, $3 = the limit.
const wsDocHeadSQL = `SELECT d.id::text, d.title, d.rev, coalesce(r.attrs->>'topic_id', ''), d.updated_at,
		(SELECT count(*) FROM workspace_doc_item i WHERE i.doc_id = d.id), r.id::text, r.rev, r.attrs
	FROM workspace_doc d JOIN workspace_doc_item r ON r.doc_id = d.id AND r.parent_id IS NULL
	WHERE ($1::uuid IS NULL OR d.id = $1) AND ($2::text IS NULL OR r.attrs->>'topic_id' = $2)
	ORDER BY d.updated_at DESC, d.id LIMIT $3`

func (s *Postgres) docHeads(ctx context.Context, tenant string, doc, topic any, limit int) ([]DocHead, error) {
	var out []DocHead
	err := s.queryTenantBatch(ctx, tenant, tenantRead{sql: wsDocHeadSQL, args: []any{doc, topic, limit},
		each: func(r pgx.Rows) error {
			var h DocHead
			err := r.Scan(&h.ID, &h.Title, &h.Rev, &h.TopicID, &h.UpdatedAt, &h.Items, &h.RootID, &h.RootRev, &h.RootAttrs)
			out = append(out, h)
			return err
		}})
	return out, err
}

// DocList is the tenant's documents (topic "" = all, else those linked to
// topic), most recently changed first, at most limit.
func (s *Postgres) DocList(ctx context.Context, tenant, topic string, limit int) ([]DocHead, error) {
	var t any
	if topic != "" {
		t = topic
	}
	return s.docHeads(ctx, tenant, nil, t, limit)
}

// DocHeadOf is one document's head. Read it BEFORE a children or subtree
// read: a write in between then makes the caller's next op a 412, never an
// op on a tree it did not see. ErrDocNotFound when gone or another tenant's.
func (s *Postgres) DocHeadOf(ctx context.Context, tenant, doc string) (DocHead, error) {
	if !isUUID(doc) {
		return DocHead{}, ErrDocNotFound
	}
	hs, err := s.docHeads(ctx, tenant, doc, nil, 1)
	if err == nil && len(hs) == 0 {
		err = ErrDocNotFound
	}
	if err != nil {
		return DocHead{}, err
	}
	return hs[0], nil
}

// DocSearch matches q against the title and body of the items of doc ("" =
// every document of the tenant), best first, at most limit. It uses spec
// 100's spool_search configuration, so a word matches here as it does in a
// message search, and runs under FORCE RLS: another tenant's items never
// match.
func (s *Postgres) DocSearch(ctx context.Context, tenant, doc, q string, limit int) ([]DocHit, error) {
	var d any
	if doc != "" {
		if !isUUID(doc) {
			return nil, ErrDocNotFound
		}
		d = doc
	}
	var out []DocHit
	err := s.queryTenantBatch(ctx, tenant, tenantRead{sql: `WITH q AS (SELECT plainto_tsquery('spool_search', $2) AS q)
		SELECT i.doc_id::text, i.id::text, i.title, ts_rank(to_tsvector('spool_search', i.title || ' ' || i.body), q.q)
		FROM workspace_doc_item i, q
		WHERE ($1::uuid IS NULL OR i.doc_id = $1) AND i.parent_id IS NOT NULL
			AND to_tsvector('spool_search', i.title || ' ' || i.body) @@ q.q
		ORDER BY 4 DESC, 1, 2 LIMIT $3`, args: []any{d, q, limit},
		each: func(r pgx.Rows) error {
			var h DocHit
			err := r.Scan(&h.DocID, &h.ItemID, &h.Title, &h.Rank)
			out = append(out, h)
			return err
		}})
	return out, err
}
