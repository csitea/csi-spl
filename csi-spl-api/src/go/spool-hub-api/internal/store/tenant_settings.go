package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
)

// The Tenant settings area (SPL-1037, specs/046, rdb 0074): the tenant's
// display name and default locale, and the per-tenant suspension of one
// member. The responder list is Fallbacks (rdb 0067).

// TenantConfig is what Tenant settings -> General shows.
type TenantConfig struct {
	DisplayName   string // "" = unset (the WUI shows the tenant id)
	DefaultLocale string // "" = unset (the hub default)
	// TopicArchivePolicy is "Who can archive topics" (CLE-77819, rdb 0093):
	// "" = unset = ArchivePolicyEveryone, else one of the ArchivePolicy* values.
	TopicArchivePolicy string
	// AgentSplit is the vendor guideline (rdb 0109). A fresh tenant is
	// DefaultAgentSplit; the zero struct is not a stored value.
	AgentSplit AgentSplit
}

// TenantConfigPatch changes the fields that are not nil; a pointer to ""
// clears one.
type TenantConfigPatch struct {
	DisplayName        *string
	DefaultLocale      *string
	TopicArchivePolicy *string
	// AgentSplit, when set, replaces all four shares. Nil leaves them.
	AgentSplit *AgentSplit
}

// MaxTenantDisplayName is the rdb 0041 CHECK on tenants.display_name.
const MaxTenantDisplayName = 200

// "Who can archive topics" (CLE-77819, owner 2026-09-30, rdb 0093). The rdb
// CHECK on tenants.topic_archive_policy MUST equal this set.
const (
	ArchivePolicyEveryone = "everyone" // any member who can read the topic
	ArchivePolicyAdmins   = "admins"   // the tenant owner or an admin only
	ArchivePolicyStarter  = "starter"  // the topic's starter, plus owner / admin
)

// DefaultArchivePolicy is what an unset ("") setting means (owner: default to
// everyone).
const DefaultArchivePolicy = ArchivePolicyEveryone

// ValidArchivePolicy reports whether p is a stored policy value ("" = unset).
func ValidArchivePolicy(p string) bool {
	switch p {
	case "", ArchivePolicyEveryone, ArchivePolicyAdmins, ArchivePolicyStarter:
		return true
	default:
		return false
	}
}

// EffectiveArchivePolicy maps the stored value (incl. "") to the policy in
// force.
func EffectiveArchivePolicy(stored string) string {
	if stored == "" {
		return DefaultArchivePolicy
	}
	return stored
}

// AgentSplit is the workspace guideline for new agent work (rdb 0109).
// The hub stores it and does not enforce it. qwen is 0 in the default so
// the owner's current claude 40 / grok 50 / agy 10 split still sums to 100.
type AgentSplit struct {
	Claude int
	Grok   int
	Agy    int
	Qwen   int
}

// DefaultAgentSplit is what a workspace has until an admin sets another.
func DefaultAgentSplit() AgentSplit {
	return AgentSplit{Claude: 40, Grok: 50, Agy: 10, Qwen: 0}
}

// Valid reports whether each share is 0..100 and the four sum to 100.
func (a AgentSplit) Valid() bool {
	for _, n := range []int{a.Claude, a.Grok, a.Agy, a.Qwen} {
		if n < 0 || n > 100 {
			return false
		}
	}
	return a.Claude+a.Grok+a.Agy+a.Qwen == 100
}

// TenantSettings is implemented by Memory and Postgres.
type TenantSettings interface {
	// TenantConfig reads the tenant's row; ErrNotFound when none.
	TenantConfig(ctx context.Context, tenant string) (TenantConfig, error)
	// SetTenantConfig applies p in one statement; ErrNotFound when no row.
	SetTenantConfig(ctx context.Context, tenant string, p TenantConfigPatch) error
	// SetMemberDisabled suspends (off=true) or restores one membership. A
	// suspended member holds no role in the tenant (MemberRole answers
	// ErrNotFound). The last-owner and last-admin guards apply to a
	// suspension as to a removal. ErrNotFound: not a member.
	SetMemberDisabled(ctx context.Context, tenant, humanID string, off bool, now time.Time) error
	// MemberState is the membership's role and whether it is suspended -
	// unlike MemberRole it also finds a suspended one, which an admin must
	// still be able to restore or remove. ErrNotFound: not a member.
	MemberState(ctx context.Context, tenant, humanID string) (role string, suspended bool, err error)
}

