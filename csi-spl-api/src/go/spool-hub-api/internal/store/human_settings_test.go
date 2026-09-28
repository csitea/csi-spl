package store

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-1100: the one-read HumanSettings answers exactly what the single
// readers answer - never set, every setting set, cleared again - and an
// unknown human is auth.ErrNoHuman through AuthHooks, as each single reader.
func TestHumanSettingsEqualsTheSingleReaders(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			hooks := AuthHooks{H: h}
			hum, err := h.Admit(ctx, Identity{Provider: "password", Subject: uid("set-")}, "", AdmitPolicy{}, time.Now().UTC())
			if err != nil {
				t.Fatal(err)
			}
			check := func(label string) {
				t.Helper()
				want, err := settingsOneByOne(ctx, h, hum)
				if err != nil {
					t.Fatal(label, err)
				}
				got, err := hooks.HumanSettings(ctx, hum)
				if err != nil {
					t.Fatal(label, err)
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("%s: one read %+v, single readers %+v", label, got, want)
				}
				if len(got.ViewPrefs) != len(auth.ViewPrefs) {
					t.Fatalf("%s: view prefs %v, want every key of %v", label, got.ViewPrefs, auth.ViewPrefs)
				}
			}
			check("unset")
			for _, err := range []error{
				h.SetPreferredLocale(ctx, hum, "fi"),
				h.SetPreferredTheme(ctx, hum, "light-red"),
				h.SetSubmitKey(ctx, hum, "ctrl-enter"),
				h.SetDisplayName(ctx, hum, "FirstName LastName"),
				h.SetRailOrder(ctx, hum, []string{"archive", "events", "flow", "topics", "issues", "channels", "dm"}),
				h.SetDiagnosticsEnabled(ctx, hum, true),
				h.SetViewPref(ctx, hum, auth.PrefMessageOrder, "newest-last"),
				h.SetViewPref(ctx, hum, auth.PrefComposerPosition, "bottom"),
				h.SetViewPref(ctx, hum, auth.PrefIssuesView, "status"),
			} {
				if err != nil {
					t.Fatal(err)
				}
			}
			check("set")
			got, _ := hooks.HumanSettings(ctx, hum)
			if got.Theme != "light-red" || !got.Diagnostics || got.ViewPrefs[auth.PrefIssuesView] != "status" || len(got.RailOrder) != 7 {
				t.Fatalf("set values not read: %+v", got)
			}
			for _, err := range []error{h.SetPreferredTheme(ctx, hum, ""), h.SetRailOrder(ctx, hum, nil),
				h.SetViewPref(ctx, hum, auth.PrefIssuesView, "")} {
				if err != nil {
					t.Fatal(err)
				}
			}
			check("cleared")
			// CONTROL: an unknown human, as the single readers answer it.
			if _, err := hooks.HumanSettings(ctx, "HUM-999999999"); !errors.Is(err, auth.ErrNoHuman) {
				t.Fatalf("unknown human: %v", err)
			}
			if _, err := hooks.PreferredTheme(ctx, "HUM-999999999"); !errors.Is(err, auth.ErrNoHuman) {
				t.Fatalf("unknown human, single reader: %v", err)
			}
		})
	}
}
