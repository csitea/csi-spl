package payments

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// spec 021 T022: the claim mail speaks the language the buyer was
// reading the checkout in. The mail is sent by the paid webhook, long after
// the buyer's request is gone, so the locale has to be kept on the checkout
// row (rdb 0025); before that column the mail was always the hub default.

// buyLocalized holds a slug with a body locale and the given request headers,
// pays it on the fake rail, and returns the claim mail it sent.
func buyLocalized(t *testing.T, r *rig, tenant, bodyLocale string, headers map[string]string) (store.Checkout, string, string) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"tenant_id": tenant, "email": "buyer@example.com", "locale": bodyLocale})
	req := httptest.NewRequest("POST", "/api/v1/checkout", bytes.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	r.h.ServeHTTP(w, req)
	if w.Code != 201 {
		t.Fatalf("checkout %s locale %q: %d %s", tenant, bodyLocale, w.Code, w.Body.String())
	}
	out := map[string]any{}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	id := out["checkout_id"].(string)
	before := len(r.mail.Messages())
	if code, f := r.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": id}); code != 200 || f["applied"] != true {
		t.Fatalf("fake-pay %s: %d %v", tenant, code, f)
	}
	msgs := r.mail.Messages()
	if len(msgs) != before+1 {
		t.Fatalf("%s: want one new claim mail, got %d", tenant, len(msgs)-before)
	}
	c, err := r.st.GetCheckout(t.Context(), id)
	if err != nil {
		t.Fatal(err)
	}
	// §1.3 reports the same locale the row keeps, so a buy can be checked from
	// outside the hub (do_spl_checkout_fake_buy asserts on it).
	if code, st := r.do(t, "GET", "/api/v1/checkout/"+id, nil); code != 200 || st["locale"] != c.Locale {
		t.Fatalf("status locale %v, row %q (%d)", st["locale"], c.Locale, code)
	}
	m := msgs[len(msgs)-1]
	return c, m.Locale, m.TextBody
}

func localeRig(t *testing.T) *rig {
	t.Helper()
	return newRig(t, mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"}))
}

// TestClaimMailFollowsBuyerLocale: what the WUI sends is what the buyer is
// mailed, and the claim link lands on the same language's page.
func TestClaimMailFollowsBuyerLocale(t *testing.T) {
	r := localeRig(t)
	for _, tc := range []struct{ tenant, sent, want, prefix string }{
		{"acme-fi", "fi", "fi", "/fi"},
		{"acme-sv", "sv-SE", "sv", "/sv"},     // a regional code normalizes
		{"acme-he", "HE", "he", "/he"},        // case is ignored
		{"acme-en", "en", "en", ""},           // the default takes no path prefix
		{"acme-us", "en-US-x-hack", "en", ""}, // a tag collapses to its base language
	} {
		c, loc, body := buyLocalized(t, r, tc.tenant, tc.sent, nil)
		if c.Locale != tc.want {
			t.Errorf("%s: checkout kept locale %q, want %q", tc.tenant, c.Locale, tc.want)
		}
		if loc != tc.want {
			t.Errorf("%s: mail rendered in %q, want %q", tc.tenant, loc, tc.want)
		}
		want := "https://dev.example.test" + tc.prefix + "/checkout/claim#checkout=" + c.ID + "&token="
		if !strings.Contains(body, want) {
			t.Errorf("%s: claim link is not %s:\n%s", tc.tenant, want, body)
		}
	}
	// the fi body is the fi TEMPLATE, not the English one relabelled
	_, _, fi := buyLocalized(t, r, "acme-fi2", "fi", nil)
	if !strings.Contains(fi, "Työtila") || strings.Contains(fi, "sign in at") {
		t.Errorf("the fi claim mail is not the fi template:\n%s", fi)
	}
}

// TestClaimMailLocaleFallsBack: no locale, or one the hub does not ship, leaves
// the mail on the hub default -- which is what every checkout did before rdb
// 0025, so nothing regresses for a buyer who says nothing.
func TestClaimMailLocaleFallsBack(t *testing.T) {
	r := localeRig(t)
	// a buyer who says nothing at all: no body locale, no headers
	c, loc, body := buyLocalized(t, r, "quiet", "", nil)
	if c.Locale != "" || loc != i18n.DefaultLocale {
		t.Errorf("silent buyer: kept %q, mailed %q, want \"\" / %q", c.Locale, loc, i18n.DefaultLocale)
	}
	if !strings.Contains(body, "https://dev.example.test/checkout/claim#checkout=") {
		t.Errorf("silent buyer: the claim link took a locale prefix:\n%s", body)
	}
	// Never trusted onward: a locale this hub does not ship (and one shaped
	// like a path) must not reach a template path or the URL, and must not
	// refuse the sale either.
	for _, bad := range []string{"klingon", "zz", "../../../etc/passwd", "fi/../en", "..", "en\x00"} {
		c, loc, body := buyLocalized(t, r, "bad-"+strings.Map(keepSlug, bad), bad, nil)
		if c.Locale != "" || loc != i18n.DefaultLocale {
			t.Errorf("locale %q: kept %q, mailed %q", bad, c.Locale, loc)
		}
		if !strings.Contains(body, "https://dev.example.test/checkout/claim#checkout=") {
			t.Errorf("locale %q reached the claim link:\n%s", bad, body)
		}
	}
	// A locale the hub stopped shipping cannot be mailed either: the row is
	// read back through Normalize, not spliced into a path.
	held, err := r.st.GetCheckout(t.Context(), c.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.st.HoldCheckout(t.Context(), held, held.CreatedAt, 0); err == nil {
		t.Error("the store re-held a checkout id that already exists")
	}
	held.ID, held.TenantID, held.Locale = "co_retired", "retired", "zz"
	if err := r.st.HoldCheckout(t.Context(), held, held.CreatedAt, 0); err == nil {
		t.Error("the store accepted a locale the hub does not ship")
	}
}

// keepSlug keeps a tenant id a valid slug while naming the bad input.
func keepSlug(r rune) rune {
	switch {
	case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
		return r
	default:
		return -1
	}
}

// TestBuyerLocaleFromHeaders: the WUI's body field wins, then X-Locale, then
// Accept-Language -- the same order every other hub mail follows (i18n.Match).
func TestBuyerLocaleFromHeaders(t *testing.T) {
	r := localeRig(t)
	for _, tc := range []struct {
		tenant, body, want string
		headers            map[string]string
	}{
		{"h-body", "fi", "fi", map[string]string{i18n.HeaderLocale: "sv", "Accept-Language": "el"}},
		{"h-xloc", "", "sv", map[string]string{i18n.HeaderLocale: "sv", "Accept-Language": "el"}},
		{"h-accept", "", "el", map[string]string{"Accept-Language": "el-GR,el;q=0.9"}},
		{"h-badx", "", "el", map[string]string{i18n.HeaderLocale: "klingon", "Accept-Language": "el"}},
		{"h-none", "", "", nil},
	} {
		c, loc, _ := buyLocalized(t, r, tc.tenant, tc.body, tc.headers)
		if c.Locale != tc.want {
			t.Errorf("%s: kept %q, want %q", tc.tenant, c.Locale, tc.want)
		}
		wantMail := tc.want
		if wantMail == "" {
			wantMail = i18n.DefaultLocale
		}
		if loc != wantMail {
			t.Errorf("%s: mailed %q, want %q", tc.tenant, loc, wantMail)
		}
	}
}
