package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The visitor's own channel (specs/121 4.1, 4.2, 4.4; T104): read, post and
// erase, each under inChannel of the visitor's row, never inTenant. Each
// method is in embedVisitorPath, so TestEmbedVisitorPathNeverInTenant walks
// it too.

// EmbedVisitors is the store side of the visitor routes; only Postgres
// implements it (the memory store has no channel scope to prove).
type EmbedVisitors interface {
	EmbedCustomer(ctx context.Context, embedID string) (EmbedCustomer, error)
	MintEmbedVisitor(ctx context.Context, in EmbedVisitorMint, now time.Time) (EmbedVisitor, error)
	EmbedVisitorByToken(ctx context.Context, embedID string, tokenHash []byte, now time.Time) (EmbedVisitor, error)
	SlideEmbedVisitor(ctx context.Context, v EmbedVisitor, life EmbedTokenLife, now time.Time) (EmbedVisitor, error)
	EmbedVisitorMessages(ctx context.Context, v EmbedVisitor, limit int) ([]EmbedMessage, error)
	PostEmbedVisitorMessage(ctx context.Context, v EmbedVisitor, p EmbedPost) error
	EraseEmbedVisitor(ctx context.Context, v EmbedVisitor) error
}

var _ EmbedVisitors = (*Postgres)(nil)

// EmbedMessage is one line of a visitor channel as the visitor sees it: no
// sender id (a staff HUM or an agent id stays the workspace's), only whether
// the visitor wrote it.
type EmbedMessage struct {
	MsgID      string
	Body       string
	Mine       bool
	ReceivedAt time.Time
}

// EmbedVisitorMessages is the newest limit lines of v's channel, oldest
// first, unexpired. The WHERE names the channel, and the channel scope would
// hide every other channel's row even if it did not.
func (s *Postgres) EmbedVisitorMessages(ctx context.Context, v EmbedVisitor, limit int) ([]EmbedMessage, error) {
	out := []EmbedMessage{}
	err := s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT msg_id::text, body, from_id = $3, received_at FROM (
				SELECT msg_id, body, from_id, received_at FROM messages
				WHERE tenant_id = $1 AND channel = $2 AND expires_at > now()
				ORDER BY received_at DESC, msg_id DESC LIMIT $4) newest
			ORDER BY received_at, msg_id`, []any{v.TenantID, v.ChannelID, v.HumanID, limit}, func(r pgx.Rows) error {
			var m EmbedMessage
			if err := r.Scan(&m.MsgID, &m.Body, &m.Mine, &m.ReceivedAt); err != nil {
				return err
			}
			out = append(out, m)
			return nil
		})
	})
	return out, err
}

// EmbedPost is the hub-built row of one visitor post (hub/embed_visitor.go):
// a note from the visitor's HUM to the whole channel (to ALL-0, the hub's
// BroadcastID), box-wui to box-wui,
// unsigned like a browser-only post. The channel, sender and tenant are the
// visitor row's, never the caller's.
type EmbedPost struct {
	MsgID, TaskID string
	TS            time.Time
	Body          string
	Inner, Canon  []byte // the v:1 message and the canonical envelope
	At, Expires   time.Time
}

// pgEmbedPost stores one visitor post: no delivery row (no box reads a
// visitor channel yet), no hours minute (a visitor is not a member), and the
// browsers' wake (pg_notify) as every insert. ErrConflict when the msg id is
// taken; the channel scope's WITH CHECK refuses any other channel.
const pgEmbedPost = `WITH ins AS (
		INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body,
			files, msg, env_sig, env, received_at, expires_at, is_parent)
		VALUES ($1, $2, $3, $4, $5, 'box-wui', $6, 'box-wui', 'ALL-0', 'note', $7, '[]', $8, '', $9, $10, $11, 1)
		ON CONFLICT (tenant_id, msg_id) DO NOTHING
		RETURNING 1),
	nfy AS (SELECT pg_notify('` + WUIWakeChannel + `', $1 || '|' || $2::text) FROM ins)
	SELECT EXISTS (SELECT 1 FROM ins), (SELECT count(*) FROM nfy)`

// PostEmbedVisitorMessage stores p in v's channel, as v, under v's channel
// scope.
func (s *Postgres) PostEmbedVisitorMessage(ctx context.Context, v EmbedVisitor, p EmbedPost) error {
	return s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) error {
		var inserted bool
		var notified int64
		if err := tx.QueryRow(ctx, pgEmbedPost, v.TenantID, p.MsgID, p.TaskID, v.ChannelID, p.TS, v.HumanID, p.Body,
			string(p.Inner), p.Canon, p.At, p.Expires).Scan(&inserted, &notified); err != nil {
			return err
		}
		if !inserted {
			return ErrConflict
		}
		return nil
	})
}

// EraseEmbedVisitor is the visitor's erasure on request (spec 4.4): its
// channel's messages, the channel (channel_humans and the embed_visitors row,
// so the token, cascade from it), its channel_guest membership and its HUM
// row, in one transaction under the channel scope. Erasing twice is a no-op.
// The door cache needs no forget: it holds members' rows, and no member is
// in a visitor channel.
func (s *Postgres) EraseEmbedVisitor(ctx context.Context, v EmbedVisitor) error {
	return s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) error {
		for _, q := range []struct {
			sql  string
			args []any
		}{
			{`DELETE FROM messages WHERE tenant_id = $1 AND channel = $2`, []any{v.TenantID, v.ChannelID}},
			{`DELETE FROM channels WHERE tenant_id = $1 AND channel_id = $2`, []any{v.TenantID, v.ChannelID}},
			{`DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2 AND role = $3`,
				[]any{v.TenantID, v.HumanID, rbac.ChannelGuest}},
			{`DELETE FROM humans h WHERE h.human_id = $1 AND h.kind = 'channel_guest'
				AND NOT EXISTS (SELECT 1 FROM tenant_memberships m WHERE m.human_id = h.human_id)`, []any{v.HumanID}},
		} {
			if _, err := tx.Exec(ctx, q.sql, q.args...); err != nil {
				return err
			}
		}
		return nil
	})
}
