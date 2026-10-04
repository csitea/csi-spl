package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The tenant's member directory (specs/025 FR-012): what the
// admin's Users page lists, and the one write it adds beyond Humans - the
// revoke of a pending invite. Every read is tenant-scoped (RLS in Postgres).

// Member is one membership with the human's name and address.
type Member struct {
	HumanID     string
	DisplayName string
	Email       string
	// Interests is the member's free-text interests (humans.interests, rdb
	// 0086, CLE-77794), "" when none. Shown in the People section's info card.
	Interests string
	Role      string
	Since     time.Time // tenant_memberships.created_at
	Disabled  bool      // the account (humans.disabled_at), every tenant
	// Suspended: this membership only (tenant_memberships.disabled_at, rdb
	// 0074, specs/046).
	Suspended bool
	// LastSeen: tenant_memberships.last_active_at; zero = never.
	LastSeen time.Time
	// AccessUntil: tenant_memberships.access_until (rdb 0113, spec 072 A27),
	// when this membership stops granting access; zero = no end.
	AccessUntil time.Time
	// Provenance of the invite this member accepted (rdb 0084), read by
	// joining tenant_invites on accepted_by = human_id. All zero when the
	// member did not come through an invite (bootstrap, or an operator seat
	// with no invite) or the invite predates 0084.
	OrderedBy     string    // the human who ordered the invite, a HUM-* id
	OrderedByName string    // that human's display name, "" when none/unknown
	OrderedVia    string    // the agent/channel that carried the order
	InvitedOn     time.Time // tenant_invites.created_at of the accepted invite
}

// PendingInvite is one invite nobody has accepted yet (expired ones too:
// the admin sees them to re-invite or revoke).
type PendingInvite struct {
	Invite
	CreatedAt time.Time
	MailCount int
	// MailedAt is the last invitation mail (nil = never). A re-invite resets
	// MailCount but keeps MailedAt (FR-016's gap), so the page reads this,
	// not the count, to say whether and when the invite was mailed.
	MailedAt *time.Time
	// OrderedByName is OrderedBy's display name (rdb 0084), "" when none.
	OrderedByName string
}

// MemberDirectory is implemented by Memory and Postgres.
type MemberDirectory interface {
	// ListMembers is every membership of tenant, oldest first.
	ListMembers(ctx context.Context, tenant string) ([]Member, error)
	// ListInvites is every unaccepted invite of tenant, oldest first.
	ListInvites(ctx context.Context, tenant string) ([]PendingInvite, error)
	// RevokeInvite deletes the unaccepted (tenant, email) invite;
	// ErrNotFound when there is none.
	RevokeInvite(ctx context.Context, tenant, email string) error
}

var (
	_ MemberDirectory = (*Memory)(nil)
	_ MemberDirectory = (*Postgres)(nil)
)

func (s *Memory) ListMembers(_ context.Context, tenant string) ([]Member, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	out := []Member{}
	for k, m := range s.hum.members {
		if k[0] != tenant {
			continue
		}
		row := Member{HumanID: k[1], Role: m.role, Since: m.since, Suspended: m.disabled, LastSeen: m.lastActive,
			AccessUntil: m.accessUntil, OrderedBy: m.orderedBy, OrderedVia: m.orderedVia, InvitedOn: m.invitedOn}
		if hm, ok := s.hum.humans[k[1]]; ok {
			row.DisplayName, row.Email, row.Disabled, row.Interests = hm.name, hm.email, hm.disabled, hm.interests
		}
		if m.orderedBy != "" {
			if ho, ok := s.hum.humans[m.orderedBy]; ok {
				row.OrderedByName = ho.name
			}
		}
		out = append(out, row)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].Since.Equal(out[j].Since) {
			return out[i].Since.Before(out[j].Since)
		}
		return out[i].HumanID < out[j].HumanID
	})
	return out, nil
}

func (s *Memory) ListInvites(_ context.Context, tenant string) ([]PendingInvite, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	out := []PendingInvite{}
	for k, in := range s.hum.invites {
		if k[0] == tenant && !in.accepted {
			p := PendingInvite{Invite: in.Invite, CreatedAt: in.createdAt, MailCount: in.mailCount}
			if in.mailedAt != nil {
				at := *in.mailedAt
				p.MailedAt = &at
			}
			if in.OrderedBy != "" {
				if ho, ok := s.hum.humans[in.OrderedBy]; ok {
					p.OrderedByName = ho.name
				}
			}
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.Before(out[j].CreatedAt)
		}
		return out[i].Email < out[j].Email
	})
	return out, nil
}

