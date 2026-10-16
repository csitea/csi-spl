package auth

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

// SPL-2108: the costs' second currency is a per-tenant override, null = EUR,
// and a pick must be a currency the hub holds rates for.

type fxPrefs struct {
	Preferences
	codes []string
	has   bool
	err   error
}

func (f fxPrefs) FXCurrencies(context.Context) ([]string, bool, error) { return f.codes, f.has, f.err }

func TestParseSecondCurrency(t *testing.T) {
	if v, has, code, _ := parseSecondCurrency(json.RawMessage(`" jpy "`)); v != "JPY" || !has || code != "" {
		t.Fatalf("jpy: %q %v %q", v, has, code)
	}
	if v, has, code, _ := parseSecondCurrency(json.RawMessage(`null`)); v != "" || !has || code != "" {
		t.Fatalf("null clears: %q %v %q", v, has, code)
	}
	if _, has, _, _ := parseSecondCurrency(nil); has {
		t.Fatal("absent must not be has")
	}
	for _, bad := range []string{`"euro"`, `"E1R"`, `1`, `{}`} {
		if _, _, code, _ := parseSecondCurrency(json.RawMessage(bad)); code != "unsupported_second_currency" {
			t.Errorf("%s: code %q", bad, code)
		}
	}
	if p := parseOK(t, `{"second_currency":"sek"}`).membershipPatch(); p["second_currency"] != "SEK" {
		t.Fatalf("patch: %+v", p)
	}
	if p := parseOK(t, `{"second_currency":null}`).membershipPatch(); p["second_currency"] != nil {
		t.Fatalf("null must clear: %+v", p)
	} else if _, ok := p["second_currency"]; !ok {
		t.Fatal("null must be in the patch (clears the key)")
	}
}

func TestCheckSecondCurrency(t *testing.T) {
	h := &Handler{prefs: fxPrefs{codes: []string{"EUR", "JPY", "SEK"}, has: true}}
	if _, code, _ := h.checkSecondCurrency(context.Background(), "JPY"); code != "" {
		t.Fatalf("JPY has rates: refused %q", code)
	}
	if st, code, _ := h.checkSecondCurrency(context.Background(), "XAU"); st != 400 || code != "unsupported_second_currency" {
		t.Fatalf("XAU has no rates: %d %q, want 400", st, code)
	}
	empty := &Handler{prefs: fxPrefs{has: true}}
	if _, code, _ := empty.checkSecondCurrency(context.Background(), "EUR"); code != "" {
		t.Fatalf("the default EUR is refused before its rates arrive: %q", code)
	}
	broken := &Handler{prefs: fxPrefs{has: true, err: errors.New("db down")}}
	if st, code, _ := broken.checkSecondCurrency(context.Background(), "JPY"); st != 503 || code == "" {
		t.Fatalf("a failed read must be a 503, never an accept: %d %q", st, code)
	}
	if got := (HumanSettings{}).Overlay(MembershipSettings{SecondCurrency: ptr("JPY")}).SecondCurrency; got != "JPY" {
		t.Fatalf("overlay: %q", got)
	}
}

func ptr(s string) *string { return &s }
