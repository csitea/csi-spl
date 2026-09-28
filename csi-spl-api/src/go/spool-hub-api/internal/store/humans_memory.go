package store

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"
)

type memHuman struct {
	name, email string
	avatar      string            // file_id
	locale      string            // preferred_locale (rdb 0017)
	theme       string            // preferred_theme (rdb 0057); light is the light-blue palette
	submitKey   string            // submit_key (rdb 0062, SPL-976); "" = never picked
	railOrder   []string          // rail_order (rdb 0063, SPL-979); nil = never reordered
	view        map[string]string // rdb 0070 message_order / composer_position; absent = never picked
	diagnostics bool              // diagnostics_enabled (rdb 0038)
	disabled    bool
}

type memMember struct {
	role, admittedBy string
	since            time.Time // tenant_memberships.created_at
	lastActive       time.Time // last_active_at (rdb 0044); zero = never switched into
	channelOrder     []string  // channel_order (rdb 0073); nil = never set
	disabled         bool      // disabled_at (rdb 0074): suspended in this tenant
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
		if _, ok := s.tenants[tenant]; !ok {
			return "", ErrNotAdmitted
		}
		_, member := h.members[[2]string{tenant, hum}]
		switch {
		case (known || linked) && member:
		default:
			if i, ok := h.invites[[2]string{tenant, id.Email}]; ok && id.Email != "" && !i.accepted && now.Before(i.ExpiresAt) {
				inv = i
				grant = &memMember{role: i.Role, admittedBy: i.InvitedBy, since: now}
			} else if p.BootstrapOwner && h.memberCount(tenant) == 0 {
				grant = &memMember{role: RoleTenantOwner, admittedBy: AdmittedBootstrap, since: now}
			} else {
				return "", ErrNotAdmitted
			}
			// A new membership is a new user seat (009 D-3); refuse over cap.
			if c := s.tenants[tenant].SeatsUsers; c > 0 && h.memberCount(tenant) >= c {
				return "", ErrSeatQuota
			}
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

func (s *Memory) MemberRole(_ context.Context, humanID, tenant string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if hm, ok := s.hum.humans[humanID]; !ok || hm.disabled {
		return "", ErrNotFound
	}
	m, ok := s.hum.members[[2]string{tenant, humanID}]
	if !ok || m.disabled {
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
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	hm.avatar = fileID
	return nil
}

func (s *Memory) Avatar(_ context.Context, humanID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return "", ErrNotFound
	}
	return hm.avatar, nil
}

func (s *Memory) SetPreferredLocale(_ context.Context, humanID, locale string) error {
	if err := checkLocale(locale); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	hm.locale = locale
	return nil
}

func (s *Memory) PreferredLocale(_ context.Context, humanID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return "", ErrNotFound
	}
	return hm.locale, nil
}

func (s *Memory) SetPreferredTheme(_ context.Context, humanID, theme string) error {
	if err := checkTheme(theme); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	hm.theme = theme
	return nil
}

func (s *Memory) PreferredTheme(_ context.Context, humanID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return "", ErrNotFound
	}
	return hm.theme, nil
}

func (s *Memory) SetSubmitKey(_ context.Context, humanID, key string) error {
	if err := checkSubmitKey(key); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	hm.submitKey = key
	return nil
}

func (s *Memory) SubmitKey(_ context.Context, humanID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return "", ErrNotFound
	}
	return hm.submitKey, nil
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

func (s *Memory) SetDisplayName(_ context.Context, humanID, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	hm.name = name
	return nil
}

func (s *Memory) DisplayName(_ context.Context, humanID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return "", ErrNotFound
	}
	return hm.name, nil
}

func (s *Memory) SetDiagnosticsEnabled(_ context.Context, humanID string, on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	hm, ok := s.hum.humans[humanID]
	if !ok {
		return ErrNotFound
	}
	hm.diagnostics = on
	return nil
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

// unverifyIdentity is a test hook: it leaves the address on the identity but
// clears human_identities.email_verified, the one shape no production path
// writes today and the one CLE-3451's linking must refuse to merge on.
func (s *Memory) unverifyIdentity(provider, subject string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if row, ok := s.hum.identities[[2]string{provider, subject}]; ok {
		row.verified = false
	}
}

// disableHuman is a test hook (humans.disabled_at); no production caller yet.
func (s *Memory) disableHuman(humanID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if hm, ok := s.hum.humans[humanID]; ok {
		hm.disabled = true
	}
}
