package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The staff side of the visitor channels (specs/121 4.4, 6; T106, rdb
// 0172): the staff list, the lead mark, the owner's block, the #sales
// triage seats and the retention sweep. Staff calls run under the tenant
// scope (a staff member is a member); the sweep reads its candidates as the
// operator and removes each under that visitor's own channel scope. None of
// these is on a visitor's request path except where the hub calls them
// after the visitor's answer is written (hub/embed_staff.go).

// EmbedSalesChannel is the private triage channel of a selling workspace
// (spec 4.4): one line per new visitor channel, and per first post after
// EmbedTriageQuiet, a link only, never the message text.
const EmbedSalesChannel = "sales"

// EmbedStaff is the store side of the staff routes and the sweep; only
// Postgres implements it, as EmbedVisitors.
type EmbedStaff interface {
	EmbedVisitorChannels(ctx context.Context, tenant string, now time.Time) ([]EmbedVisitorChannel, error)
	SetEmbedLead(ctx context.Context, tenant, channel string, lead bool, now time.Time) error
	BlockEmbedVisitor(ctx context.Context, tenant, channel string, now time.Time) error
	EmbedTriageSeats(ctx context.Context, tenant, channel string, newChannel bool, now time.Time) error
	EmbedQuiet(ctx context.Context, tenant, channel, msgID string, since time.Time) (bool, error)
	EmbedRetentionDue(ctx context.Context, before time.Time, limit int) ([]EmbedVisitor, error)
	RetireEmbedVisitor(ctx context.Context, v EmbedVisitor, before time.Time) (bool, error)
}

var _ EmbedStaff = (*Postgres)(nil)

// EmbedVisitorChannel is one visitor channel as staff see it: no token, no
// e-mail, no ip_hash.
type EmbedVisitorChannel struct {
	ChannelID string
	EmbedID   string
	CreatedAt time.Time
	LastAt    time.Time // the newest message, else CreatedAt
	LeadAt    time.Time // zero = not a lead
	BlockedAt time.Time // zero = not blocked
	Live      bool      // the token is live (not expired, not blocked)
}

// embedStaffListMax caps the staff list: the sweep keeps it short (30 days).
const embedStaffListMax = 500

// pgEmbedLastAt is a visitor row's newest message time, else its mint.
const pgEmbedLastAt = `coalesce((SELECT max(m.received_at) FROM messages m
	WHERE m.tenant_id = v.tenant_id AND m.channel = v.channel_id), v.created_at)`

// EmbedVisitorChannels is tenant's visitor channels, newest activity first.
func (s *Postgres) EmbedVisitorChannels(ctx context.Context, tenant string, now time.Time) ([]EmbedVisitorChannel, error) {
	out := []EmbedVisitorChannel{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT v.channel_id, v.embed_id, v.created_at, `+pgEmbedLastAt+` AS last_at,
				v.lead_at, v.blocked_at, v.expires_at > $2
			FROM embed_visitors v WHERE v.tenant_id = $1
			ORDER BY last_at DESC, v.channel_id LIMIT $3`, []any{tenant, now, embedStaffListMax}, func(r pgx.Rows) error {
			var c EmbedVisitorChannel
			var lead, blocked *time.Time
			if err := r.Scan(&c.ChannelID, &c.EmbedID, &c.CreatedAt, &c.LastAt, &lead, &blocked, &c.Live); err != nil {
				return err
			}
			if lead != nil {
				c.LeadAt = *lead
			}
			if blocked != nil {
				c.BlockedAt = *blocked
			}
			out = append(out, c)
			return nil
		})
	})
	return out, err
}

// embedStaffWrite runs one UPDATE of tenant's visitor row of channel;
// ErrNotFound when channel is no visitor channel of tenant.
func (s *Postgres) embedStaffWrite(ctx context.Context, tenant, channel, sql string, args ...any) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, sql, append([]any{tenant, channel}, args...)...)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		return err
	})
}

// SetEmbedLead marks channel a lead at now (kept past retention), or clears
// the mark (lead false: retention counts from its last message again).
func (s *Postgres) SetEmbedLead(ctx context.Context, tenant, channel string, lead bool, now time.Time) error {
	return s.embedStaffWrite(ctx, tenant, channel, `UPDATE embed_visitors
		SET lead_at = CASE WHEN $3 THEN coalesce(lead_at, $4) END
		WHERE tenant_id = $1 AND channel_id = $2`, lead, now)
}

// BlockEmbedVisitor is the owner's block (spec 6): the token ends at now
// (an expired token never revives, SlideEmbedVisitor) and blocked_at says
// why; the channel and its messages stay. Blocking twice keeps the first
// time.
func (s *Postgres) BlockEmbedVisitor(ctx context.Context, tenant, channel string, now time.Time) error {
	return s.embedStaffWrite(ctx, tenant, channel, `UPDATE embed_visitors
		SET blocked_at = coalesce(blocked_at, $3), expires_at = LEAST(expires_at, $3)
		WHERE tenant_id = $1 AND channel_id = $2`, now)
}

// pgEmbedSeatStaff seats tenant's staff (a role set holding biz_owner or
// admin, rdb 0201; not disabled) in one channel; a row already there is kept
// as it is.
const pgEmbedSeatStaff = `INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by)
	SELECT m.tenant_id, $2, m.human_id, $3, 'hub' FROM tenant_memberships m
	WHERE m.tenant_id = $1 AND m.disabled_at IS NULL
	  AND EXISTS (SELECT 1 FROM tenant_member_roles x WHERE x.tenant_id = m.tenant_id
	              AND x.human_id = m.human_id AND x.role_id = ANY ($4::text[]))
	ON CONFLICT (tenant_id, channel_id, human_id) DO NOTHING`

// embedStaffRoles are the roles that see visitor channels (spec 4.4).
var embedStaffRoles = []string{rbac.BizOwner, rbac.Admin}

// EmbedTriageSeats prepares a triage line for channel in one transaction:
// the private #sales channel when tenant has none yet, with its staff
// seated, and, for a new visitor channel, the staff seated in it so the
// triage link opens (a later line re-seats nobody: who left, stays out).
// ErrNotFound when channel is no visitor channel of tenant.
func (s *Postgres) EmbedTriageSeats(ctx context.Context, tenant, channel string, newChannel bool, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM embed_visitors WHERE tenant_id = $1 AND channel_id = $2)`,
			tenant, channel).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		tag, err := tx.Exec(ctx, `INSERT INTO channels (tenant_id, channel_id, name, description, created_by, created_at, is_private)
			VALUES ($1, $2, $2, 'Website visitors: one line per new conversation', 'hub', $3, true)
			ON CONFLICT (tenant_id, channel_id) DO NOTHING`, tenant, EmbedSalesChannel, now)
		if err != nil {
			return err
		}
		seat := []string{}
		if newChannel {
			seat = append(seat, channel)
		}
		if tag.RowsAffected() == 1 {
			seat = append(seat, EmbedSalesChannel)
		}
		for _, ch := range seat {
			if _, err := tx.Exec(ctx, pgEmbedSeatStaff, tenant, ch, now, embedStaffRoles); err != nil {
				return err
			}
		}
		return nil
	})
}

