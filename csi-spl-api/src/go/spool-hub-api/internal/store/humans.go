package store

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// ProviderNative is the provider slug of a native email+password identity
// (rdb 0006, rdb 0009). Every other slug is a federated (IdP) identity. Taken
// from auth so the two cannot drift; auth does not import store, so the
// direction is safe.
const ProviderNative = auth.ProviderPassword

// Humans, their sign-in identities and tenant membership (specs/010 T012/T013,
// FR-008, FR-012, OQ-A3, OQ-A5; rdb 0006_users_and_memberships.sql).
//
// CLE-3451 amends rdb 0006's note "a new identity is never linked to an
// existing human by email alone": it is linked when BOTH sides carry a
// PROVIDER-VERIFIED address (Admit, below). Keying humans on (provider,
// subject) alone made signing up with a password for an address that already
// had a Google identity mint a SECOND, unlinked human, which then had no
// invite and no bootstrap left and was refused with 403 not_allowed.

// ErrNotAdmitted refuses a sign-in to a tenant: not a member, no matching
// invite, and no bootstrap (FR-012). Nothing was written.
var ErrNotAdmitted = errors.New("not admitted to tenant")

// Membership roles (tenant_memberships.role) are rows since rdb 0021
// (specs/025): any role_id visible to the tenant. These two are the ones the
// store itself assigns.
const (
	// RoleTenantOwner is what bootstrap seats ("tenant owner = biz-owner").
	RoleTenantOwner = rbac.BizOwner
	// RoleDefault is an invite's role when it names none (025 OQ-8).
	RoleDefault = rbac.Developer
)

// Role refusals (025 FR-002, §3.4).
var (
	// ErrUnknownRole: the role is not visible to the tenant.
	ErrUnknownRole = errors.New("unknown role")
	// ErrLastOwner: the change would leave the tenant with no member holding
	// a tenant-owner role. Nothing was written.
	ErrLastOwner = errors.New("the tenant's last owner cannot be removed or demoted")
	// ErrRoleChanged: the member no longer holds the expected from-role.
	ErrRoleChanged = errors.New("the member's role changed")
	// ErrLastAdmin: the change would leave the tenant with no enabled member
	// whose role grants members.invite (owner 2026-09-25: only the admin adds
	// users, so an admin-less tenant could never add one again). Nothing was
	// written.
	ErrLastAdmin = errors.New("the tenant's last admin cannot be removed or demoted")
)

var roleRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)

// normalizeRole maps a legacy 010 name and checks the id shape; "" = def.
func normalizeRole(role, def string) (string, error) {
	role = rbac.Legacy(strings.TrimSpace(role))
	if role == "" {
		role = def
	}
	if !roleRe.MatchString(role) {
		return "", ErrUnknownRole
	}
	return role, nil
}

// Admitted-by markers for rows no owner HUM-* admitted.
const (
	AdmittedBootstrap = "bootstrap"
	AdmittedOperator  = "operator"
)

var providerRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// Identity is one verified sign-in: (Provider, Subject) is the key; Email is
// the provider-verified address (matched against invites), never a key.
type Identity struct {
	Provider string
	Subject  string
	Email    string
	Name     string
}

// AdmitPolicy is the admission switchboard (FR-012).
type AdmitPolicy struct {
	// BootstrapOwner: the first human on a tenant with zero members becomes
	// its owner. dev/lde only until the owner decides OQ-A5.
	BootstrapOwner bool
}

// Invite admits the first sign-in whose verified Email matches, once.
type Invite struct {
	TenantID  string
	Email     string
	Role      string
	InvitedBy string // owner HUM-* or AdmittedOperator
	ExpiresAt time.Time
}

