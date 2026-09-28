package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The tenant's member directory (specs/025 FR-012, CLE-34969): what the
// admin's Users page lists, and the one write it adds beyond Humans - the
// revoke of a pending invite. Every read is tenant-scoped (RLS in Postgres).

// Member is one membership with the human's name and address.
type Member struct {
	HumanID     string
	DisplayName string
	Email       string
	Role        string
	Since       time.Time // tenant_memberships.created_at
	Disabled    bool      // the account (humans.disabled_at), every tenant
	// Suspended: this membership only (tenant_memberships.disabled_at, rdb
	// 0074, specs/046).
	Suspended bool
	// LastSeen: tenant_memberships.last_active_at; zero = never.
	LastSeen time.Time
}

// PendingInvite is one invite nobody has accepted yet (expired ones too:
// the admin sees them to re-invite or revoke).
type PendingInvite struct {
	Invite
	CreatedAt time.Time
	MailCount int
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
		row := Member{HumanID: k[1], Role: m.role, Since: m.since, Suspended: m.disabled, LastSeen: m.lastActive}
		if hm, ok := s.hum.humans[k[1]]; ok {
			row.DisplayName, row.Email, row.Disabled = hm.name, hm.email, hm.disabled
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
			out = append(out, PendingInvite{Invite: in.Invite, CreatedAt: in.createdAt, MailCount: in.mailCount})
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
	err := s.queryTenant(ctx, tenant, `SELECT m.human_id, coalesce(h.display_name, ''), coalesce(h.email, ''), m.role,
			m.created_at, h.disabled_at IS NOT NULL, m.disabled_at IS NOT NULL, m.last_active_at
		FROM tenant_memberships m JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 ORDER BY m.created_at, m.human_id`, []any{tenant}, func(rows pgx.Rows) error {
		var m Member
		var seen *time.Time
		if err := rows.Scan(&m.HumanID, &m.DisplayName, &m.Email, &m.Role, &m.Since, &m.Disabled, &m.Suspended, &seen); err != nil {
			return err
		}
		if seen != nil {
			m.LastSeen = seen.UTC()
		}
		out = append(out, m)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Postgres) ListInvites(ctx context.Context, tenant string) ([]PendingInvite, error) {
	out := []PendingInvite{}
	err := s.queryTenant(ctx, tenant, `SELECT tenant_id, email, role, invited_by, expires_at, created_at, mail_count
		FROM tenant_invites WHERE tenant_id = $1 AND accepted_at IS NULL ORDER BY created_at, email`,
		[]any{tenant}, func(rows pgx.Rows) error {
			var p PendingInvite
			if err := rows.Scan(&p.TenantID, &p.Email, &p.Role, &p.InvitedBy, &p.ExpiresAt, &p.CreatedAt, &p.MailCount); err != nil {
				return err
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
