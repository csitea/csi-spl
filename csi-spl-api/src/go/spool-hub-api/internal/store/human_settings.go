package store

import (
	"context"
	"errors"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// humanSettingsReader is the optional one-read form of the Humans setting
// readers (SPL-1100): *Postgres and *Memory have it.
type humanSettingsReader interface {
	HumanSettings(ctx context.Context, humanID string) (auth.HumanSettings, error)
}

// HumanSettings reads every setting the session and login answers carry in
// one call; an unknown human is auth.ErrNoHuman. A Humans without the one-read
// form is read setting by setting, as before.
func (a AuthHooks) HumanSettings(ctx context.Context, humanID string) (auth.HumanSettings, error) {
	var (
		v   auth.HumanSettings
		err error
	)
	if r, ok := a.H.(humanSettingsReader); ok {
		v, err = r.HumanSettings(ctx, humanID)
	} else {
		v, err = settingsOneByOne(ctx, a.H, humanID)
	}
	if errors.Is(err, ErrNotFound) {
		return auth.HumanSettings{}, auth.ErrNoHuman
	}
	return v, err
}

// viewPrefColumns is auth.ViewPrefs' keys (each the humans column of that
// name, rdb 0070) in a fixed order.
var viewPrefColumns = func() []string {
	keys := make([]string, 0, len(auth.ViewPrefs))
	for k := range auth.ViewPrefs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}()

// humanSettingsSQL reads every setting of one human in one statement;
// the columns are the single readers' own, COALESCEd the same way.
var humanSettingsSQL = func() string {
	cols := []string{"COALESCE(preferred_locale, '')", "COALESCE(preferred_theme, '')", "COALESCE(submit_key, '')",
		"COALESCE(display_name, '')", "rail_order", "diagnostics_enabled", "issues_columns"}
	for _, k := range viewPrefColumns {
		cols = append(cols, "COALESCE("+k+", '')")
	}
	return "SELECT " + strings.Join(cols, ", ") + " FROM humans WHERE human_id = $1"
}()

// humans is hub-wide (outside rdb 0014's RLS): no tenant scope, like the
// single readers.
func (s *Postgres) HumanSettings(ctx context.Context, humanID string) (auth.HumanSettings, error) {
	var v auth.HumanSettings
	views := make([]string, len(viewPrefColumns))
	dest := []any{&v.Locale, &v.Theme, &v.SubmitKey, &v.DisplayName, &v.RailOrder, &v.Diagnostics, &v.IssueColumns}
	for i := range views {
		dest = append(dest, &views[i])
	}
	err := s.pool.QueryRow(ctx, humanSettingsSQL, humanID).Scan(dest...)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.HumanSettings{}, ErrNotFound
	}
	if err != nil {
		return auth.HumanSettings{}, err
	}
	v.ViewPrefs = make(map[string]string, len(views))
	for i, k := range viewPrefColumns {
		v.ViewPrefs[k] = views[i]
	}
	v.IssueColumns = copyCols(v.IssueColumns)
	return v, nil
}

func (s *Memory) HumanSettings(ctx context.Context, humanID string) (auth.HumanSettings, error) {
	return settingsOneByOne(ctx, s, humanID)
}

// settingsOneByOne is HumanSettings from the single readers (the memory
// store, and any Humans without the one-read form).
func settingsOneByOne(ctx context.Context, h Humans, humanID string) (v auth.HumanSettings, err error) {
	if v.Locale, err = h.PreferredLocale(ctx, humanID); err != nil {
		return v, err
	}
	if v.Theme, err = h.PreferredTheme(ctx, humanID); err != nil {
		return v, err
	}
	if v.SubmitKey, err = h.SubmitKey(ctx, humanID); err != nil {
		return v, err
	}
	if v.DisplayName, err = h.DisplayName(ctx, humanID); err != nil {
		return v, err
	}
	if v.RailOrder, err = h.RailOrder(ctx, humanID); err != nil {
		return v, err
	}
	if v.Diagnostics, err = h.DiagnosticsEnabled(ctx, humanID); err != nil {
		return v, err
	}
	if v.IssueColumns, err = h.IssueColumns(ctx, humanID); err != nil {
		return v, err
	}
	v.ViewPrefs = make(map[string]string, len(viewPrefColumns))
	for _, k := range viewPrefColumns {
		if v.ViewPrefs[k], err = h.ViewPref(ctx, humanID, k); err != nil {
			return v, err
		}
	}
	return v, nil
}
