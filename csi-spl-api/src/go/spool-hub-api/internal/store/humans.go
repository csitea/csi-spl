package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
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

// ErrInviteExpired is the special case of ErrNotAdmitted where the ONLY reason
// admission failed is that this address has a pending (never-accepted) invite
// to this tenant whose expires_at has passed. The sign-in is still refused and
// nothing is written, but the caller can tell an invited-but-lapsed person
// (who needs a fresh invite) from a stranger (who needs an invite at all), so
// the login page shows "your invitation expired" instead of the blank
// not_allowed both cases used to share (CLE-77781, topic db1d0b6f). It WRAPS
// ErrNotAdmitted: every existing `errors.Is(err, ErrNotAdmitted)` still holds,
// so a caller that does not care about the reason is unchanged; one that does
// checks ErrInviteExpired first.
var ErrInviteExpired = fmt.Errorf("%w: invite expired", ErrNotAdmitted)

// ErrDemoFull refuses an open demo admission (specs/077 FR-006, T008): the
// demo workspace already holds AdmitPolicy.OpenMaxLive live demo_user seats.
// It WRAPS ErrNotAdmitted like ErrInviteExpired; nothing was written.
var ErrDemoFull = fmt.Errorf("%w: demo full", ErrNotAdmitted)

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

// humanIDRe is the HUM-* id shape (rdb 0006), reused to validate an invite's
// ordered_by (rdb 0084).
var humanIDRe = regexp.MustCompile(`^HUM-[0-9]+$`)

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
	AdmittedCheckout  = "checkout" // the paid webhook's buyer invite (047 W1)
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
	// OpenWorkspace is the demo workspace (specs/077 FR-004, T007): a
	// provider-verified identity of an OpenProviders provider signing in to
	// it with no invite is seated as rbac.DemoUser. "" = the demo is off
	// (SPOOL_HUB_DEMO_ENABLED false): every workspace is invite-only.
	// Bootstrap never seats an owner here: a visitor must not find an empty
	// demo workspace and own it.
	OpenWorkspace string
	// OpenProviders are the providers the open rule admits (cnf
	// env.demo.providers, default google,facebook). A native (password) or
	// operator identity is never admitted by it, whatever this lists.
	OpenProviders []string
	// OpenMaxLive caps the live demo_user seats of OpenWorkspace (cnf
	// demo.max_live, specs/077 FR-006, T008); the next open admission is
	// ErrDemoFull. <= 0 is DefaultDemoMaxLive, never unlimited.
	OpenMaxLive int
}

// DefaultDemoMaxLive is the owner's 9 visitors at a time (specs/077 1.1).
const DefaultDemoMaxLive = 9

// maxLive is the live demo seat cap open admission enforces.
func (p AdmitPolicy) maxLive() int {
	if p.OpenMaxLive <= 0 {
		return DefaultDemoMaxLive
	}
	return p.OpenMaxLive
}

// AdmittedDemo marks a membership the open demo rule seated (specs/077).
const AdmittedDemo = "demo"

// openAdmits reports whether the open rule may seat id in tenant: the demo
// is on, tenant IS the demo workspace, the provider is listed and federated,
// and the address is provider-verified (Identity.Email is non-empty only
// then, auth FR-004). The store refuses it anyway to a human who is a real
// member of another workspace (spec 3.8: the demo workspace has no real
// members, and its 3-hour end must never touch a real person's data).
func (p AdmitPolicy) openAdmits(id Identity, tenant string) bool {
	if p.OpenWorkspace == "" || tenant != p.OpenWorkspace || id.Email == "" {
		return false
	}
	if id.Provider == ProviderNative || id.Provider == ProviderOperator {
		return false
	}
	return slices.Contains(p.OpenProviders, id.Provider)
}

// bootstraps reports whether the bootstrap rule applies to tenant: never in
// the open demo workspace.
func (p AdmitPolicy) bootstraps(tenant string) bool {
	return p.BootstrapOwner && (p.OpenWorkspace == "" || tenant != p.OpenWorkspace)
}

