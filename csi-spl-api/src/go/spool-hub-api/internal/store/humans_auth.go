package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
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
	_ auth.AvatarSource     = AuthHooks{}
	_ auth.Preferences      = AuthHooks{}
	_ auth.TenantLister     = AuthHooks{}
	_ auth.FederatedLookup  = AuthHooks{}
	_ auth.InviteLander     = AuthHooks{}
)

// Register maps ErrNotAdmitted and ErrSeatQuota to auth.ErrNotAllowed
// (auth_error=not_allowed).
// Identity.Email is provider-verified (auth FR-004), so it may match an invite.
func (a AuthHooks) Register(ctx context.Context, id auth.Identity, tenant string) (string, error) {
	now := time.Now
	if a.Now != nil {
		now = a.Now
	}
	hum, err := a.H.Admit(ctx, Identity{Provider: id.Provider, Subject: id.Subject, Email: id.Email, Name: id.Name},
		tenant, a.Policy, now().UTC())
	// An invited address whose invite lapsed: distinct code so the login page
	// says "ask for a fresh invite" (CLE-77781, SPL-1229). Checked before
	// ErrNotAdmitted — the two are different sentinels, order is just clarity.
	if errors.Is(err, ErrInviteExpired) {
		return "", auth.ErrInviteExpired
	}
	// A new seat over the M4 cap (009 D-6): the redirect has no status, so it
	// is not_allowed, and nothing was written.
	if errors.Is(err, ErrNotAdmitted) || errors.Is(err, ErrSeatQuota) {
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

// InvitedTenant is the workspace a sign-in that named no tenant lands in: the
// newest live invite for the provider-verified address, "" when there is none
// or the store keeps no invites (SPL-1230, auth.InviteLander).
func (a AuthHooks) InvitedTenant(ctx context.Context, email string) (string, error) {
	f, ok := a.H.(InviteFinder)
	if !ok || email == "" {
		return "", nil
	}
	now := time.Now
	if a.Now != nil {
		now = a.Now
	}
	ts, err := f.LiveInviteTenants(ctx, email, now().UTC())
	if err != nil || len(ts) == 0 {
		return "", err
	}
	return ts[0], nil
}

// storeAvatar puts the already-checked picture bytes (auth.fetchAvatar:
// https, size cap, image type) at avatars/<sha256>, hub-wide, and records
// that file_id on the human, on every sign-in: with no tenant, or before an
// invite is accepted, the person's own picture is still theirs (CLE-3406,
// GET /api/v1/auth/avatar). With a tenant it is also put at
// t/<tenant>/files/<sha256>, the tenant file the roster names (010 T044).
// Content-addressed: a repeat login writes nothing new; a changed picture
// is a new file_id.
func (a AuthHooks) storeAvatar(ctx context.Context, hum, tenant string, pic []byte) error {
	if a.Blob == nil || len(pic) == 0 {
		return nil
	}
	if len(pic) > auth.AvatarMaxBytes {
		return errors.New("avatar over the size cap")
	}
	sum := sha256.Sum256(pic)
	fileID := hex.EncodeToString(sum[:])
	own, err := blob.AvatarKey(fileID)
	if err != nil {
		return err
	}
	keys := []string{own}
	if tenant != "" {
		key, err := blob.Key(tenant, fileID)
		if err != nil {
			return err
		}
		keys = append(keys, key)
	}
	for _, key := range keys {
		if ok, err := a.Blob.Exists(ctx, key); err != nil || !ok {
			if err := a.Blob.Put(ctx, key, pic); err != nil {
				return err
			}
		}
	}
	return a.H.SetAvatar(ctx, hum, fileID)
}

// OwnAvatar is the signed-in human's own stored picture (auth.AvatarSource):
// the bytes at avatars/<file_id>, or auth.ErrNoAvatar when the human has none
// or it was stored before the hub-wide copy existed (the next sign-in puts it).
func (a AuthHooks) OwnAvatar(ctx context.Context, humanID string) ([]byte, error) {
	if a.Blob == nil {
		return nil, auth.ErrNoAvatar
	}
	fid, err := a.H.Avatar(ctx, humanID)
	if errors.Is(err, ErrNotFound) || (err == nil && fid == "") {
		return nil, auth.ErrNoAvatar
	}
	if err != nil {
		return nil, err
	}
	key, err := blob.AvatarKey(fid)
	if err != nil {
		return nil, auth.ErrNoAvatar
	}
	rc, err := a.Blob.Get(ctx, key)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, auth.ErrNoAvatar
	}
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, auth.AvatarMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) > auth.AvatarMaxBytes {
		return nil, errors.New("stored avatar over the size cap")
	}
	return b, nil
}