// EmbedQuiet reports whether channel was quiet before msgID: made at or
// before since, and no other message received after since. A first post
// after quiet gets a triage line (spec 4.4); a post in a channel made after
// since does not (its mint had one).
func (s *Postgres) EmbedQuiet(ctx context.Context, tenant, channel, msgID string, since time.Time) (bool, error) {
	var quiet bool
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM embed_visitors v
			WHERE v.tenant_id = $1 AND v.channel_id = $2 AND v.created_at <= $4
			  AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = $1 AND m.channel = $2
			                  AND m.msg_id::text <> $3 AND m.received_at > $4))`,
			tenant, channel, msgID, since).Scan(&quiet)
	})
	return quiet, err
}

// pgEmbedRetentionDue is the retention rule (spec 4.4): not a lead, made
// before $1, and no message received at or after $1.
const pgEmbedRetentionDue = `v.lead_at IS NULL AND v.created_at < $1
	AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = v.tenant_id AND m.channel = v.channel_id
	                AND m.received_at >= $1)`

// EmbedRetentionDue is at most limit visitors, every workspace, whose
// channel is due for removal at before (now minus the retention). An
// operator read: the sweep has no tenant; RetireEmbedVisitor re-checks each
// under its own channel scope.
func (s *Postgres) EmbedRetentionDue(ctx context.Context, before time.Time, limit int) ([]EmbedVisitor, error) {
	out := []EmbedVisitor{}
	err := s.asOperatorQuery(ctx, `SELECT `+pgEmbedVisitorCols+` FROM embed_visitors v
		WHERE `+pgEmbedRetentionDue+` ORDER BY v.created_at LIMIT $2`, []any{before, limit}, func(r pgx.Rows) error {
		v, err := scanEmbedVisitor(r)
		if err == nil {
			out = append(out, v)
		}
		return err
	})
	return out, err
}

// RetireEmbedVisitor removes v's channel as the erasure does, under v's
// channel scope, only if it is still due at before (a post or a lead mark
// since the read keeps it). False when it was kept or is gone already.
func (s *Postgres) RetireEmbedVisitor(ctx context.Context, v EmbedVisitor, before time.Time) (bool, error) {
	var due bool
	err := s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT true FROM embed_visitors v WHERE v.tenant_id = $2 AND v.visitor_id = $3::uuid
			AND `+pgEmbedRetentionDue+` FOR UPDATE`, before, v.TenantID, v.VisitorID).Scan(&due)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		return eraseEmbedVisitorTx(ctx, tx, v)
	})
	return due, err
}
