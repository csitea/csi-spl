package payments

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// CardKeyMode is the boot log's stand-in for the card key: the mode, never
// the key. Fake keys only; each key is built so no scanner reads
// it as a real key (gitleaks stripe-access-token).
func TestCardKeyModeNeverShowsKey(t *testing.T) {
	cases := []struct {
		name, key, want string
	}{
		{"test-shaped", "sk_" + "test_" + "fakeEntryKey01", "test"},
		{"restricted test-shaped", "rk_" + "test_" + "fakeEntryKey02", "test"},
		{"live-shaped", "sk_" + "live_" + "fakeEntryKey03", "live"},
		{"restricted live-shaped", "rk_" + "live_" + "fakeEntryKey06", "live"},
		{"malformed", "pk_live_fakeEntryKey04", ""},
		{"empty", "", ""},
	}
	for _, c := range cases {
		got := (&Config{StripeSecretKey: c.key}).CardKeyMode()
		if got != c.want {
			t.Errorf("%s: CardKeyMode() = %q, want %q", c.name, got, c.want)
		}
		if c.key != "" && strings.Contains(got, "fakeEntryKey") {
			t.Errorf("%s: CardKeyMode() = %q holds the key", c.name, got)
		}
	}
}

// Load (the process env) reads what LoadFrom reads from the same map. No
// t.Parallel: t.Setenv forbids it.
func TestLoadEqualsLoadFrom(t *testing.T) {
	vars := withClaimURL(map[string]string{
		"SPOOL_HUB_PAYMENT_PROVIDER": "stripe", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000",
		"SPOOL_HUB_PAYMENT_HOLD": "2h", "SPOOL_HUB_PAYMENT_CURRENCY": " EUR ",
		"SPOOL_HUB_STRIPE_SECRET_KEY": "sk_" + "test_" + "fakeEntryKey05", "SPOOL_HUB_STRIPE_WEBHOOK_SECRET": "whsec_fakeEntry",
		"SPOOL_HUB_STRIPE_PUBLISHABLE_KEY": "pk_test_fakeEntry",
	})
	for _, kv := range os.Environ() {
		if k, _, _ := strings.Cut(kv, "="); strings.HasPrefix(k, "SPOOL_HUB_") {
			t.Setenv(k, "")
			_ = os.Unsetenv(k)
		}
	}
	for k, v := range vars {
		t.Setenv(k, v)
	}
	fromEnv, err := Load(" LDE ")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	fromMap, err := LoadFrom(" LDE ", vars)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	// A mismatch prints both with the key blanked: a red run logs no key.
	if !reflect.DeepEqual(fromEnv, fromMap) {
		e, m := *fromEnv, *fromMap
		keyEqual := e.StripeSecretKey == m.StripeSecretKey
		e.StripeSecretKey, m.StripeSecretKey = "", ""
		t.Fatalf("Load = %+v\nLoadFrom = %+v\nStripeSecretKey equal: %v", e, m, keyEqual)
	}
	if fromEnv.Env != "lde" || fromEnv.Currency != "eur" || fromEnv.PlanCents != 2000 {
		t.Fatalf("Load did not read the env: Env=%q Currency=%q PlanCents=%d", fromEnv.Env, fromEnv.Currency, fromEnv.PlanCents)
	}
}

// NewWired refuses a nil store with the error New gives.
func TestNewWiredNilStore(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"})
	h, err := NewWired(cfg, Deps{})
	if h != nil || err == nil {
		t.Fatalf("NewWired(nil store) = %v, %v; want nil, error", h, err)
	}
	_, want := New(cfg, Deps{})
	if want == nil || err.Error() != want.Error() {
		t.Fatalf("NewWired error %q, New error %v", err, want)
	}
}
