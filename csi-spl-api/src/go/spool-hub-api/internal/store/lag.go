package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 059 §11.1 S4, Kafka's consumer lag: per box, the delivery rows the hub
// sent that the box has not committed (rdb 0100 acked_at), and the age of the
// oldest. A box that never commits is not hidden: a dead box (no hello for
// days) is reported as lag, never kept or deleted silently. Read-only.

// BoxLag is one box's consumer lag.
type BoxLag struct {
	TenantID    string
	BoxID       string
	Uncommitted int       // state 'sent', acked_at NULL
	Queued      int       // state 'queued', unexpired: not sent yet
	OldestSent  time.Time // sent_at of the oldest uncommitted row; zero when Uncommitted == 0
	LastHello   time.Time // boxes.last_hello_at; zero = never said hello
}

// Dead reports a box with no hello within deadAfter (or none at all).
func (l BoxLag) Dead(now time.Time, deadAfter time.Duration) bool {
	return l.LastHello.IsZero() || now.Sub(l.LastHello) > deadAfter
}

// Alert reports a LIVE box whose oldest uncommitted row is older than maxAge.
// A dead box's lag is reported, but it is not an alert: nobody is there to poke.
func (l BoxLag) Alert(now time.Time, maxAge, deadAfter time.Duration) bool {
	return l.Uncommitted > 0 && !l.Dead(now, deadAfter) && now.Sub(l.OldestSent) > maxAge
}

// Lag is implemented by stores that can report consumer lag.
type Lag interface {
	// ConsumerLag lists every box, across tenants, with an uncommitted or a
	// queued row, ordered by tenant then box. A box with neither is not listed:
	// its lag is 0.
	ConsumerLag(ctx context.Context, now time.Time) ([]BoxLag, error)
}

// ConsumerLag reads the deliveries_unacked partial index (rdb 0100) for the
// uncommitted rows. Operator scope: lag is a fleet-wide report, no route.
func (s *Postgres) ConsumerLag(ctx context.Context, now time.Time) ([]BoxLag, error) {
	var out []BoxLag
	err := s.asOperatorQuery(ctx, `SELECT d.tenant_id, d.to_box,
			count(*) FILTER (WHERE d.state = 'sent' AND d.acked_at IS NULL),
			count(*) FILTER (WHERE d.state = 'queued'),
			min(d.sent_at) FILTER (WHERE d.state = 'sent' AND d.acked_at IS NULL),
			b.last_hello_at
		FROM deliveries d
		LEFT JOIN boxes b ON b.tenant_id = d.tenant_id AND b.box_id = d.to_box
		WHERE (d.state = 'sent' AND d.acked_at IS NULL) OR (d.state = 'queued' AND d.expires_at > $1)
		GROUP BY d.tenant_id, d.to_box, b.last_hello_at
		ORDER BY d.tenant_id, d.to_box`, []any{now}, func(rows pgx.Rows) error {
		var l BoxLag
		var oldest, hello *time.Time
		if err := rows.Scan(&l.TenantID, &l.BoxID, &l.Uncommitted, &l.Queued, &oldest, &hello); err != nil {
			return err
		}
		if oldest != nil {
			l.OldestSent = *oldest
		}
		if hello != nil {
			l.LastHello = *hello
		}
		out = append(out, l)
		return nil
	})
	return out, err
}

func (s *Memory) ConsumerLag(_ context.Context, now time.Time) ([]BoxLag, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	by := map[[2]string]*BoxLag{}
	for k, d := range s.deliveries {
		unc := d.state == StateSent && !d.acked
		que := d.state == StateQueued && now.Before(d.expiresAt)
		if !unc && !que {
			continue
		}
		bk := [2]string{k[0], k[2]}
		l, ok := by[bk]
		if !ok {
			l = &BoxLag{TenantID: k[0], BoxID: k[2], LastHello: s.boxes[bk]}
			by[bk] = l
		}
		if que {
			l.Queued++
			continue
		}
		l.Uncommitted++
		if l.OldestSent.IsZero() || d.sentAt.Before(l.OldestSent) {
			l.OldestSent = d.sentAt
		}
	}
	out := make([]BoxLag, 0, len(by))
	for _, l := range by {
		out = append(out, *l)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].TenantID != out[j].TenantID {
			return out[i].TenantID < out[j].TenantID
		}
		return out[i].BoxID < out[j].BoxID
	})
	return out, nil
}
