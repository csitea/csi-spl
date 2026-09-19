package store

import (
	"context"
	"errors"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// AuthHooks adapts Humans to the sign-in package's hooks (010 T012/T013):
// auth.Registrar (a callback admits the human) and auth.Membership (the view
// door asks MemberRole on every request, so a removed member is out at once).
type AuthHooks struct {
	H      Humans
	Policy AdmitPolicy
	Now    func() time.Time // nil = time.Now
}

var (
	_ auth.Registrar        = AuthHooks{}
	_ auth.Membership       = AuthHooks{}
	_ auth.IdentityUnlinker = AuthHooks{}
)

// Register maps ErrNotAdmitted to auth.ErrNotAllowed (auth_error=not_allowed).
// Identity.Email is provider-verified (auth FR-004), so it may match an invite.
func (a AuthHooks) Register(ctx context.Context, id auth.Identity, tenant string) (string, error) {
	now := time.Now
	if a.Now != nil {
		now = a.Now
	}
	hum, err := a.H.Admit(ctx, Identity{Provider: id.Provider, Subject: id.Subject, Email: id.Email, Name: id.Name},
		tenant, a.Policy, now().UTC())
	if errors.Is(err, ErrNotAdmitted) {
		return "", auth.ErrNotAllowed
	}
	return hum, err
}

// Member reports membership; any lookup error fails the door closed.
func (a AuthHooks) Member(ctx context.Context, humanID, tenant string) (bool, error) {
	_, err := a.H.MemberRole(ctx, humanID, tenant)
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	return err == nil, err
}

// Unlink removes one identity (Meta deauthorize / data deletion, 010 FR-013).
func (a AuthHooks) Unlink(ctx context.Context, provider, subject string) error {
	return a.H.UnlinkIdentity(ctx, provider, subject)
}
