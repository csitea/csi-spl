package store

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// A person's PER-TENANT override of their layout/behaviour settings (rdb 0078,
// tenant_memberships.settings, CLE-35099, spec 023 addendum). It sits on the
// membership row like channel_order (rdb 0073): a channel id or a chosen theme
// only means something inside its tenant. A key absent = no override, so the
// hub falls back to the humans-row global (auth.HumanSettings) then the product
// default. display_name and the avatar stay per human and are not kept here.

// membershipSettingsStore is the store's read/write of the settings column;
// *Postgres and *Memory implement it. AuthHooks exposes it to the auth package.
type membershipSettingsStore interface {
	MembershipSettings(ctx context.Context, humanID, tenant string) (auth.MembershipSettings, error)
	SetMembershipSettings(ctx context.Context, humanID, tenant string, patch map[string]any) error
}

var (
	_ membershipSettingsStore = (*Memory)(nil)
	_ membershipSettingsStore = (*Postgres)(nil)
	// AuthHooks satisfies the auth package's optional reader / writer.
	_ auth.MembershipSettingsReader = AuthHooks{}
	_ auth.MembershipSettingsWriter = AuthHooks{}
)

// MembershipSettings is the per-tenant override, or the zero value when the
// underlying store keeps none (settings stay global). AuthHooks delegates to
// the store's own reader.
func (a AuthHooks) MembershipSettings(ctx context.Context, humanID, tenant string) (auth.MembershipSettings, error) {
	ms, ok := a.H.(membershipSettingsStore)
	if !ok {
		return auth.MembershipSettings{}, nil
	}
	return ms.MembershipSettings(ctx, humanID, tenant)
}

// SetMembershipSettings merges patch into the tenant's override; a no-op when
// the store keeps none. An unknown membership is auth.ErrNoHuman.
func (a AuthHooks) SetMembershipSettings(ctx context.Context, humanID, tenant string, patch map[string]any) error {
	ms, ok := a.H.(membershipSettingsStore)
	if !ok {
		return nil
	}
	err := ms.SetMembershipSettings(ctx, humanID, tenant, patch)
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}

// ---- Postgres ----

// MembershipSettings reads the tenant's settings jsonb and decodes it; a NULL
// column or no such membership is the zero override (fall back to the global).
// It touches one row of the tenant it names, so it runs in that tenant's scope
// (FORCE RLS, rdb 0014), like ChannelOrder.
func (s *Postgres) MembershipSettings(ctx context.Context, humanID, tenant string) (auth.MembershipSettings, error) {
	var raw []byte
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT settings FROM tenant_memberships
			WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID).Scan(&raw)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.MembershipSettings{}, nil
	}
	if err != nil {
		return auth.MembershipSettings{}, err
	}
	return decodeMembershipSettings(raw)
}

// SetMembershipSettings merges patch into the tenant's settings in one
// statement: present keys win, a null value drops that key (jsonb_strip_nulls),
// so a cleared setting falls back to the global. ErrNotFound when there is no
// such membership.
func (s *Postgres) SetMembershipSettings(ctx context.Context, humanID, tenant string, patch map[string]any) error {
	b, err := json.Marshal(patch)
	if err != nil {
		return err
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE tenant_memberships
			SET settings = NULLIF(jsonb_strip_nulls(COALESCE(settings, '{}'::jsonb) || $3::jsonb), '{}'::jsonb)
			WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID, b)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// ---- Memory ----

func (s *Memory) MembershipSettings(_ context.Context, humanID, tenant string) (auth.MembershipSettings, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	m, ok := s.hum.members[[2]string{tenant, humanID}]
	if !ok || len(m.settings) == 0 {
		return auth.MembershipSettings{}, nil
	}
	obj := make(map[string]json.RawMessage, len(m.settings))
	for k, v := range m.settings {
		obj[k] = v
	}
	raw, err := json.Marshal(obj)
	if err != nil {
		return auth.MembershipSettings{}, err
	}
	return decodeMembershipSettings(raw)
}

func (s *Memory) SetMembershipSettings(_ context.Context, humanID, tenant string, patch map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	settings := map[string]json.RawMessage{}
	for key, v := range m.settings {
		settings[key] = v
	}
	for key, val := range patch {
		if val == nil {
			delete(settings, key)
			continue
		}
		b, err := json.Marshal(val)
		if err != nil {
			return err
		}
		settings[key] = b
	}
	m.settings = settings
	if len(settings) == 0 {
		m.settings = nil
	}
	s.hum.members[k] = m
	return nil
}

// decodeMembershipSettings unmarshals the stored jsonb into the override; an
// empty / null column is the zero value.
func decodeMembershipSettings(raw []byte) (auth.MembershipSettings, error) {
	var ms auth.MembershipSettings
	if len(raw) == 0 || string(raw) == "null" {
		return ms, nil
	}
	if err := json.Unmarshal(raw, &ms); err != nil {
		return auth.MembershipSettings{}, err
	}
	return ms, nil
}
