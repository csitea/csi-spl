package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of channel_invites.go (rdb 0231). Every call runs in the
// workspace's own scope; rdb 0231's tenant_scope policy is FOR ALL.

// AddChannelInvite records a pending membership (ChannelInvites).
func (s *Postgres) AddChannelInvite(ctx context.Context, tenant, channel, email, by string, now time.Time) error {
	channel, email = NormalizeChannel(channel), NormalizeInviteEmail(email)
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var open bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenant_invites
			WHERE tenant_id = $1 AND email = $2 AND accepted_at IS NULL AND expires_at > $3)`,
			tenant, email, now).Scan(&open); err != nil {
			return err
		}
		if !open {
			return ErrNoOpenInvite
		}
		_, err := tx.Exec(ctx, `INSERT INTO channel_invites (tenant_id, channel_id, email, added_by, created_at)
			VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING`, tenant, channel, email, by, now)
		return mapFK(err)
	})
}

// ChannelInvitees lists the open pending addresses (ChannelInvites).
func (s *Postgres) ChannelInvitees(ctx context.Context, tenant, channel string, now time.Time) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT c.email FROM channel_invites c
		JOIN tenant_invites v ON v.tenant_id = c.tenant_id AND v.email = c.email
		WHERE c.tenant_id = $1 AND c.channel_id = $2 AND v.accepted_at IS NULL AND v.expires_at > $3
		ORDER BY c.email`, []any{tenant, NormalizeChannel(channel), now},
		func(rows pgx.Rows) error {
			var e string
			if err := rows.Scan(&e); err != nil {
				return err
			}
			out = append(out, e)
			return nil
		})
	return out, err
}

// RemoveChannelInvite drops one pending row (ChannelInvites).
func (s *Postgres) RemoveChannelInvite(ctx context.Context, tenant, channel, email string) error {
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM channel_invites
		WHERE tenant_id = $1 AND channel_id = $2 AND email = $3`, tenant, NormalizeChannel(channel), NormalizeInviteEmail(email))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// promoteChannelInvitesTx moves the pending channel rows of the just
// accepted (tenant, email) invite into channel_humans for hum. tx runs in the
// tenant scope. Admit needs no door-cache clearing: the cache holds found
// memberships only, and hum had none in tenant before this transaction.
func promoteChannelInvitesTx(ctx context.Context, tx pgx.Tx, tenant, email, hum string, now time.Time) error {
	if email == "" {
		return nil
	}
	_, err := tx.Exec(ctx, `WITH moved AS (DELETE FROM channel_invites
			WHERE tenant_id = $1 AND email = $2 RETURNING channel_id, added_by)
		INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by)
		SELECT $1, channel_id, $3, $4, added_by FROM moved ON CONFLICT DO NOTHING`, tenant, email, hum, now)
	return err
}
