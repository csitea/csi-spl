package auth

import (
	"context"
	"fmt"
)

// HumanSettings is every per-human setting that GET /session and the native
// POST /login answer carry, read in ONE store call (SPL-1100). Before, those
// answers read the humans row once per setting: nine round trips to Cloud SQL
// for one row.
type HumanSettings struct {
	Locale, Theme, SubmitKey, DisplayName string
	// RailOrder is nil when never reordered.
	RailOrder []string
	// ViewPrefs holds every ViewPrefs key, "" when never picked.
	ViewPrefs   map[string]string
	Diagnostics bool
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
func (h *Handler) withSettings(ctx context.Context, s Session) context.Context {
	sr, ok := h.prefs.(SettingsReader)
	if !ok || s.HumanID == "" {
		return ctx
	}
	v, err := sr.HumanSettings(ctx, s.HumanID)
	return context.WithValue(ctx, settingsKey{}, &settingsSnapshot{human: s.HumanID, s: v, err: err})
}

// settings is the reader for humanID: the request's snapshot when it holds
// that human, else the store (h.prefs, which the callers checked is set).
func (h *Handler) settings(ctx context.Context, humanID string) settingReader {
	if snap, ok := ctx.Value(settingsKey{}).(*settingsSnapshot); ok && snap.human == humanID {
		return snap
	}
	return h.prefs
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

func (p *settingsSnapshot) DiagnosticsEnabled(context.Context, string) (bool, error) {
	return p.s.Diagnostics, p.err
}

func (p *settingsSnapshot) DisplayName(context.Context, string) (string, error) {
	return p.s.DisplayName, p.err
}