var (
	_ TenantSettings = (*Memory)(nil)
	_ TenantSettings = (*Postgres)(nil)
)

// ErrBadTenantConfig: a display name or locale outside the rdb checks.
var ErrBadTenantConfig = errors.New("store: bad tenant setting")

func normalizeTenantConfig(p *TenantConfigPatch) error {
	if p.DisplayName != nil {
		n := strings.TrimSpace(*p.DisplayName)
		if len([]rune(n)) > MaxTenantDisplayName || strings.ContainsAny(n, "\r\n") {
			return ErrBadTenantConfig
		}
		p.DisplayName = &n
	}
	if p.DefaultLocale != nil {
		l := strings.TrimSpace(*p.DefaultLocale)
		if checkLocale(l) != nil {
			return ErrBadTenantConfig
		}
		p.DefaultLocale = &l
	}
	if p.TopicArchivePolicy != nil {
		pol := strings.TrimSpace(*p.TopicArchivePolicy)
		if !ValidArchivePolicy(pol) {
			return ErrBadTenantConfig
		}
		p.TopicArchivePolicy = &pol
	}
	if p.AgentSplit != nil && !p.AgentSplit.Valid() {
		return ErrBadTenantConfig
	}
	return nil
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// ---- Memory -----------------------------------------------------------------

func (s *Memory) TenantConfig(_ context.Context, tenant string) (TenantConfig, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[tenant]
	if !ok {
		return TenantConfig{}, ErrNotFound
	}
	sp := DefaultAgentSplit()
	if s.agentSplit != nil {
		if v, ok := s.agentSplit[tenant]; ok {
			sp = v
		}
	}
	return TenantConfig{DisplayName: t.DisplayName, DefaultLocale: s.tenantLocale[tenant],
		TopicArchivePolicy: t.TopicArchivePolicy, AgentSplit: sp}, nil
}

func (s *Memory) SetTenantConfig(_ context.Context, tenant string, p TenantConfigPatch) error {
	if err := normalizeTenantConfig(&p); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[tenant]
	if !ok {
		return ErrNotFound
	}
	if p.DisplayName != nil {
		t.DisplayName = *p.DisplayName
		s.tenants[tenant] = t
	}
	if p.DefaultLocale != nil {
		if s.tenantLocale == nil {
			s.tenantLocale = map[string]string{}
		}
		s.tenantLocale[tenant] = *p.DefaultLocale
	}
	if p.TopicArchivePolicy != nil {
		t.TopicArchivePolicy = *p.TopicArchivePolicy
		s.tenants[tenant] = t
	}
	if p.AgentSplit != nil {
		if s.agentSplit == nil {
			s.agentSplit = map[string]AgentSplit{}
		}
		s.agentSplit[tenant] = *p.AgentSplit
	}
	return nil
}

func (s *Memory) SetMemberDisabled(_ context.Context, tenant, humanID string, off bool, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	if off && !m.disabled {
		roles := memRoles()
		if roles[m.role].TenantOwner && s.memOwnersLeft(tenant, humanID) == 0 {
			return ErrLastOwner
		}
		if grants(roles[m.role], rbac.MembersInvite) && s.memAdminsLeft(tenant, humanID) == 0 {
			return ErrLastAdmin
		}
	}
	m.disabled = off
	s.hum.members[k] = m
	return nil
}

func (s *Memory) MemberState(_ context.Context, tenant, humanID string) (string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	m, ok := s.hum.members[[2]string{tenant, humanID}]
	if !ok {
		return "", false, ErrNotFound
	}
	return m.role, m.disabled, nil
}

// ---- Postgres ---------------------------------------------------------------

func (s *Postgres) MemberState(ctx context.Context, tenant, humanID string) (string, bool, error) {
	var role string
	var off bool
	err := s.queryRowTenant(ctx, tenant, `SELECT role, disabled_at IS NOT NULL FROM tenant_memberships
		WHERE tenant_id = $1 AND human_id = $2`, []any{tenant, humanID}, &role, &off)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, ErrNotFound
	}
	return role, off, err
}

