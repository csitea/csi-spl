package hub_test

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"
	"net/http"
	"slices"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-2108: the costs' second currency. POST /v1/operator/fx/rates (the box
// feed of daily rates), GET /v1/tenant/fx/currencies, and GET /v1/tenant/costs
// converting to the caller's own pick. On Postgres (hub-pg.tst.sh) the real
// store converts; on the memory store (no rates) the routes answer as off and
// the cost read is asked for the caller's currency.

// fxQuote is a made-up three-letter code no other test of this run uses (the
// rates are hub-wide, shared by every test on the database).
func fxQuote(t *testing.T) string {
	t.Helper()
	for {
		n, err := rand.Int(rand.Reader, big.NewInt(26*26))
		if err != nil {
			t.Fatal(err)
		}
		q := fmt.Sprintf("Q%c%c", 'A'+rune(n.Int64()/26), 'A'+rune(n.Int64()%26))
		if _, taken := hubFXQuotes.LoadOrStore(q, true); !taken {
			return q
		}
	}
}

var hubFXQuotes sync.Map

// TestFXRatesRoute: the operator SA writes rates and gets counts back; a
// member session is refused; a bad row is 400. The currencies route lists the
// quote to any member and names EUR as the default.
func TestFXRatesRoute(t *testing.T) {
	e, tid, _ := costEnv(t)
	q := fxQuote(t)
	body := map[string]any{"rows": []map[string]any{
		{"day": "2011-03-04", "quote": q, "rate": 0.9, "source": "FED"},
		{"day": "2011-03-07", "quote": q, "rate": 0.8, "source": "FED"},
	}}
	code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/fx/rates", "good", body)
	if _, pg := e.st.(*store.Postgres); !pg {
		if code != http.StatusServiceUnavailable || out["error"] != "fx_off" {
			t.Fatalf("memory store: %d %v, want 503 fx_off", code, out)
		}
		return
	}
	if code != http.StatusOK || out["rows"] != float64(2) || out["written"] != float64(2) {
		t.Fatalf("CONTROL: the operator's post: %d %v", code, out)
	}
	for _, c := range []struct {
		token string
		want  int
	}{{"", http.StatusUnauthorized}, {"stranger", http.StatusForbidden}} {
		if code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/fx/rates", c.token, body); code != c.want {
			t.Errorf("token %q: %d %v, want %d", c.token, code, out, c.want)
		}
	}
	bad := map[string]any{"rows": []map[string]any{{"day": "2011-03-04", "quote": q, "rate": -1, "source": "FED"}}}
	if code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/fx/rates", "good", bad); code != http.StatusBadRequest {
		t.Errorf("a negative rate: %d %v, want 400", code, out)
	}
	hum := seat(t, e, tid, rbac.RegularUser)
	code, out = call(t, e, tid, http.MethodGet, "/v1/tenant/fx/currencies", hum, nil)
	cs, _ := out["currencies"].([]any)
	if code != http.StatusOK || out["default"] != "EUR" || !slices.Contains(cs, any(q)) {
		t.Fatalf("currencies: %d %v, want %s listed and default EUR", code, out, q)
	}
}

// TestCostReadSecondCurrency: the caller's own pick (membership settings
// second_currency) converts the part at its day's rate and the answer names
// the currency, the rate and its day; a member who never picked gets EUR.
// CONTROL: the USD amount is the seeded one, so the second amount is the
// conversion's.
func TestCostReadSecondCurrency(t *testing.T) {
	e, _, other, _, whoOther, stub := costReadEnv(t)
	q := fxQuote(t)
	ctx := context.Background()
	picker, never := whoOther[rbac.BizOwner], whoOther[rbac.Admin]
	if err := e.st.(interface {
		SetMembershipSettings(ctx context.Context, humanID, tenant string, patch map[string]any) error
	}).SetMembershipSettings(ctx, picker, other, map[string]any{"second_currency": q}); err != nil {
		t.Fatal(err)
	}
	pg, isPG := e.st.(*store.Postgres)
	if isPG {
		// the seeded rows are of 2011-03-04 (a Friday): its rate, and a later one
		if _, err := pg.PutFXRates(ctx, []store.FXRate{{Day: "2011-03-04", Quote: q, Rate: 0.9, Source: "FED"},
			{Day: "2011-03-07", Quote: q, Rate: 0.5, Source: "FED"}}); err != nil {
			t.Fatal(err)
		}
	}
	code, body := call(t, e, other, http.MethodGet, costPath, picker, nil)
	if code != http.StatusOK || body["second_currency"] != q {
		t.Fatalf("the picker's answer: %d %v, want second_currency %s", code, body, q)
	}
	if code, body := call(t, e, other, http.MethodGet, costPath, never, nil); code != http.StatusOK || body["second_currency"] != "EUR" {
		t.Fatalf("a member who never picked: %d %v, want EUR", code, body)
	}
	if !isPG {
		var asked []string
		for _, a := range stub.asks {
			asked = append(asked, a.Currency)
		}
		if !slices.Equal(asked, []string{q, "EUR"}) {
			t.Fatalf("the hub asked the store for %v, want [%s EUR]", asked, q)
		}
		return
	}
	parts, _ := body["parts"].([]any)
	if len(parts) != 1 {
		t.Fatalf("parts %v, want the workspace's one row", body["parts"])
	}
	p := parts[0].(map[string]any)
	if p["usd_micros"] != float64(2_000_000) {
		t.Fatalf("CONTROL: usd_micros %v, want 2000000", p["usd_micros"])
	}
	if p["second_micros"] != float64(1_800_000) || p["fx_rate"] != 0.9 || p["fx_rate_day"] != "2011-03-04" {
		t.Fatalf("2.00 USD at 0.9 of 2011-03-04: %v", p)
	}
	if tot := body["total"].(map[string]any); tot["second_micros"] != float64(1_800_000) {
		t.Fatalf("total %v, want second_micros 1800000", tot)
	}
}