// Invite admits the first sign-in whose verified Email matches, once.
type Invite struct {
	TenantID  string
	Email     string
	Role      string
	InvitedBy string // owner HUM-* or AdmittedOperator
	ExpiresAt time.Time
	// OrderedBy is the human who ordered the invite (a HUM-* id), or "" when
	// unknown (the historic operator rows, rdb 0084). For a WUI/API admin
	// invite it equals InvitedBy; for an operator CLI invite it is the person
	// who asked for it.
	OrderedBy string
	// OrderedVia is the agent or channel that carried the order, e.g.
	// "CLE-34967" or "[terminal]"; "" when there was none.
	OrderedVia string
}

// ProvisionInput seats a member by email for a person who has NEVER signed in
// (CLE-77781, owner niba-consult: "added, not invited"). The operator asserts
// the address; the person still proves they own it at their first real sign-in
// (a provider-verified email, or the native password below), which LINKS to the
// human this seats rather than minting a second one.
type ProvisionInput struct {
	Tenant      string
	Email       string
	DisplayName string
	Role        string
	OrderedBy   string // HUM-* who ordered the seat (rdb 0084 provenance)
	OrderedVia  string
	// PasswordHash, when non-empty, is a ready argon2id PHC string (the CLI
	// hashes a password read from a file on stdin, never argv/env): the member
	// also gets a native email+password credential, email PRE-VERIFIED so no
	// verification mail is sent, and the (provider=password, subject=email)
	// identity native login resolves. Postgres only — the memory store keeps no
	// credentials table, so the memory path ignores it.
	PasswordHash string
}

// MemberProvisioner seats a member by email before any sign-in, idempotently:
// it creates the human (once), an 'operator' identity that carries the
// verified address so a later real sign-in links to this human yet is itself
// unusable to sign in, the tenant membership (admitted_by 'operator'), accepts
// any pending invite for the address, and — with ProvisionInput.PasswordHash —
// a native credential. Both Memory and Postgres implement it.
type MemberProvisioner interface {
	ProvisionMember(ctx context.Context, in ProvisionInput, now time.Time) (humanID string, createdHuman bool, err error)
}

// ProviderOperator is the identity provider of an operator-seated member (a
// row human_identities carries so a later real sign-in with the same verified
// address links to the same human). No sign-in path emits it, so the identity
// can never itself sign in.
const ProviderOperator = "operator"

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
	// SetPreferredLocale records the human's picked locale (rdb 0017),
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
	// SetSubmitKey records how Enter behaves in the human's text fields
	// (rdb 0062, SPL-976), one of auth.SubmitKeys, or "" to clear it.
	// Unknown human = ErrNotFound.
	SetSubmitKey(ctx context.Context, humanID, key string) error
	// SubmitKey returns it, "" when none, or ErrNotFound.
	SubmitKey(ctx context.Context, humanID string) (string, error)
	// SetRailOrder records the human's left-rail order (rdb 0063, SPL-979), a
	// permutation of auth.RailTabs, or nil to clear it. Unknown human =
	// ErrNotFound.
	SetRailOrder(ctx context.Context, humanID string, order []string) error
	// RailOrder returns it, nil when none, or ErrNotFound.
	RailOrder(ctx context.Context, humanID string) ([]string, error)
	// SetViewPref records one layout choice (rdb 0070, topic c6994436): key
	// is an auth.ViewPrefs key (the column of that name), value one of its
	// values or "" to clear it. Unknown human = ErrNotFound.
	SetViewPref(ctx context.Context, humanID, key, value string) error
	// ViewPref returns it, "" when none, or ErrNotFound.
	ViewPref(ctx context.Context, humanID, key string) (string, error)
	// SetIssueColumns records the human's Issues sheet column widths (rdb
	// 0076, SPL-1132), column -> px as auth.IsIssueColumns admits, or nil
	// (or empty) to clear them. Unknown human = ErrNotFound.
	SetIssueColumns(ctx context.Context, humanID string, cols map[string]int) error
	// IssueColumns returns them, nil when none, or ErrNotFound.
	IssueColumns(ctx context.Context, humanID string) (map[string]int, error)
	// IdentityLocale returns the picked locale of the human the (provider,
	// subject) sign-in belongs to; "" (nil error) when there is no such
	// identity or nothing is picked.
	IdentityLocale(ctx context.Context, provider, subject string) (string, error)
	// SetDiagnosticsEnabled records the human's "Debug pane" setting (rdb
	// 0038). Unknown human = ErrNotFound.
	SetDiagnosticsEnabled(ctx context.Context, humanID string, on bool) error
	// DiagnosticsEnabled returns that setting, false when never set, or
	// ErrNotFound.
	DiagnosticsEnabled(ctx context.Context, humanID string) (bool, error)
	// SetDisplayName records the human's own shown name, one the
	// auth layer's ValidDisplayName admitted. Unknown human = ErrNotFound.
	// Once a human has a name, Admit no longer replaces it with the IdP's.
	SetDisplayName(ctx context.Context, humanID, name string) error
	// DisplayName returns it, "" when none, or ErrNotFound.
	DisplayName(ctx context.Context, humanID string) (string, error)
	// SetInterests records the human's free-text interests (rdb 0086,
	// CLE-77794), one the auth layer's ValidInterests admitted, or "" to clear
	// it. Unknown human = ErrNotFound. Shown in the People section's info card.
	SetInterests(ctx context.Context, humanID, interests string) error
	// Interests returns it, "" when none, or ErrNotFound.
	Interests(ctx context.Context, humanID string) (string, error)
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

