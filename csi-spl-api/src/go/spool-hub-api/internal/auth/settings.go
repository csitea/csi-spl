package auth

import (
	"context"
	"encoding/json"
	"fmt"
)

// HumanSettings is every per-human setting that GET /session and the native
// POST /login answer carry, read in ONE store call (SPL-1100). Before, those
// answers read the humans row once per setting: nine round trips to Cloud SQL
// for one row.
//
// It holds the GLOBAL humans-row values; the per-tenant override (rdb 0078,
// CLE-35099) is applied over it by Overlay before the answer reads it, so the
// same fields carry the tenant's value when one is set (spec 023 addendum
// per-tenant-settings.md).
type HumanSettings struct {
	Locale, Theme, SubmitKey, DisplayName string
	// RailOrder is nil when never reordered.
	RailOrder []string
	// ViewPrefs holds every ViewPrefs key, "" when never picked.
	ViewPrefs map[string]string
	// IssueColumns is nil when the Issues sheet was never sized (SPL-1132).
	IssueColumns map[string]int
	Diagnostics  bool
	// IssuesSort is the Issues list default sort (CLE-35099), nil when never
	// picked (the product default is then priority ascending).
	IssuesSort *IssuesSort
	// PaneSizes is the two vertical dividers' widths as fractions of the
	// window (CLE-35099, SPL-1182), nil when never dragged.
	PaneSizes map[string]float64
}

// IssuesSort is a person's default sort of the Issues list (CLE-35099): the
// column and the direction. Col is one of IssuesSortColumns, Dir one of
// IssuesSortDirs. The product default (a nil IssuesSort) is priority ascending
// (1 at the top), tie-broken by the hub's stable secondary order (updated,
// newest first).
type IssuesSort struct {
	Col string `json:"col"`
	Dir string `json:"dir"`
}

// MembershipSettings is a person's PER-TENANT override of HumanSettings
// (rdb 0078, tenant_memberships.settings). A nil pointer / nil map field = no
// override for that setting in this tenant, so the read falls back to the
// humans-row global, then the product default (spec 023 addendum). It is the
// decoded form of the settings jsonb column; display_name and the avatar are
// NOT here (they stay per human).
type MembershipSettings struct {
	Locale           *string            `json:"preferred_locale,omitempty"`
	Theme            *string            `json:"preferred_theme,omitempty"`
	SubmitKey        *string            `json:"submit_key,omitempty"`
	RailOrder        []string           `json:"rail_order,omitempty"`
	MessageOrder     *string            `json:"message_order,omitempty"`
	ComposerPosition *string            `json:"composer_position,omitempty"`
	IssuesView       *string            `json:"issues_view,omitempty"`
	CloseButtons     *string            `json:"close_buttons,omitempty"`
	IssueColumns     map[string]int     `json:"issues_columns,omitempty"`
	Diagnostics      *bool              `json:"diagnostics_enabled,omitempty"`
	IssuesSort       *IssuesSort        `json:"issues_sort,omitempty"`
	PaneSizes        map[string]float64 `json:"pane_sizes,omitempty"`
}

// Overlay returns b with every set field of the per-tenant override o applied
// over it (rdb 0078). A nil override field leaves the global value. The
// ViewPrefs map is copied so the caller's snapshot is not shared-mutated.
func (b HumanSettings) Overlay(o MembershipSettings) HumanSettings {
	if o.Locale != nil {
		b.Locale = *o.Locale
	}
	if o.Theme != nil {
		b.Theme = *o.Theme
	}
	if o.SubmitKey != nil {
		b.SubmitKey = *o.SubmitKey
	}
	if o.RailOrder != nil {
		b.RailOrder = o.RailOrder
	}
	vp := make(map[string]string, len(b.ViewPrefs)+len(ViewPrefs))
	for k, v := range b.ViewPrefs {
		vp[k] = v
	}
	if o.MessageOrder != nil {
		vp[PrefMessageOrder] = *o.MessageOrder
	}
	if o.ComposerPosition != nil {
		vp[PrefComposerPosition] = *o.ComposerPosition
	}
	if o.IssuesView != nil {
		vp[PrefIssuesView] = *o.IssuesView
	}
	if o.CloseButtons != nil {
		vp[PrefCloseButtons] = *o.CloseButtons
	}
	b.ViewPrefs = vp
	if o.IssueColumns != nil {
		b.IssueColumns = o.IssueColumns
	}
	if o.Diagnostics != nil {
		b.Diagnostics = *o.Diagnostics
	}
	if o.IssuesSort != nil {
		b.IssuesSort = o.IssuesSort
	}
	if o.PaneSizes != nil {
		b.PaneSizes = o.PaneSizes
	}
	return b
}

// MembershipSettingsReader is an optional extension of Preferences: a store
// that reads a human's per-tenant override (rdb 0078). Without it, settings
// stay global (every tenant shows the humans-row value). An unknown membership
// is an empty MembershipSettings and a nil error (no override → fall back).
type MembershipSettingsReader interface {
	MembershipSettings(ctx context.Context, humanID, tenant string) (MembershipSettings, error)
}

// MembershipSettingsWriter is an optional extension of Preferences: a store
// that writes a human's per-tenant override (rdb 0078). patch holds only the
// keys being changed; a nil value clears that key (the read then falls back to
// the global). An unknown membership is ErrNoHuman.
type MembershipSettingsWriter interface {
	SetMembershipSettings(ctx context.Context, humanID, tenant string, patch map[string]any) error
}

// SettingsReader is an optional extension of Preferences: a store that reads
// all of HumanSettings at once. An unknown human is ErrNoHuman, exactly as
// the single readers answer. Without it every setting is read on its own.
type SettingsReader interface {
	HumanSettings(ctx context.Context, humanID string) (HumanSettings, error)
}