// Member reports membership; any lookup error fails the door closed.
func (a AuthHooks) Member(ctx context.Context, humanID, tenant string) (bool, error) {
	_, err := a.H.MemberRole(ctx, humanID, tenant)
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	return err == nil, err
}

// Tenants lists the human's memberships (specs/026 §3) when the store can.
func (a AuthHooks) Tenants(ctx context.Context, humanID string) ([]auth.TenantRole, error) {
	ml, ok := a.H.(MembershipLister)
	if !ok {
		return nil, errors.New("store: memberships cannot be listed")
	}
	ms, err := ml.Memberships(ctx, humanID)
	if err != nil {
		return nil, err
	}
	out := make([]auth.TenantRole, 0, len(ms))
	for _, m := range ms {
		out = append(out, auth.TenantRole{TenantID: m.TenantID, Role: m.Role, DisplayName: m.DisplayName,
			LastActiveAt: m.LastActiveAt, Settings: m.Settings})
	}
	return out, nil
}

// TouchTenant stamps the membership the human just switched into (specs/026
// §6); a non-member is auth.ErrNotMember.
func (a AuthHooks) TouchTenant(ctx context.Context, humanID, tenant string) error {
	mt, ok := a.H.(MembershipToucher)
	if !ok {
		return errors.New("store: memberships cannot be touched")
	}
	now := time.Now
	if a.Now != nil {
		now = a.Now
	}
	err := mt.TouchMembership(ctx, humanID, tenant, now())
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNotMember
	}
	return err
}

// Unlink removes one identity (Meta deauthorize / data deletion, 010 FR-013).
func (a AuthHooks) Unlink(ctx context.Context, provider, subject string) error {
	return a.H.UnlinkIdentity(ctx, provider, subject)
}

// PreferredLocale is the human's picked locale; an unknown human
// is auth.ErrNoHuman.
func (a AuthHooks) PreferredLocale(ctx context.Context, humanID string) (string, error) {
	loc, err := a.H.PreferredLocale(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return "", auth.ErrNoHuman
	}
	return loc, err
}

// SetPreferredLocale stores it ("" clears); an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetPreferredLocale(ctx context.Context, humanID, locale string) error {
	err := a.H.SetPreferredLocale(ctx, humanID, locale)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// PreferredTheme is the human's colour theme; an unknown human is auth.ErrNoHuman.
func (a AuthHooks) PreferredTheme(ctx context.Context, humanID string) (string, error) {
	theme, err := a.H.PreferredTheme(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return "", auth.ErrNoHuman
	}
	return theme, err
}

// SetPreferredTheme stores it ("" clears); an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetPreferredTheme(ctx context.Context, humanID, theme string) error {
	err := a.H.SetPreferredTheme(ctx, humanID, theme)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// SubmitKey is the human's Behaviour "Text fields" choice (SPL-976); an
// unknown human is auth.ErrNoHuman.
func (a AuthHooks) SubmitKey(ctx context.Context, humanID string) (string, error) {
	key, err := a.H.SubmitKey(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return "", auth.ErrNoHuman
	}
	return key, err
}

