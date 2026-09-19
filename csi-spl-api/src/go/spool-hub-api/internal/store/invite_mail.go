package store

import (
	"context"
	"errors"
	"strings"
	"time"
)

// The invitation email's resend state (010 FR-016, rdb 0019). A send is
// claimed before the relay is called: one decision, taken under the row lock,
// so two concurrent resends cannot both mail.

// ClaimInviteMail outcomes. Only InviteMailClaimed may send.
const (
	InviteMailClaimed     = "claimed"
	InviteMailNotFound    = "not_found"
	InviteMailAccepted    = "skipped_accepted"
	InviteMailExpired     = "skipped_expired"
	InviteMailRateLimited = "rate_limited"
)

// InviteMailLimits bounds how often one invite is mailed.
type InviteMailLimits struct {
	// MinGap is the least time between two sends of one invite.
	MinGap time.Duration
	// MaxSends caps sends since the invite was last (re)created.
	MaxSends int
}

// InviteMailClaim is what ClaimInviteMail decided, with the invite it read.
type InviteMailClaim struct {
	Outcome string
	Invite  Invite
	// Prev* are mailed_at / mail_count before the claim (ReleaseInviteMail).
	PrevMailedAt  *time.Time
	PrevMailCount int
	// ClaimedAt is the mailed_at the claim wrote (zero unless claimed).
	ClaimedAt time.Time
}

// InviteMails is the store side of FR-016. Memory and Postgres implement it.
type InviteMails interface {
	// ClaimInviteMail decides whether the (tenant, email) invite may be
	// mailed now and, when it may, records the send (mailed_at = now,
	// mail_count + 1). Not-found / accepted / expired / rate-limited write
	// nothing.
	ClaimInviteMail(ctx context.Context, tenant, email string, lim InviteMailLimits, now time.Time) (InviteMailClaim, error)
	// ReleaseInviteMail undoes a claim whose relay send failed, only while
	// the row still carries that claim.
	ReleaseInviteMail(ctx context.Context, c InviteMailClaim) error
}

var (
	_ InviteMails = (*Memory)(nil)
	_ InviteMails = (*Postgres)(nil)
)

func checkInviteMailArgs(email *string, lim InviteMailLimits) error {
	*email = strings.ToLower(strings.TrimSpace(*email))
	if *email == "" {
		return errors.New("invite email is required")
	}
	if lim.MinGap < 0 || lim.MaxSends < 1 {
		return errors.New("invite mail limits need MinGap >= 0 and MaxSends >= 1")
	}
	return nil
}

// decideInviteMail is the one rule both stores apply.
func decideInviteMail(accepted bool, expiresAt time.Time, mailedAt *time.Time, count int, lim InviteMailLimits, now time.Time) string {
	switch {
	case accepted:
		return InviteMailAccepted
	case !now.Before(expiresAt):
		return InviteMailExpired
	case count >= lim.MaxSends:
		return InviteMailRateLimited
	case mailedAt != nil && now.Sub(*mailedAt) < lim.MinGap:
		return InviteMailRateLimited
	}
	return InviteMailClaimed
}

func (s *Memory) ClaimInviteMail(_ context.Context, tenant, email string, lim InviteMailLimits, now time.Time) (InviteMailClaim, error) {
	if err := checkInviteMailArgs(&email, lim); err != nil {
		return InviteMailClaim{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	i, ok := s.hum.invites[[2]string{tenant, email}]
	if !ok {
		return InviteMailClaim{Outcome: InviteMailNotFound}, nil
	}
	c := InviteMailClaim{Invite: i.Invite, PrevMailCount: i.mailCount}
	if i.mailedAt != nil {
		t := *i.mailedAt
		c.PrevMailedAt = &t
	}
	c.Outcome = decideInviteMail(i.accepted, i.ExpiresAt, i.mailedAt, i.mailCount, lim, now)
	if c.Outcome == InviteMailClaimed {
		t := now
		i.mailedAt, c.ClaimedAt = &t, now
		i.mailCount++
	}
	return c, nil
}

func (s *Memory) ReleaseInviteMail(_ context.Context, c InviteMailClaim) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	i, ok := s.hum.invites[[2]string{c.Invite.TenantID, c.Invite.Email}]
	if !ok || i.mailedAt == nil || !i.mailedAt.Equal(c.ClaimedAt) {
		return nil
	}
	i.mailedAt, i.mailCount = c.PrevMailedAt, c.PrevMailCount
	return nil
}
