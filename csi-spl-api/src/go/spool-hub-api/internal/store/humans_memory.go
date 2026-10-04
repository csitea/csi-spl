package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

type memHuman struct {
	name, email string
	interests   string            // interests (rdb 0086, CLE-77794); "" = none
	avatar      string            // file_id
	locale      string            // preferred_locale (rdb 0017)
	theme       string            // preferred_theme (rdb 0057); light is the light-blue palette
	submitKey   string            // submit_key (rdb 0062, SPL-976); "" = never picked
	railOrder   []string          // rail_order (rdb 0063, SPL-979); nil = never reordered
	view        map[string]string // rdb 0070 message_order / composer_position; absent = never picked
	issueCols   map[string]int    // issues_columns (rdb 0076, SPL-1132); nil = never sized
	diagnostics bool              // diagnostics_enabled (rdb 0038)
	disabled    bool
}

type memMember struct {
	role, admittedBy string
	since            time.Time                  // tenant_memberships.created_at
	lastActive       time.Time                  // last_active_at (rdb 0044); zero = never switched into
	channelOrder     []string                   // channel_order (rdb 0073); nil = never set
	settings         map[string]json.RawMessage // settings jsonb (rdb 0078); per-tenant override, nil = none
	disabled         bool                       // disabled_at (rdb 0074): suspended in this tenant
	accessUntil      time.Time                  // access_until (rdb 0113); zero = no end
	// Provenance copied from the accepted invite (rdb 0084), mirroring the
	// Postgres read that joins tenant_invites on accepted_by.
	orderedBy, orderedVia string
	invitedOn             time.Time
}

// memIdent is one human_identities row: which human the (provider, subject)
// belongs to, and the address the provider asserted. verified mirrors the
// column of the same name - CLE-3451 links a new identity onto an existing
// human only when BOTH sides carry a verified address.
type memIdent struct {
	human, email string
	verified     bool
}

type memInvite struct {
	Invite
	accepted  bool
	mailedAt  *time.Time // rdb 0019 (FR-016)
	mailCount int
	createdAt time.Time // tenant_invites.created_at
}

// memHumans is Memory's copy of the 0006 tables; zero value is empty.
type memHumans struct {
	next       int
	humans     map[string]*memHuman
	identities map[[2]string]*memIdent // (provider, subject) -> the row
	members    map[[2]string]memMember // (tenant, HUM-*) -> role
	invites    map[[2]string]*memInvite
}

func (h *memHumans) init() {
	if h.humans == nil {
		h.humans = map[string]*memHuman{}
		h.identities = map[[2]string]*memIdent{}
		h.members = map[[2]string]memMember{}
		h.invites = map[[2]string]*memInvite{}
	}
}

// realElsewhere reports whether hum holds a membership in a workspace other
// than tenant (the open demo rule never seats a real member, specs/077).
func (h *memHumans) realElsewhere(hum, tenant string) bool {
	for k := range h.members {
		if k[1] == hum && k[0] != tenant {
			return true
		}
	}
	return false
}

func (h *memHumans) memberCount(tenant string) int {
	n := 0
	for k := range h.members {
		if k[0] == tenant {
			n++
		}
	}
	return n
}

// verifiedHuman is the human an already-known identity proved this address
// for, "" when no identity carries it VERIFIED (CLE-3451 defect 2). Ordered by
// human id so the answer does not depend on map iteration order.
func (h *memHumans) verifiedHuman(email string) string {
	if email == "" {
		return ""
	}
	best := ""
	for _, i := range h.identities {
		if i.verified && i.email == email && (best == "" || i.human < best) {
			best = i.human
		}
	}
	return best
}

