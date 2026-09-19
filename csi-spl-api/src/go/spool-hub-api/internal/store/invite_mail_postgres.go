package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// ClaimInviteMail reads the invite FOR UPDATE in the tenant's scope (0014
// RLS) and, when decideInviteMail allows it, records the send in the same
// transaction.
func (s *Postgres) ClaimInviteMail(ctx context.Context, tenant, email string, lim InviteMailLimits, now time.Time) (InviteMailClaim, error) {
	if err := checkInviteMailArgs(&email, lim); err != nil {
		return InviteMailClaim{}, err
	}
	now = now.UTC().Truncate(time.Microsecond) // timestamptz precision: Release matches it
	var c InviteMailClaim
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var acceptedAt *time.Time
		in := Invite{TenantID: tenant, Email: email}
		err := tx.QueryRow(ctx, `SELECT role, invited_by, expires_at, accepted_at, mailed_at, mail_count
			FROM tenant_invites WHERE tenant_id = $1 AND email = $2 FOR UPDATE`, tenant, email).
			Scan(&in.Role, &in.InvitedBy, &in.ExpiresAt, &acceptedAt, &c.PrevMailedAt, &c.PrevMailCount)
		if errors.Is(err, pgx.ErrNoRows) {
			c.Outcome = InviteMailNotFound
			return nil
		}
		if err != nil {
			return err
		}
		c.Invite = in
		c.Outcome = decideInviteMail(acceptedAt != nil, in.ExpiresAt, c.PrevMailedAt, c.PrevMailCount, lim, now)
		if c.Outcome != InviteMailClaimed {
			return nil
		}
		c.ClaimedAt = now
		_, err = tx.Exec(ctx, `UPDATE tenant_invites SET mailed_at = $3, mail_count = mail_count + 1
			WHERE tenant_id = $1 AND email = $2`, tenant, email, now)
		return err
	})
	if err != nil {
		return InviteMailClaim{}, err
	}
	return c, nil
}

// ReleaseInviteMail restores the pre-claim state while the row still carries
// this claim's mailed_at (a later claim is never undone).
func (s *Postgres) ReleaseInviteMail(ctx context.Context, c InviteMailClaim) error {
	if c.Outcome != InviteMailClaimed {
		return nil
	}
	_, err := s.execTenant(ctx, c.Invite.TenantID, `UPDATE tenant_invites SET mailed_at = $4, mail_count = $5
		WHERE tenant_id = $1 AND email = $2 AND mailed_at = $3`,
		c.Invite.TenantID, c.Invite.Email, c.ClaimedAt, c.PrevMailedAt, c.PrevMailCount)
	return err
}