// checkSubmitKey admits "" (never picked) or one of auth.SubmitKeys, the list
// humans_submit_key_check (rdb 0062) agrees on.
func checkSubmitKey(key string) error {
	if key == "" || auth.IsSubmitKey(key) {
		return nil
	}
	return errors.New("submit key must be enter or ctrl-enter")
}

// checkRailOrder admits nil (never reordered) or a permutation of
// auth.RailTabs, what humans_rail_order_check (rdb 0063) admits.
func checkRailOrder(order []string) error {
	if order == nil || auth.IsRailOrder(order) {
		return nil
	}
	return errors.New("rail order must hold each rail tab exactly once")
}

// checkViewPref admits a known auth.ViewPrefs key with "" (never picked) or
// one of its values, what rdb 0070's CHECKs admit. Postgres interpolates the
// key as a column name, so an unknown key must never get past here.
func checkViewPref(key, value string) error {
	if _, ok := auth.ViewPrefs[key]; !ok {
		return errors.New("unknown view preference " + key)
	}
	if value == "" || auth.IsViewPref(key, value) {
		return nil
	}
	return errors.New(key + " must be one of " + strings.Join(auth.ViewPrefs[key], ","))
}

// checkIssueColumns admits nil / empty (never sized) or what
// auth.IsIssueColumns admits; humans_issues_columns_check (rdb 0076) only
// pins the JSON shape (an object).
func checkIssueColumns(cols map[string]int) error {
	if auth.IsIssueColumns(cols) {
		return nil
	}
	return errors.New("issues columns must map sheet columns to a width in px")
}

var fileIDRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

func checkFileID(id string) error {
	if !fileIDRe.MatchString(id) {
		return errors.New("avatar file_id must be a sha256 hex digest")
	}
	return nil
}

// maxEmailLen is the RFC 5321 path limit; an identity subject shares it.
const maxEmailLen = 320

func normalizeIdentity(id *Identity) error {
	id.Provider = strings.TrimSpace(id.Provider)
	id.Email = strings.ToLower(strings.TrimSpace(id.Email))
	if !providerRe.MatchString(id.Provider) {
		return errors.New("identity provider must match ^[a-z][a-z0-9-]{0,31}$")
	}
	if id.Subject == "" || len(id.Subject) > maxEmailLen || len(id.Email) > maxEmailLen {
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
	if len(in.Email) < 3 || len(in.Email) > maxEmailLen || !strings.Contains(in.Email, "@") {
		return errors.New("invite email must be an address")
	}
	if in.InvitedBy == "" || in.ExpiresAt.IsZero() {
		return errors.New("invite needs invited_by and expires_at")
	}
	in.OrderedBy = strings.TrimSpace(in.OrderedBy)
	in.OrderedVia = strings.TrimSpace(in.OrderedVia)
	if in.OrderedBy != "" && !humanIDRe.MatchString(in.OrderedBy) {
		return errors.New("invite ordered_by must be a HUM-* id")
	}
	if len(in.OrderedVia) > 64 {
		return errors.New("invite ordered_via is at most 64 chars")
	}
	return nil
}

var (
	_ Humans = (*Memory)(nil)
	_ Humans = (*Postgres)(nil)
)