func (s *Memory) Admit(_ context.Context, id Identity, tenant string, p AdmitPolicy, now time.Time) (string, error) {
	if err := normalizeIdentity(&id); err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	h := &s.hum
	h.init()
	var hum string
	row, known := h.identities[[2]string{id.Provider, id.Subject}]
	if known {
		hum = row.human
	}
	// CLE-3451 defect 2: a NEW identity whose provider-verified address already
	// belongs to a human joins that human instead of minting a second, unlinked
	// one. id.Email is non-empty only when the provider asserted the address
	// (auth FR-004: oidc.go / idp.go refuse the sign-in otherwise), and the row
	// side must carry verified - merging on an unverified address on either
	// side would be an account takeover.
	linked := false
	if !known {
		if h2 := h.verifiedHuman(id.Email); h2 != "" {
			hum, linked = h2, true
		}
	}
	if (known || linked) && h.humans[hum].disabled {
		return "", ErrNotAdmitted
	}
	// Decide admission before writing anything (a refusal writes nothing).
	var grant *memMember
	var inv *memInvite
	if tenant != "" {
		var err error
		if grant, inv, err = s.admitToTenant(tenant, hum, id, known || linked, p, now); err != nil {
			return "", err
		}
	}
	if !known {
		if !linked {
			h.next++
			hum = fmt.Sprintf("HUM-%d", h.next)
			h.humans[hum] = &memHuman{}
		}
		h.identities[[2]string{id.Provider, id.Subject}] = &memIdent{human: hum}
	}
	if ident := h.identities[[2]string{id.Provider, id.Subject}]; id.Email != "" {
		ident.email, ident.verified = id.Email, true
	}
	if id.Email != "" {
		h.humans[hum].email = id.Email
	}
	// The IdP name only seeds an empty name: once the human has one (their
	// own, set in Settings) a sign-in never replaces it.
	if id.Name != "" && h.humans[hum].name == "" {
		h.humans[hum].name = id.Name
	}
	if grant != nil {
		h.members[[2]string{tenant, hum}] = *grant
	}
	if inv != nil {
		inv.accepted = true
	}
	return hum, nil
}

// admitToTenant decides the tenant grant for an already-resolved human without
// writing anything: an open matching invite (its role and provenance), else the
// bootstrap owner, else a pending-but-lapsed invite is ErrInviteExpired (distinct
// so the login page can say "ask for a fresh invite", CLE-77781/SPL-1229), else
// a plain refusal. In the open demo workspace the open rule (specs/077 T007)
// stands where bootstrap would: a demo_user seat for a verified Google or
// Facebook identity that is no real member elsewhere. resolved is (known ||
// linked): a resolved human that is already a member needs no grant. A new
// membership is a new user seat (009 D-3), refused over the tenant cap.
func (s *Memory) admitToTenant(tenant, hum string, id Identity, resolved bool, p AdmitPolicy, now time.Time) (*memMember, *memInvite, error) {
	email := id.Email
	if _, ok := s.tenants[tenant]; !ok {
		return nil, nil, ErrNotAdmitted
	}
	h := &s.hum
	if _, member := h.members[[2]string{tenant, hum}]; resolved && member {
		return nil, nil, nil
	}
	var grant *memMember
	var inv *memInvite
	if i, ok := h.invites[[2]string{tenant, email}]; ok && email != "" && !i.accepted && now.Before(i.ExpiresAt) {
		inv = i
		grant = &memMember{role: i.Role, admittedBy: i.InvitedBy, since: now,
			orderedBy: i.OrderedBy, orderedVia: i.OrderedVia, invitedOn: i.createdAt}
	} else if p.openAdmits(id, tenant) && !(resolved && h.realElsewhere(hum, tenant)) {
		grant = &memMember{role: rbac.DemoUser, admittedBy: AdmittedDemo, since: now}
	} else if p.bootstraps(tenant) && h.memberCount(tenant) == 0 {
		grant = &memMember{role: RoleTenantOwner, admittedBy: AdmittedBootstrap, since: now}
	} else if i, ok := h.invites[[2]string{tenant, email}]; ok && email != "" && !i.accepted && !now.Before(i.ExpiresAt) {
		// A pending invite that merely lapsed: distinct from a stranger.
		return nil, nil, ErrInviteExpired
	} else {
		return nil, nil, ErrNotAdmitted
	}
	if c := s.tenants[tenant].SeatsUsers; c > 0 && h.memberCount(tenant) >= c {
		return nil, nil, ErrSeatQuota
	}
	return grant, inv, nil
}