func (s *Memory) RevokeInvite(_ context.Context, tenant, email string) error {
	email = strings.ToLower(strings.TrimSpace(email))
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, email}
	if in, ok := s.hum.invites[k]; !ok || in.accepted {
		return ErrNotFound
	}
	delete(s.hum.invites, k)
	return nil
}

func (s *Postgres) ListMembers(ctx context.Context, tenant string) ([]Member, error) {
	out := []Member{}
	r := listMembersRead(tenant, &out, s.hasAccessUntil(ctx))
	if err := s.queryTenant(ctx, tenant, r.sql, r.args, r.each); err != nil {
		return nil, err
	}
	return out, nil
}

// listMembersRead is ListMembers' statement, shared with ViewRoster's batch;
// withAccess reads rdb 0113 access_until (NULL before it).
func listMembersRead(tenant string, out *[]Member, withAccess bool) tenantRead {
	return tenantRead{sql: `SELECT m.human_id, coalesce(h.display_name, ''), coalesce(h.email, ''), coalesce(h.interests, ''), m.role,
			m.created_at, h.disabled_at IS NOT NULL, m.disabled_at IS NOT NULL, m.last_active_at,
			ti.ordered_by, coalesce(ho.display_name, ''), ti.ordered_via, ti.created_at, ` + accessUntilCol(withAccess) + `
		FROM tenant_memberships m JOIN humans h ON h.human_id = m.human_id
		LEFT JOIN tenant_invites ti ON ti.tenant_id = m.tenant_id AND ti.accepted_by = m.human_id
		LEFT JOIN humans ho ON ho.human_id = ti.ordered_by
		WHERE m.tenant_id = $1 AND NOT h.technical ORDER BY m.created_at, m.human_id`, args: []any{tenant}, each: func(rows pgx.Rows) error {
		var m Member
		var seen, invitedOn, until *time.Time
		var orderedBy, orderedVia *string
		if err := rows.Scan(&m.HumanID, &m.DisplayName, &m.Email, &m.Interests, &m.Role, &m.Since, &m.Disabled, &m.Suspended, &seen,
			&orderedBy, &m.OrderedByName, &orderedVia, &invitedOn, &until); err != nil {
			return err
		}
		if seen != nil {
			m.LastSeen = seen.UTC()
		}
		if orderedBy != nil {
			m.OrderedBy = *orderedBy
		}
		if orderedVia != nil {
			m.OrderedVia = *orderedVia
		}
		if invitedOn != nil {
			m.InvitedOn = invitedOn.UTC()
		}
		if until != nil {
			m.AccessUntil = until.UTC()
		}
		*out = append(*out, m)
		return nil
	}}
}

func (s *Postgres) ListInvites(ctx context.Context, tenant string) ([]PendingInvite, error) {
	out := []PendingInvite{}
	err := s.queryTenant(ctx, tenant, `SELECT ti.tenant_id, ti.email, ti.role, ti.invited_by, ti.expires_at, ti.created_at, ti.mail_count, ti.mailed_at,
			ti.ordered_by, coalesce(ho.display_name, ''), ti.ordered_via
		FROM tenant_invites ti LEFT JOIN humans ho ON ho.human_id = ti.ordered_by
		WHERE ti.tenant_id = $1 AND ti.accepted_at IS NULL ORDER BY ti.created_at, ti.email`,
		[]any{tenant}, func(rows pgx.Rows) error {
			var p PendingInvite
			var orderedBy, orderedVia *string
			if err := rows.Scan(&p.TenantID, &p.Email, &p.Role, &p.InvitedBy, &p.ExpiresAt, &p.CreatedAt, &p.MailCount, &p.MailedAt,
				&orderedBy, &p.OrderedByName, &orderedVia); err != nil {
				return err
			}
			if orderedBy != nil {
				p.OrderedBy = *orderedBy
			}
			if orderedVia != nil {
				p.OrderedVia = *orderedVia
			}
			out = append(out, p)
			return nil
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Postgres) RevokeInvite(ctx context.Context, tenant, email string) error {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return errors.New("invite email is required")
	}
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM tenant_invites
		WHERE tenant_id = $1 AND email = $2 AND accepted_at IS NULL`, tenant, email)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