// Humans is the store side of registration and membership. Memory and
// Postgres both implement it.
type Humans interface {
	// Admit upserts the human for (provider, subject) and, when tenant != "",
	// admits them to it (member already → ok; matching invite → its role;
	// BootstrapOwner and zero members → owner). A refusal is ErrNotAdmitted
	// and writes nothing, not even the human. A disabled human is refused.
	Admit(ctx context.Context, id Identity, tenant string, p AdmitPolicy, now time.Time) (humanID string, err error)
	// MemberRole returns the human's role in tenant, or ErrNotFound. A
	// disabled human has no role.
	MemberRole(ctx context.Context, humanID, tenant string) (string, error)
	// PutInvite creates or replaces the (tenant, email) invite. The tenant
	// must exist (ErrNotFound).
	PutInvite(ctx context.Context, in Invite, now time.Time) error
	// UnlinkIdentity deletes one (provider, subject) identity (Meta
	// deauthorize / data deletion). Unknown = nil.
	UnlinkIdentity(ctx context.Context, provider, subject string) error
	// SetAvatar records the human's picture as a blob file_id (a sha256 hex
	// digest, rdb 0010; 010 T044). Unknown human = ErrNotFound.
	SetAvatar(ctx context.Context, humanID, fileID string) error
	// Avatar returns the human's avatar file_id, "" when none, or ErrNotFound.
	Avatar(ctx context.Context, humanID string) (string, error)
	// TenantAvatars maps every member HUM-* of tenant (disabled humans
	// excluded) to its avatar file_id, "" when none (view-v1 §4.1 humans).
	TenantAvatars(ctx context.Context, tenant string) (map[string]string, error)
	// SetPreferredLocale records the human's picked locale (rdb 0017, CLE-3403),
	// one of i18n.Supported, or "" to clear it. Unknown human = ErrNotFound.
	SetPreferredLocale(ctx context.Context, humanID, locale string) error
	// PreferredLocale returns the human's picked locale, "" when none, or
	// ErrNotFound.
	PreferredLocale(ctx context.Context, humanID string) (string, error)
	// SetPreferredTheme records the human's colour theme, one of the palette
	// ids, or "" to clear it. Unknown human = ErrNotFound.
	SetPreferredTheme(ctx context.Context, humanID, theme string) error
	// PreferredTheme returns the human's theme, "" when none, or ErrNotFound.
	PreferredTheme(ctx context.Context, humanID string) (string, error)
	// IdentityLocale returns the picked locale of the human the (provider,
	// subject) sign-in belongs to; "" (nil error) when there is no such
	// identity or nothing is picked.
	IdentityLocale(ctx context.Context, provider, subject string) (string, error)
	// SetDiagnosticsEnabled records the human's "Debug pane" setting (rdb
	// 0038, CLE-34963). Unknown human = ErrNotFound.
	SetDiagnosticsEnabled(ctx context.Context, humanID string, on bool) error
	// DiagnosticsEnabled returns that setting, false when never set, or
	// ErrNotFound.
	DiagnosticsEnabled(ctx context.Context, humanID string) (bool, error)
	// SetDisplayName records the human's own shown name (CLE-34968), one the
	// auth layer's ValidDisplayName admitted. Unknown human = ErrNotFound.
	// Once a human has a name, Admit no longer replaces it with the IdP's.
	SetDisplayName(ctx context.Context, humanID, name string) error
	// DisplayName returns it, "" when none, or ErrNotFound.
	DisplayName(ctx context.Context, humanID string) (string, error)
	// FederatedAccount lists the providers, other than ProviderNative, whose
	// VERIFIED identity carries email on a human that is not disabled, sorted,
	// plus that human's picked locale ("" when none). An address nobody signs
	// in with is an empty list and a nil error. CLE-3451 defect 1: the
	// forgot-password route needs to tell a Google-only address apart from an
	// address that does not exist, WITHOUT saying so on the wire.
	FederatedAccount(ctx context.Context, email string) (providers []string, locale string, err error)
	// TenantRoles is every role visible to tenant (system + its own) with
	// its grants (rdb 0021; memory: rbac.Defaults).
	TenantRoles(ctx context.Context, tenant string) (map[string]rbac.Role, error)
	// SetMemberRole sets one member's role. from != "": only while the
	// member holds it (else ErrRoleChanged). ErrNotFound: not a member;
	// ErrUnknownRole; ErrLastOwner (025 §3.4 rule 3).
	SetMemberRole(ctx context.Context, tenant, humanID, role, from string) error
	// RemoveMember deletes one membership. ErrNotFound; ErrLastOwner.
	RemoveMember(ctx context.Context, tenant, humanID string) error
}

// checkLocale guards every stored locale (humans / password_credentials
// preferred_locale rdb 0017, payment_checkouts.buyer_locale rdb 0025): "" is
// "never said", anything else must be one of i18n.Supported.
func checkLocale(loc string) error {
	if loc != "" && !i18n.IsSupported(loc) {
		return errors.New("locale must be one of the supported locales")
	}
	return nil
}

// checkTheme admits "" (never picked) or one of auth.ThemeIDs, the one list
// the hub, PUT preferences and humans_preferred_theme_check agree on.
func checkTheme(theme string) error {
	if theme == "" || auth.IsTheme(theme) {
		return nil
	}
	return errors.New("theme must be one of the palette themes")
}

var fileIDRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

func checkFileID(id string) error {
	if !fileIDRe.MatchString(id) {
		return errors.New("avatar file_id must be a sha256 hex digest")
	}
	return nil
}

func normalizeIdentity(id *Identity) error {
	id.Provider = strings.TrimSpace(id.Provider)
	id.Email = strings.ToLower(strings.TrimSpace(id.Email))
	if !providerRe.MatchString(id.Provider) {
		return errors.New("identity provider must match ^[a-z][a-z0-9-]{0,31}$")
	}
	if id.Subject == "" || len(id.Subject) > 320 || len(id.Email) > 320 {
		return errors.New("identity subject must be 1..320 bytes, email at most 320")
	}
	if len(id.Name) > 200 {
		id.Name = id.Name[:200]
	}
	return nil
}

func normalizeInvite(in *Invite) error {
	in.Email = strings.ToLower(strings.TrimSpace(in.Email))
	role, err := normalizeRole(in.Role, RoleDefault)
	if err != nil {
		return err
	}
	in.Role = role
	if len(in.Email) < 3 || len(in.Email) > 320 || !strings.Contains(in.Email, "@") {
		return errors.New("invite email must be an address")
	}
	if in.InvitedBy == "" || in.ExpiresAt.IsZero() {
		return errors.New("invite needs invited_by and expires_at")
	}
	return nil
}

var (
	_ Humans = (*Memory)(nil)
	_ Humans = (*Postgres)(nil)
)
