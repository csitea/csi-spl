package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 059 §11 S2, rdb 0100: the box commits a delivery once its inbox copy
// is written (Kafka's "commit after processing"; per record, as a share group
// acks, because a hello drain and a live push can reach the box out of order).
// ClaimSent keeps the old meaning for a box without the commit feature: the
// row is acked the moment it is claimed.

// Acks is implemented by stores that keep the per-delivery commit.
type Acks interface {
	// ClaimSentUnacked is ClaimSent for a committing box: the row is sent
	// but NOT acked until AckDelivery.
	ClaimSentUnacked(ctx context.Context, tenant, msgID, toBox string, now time.Time) (bool, error)
	// AckDelivery records the box's commit; a second commit is a no-op.
	AckDelivery(ctx context.Context, tenant, msgID, toBox string, now time.Time) error
	// UnackedFor lists the sent, unacked, unexpired rows of a box last sent
	// before sentBefore, oldest first.
	UnackedFor(ctx context.Context, tenant, toBox string, now, sentBefore time.Time) ([]Queued, error)
	// ReclaimUnacked takes one such row for a new push (sent_at = now) and
	// reports whether this caller got it, so two pushers never both send it.
	ReclaimUnacked(ctx context.Context, tenant, msgID, toBox string, now, sentBefore time.Time) (bool, error)
}

func (s *Postgres) ClaimSentUnacked(ctx context.Context, tenant, msgID, toBox string, now time.Time) (bool, error) {
	tag, err := s.execTenant(ctx, tenant, `UPDATE deliveries SET state = 'sent', sent_at = $4, acked_at = NULL
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'queued' AND expires_at > $4`,
		tenant, msgID, toBox, now)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Postgres) AckDelivery(ctx context.Context, tenant, msgID, toBox string, now time.Time) error {
	_, err := s.execTenant(ctx, tenant, `UPDATE deliveries SET acked_at = $4
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'sent' AND acked_at IS NULL`,
		tenant, msgID, toBox, now)
	return err
}

func (s *Postgres) UnackedFor(ctx context.Context, tenant, toBox string, now, sentBefore time.Time) ([]Queued, error) {
	var out []Queued
	err := s.queryTenant(ctx, tenant, `SELECT d.msg_id::text, m.env FROM deliveries d
		JOIN messages m ON m.tenant_id = d.tenant_id AND m.msg_id = d.msg_id
		WHERE d.tenant_id = $1 AND d.to_box = $2 AND d.state = 'sent' AND d.acked_at IS NULL
		  AND d.sent_at < $4 AND d.expires_at > $3
		ORDER BY d.received_at, d.msg_id`, []any{tenant, toBox, now, sentBefore}, func(rows pgx.Rows) error {
		var q Queued
		if err := rows.Scan(&q.MsgID, &q.Env); err != nil {
			return err
		}
		out = append(out, q)
		return nil
	})
	return out, err
}

func (s *Postgres) ReclaimUnacked(ctx context.Context, tenant, msgID, toBox string, now, sentBefore time.Time) (bool, error) {
	tag, err := s.execTenant(ctx, tenant, `UPDATE deliveries SET sent_at = $4
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'sent' AND acked_at IS NULL
		  AND sent_at < $5 AND expires_at > $4`, tenant, msgID, toBox, now, sentBefore)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Memory) ClaimSentUnacked(_ context.Context, tenant, msgID, toBox string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deliveries[[3]string{tenant, msgID, toBox}]
	if !ok || d.state != StateQueued || !now.Before(d.expiresAt) {
		return false, nil
	}
	d.state, d.sentAt, d.acked = StateSent, now, false
	return true, nil
}

func (s *Memory) AckDelivery(_ context.Context, tenant, msgID, toBox string, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d, ok := s.deliveries[[3]string{tenant, msgID, toBox}]; ok && d.state == StateSent {
		d.acked = true
	}
	return nil
}

func (s *Memory) UnackedFor(_ context.Context, tenant, toBox string, now, sentBefore time.Time) ([]Queued, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	type row struct {
		id string
		d  *memDelivery
	}
	var rows []row
	for k, d := range s.deliveries {
		if k[0] == tenant && k[2] == toBox && d.state == StateSent && !d.acked &&
			d.sentAt.Before(sentBefore) && now.Before(d.expiresAt) {
			rows = append(rows, row{k[1], d})
		}
	}
	sort.Slice(rows, func(i, j int) bool { return older(rows[i].d, rows[j].d) })
	out := make([]Queued, 0, len(rows))
	for _, r := range rows {
		if m, ok := s.messages[[2]string{tenant, r.id}]; ok {
			out = append(out, Queued{MsgID: r.id, Env: m.Env})
		}
	}
	return out, nil
}

func (s *Memory) ReclaimUnacked(_ context.Context, tenant, msgID, toBox string, now, sentBefore time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deliveries[[3]string{tenant, msgID, toBox}]
	if !ok || d.state != StateSent || d.acked || !d.sentAt.Before(sentBefore) || !now.Before(d.expiresAt) {
		return false, nil
	}
	d.sentAt = now
	return true, nil
}
