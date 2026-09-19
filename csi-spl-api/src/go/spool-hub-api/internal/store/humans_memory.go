package store

import (
	"context"
	"fmt"
	"time"
)

type memHuman struct {
	name, email string
	avatar      string // file_id
	disabled    bool
}

type memMember struct{ role, admittedBy string }

type memInvite struct {
	Invite
	accepted bool
}

// memHumans is Memory's copy of the 0006 tables; zero value is empty.
type memHumans struct {
	next       int
	humans     map[string]*memHuman
	identities map[[2]string]string    // (provider, subject) -> HUM-*
	members    map[[2]string]memMember // (tenant, HUM-*) -> role
	invites    map[[2]string]*memInvite
}

func (h *memHumans) init() {
	if h.humans == nil {
		h.humans = map[string]*memHuman{}
		h.identities = map[[2]string]string{}
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

func (s *Memory) Admit(_ context.Context, id Identity, tenant string, p AdmitPolicy, now time.Time) (string, error) {
	if err := normalizeIdentity(&id); err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	h := &s.hum
	h.init()
	hum, known := h.identities[[2]string{id.Provider, id.Subject}]
	if known && h.humans[hum].disabled {
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
		case known && member:
		default:
			if i, ok := h.invites[[2]string{tenant, id.Email}]; ok && id.Email != "" && !i.accepted && now.Before(i.ExpiresAt) {
				inv = i
				grant = &memMember{role: i.Role, admittedBy: i.InvitedBy}
			} else if p.BootstrapOwner && h.memberCount(tenant) == 0 {
				grant = &memMember{role: RoleOwner, admittedBy: AdmittedBootstrap}
			} else {
				return "", ErrNotAdmitted
			}
		}
	}
	if !known {
		h.next++
		hum = fmt.Sprintf("HUM-%d", h.next)
		h.humans[hum] = &memHuman{}
		h.identities[[2]string{id.Provider, id.Subject}] = hum
	}
	if id.Email != "" {
		h.humans[hum].email = id.Email
	}
	if id.Name != "" {
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
	if !ok {
		return "", ErrNotFound
	}
	return m.role, nil
}

func (s *Memory) PutInvite(_ context.Context, in Invite, _ time.Time) error {
	if err := normalizeInvite(&in); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if _, ok := s.tenants[in.TenantID]; !ok {
		return ErrNotFound
	}
	s.hum.invites[[2]string{in.TenantID, in.Email}] = &memInvite{Invite: in}
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

// disableHuman is a test hook (humans.disabled_at); no production caller yet.
func (s *Memory) disableHuman(humanID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if hm, ok := s.hum.humans[humanID]; ok {
		hm.disabled = true
	}
}
