package payments

import (
	"crypto/ed25519"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// 017 T009 (FR-SEC-003): the claim mail carries a tenant URL and a single-use
// claim link, and NEVER key material. TestFakeBuyEndToEnd checks the happy
// path's one body in passing; this is the standing regression test, and the
// whole point of it is that it fails the day any encoding of the root key or
// its seed reaches a rendered mail.
//
// Two halves, because they fail for different reasons:
//   - the live buy (fake rail): the key the claim actually minted, the
//     placeholder it rotated away from, and their seeds, in every encoding a
//     careless template or log helper would reach for;
//   - every one of the 19 i18n.Supported locales: a template added or
//     retranslated for one locale only is still checked.

// keyShaped is what an ed25519 secret looks like whatever variable leaked it:
// 64 bytes of base64 (86 chars + padding), or 32/64 bytes of hex. The emailed
// claim token is 43 base64url chars, so neither pattern can match it.
var keyShaped = []*regexp.Regexp{
	regexp.MustCompile(`[A-Za-z0-9+/]{86}={0,2}`),
	regexp.MustCompile(`[A-Za-z0-9_-]{86}`),
	regexp.MustCompile(`[0-9a-fA-F]{64,}`),
}

// secretEncodings is every spelling of b a leak could take: the encoders the
// hub already imports, plus hex in both cases.
func secretEncodings(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	return []string{
		base64.StdEncoding.EncodeToString(b),
		base64.RawStdEncoding.EncodeToString(b),
		base64.URLEncoding.EncodeToString(b),
		base64.RawURLEncoding.EncodeToString(b),
		hex.EncodeToString(b),
		strings.ToUpper(hex.EncodeToString(b)),
		base32.StdEncoding.EncodeToString(b),
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b),
	}
}

// assertNoKeyMaterial fails when text carries any encoding of secrets, or
// anything key-shaped at all.
func assertNoKeyMaterial(t *testing.T, what, text string, secrets ...[]byte) {
	t.Helper()
	for _, s := range secrets {
		for _, enc := range secretEncodings(s) {
			if strings.Contains(text, enc) {
				t.Errorf("%s carries key material (%d-byte secret): %s", what, len(s), text)
				return
			}
		}
	}
	for _, re := range keyShaped {
		if m := re.FindString(text); m != "" {
			t.Errorf("%s carries a key-shaped run %q: %s", what, m, text)
			return
		}
	}
}

// TestClaimMailCarriesNoKeyMaterial is 017 T009 / SEC-03: build the real claim
// mail and assert its subject and body carry neither the root private key nor
// any seed material.
func TestClaimMailCarriesNoKeyMaterial(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
	r := newRig(t, cfg)

	_, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	id, browserTok := co["checkout_id"].(string), co["claim_token"].(string)
	if code, _ := r.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": id}); code != 200 {
		t.Fatalf("fake-pay: %d", code)
	}
	// the placeholder root key the checkout held: it must not be mailed either
	ten, err := r.st.GetTenant(t.Context(), "acme")
	if err != nil {
		t.Fatal(err)
	}
	placeholder := []byte(ten.RootPubKey)

	msgs := r.mail.Messages()
	if len(msgs) != 1 || msgs[0].Template != TemplateTenantPaid {
		t.Fatalf("want one %s mail, got %+v", TemplateTenantPaid, msgs)
	}
	// The mail is the real one: it carries the claim link (without this the
	// assertions below would pass on an empty body).
	if !strings.Contains(msgs[0].TextBody, claimURL+"#checkout="+id+"&token=") {
		t.Fatalf("the claim mail carries no claim link:\n%s", msgs[0].TextBody)
	}
	link := strings.TrimSpace(strings.SplitN(msgs[0].TextBody[strings.Index(msgs[0].TextBody, "&token=")+len("&token="):], "\n", 2)[0])

	code, cl := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": link})
	if code != 200 {
		t.Fatalf("claim: %d %v", code, cl)
	}
	priv, err := base64.StdEncoding.DecodeString(cl["root_private_key"].(string))
	if err != nil || len(priv) != ed25519.PrivateKeySize {
		t.Fatalf("claim returned no usable root key: %v", err)
	}
	minted := ed25519.PrivateKey(priv)
	secrets := [][]byte{priv, minted.Seed(), []byte(minted.Public().(ed25519.PublicKey)), placeholder}

	// The claim sends no second mail, so this is the one body the buyer got.
	for i, m := range r.mail.Messages() {
		assertNoKeyMaterial(t, "claim mail subject", m.Subject, secrets...)
		assertNoKeyMaterial(t, "claim mail body", m.TextBody, secrets...)
		if i > 0 {
			t.Error("the claim must not send a second mail")
		}
	}
	if strings.Contains(msgs[0].TextBody, browserTok) {
		t.Error("the browser claim token reached the mail body")
	}
	// CONTROL: the detector would have caught the key had it been there — a
	// green assertion above is evidence only if planting a secret turns red.
	for _, s := range secrets {
		planted := msgs[0].TextBody + "\n" + base64.StdEncoding.EncodeToString(s)
		probe := &testing.T{}
		assertNoKeyMaterial(probe, "planted", planted, secrets...)
		if !probe.Failed() {
			t.Fatalf("the detector misses a %d-byte secret planted in the body", len(s))
		}
	}
}

// TestClaimMailNoKeyMaterialEveryLocale renders the claim mail in all 19
// locales: a template added or retranslated for one locale only is still held
// to FR-SEC-003, and none of them may spell a secret out.
func TestClaimMailNoKeyMaterialEveryLocale(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	secrets := [][]byte{priv, priv.Seed(), []byte(pub)}
	if len(i18n.Supported) != 19 {
		t.Fatalf("i18n.Supported is %d locales, the mail templates ship 19", len(i18n.Supported))
	}
	for _, loc := range i18n.Supported {
		link := i18n.LocalizeURL(claimURL, loc, i18n.DefaultLocale) + "#checkout=co_x&token=" + NewClaimToken()
		m, err := TenantPaid("buyer@example.com", loc, "acme", "https://dev.example.test/login?tenant=acme", link, time.Hour)
		if err != nil {
			t.Fatalf("%s: %v", loc, err)
		}
		if m.Locale != loc || m.Template != mail.TemplateTenantPaid {
			t.Fatalf("%s rendered as %q / %q", loc, m.Locale, m.Template)
		}
		if !strings.Contains(m.TextBody, link) || !strings.Contains(m.TextBody, "acme") {
			t.Fatalf("%s: the body carries no claim link / tenant:\n%s", loc, m.TextBody)
		}
		assertNoKeyMaterial(t, "subject ("+loc+")", m.Subject, secrets...)
		assertNoKeyMaterial(t, "body ("+loc+")", m.TextBody, secrets...)
	}
}