// settingReader is the part of Preferences the session and login answers
// read; h.prefs, or a settingsSnapshot of one request.
type settingReader interface {
	PreferredLocale(ctx context.Context, humanID string) (string, error)
	PreferredTheme(ctx context.Context, humanID string) (string, error)
	SubmitKey(ctx context.Context, humanID string) (string, error)
	RailOrder(ctx context.Context, humanID string) ([]string, error)
	ViewPref(ctx context.Context, humanID, key string) (string, error)
	IssueColumns(ctx context.Context, humanID string) (map[string]int, error)
	DiagnosticsEnabled(ctx context.Context, humanID string) (bool, error)
	DisplayName(ctx context.Context, humanID string) (string, error)
}

// settingsSnapshot answers the single readers from one HumanSettings read.
// A failed read fails every setting with the same error, so each answer
// field falls back exactly as it did when its own read failed.
type settingsSnapshot struct {
	human string
	s     HumanSettings
	err   error
}

type settingsKey struct{}

// withSettings reads the session human's settings once, when the store can,
// and hands them to every reader of this answer through ctx. It is taken per
// answer and never kept: a setting changed a moment ago is read fresh by the
// next GET /session (diagnosticsGrant's rule 1).
//
// override is the active tenant's per-tenant override (rdb 0078), already
// decoded — applied over the global values so the same fields carry the
// tenant's value. GET /session decodes it from the tenants list it already
// reads (no extra round trip); the cold native login reads it directly. The
// zero override leaves the globals.
func (h *Handler) withSettings(ctx context.Context, s Session, override MembershipSettings) context.Context {
	sr, ok := h.prefs.(SettingsReader)
	if !ok || s.HumanID == "" {
		return ctx
	}
	v, err := sr.HumanSettings(ctx, s.HumanID)
	if err == nil {
		v = v.Overlay(override)
	}
	return context.WithValue(ctx, settingsKey{}, &settingsSnapshot{human: s.HumanID, s: v, err: err})
}

// overrideFromRoles decodes the per-tenant override for tenant from a tenants
// list GET /session already read (rdb 0078). The zero override when the tenant
// is unset, absent, or has none — the read then keeps the global.
func overrideFromRoles(roles []TenantRole, tenant string) MembershipSettings {
	if tenant == "" {
		return MembershipSettings{}
	}
	for _, r := range roles {
		if r.TenantID == tenant && len(r.Settings) > 0 {
			var o MembershipSettings
			if json.Unmarshal(r.Settings, &o) == nil {
				return o
			}
		}
	}
	return MembershipSettings{}
}

// membershipOverride reads one tenant's override directly (rdb 0078), for the
// cold native login answer (GET /session uses overrideFromRoles instead).
func (h *Handler) membershipOverride(ctx context.Context, humanID, tenant string) MembershipSettings {
	if tenant == "" || humanID == "" {
		return MembershipSettings{}
	}
	if mr, ok := h.prefs.(MembershipSettingsReader); ok {
		if o, err := mr.MembershipSettings(ctx, humanID, tenant); err == nil {
			return o
		} else {
			h.log.Warn().Err(err).Str("tenant", tenant).Msg("auth membership settings overlay")
		}
	}
	return MembershipSettings{}
}

// settings is the reader for humanID: the request's snapshot when it holds
// that human, else the store (h.prefs, which the callers checked is set).
func (h *Handler) settings(ctx context.Context, humanID string) settingReader {
	if snap, ok := ctx.Value(settingsKey{}).(*settingsSnapshot); ok && snap.human == humanID {
		return snap
	}
	return h.prefs
}

// settingsSnap is the request's overlaid HumanSettings for humanID (withSettings),
// present only when the read succeeded. The settings with no per-column reader
// on the store — issues_sort, pane_sizes (rdb 0078) — are read from here, so
// they carry the per-tenant override with no extra store round trip.
func (h *Handler) settingsSnap(ctx context.Context, humanID string) (HumanSettings, bool) {
	if snap, ok := ctx.Value(settingsKey{}).(*settingsSnapshot); ok && snap.human == humanID && snap.err == nil {
		return snap.s, true
	}
	return HumanSettings{}, false
}

func (p *settingsSnapshot) PreferredLocale(context.Context, string) (string, error) {
	return p.s.Locale, p.err
}

func (p *settingsSnapshot) PreferredTheme(context.Context, string) (string, error) {
	return p.s.Theme, p.err
}

func (p *settingsSnapshot) SubmitKey(context.Context, string) (string, error) {
	return p.s.SubmitKey, p.err
}

func (p *settingsSnapshot) RailOrder(context.Context, string) ([]string, error) {
	if p.err != nil {
		return nil, p.err
	}
	return p.s.RailOrder, nil
}

func (p *settingsSnapshot) ViewPref(_ context.Context, _ string, key string) (string, error) {
	if p.err != nil {
		return "", p.err
	}
	v, ok := p.s.ViewPrefs[key]
	if _, known := ViewPrefs[key]; !ok || !known {
		return "", fmt.Errorf("auth: unknown view pref %q", key)
	}
	return v, nil
}

func (p *settingsSnapshot) IssueColumns(context.Context, string) (map[string]int, error) {
	if p.err != nil {
		return nil, p.err
	}
	return p.s.IssueColumns, nil
}

func (p *settingsSnapshot) DiagnosticsEnabled(context.Context, string) (bool, error) {
	return p.s.Diagnostics, p.err
}

func (p *settingsSnapshot) DisplayName(context.Context, string) (string, error) {
	return p.s.DisplayName, p.err
}
