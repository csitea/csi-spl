package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

// AuthHooks adapts Humans to the sign-in package's hooks (010 T012/T013):
// auth.Registrar (a callback admits the human) and auth.Membership (the view
// door asks MemberRole on every request, so a removed member is out at once).
type AuthHooks struct {
	H      Humans
	Policy AdmitPolicy
	Now    func() time.Time // nil = time.Now
	// Blob keeps the IdP picture (010 T044) under the tenant signed in to;
	// nil = pictures are dropped. The same store GET /v1/files/{file_id}
	// serves, so the WUI loads the avatar as a tenant file.
	Blob blob.Store
	// AvatarErr, when set, is told why a fetched picture was not stored.
	// A picture never blocks the sign-in.
	AvatarErr func(humanID string, err error)
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
	if err != nil {
		return "", err
	}
	// After admission, so a refused sign-in writes no blob either.
	if err := a.storeAvatar(ctx, hum, tenant, id.Avatar); err != nil && a.AvatarErr != nil {
		a.AvatarErr(hum, err)
	}
	return hum, nil
}

// storeAvatar puts the already-checked picture bytes (auth.fetchAvatar:
// https, size cap, image type) at t/<tenant>/files/<sha256> and records that
// file_id on the human. Content-addressed: a repeat login writes nothing new.
// Without a tenant there is no blob prefix to put it under, so it waits for
// a sign-in to one.
func (a AuthHooks) storeAvatar(ctx context.Context, hum, tenant string, pic []byte) error {
	if a.Blob == nil || tenant == "" || len(pic) == 0 {
		return nil
	}
	if len(pic) > auth.AvatarMaxBytes {
		return errors.New("avatar over the size cap")
	}
	sum := sha256.Sum256(pic)
	fileID := hex.EncodeToString(sum[:])
	key, err := blob.Key(tenant, fileID)
	if err != nil {
		return err
	}
	if ok, err := a.Blob.Exists(ctx, key); err != nil || !ok {
		if err := a.Blob.Put(ctx, key, pic); err != nil {
			return err
		}
	}
	return a.H.SetAvatar(ctx, hum, fileID)
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
