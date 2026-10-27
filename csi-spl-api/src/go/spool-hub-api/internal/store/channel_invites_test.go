package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"
)

// Spec 025 section 11 (SPL-3686, rdb 0231): a pending channel membership for
// an invited address. Memory always, Postgres with a DSN (hub-pg.tst.sh,
// PRE_PUSH_TIER=full). Red on origin/master before SPL-3686: no
// ChannelInvites, the package does not compile.

type chInviteCase struct {
	ctx context.Context
	s   Store
	ci  ChannelInvites
	h   Humans
	tid string
	ch  string
	now time.Time
}

func newChInviteCase(t *testing.T, s Store) chInviteCase {
	t.Helper()
	c := chInviteCase{ctx: context.Background(), s: s, ci: s.(ChannelInvites), h: s.(Humans), tid: newTenant(t, s),
		ch: "launch", now: time.Now().UTC().Truncate(time.Microsecond)}
	if err := s.CreateChannel(c.ctx, Channel{TenantID: c.tid, ChannelID: c.ch, Name: c.ch, CreatedBy: "HUM-1", CreatedAt: c.now}); err != nil {
		t.Fatal(err)
	}
	return c
}

func (c chInviteCase) invite(t *testing.T, email string, at time.Time) {
	t.Helper()
	if err := c.h.PutInvite(c.ctx, Invite{TenantID: c.tid, Email: email, Role: "developer", InvitedBy: "HUM-1",
		ExpiresAt: at.Add(time.Hour)}, at); err != nil {
		t.Fatal(err)
	}
}

func (c chInviteCase) pending(t *testing.T, at time.Time) []string {
	t.Helper()
	out, err := c.ci.ChannelInvitees(c.ctx, c.tid, c.ch, at)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func (c chInviteCase) inChannel(t *testing.T, hum string) bool {
	t.Helper()
	ms, err := c.s.ChannelHumanMembers(c.ctx, c.tid, c.ch)
	if err != nil {
		t.Fatal(err)
	}
	return slices.Contains(ms, hum)
}

func (c chInviteCase) admit(email string, at time.Time) (string, error) {
	return c.h.Admit(c.ctx, Identity{Provider: "google", Subject: "s-" + email, Email: email}, c.tid, AdmitPolicy{}, at)
}

// TestChannelInviteAcceptJoins: the add needs an open invite, grants nothing
// before the invite is accepted, and the accepted invite puts the new member
// in the channel. CONTROL: an address with no invite is refused and writes
// nothing.
func TestChannelInviteAcceptJoins(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newChInviteCase(t, s)
			if err := c.ci.AddChannelInvite(c.ctx, c.tid, c.ch, "nobody@example.com", "HUM-1", c.now); !errors.Is(err, ErrNoOpenInvite) {
				t.Fatalf("no invite: %v, want ErrNoOpenInvite", err)
			}
			c.invite(t, "new@example.com", c.now)
			if err := c.ci.AddChannelInvite(c.ctx, c.tid, "no-such", "new@example.com", "HUM-1", c.now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown channel: %v, want ErrNotFound", err)
			}
			for i := 0; i < 2; i++ { // the second add changes nothing
				if err := c.ci.AddChannelInvite(c.ctx, c.tid, c.ch, " New@Example.com ", "HUM-1", c.now); err != nil {
					t.Fatalf("add %d: %v", i, err)
				}
			}
			if got := c.pending(t, c.now); !slices.Equal(got, []string{"new@example.com"}) {
				t.Fatalf("pending: %v", got)
			}
			hum, err := c.admit("new@example.com", c.now.Add(time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			if !c.inChannel(t, hum) {
				t.Fatalf("%s accepted the invite but is not in #%s", hum, c.ch)
			}
			if got := c.pending(t, c.now); len(got) != 0 {
				t.Fatalf("pending after accept: %v", got)
			}
		})
	}
}

// TestChannelInviteProvisionJoins: an operator seat accepts the invite too.
func TestChannelInviteProvisionJoins(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newChInviteCase(t, s)
			c.invite(t, "seat@example.com", c.now)
			if err := c.ci.AddChannelInvite(c.ctx, c.tid, c.ch, "seat@example.com", "HUM-1", c.now); err != nil {
				t.Fatal(err)
			}
			hum, _, err := s.(MemberProvisioner).ProvisionMember(c.ctx, ProvisionInput{Tenant: c.tid, Email: "seat@example.com",
				Role: "developer", OrderedBy: "HUM-1"}, c.now)
			if err != nil {
				t.Fatal(err)
			}
			if !c.inChannel(t, hum) {
				t.Fatalf("provisioned %s is not in #%s", hum, c.ch)
			}
		})
	}
}

// TestChannelInviteRevokeExpireRemove: a revoked invite takes its pending
// row with it; an expired one leaves it inert and a re-invite clears it; a
// re-invite of an OPEN invite keeps it; the adder may remove it.
func TestChannelInviteRevokeExpireRemove(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newChInviteCase(t, s)
			for _, e := range []string{"rev@example.com", "exp@example.com", "keep@example.com", "undo@example.com"} {
				c.invite(t, e, c.now)
				if err := c.ci.AddChannelInvite(c.ctx, c.tid, c.ch, e, "HUM-1", c.now); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.(MemberDirectory).RevokeInvite(c.ctx, c.tid, "rev@example.com"); err != nil {
				t.Fatal(err)
			}
			c.invite(t, "keep@example.com", c.now) // re-invite while open
			if err := c.ci.RemoveChannelInvite(c.ctx, c.tid, c.ch, "undo@example.com"); err != nil {
				t.Fatal(err)
			}
			if err := c.ci.RemoveChannelInvite(c.ctx, c.tid, c.ch, "undo@example.com"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second remove: %v, want ErrNotFound", err)
			}
			want := []string{"exp@example.com", "keep@example.com"}
			if got := c.pending(t, c.now); !slices.Equal(got, want) {
				t.Fatalf("pending: %v, want %v", got, want)
			}
			later := c.now.Add(2 * time.Hour) // every invite above has lapsed
			if got := c.pending(t, later); len(got) != 0 {
				t.Fatalf("pending after expiry: %v", got)
			}
			c.invite(t, "exp@example.com", later) // re-invite of a lapsed address
			c.invite(t, "rev@example.com", later)
			if got := c.pending(t, later); len(got) != 0 {
				t.Fatalf("a re-invite revived a lapsed or revoked pending row: %v", got)
			}
			for _, e := range []string{"exp@example.com", "rev@example.com"} {
				hum, err := c.admit(e, later.Add(time.Minute))
				if err != nil {
					t.Fatal(err)
				}
				if c.inChannel(t, hum) {
					t.Fatalf("%s (%s) joined #%s through a lapsed or revoked pending row", hum, e, c.ch)
				}
			}
		})
	}
}