func (s *Postgres) TenantConfig(ctx context.Context, tenant string) (TenantConfig, error) {
	var c TenantConfig
	err := s.queryRowTenant(ctx, tenant, `SELECT COALESCE(display_name, ''), COALESCE(default_locale, ''),
		COALESCE(topic_archive_policy, ''),
		agent_split_claude, agent_split_grok, agent_split_agy, agent_split_qwen
		FROM tenants WHERE tenant_id = $1`, []any{tenant}, &c.DisplayName, &c.DefaultLocale, &c.TopicArchivePolicy,
		&c.AgentSplit.Claude, &c.AgentSplit.Grok, &c.AgentSplit.Agy, &c.AgentSplit.Qwen)
	if errors.Is(err, pgx.ErrNoRows) {
		return TenantConfig{}, ErrNotFound
	}
	return c, err
}

func (s *Postgres) SetTenantConfig(ctx context.Context, tenant string, p TenantConfigPatch) error {
	if err := normalizeTenantConfig(&p); err != nil {
		return err
	}
	// topic_archive_policy rides the cached tenant row (getTenant); drop the
	// hot entry so a policy change takes effect at once.
	defer s.hot.forget()
	var name, loc, pol any
	var claude, grok, agy, qwen any
	if p.DisplayName != nil {
		name = nullIfEmpty(*p.DisplayName)
	}
	if p.DefaultLocale != nil {
		loc = nullIfEmpty(*p.DefaultLocale)
	}
	if p.TopicArchivePolicy != nil {
		pol = nullIfEmpty(*p.TopicArchivePolicy)
	}
	if p.AgentSplit != nil {
		claude = p.AgentSplit.Claude
		grok = p.AgentSplit.Grok
		agy = p.AgentSplit.Agy
		qwen = p.AgentSplit.Qwen
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET
		display_name         = CASE WHEN $2 THEN $3::text ELSE display_name END,
		default_locale       = CASE WHEN $4 THEN $5::text ELSE default_locale END,
		topic_archive_policy = CASE WHEN $6 THEN $7::text ELSE topic_archive_policy END,
		agent_split_claude   = CASE WHEN $8 THEN $9::smallint ELSE agent_split_claude END,
		agent_split_grok     = CASE WHEN $8 THEN $10::smallint ELSE agent_split_grok END,
		agent_split_agy      = CASE WHEN $8 THEN $11::smallint ELSE agent_split_agy END,
		agent_split_qwen     = CASE WHEN $8 THEN $12::smallint ELSE agent_split_qwen END
		WHERE tenant_id = $1`, tenant, p.DisplayName != nil, name, p.DefaultLocale != nil, loc,
		p.TopicArchivePolicy != nil, pol, p.AgentSplit != nil, claude, grok, agy, qwen)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) SetMemberDisabled(ctx context.Context, tenant, humanID string, off bool, now time.Time) error {
	defer s.hot.forget() // DB payload cut 5: a suspended member leaves the door cache
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		cur, owner, err := memberTx(ctx, tx, tenant, humanID)
		if err != nil {
			return err
		}
		if off {
			if owner {
				if n, err := ownersLeftTx(ctx, tx, tenant, humanID); err != nil {
					return err
				} else if n == 0 {
					return ErrLastOwner
				}
			}
			if err := lastAdminTx(ctx, tx, tenant, humanID, cur, ""); err != nil {
				return err
			}
		}
		var at any
		if off {
			at = now.UTC()
		}
		_, err = tx.Exec(ctx, `UPDATE tenant_memberships
			SET disabled_at = CASE WHEN $3::timestamptz IS NULL THEN NULL ELSE COALESCE(disabled_at, $3) END
			WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID, at)
		return err
	})
}