// SetSubmitKey stores it ("" clears); an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetSubmitKey(ctx context.Context, humanID, key string) error {
	err := a.H.SetSubmitKey(ctx, humanID, key)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// RailOrder is the human's left-rail order (SPL-979); an unknown human is
// auth.ErrNoHuman.
func (a AuthHooks) RailOrder(ctx context.Context, humanID string) ([]string, error) {
	order, err := a.H.RailOrder(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return nil, auth.ErrNoHuman
	}
	return order, err
}

// SetRailOrder stores it (nil clears); an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetRailOrder(ctx context.Context, humanID string, order []string) error {
	err := a.H.SetRailOrder(ctx, humanID, order)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// ViewPref is one of the human's layout choices (topic c6994436); an unknown
// human is auth.ErrNoHuman.
func (a AuthHooks) ViewPref(ctx context.Context, humanID, key string) (string, error) {
	v, err := a.H.ViewPref(ctx, humanID, key)
	if errors.Is(err, ErrNotFound) {
		return "", auth.ErrNoHuman
	}
	return v, err
}

// SetViewPref stores it ("" clears); an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetViewPref(ctx context.Context, humanID, key, value string) error {
	err := a.H.SetViewPref(ctx, humanID, key, value)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// IssueColumns is the human's Issues sheet column widths (SPL-1132); an
// unknown human is auth.ErrNoHuman.
func (a AuthHooks) IssueColumns(ctx context.Context, humanID string) (map[string]int, error) {
	cols, err := a.H.IssueColumns(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return nil, auth.ErrNoHuman
	}
	return cols, err
}

// SetIssueColumns stores them (nil clears); an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetIssueColumns(ctx context.Context, humanID string, cols map[string]int) error {
	err := a.H.SetIssueColumns(ctx, humanID, cols)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// DiagnosticsEnabled is the human's "Debug pane" setting; an
// unknown human is auth.ErrNoHuman.
func (a AuthHooks) DiagnosticsEnabled(ctx context.Context, humanID string) (bool, error) {
	on, err := a.H.DiagnosticsEnabled(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return false, auth.ErrNoHuman
	}
	return on, err
}

// SetDiagnosticsEnabled stores it; an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetDiagnosticsEnabled(ctx context.Context, humanID string, on bool) error {
	err := a.H.SetDiagnosticsEnabled(ctx, humanID, on)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// DisplayName is the human's shown name; an unknown human is
// auth.ErrNoHuman.
func (a AuthHooks) DisplayName(ctx context.Context, humanID string) (string, error) {
	name, err := a.H.DisplayName(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return "", auth.ErrNoHuman
	}
	return name, err
}

// SetDisplayName stores it; an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetDisplayName(ctx context.Context, humanID, name string) error {
	err := a.H.SetDisplayName(ctx, humanID, name)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// Interests is the human's free-text interests (rdb 0086); an unknown human is
// auth.ErrNoHuman.
func (a AuthHooks) Interests(ctx context.Context, humanID string) (string, error) {
	v, err := a.H.Interests(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return "", auth.ErrNoHuman
	}
	return v, err
}

// SetInterests stores it ("" clears); an unknown human is auth.ErrNoHuman.
func (a AuthHooks) SetInterests(ctx context.Context, humanID, interests string) error {
	err := a.H.SetInterests(ctx, humanID, interests)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// IdentityLocale is the picked locale of the human behind one sign-in.
func (a AuthHooks) IdentityLocale(ctx context.Context, provider, subject string) (string, error) {
	return a.H.IdentityLocale(ctx, provider, subject)
}

// FederatedAccount tells the forgot-password route that an address with no
// password credential is nonetheless a known IdP account (CLE-3451 defect 1).
func (a AuthHooks) FederatedAccount(ctx context.Context, email string) ([]string, string, error) {
	return a.H.FederatedAccount(ctx, email)
}
