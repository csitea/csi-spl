package store

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
)

// Humans, their sign-in identities and tenant membership (specs/010 T012/T013,
// FR-008, FR-012, OQ-A3, OQ-A5; rdb 0006_users_and_memberships.sql).

// ErrNotAdmitted refuses a sign-in to a tenant: not a member, no matching
// invite, and no bootstrap (FR-012). Nothing was written.
var ErrNotAdmitted = errors.New("not admitted to tenant")

// Membership roles (tenant_memberships.role).
const (
	RoleOwner  = "owner"
	RoleMember = "member"
)

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
	if in.Role == "" {
		in.Role = RoleMember
	}
	if in.Role != RoleOwner && in.Role != RoleMember {
		return errors.New("invite role must be owner or member")
	}
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
