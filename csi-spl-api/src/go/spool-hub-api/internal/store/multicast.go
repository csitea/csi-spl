package store

import (
	"context"
	"errors"
	"sort"

	"github.com/jackc/pgx/v5"
)

// Spec 186 row M2 (rdb 0321): the multicast id. A copy carries
// Message.McID; InsertMessage writes it (insertMessageArgs, $25) and
// MulticastAuthor reads who sent the multicast, so a second author cannot
// reuse an id (7.1.1); MulticastCopies lists the copies.

// MulticastAuthor: see Store.
func (s *Memory) MulticastAuthor(_ context.Context, tenant, mcID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, m := range s.messages {
		if k[0] == tenant && m.McID != "" && m.McID == mcID {
			return m.FromID, nil
		}
	}
	return "", ErrNotFound
}

// MulticastAuthor: see Store. Walks the partial index messages_mc_id.
func (s *Postgres) MulticastAuthor(ctx context.Context, tenant, mcID string) (string, error) {
	var from string
	err := s.queryRowTenant(ctx, tenant, `SELECT from_id FROM messages WHERE tenant_id = $1 AND mc_id = $2::uuid LIMIT 1`,
		[]any{tenant, mcID}, &from)
	if errors.Is(err, pgx.ErrNoRows) {
		err = ErrNotFound
	}
	return from, err
}

// MulticastCopies: see Store.
func (s *Memory) MulticastCopies(_ context.Context, tenant, mcID string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for k, m := range s.messages {
		if k[0] == tenant && m.McID != "" && m.McID == mcID {
			out = append(out, m.MsgID)
		}
	}
	sort.Strings(out)
	return out, nil
}

// MulticastCopies: see Store. Walks the partial index messages_mc_id.
func (s *Postgres) MulticastCopies(ctx context.Context, tenant, mcID string) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text FROM messages WHERE tenant_id = $1 AND mc_id = $2::uuid ORDER BY msg_id`,
		[]any{tenant, mcID}, func(rows pgx.Rows) error {
			var id string
			if err := rows.Scan(&id); err != nil {
				return err
			}
			out = append(out, id)
			return nil
		})
	return out, err
}
