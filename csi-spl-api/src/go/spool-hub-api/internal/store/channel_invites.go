package store

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"
)

// Pending channel membership (rdb 0231, spec 025 section 11, SPL-3686): the
// channel owner puts the address of an OPEN workspace invite in a channel
// before that person has joined. The row grants nothing - the read door reads
// channel_humans only. Accepting the invite (Admit's invite path,
// ProvisionMember) moves every row of the address to channel_humans for the
// new member. A revoked invite takes its rows with it; an expired one leaves
// them inert (not listed, not moved) until a re-invite clears them.

// ErrNoOpenInvite: the address holds no open (unaccepted, unexpired) invite
// to the workspace, so nothing was written.
var ErrNoOpenInvite = errors.New("store: no open invite for that address")

// ChannelInvites is implemented by Memory and Postgres.
type ChannelInvites interface {
	// AddChannelInvite records the pending membership of email in channel.
	// ErrNoOpenInvite when the workspace has no open invite for email,
	// ErrNotFound when the channel does not exist. Already pending = nil.
	AddChannelInvite(ctx context.Context, tenant, channel, email, by string, now time.Time) error
	// ChannelInvitees is the sorted addresses pending in channel whose
	// invite is still open at now.
	ChannelInvitees(ctx context.Context, tenant, channel string, now time.Time) ([]string, error)
	// RemoveChannelInvite drops one pending row; ErrNotFound when none.
	RemoveChannelInvite(ctx context.Context, tenant, channel, email string) error
}

var (
	_ ChannelInvites = (*Memory)(nil)
	_ ChannelInvites = (*Postgres)(nil)
)

// NormalizeInviteEmail is the address form tenant_invites keys on.
func NormalizeInviteEmail(email string) string { return strings.ToLower(strings.TrimSpace(email)) }

// memChannelInviteKey is (tenant, channel, email).
type memChannelInviteKey [3]string

// openInviteLocked is the open invite of (tenant, email) at now, or nil. s.mu held.
func (s *Memory) openInviteLocked(tenant, email string, now time.Time) *memInvite {
	s.hum.init()
	i, ok := s.hum.invites[[2]string{tenant, email}]
	if !ok || i.accepted || !now.Before(i.ExpiresAt) {
		return nil
	}
	return i
}

// AddChannelInvite records a pending membership (ChannelInvites).
func (s *Memory) AddChannelInvite(_ context.Context, tenant, channel, email, by string, now time.Time) error {
	channel, email = NormalizeChannel(channel), NormalizeInviteEmail(email)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	if _, ok := s.ch.rows[[2]string{tenant, channel}]; !ok {
		return ErrNotFound
	}
	if s.openInviteLocked(tenant, email, now) == nil {
		return ErrNoOpenInvite
	}
	if s.chInvites == nil {
		s.chInvites = map[memChannelInviteKey]string{}
	}
	k := memChannelInviteKey{tenant, channel, email}
	if _, ok := s.chInvites[k]; !ok {
		s.chInvites[k] = by
	}
	return nil
}

// ChannelInvitees lists the open pending addresses (ChannelInvites).
func (s *Memory) ChannelInvitees(_ context.Context, tenant, channel string, now time.Time) ([]string, error) {
	channel = NormalizeChannel(channel)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	if _, ok := s.ch.rows[[2]string{tenant, channel}]; !ok {
		return nil, nil
	}
	var out []string
	for k := range s.chInvites {
		if k[0] == tenant && k[1] == channel && s.openInviteLocked(tenant, k[2], now) != nil {
			out = append(out, k[2])
		}
	}
	slices.Sort(out)
	return out, nil
}

// RemoveChannelInvite drops one pending row (ChannelInvites).
func (s *Memory) RemoveChannelInvite(_ context.Context, tenant, channel, email string) error {
	k := memChannelInviteKey{tenant, NormalizeChannel(channel), NormalizeInviteEmail(email)}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.chInvites[k]; !ok {
		return ErrNotFound
	}
	delete(s.chInvites, k)
	return nil
}

// promoteChannelInvitesLocked moves every pending row of (tenant, email) into
// channel_humans for hum: the invite was just accepted. s.mu held.
func (s *Memory) promoteChannelInvitesLocked(tenant, email, hum string) {
	s.ch.init()
	for k, by := range s.chInvites {
		if k[0] != tenant || k[2] != email {
			continue
		}
		delete(s.chInvites, k)
		if _, ok := s.ch.rows[[2]string{tenant, k[1]}]; !ok {
			continue // the channel was deleted: its pending rows go with it
		}
		ck := [2]string{tenant, k[1]}
		if s.ch.humansLocked()[ck] == nil {
			s.ch.humansLocked()[ck] = map[string]string{}
		}
		s.ch.humansLocked()[ck][hum] = by
	}
}

// dropChannelInvitesLocked forgets every pending row of (tenant, email): the
// invite was revoked, or is being replaced after it lapsed or was accepted. s.mu held.
func (s *Memory) dropChannelInvitesLocked(tenant, email string) {
	for k := range s.chInvites {
		if k[0] == tenant && k[2] == email {
			delete(s.chInvites, k)
		}
	}
}