// ProvisionMember seats a member by email before any sign-in (CLE-77781); see
// store.MemberProvisioner. Idempotent. The memory store keeps no credentials
// table, so PasswordHash only seeds the (password, email) identity that native
// login would resolve to — enough to prove linking in a memory test.
func (s *Memory) ProvisionMember(_ context.Context, in ProvisionInput, now time.Time) (string, bool, error) {
	email := strings.ToLower(strings.TrimSpace(in.Email))
	if email == "" || !strings.Contains(email, "@") {
		return "", false, errors.New("provision: a valid email is required")
	}
	role, err := normalizeRole(in.Role, "")
	if err != nil {
		return "", false, err
	}
	if _, ok := memRoles()[role]; !ok {
		return "", false, ErrUnknownRole
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[in.Tenant]; !ok {
		return "", false, ErrNotFound
	}
	h := &s.hum
	h.init()
	hum := h.verifiedHuman(email)
	createdHuman := false
	if hum == "" {
		h.next++
		hum = fmt.Sprintf("HUM-%d", h.next)
		h.humans[hum] = &memHuman{name: in.DisplayName, email: email}
		createdHuman = true
	} else if hm := h.humans[hum]; hm != nil {
		if hm.name == "" {
			hm.name = in.DisplayName
		}
		if hm.email == "" {
			hm.email = email
		}
	}
	// operator identity (verified) — links a later real sign-in, never signs in.
	if _, ok := h.identities[[2]string{ProviderOperator, email}]; !ok {
		h.identities[[2]string{ProviderOperator, email}] = &memIdent{human: hum, email: email, verified: true}
	}
	if _, ok := h.members[[2]string{in.Tenant, hum}]; !ok {
		h.members[[2]string{in.Tenant, hum}] = memMember{role: role, admittedBy: AdmittedOperator, since: now,
			orderedBy: in.OrderedBy, orderedVia: in.OrderedVia, invitedOn: now}
	}
	if inv, ok := h.invites[[2]string{in.Tenant, email}]; ok && !inv.accepted {
		inv.accepted = true
		if inv.OrderedBy == "" {
			inv.OrderedBy = in.OrderedBy
		}
		if inv.OrderedVia == "" {
			inv.OrderedVia = in.OrderedVia
		}
	}
	if in.PasswordHash != "" {
		if _, ok := h.identities[[2]string{ProviderNative, email}]; !ok {
			h.identities[[2]string{ProviderNative, email}] = &memIdent{human: hum, email: email, verified: true}
		}
	}
	return hum, createdHuman, nil
}

func (s *Memory) MemberRole(_ context.Context, humanID, tenant string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if hm, ok := s.hum.humans[humanID]; !ok || hm.disabled {
		return "", ErrNotFound
	}
	m, ok := s.hum.members[[2]string{tenant, humanID}]
	if !ok || m.disabled || lapsed(m.accessUntil, time.Now()) {
		return "", ErrNotFound
	}
	return m.role, nil
}

func (s *Memory) PutInvite(_ context.Context, in Invite, now time.Time) error {
	if err := normalizeInvite(&in); err != nil {
		return err
	}
	if _, ok := memRoles()[in.Role]; !ok {
		return ErrUnknownRole
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if _, ok := s.tenants[in.TenantID]; !ok {
		return ErrNotFound
	}
	// A re-invite resets the mail count, never mailed_at (rdb 0019).
	ni := &memInvite{Invite: in, createdAt: now}
	if old, ok := s.hum.invites[[2]string{in.TenantID, in.Email}]; ok {
		ni.mailedAt = old.mailedAt
	}
	s.hum.invites[[2]string{in.TenantID, in.Email}] = ni
	return nil
}

func (s *Memory) UnlinkIdentity(_ context.Context, provider, subject string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	delete(s.hum.identities, [2]string{provider, subject})
	return nil
}

func (s *Memory) SetAvatar(_ context.Context, humanID, fileID string) error {
	if err := checkFileID(fileID); err != nil {
		return err
	}
	return s.withHuman(humanID, func(hm *memHuman) { hm.avatar = fileID })
}

func (s *Memory) Avatar(_ context.Context, humanID string) (string, error) {
	return s.humanText(humanID, func(hm *memHuman) string { return hm.avatar })
}

func (s *Memory) SetPreferredLocale(_ context.Context, humanID, locale string) error {
	if err := checkLocale(locale); err != nil {
		return err
	}
	return s.withHuman(humanID, func(hm *memHuman) { hm.locale = locale })
}

func (s *Memory) PreferredLocale(_ context.Context, humanID string) (string, error) {
	return s.humanText(humanID, func(hm *memHuman) string { return hm.locale })
}

func (s *Memory) SetPreferredTheme(_ context.Context, humanID, theme string) error {
	if err := checkTheme(theme); err != nil {
		return err
	}
	return s.withHuman(humanID, func(hm *memHuman) { hm.theme = theme })
}

func (s *Memory) PreferredTheme(_ context.Context, humanID string) (string, error) {
	return s.humanText(humanID, func(hm *memHuman) string { return hm.theme })
}

func (s *Memory) SetSubmitKey(_ context.Context, humanID, key string) error {
	if err := checkSubmitKey(key); err != nil {
		return err
	}
	return s.withHuman(humanID, func(hm *memHuman) { hm.submitKey = key })
}

func (s *Memory) SubmitKey(_ context.Context, humanID string) (string, error) {
	return s.humanText(humanID, func(hm *memHuman) string { return hm.submitKey })
}

func (s *Memory) SetRailOrder(_ context.Context, humanID string, order []string) error {
	if err := checkRailOrder(order); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	hm.railOrder = append([]string(nil), order...)
	if order == nil {
		hm.railOrder = nil
	}
	return nil
}

func (s *Memory) RailOrder(_ context.Context, humanID string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return nil, ErrNotFound
	}
	if hm.railOrder == nil {
		return nil, nil
	}
	return append([]string(nil), hm.railOrder...), nil
}

func (s *Memory) SetViewPref(_ context.Context, humanID, key, value string) error {
	if err := checkViewPref(key, value); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	if hm.view == nil {
		hm.view = map[string]string{}
	}
	hm.view[key] = value
	return nil
}

func (s *Memory) ViewPref(_ context.Context, humanID, key string) (string, error) {
	if err := checkViewPref(key, ""); err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return "", ErrNotFound
	}
	return hm.view[key], nil
}

func (s *Memory) SetIssueColumns(_ context.Context, humanID string, cols map[string]int) error {
	if err := checkIssueColumns(cols); err != nil {
		return err
	}
	return s.withHuman(humanID, func(hm *memHuman) { hm.issueCols = copyCols(cols) })
}

func (s *Memory) IssueColumns(_ context.Context, humanID string) (map[string]int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return nil, ErrNotFound
	}
	return copyCols(hm.issueCols), nil
}

// copyCols is a private copy of a width map; nil or empty is nil.
func copyCols(cols map[string]int) map[string]int {
	if len(cols) == 0 {
		return nil
	}
	out := make(map[string]int, len(cols))
	for k, v := range cols {
		out[k] = v
	}
	return out
}

func (s *Memory) SetDisplayName(_ context.Context, humanID, name string) error {
	return s.withHuman(humanID, func(hm *memHuman) { hm.name = name })
}

func (s *Memory) DisplayName(_ context.Context, humanID string) (string, error) {
	return s.humanText(humanID, func(hm *memHuman) string { return hm.name })
}

func (s *Memory) SetInterests(_ context.Context, humanID, interests string) error {
	return s.withHuman(humanID, func(hm *memHuman) { hm.interests = interests })
}

func (s *Memory) Interests(_ context.Context, humanID string) (string, error) {
	return s.humanText(humanID, func(hm *memHuman) string { return hm.interests })
}

func (s *Memory) SetDiagnosticsEnabled(_ context.Context, humanID string, on bool) error {
	return s.withHuman(humanID, func(hm *memHuman) { hm.diagnostics = on })
}

func (s *Memory) DiagnosticsEnabled(_ context.Context, humanID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return false, ErrNotFound
	}
	return hm.diagnostics, nil
}

func (s *Memory) IdentityLocale(_ context.Context, provider, subject string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if row, ok := s.hum.identities[[2]string{provider, subject}]; ok {
		if hm, ok := s.hum.humans[row.human]; ok {
			return hm.locale, nil
		}
	}
	return "", nil
}

// FederatedAccount is CLE-3451 defect 1's lookup: which IdPs already carry
// this address, verified, on a human that is not disabled.
func (s *Memory) FederatedAccount(_ context.Context, email string) ([]string, string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return nil, "", nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	locales := map[string]string{}
	var provs []string
	for k, i := range s.hum.identities {
		hm, ok := s.hum.humans[i.human]
		if !i.verified || i.email != email || k[0] == ProviderNative || !ok || hm.disabled {
			continue
		}
		provs = append(provs, k[0])
		locales[k[0]] = hm.locale
	}
	sort.Strings(provs)
	locale := ""
	for _, p := range provs { // deterministic: the first provider's human
		if locale = locales[p]; locale != "" {
			break
		}
	}
	return provs, locale, nil
}

func (s *Memory) TenantAvatars(_ context.Context, tenant string) (map[string]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	out := map[string]string{}
	for k := range s.hum.members {
		if hm, ok := s.hum.humans[k[1]]; k[0] == tenant && ok && !hm.disabled {
			out[k[1]] = hm.avatar
		}
	}
	return out, nil
}

// withHuman runs fn on the human under the store lock; a missing human is
// ErrNotFound and fn does not run.
func (s *Memory) withHuman(humanID string, fn func(*memHuman)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	fn(hm)
	return nil
}

// humanText reads one text field of the human; a missing human is ErrNotFound.
func (s *Memory) humanText(humanID string, get func(*memHuman) string) (string, error) {
	var v string
	err := s.withHuman(humanID, func(hm *memHuman) { v = get(hm) })
	return v, err
}
