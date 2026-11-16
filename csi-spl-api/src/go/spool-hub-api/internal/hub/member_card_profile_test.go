package hub_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// Spec 154 section 12.5 (SPL-5707; owner HUM-10, t1 028ac340, poll 36ec7895
// A/A/A): a member saves a first name, a last name and a phone in Settings;
// every other member of a workspace reads them with the address on the
// member card, except in a name-only workspace (t1), where the card carries
// the two names and nothing else. The phone is the member's own, never one of
// anyone's private contacts. Memory, and Postgres under SPOOL_TEST_PG_DSN.

const (
	qFirst, qLast  = "FirstName", "Van LastName"
	qPhoneTyped    = "+358 40 123-4567"
	qPhone         = "+358401234567"
	privatePhone   = "+15550001111" // a private contact's number: never on a card
	privatePhoneQ  = "+15550002222"
	privateContact = "private-contact@example.com"
)

// authDo sends one request to the login host's /api/v1/auth/<path> from b.
func authDo(t *testing.T, b *http.Client, method, path string, body any) (int, []byte, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, "http://"+loginHost+"/api/v1/auth/"+path, rd)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Content-Type", "application/json")
	resp, err := b.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, raw, out
}

// profiledRig: P1 and Q in W1 (Q a developer); Q saved its name and phone;
// P1 and Q each keep a private contact with a phone.
func profiledRig(t *testing.T, more ...func(o *hub.Options, w1, w2 string)) (*contactsRig, *http.Client, string) {
	t.Helper()
	c := newContactsRig(t, onAll, more...)
	q, qHum := c.other(t, "developer")
	code, raw, out := authDo(t, q, http.MethodPut, "preferences", map[string]any{"first_name": qFirst, "last_name": qLast, "phone": qPhoneTyped})
	if code != http.StatusOK || out["phone"] != qPhone || out["display_name"] != qFirst+" "+qLast {
		t.Fatalf("Q saves the profile = %d %s, want 200, phone %s, display_name joined", code, raw, qPhone)
	}
	c.create(t, c.b1, map[string]any{"first_name": "Private", "last_name": "Contact", "email": privateContact, "phone": privatePhone})
	c.do(t, q, http.MethodPost, contactsBase, map[string]any{"first_name": "Private", "last_name": "Two", "phone": privatePhoneQ}, nil)
	return c, q, qHum
}

func noPrivatePhone(t *testing.T, name string, raw []byte) {
	t.Helper()
	for _, p := range []string{privatePhone, privatePhoneQ, privateContact} {
		if strings.Contains(string(raw), p) {
			t.Errorf("%s carries a private contact's %s: %s", name, p, raw)
		}
	}
}

// C50: outside a name-only workspace P1 reads Q's first name, last name,
// address and phone; display_name is their join; no private contact leaks.
func TestMemberCardProfileEveryWorkspace(t *testing.T) {
	c, q, qHum := profiledRig(t)
	code, raw, out := c.do(t, c.b1, http.MethodGet, memberCardPath(qHum), nil, nil)
	if code != http.StatusOK || out["first_name"] != qFirst || out["last_name"] != qLast || out["phone"] != qPhone ||
		!strings.HasSuffix(asString(out["email"]), "@example.com") || out["display_name"] != qFirst+" "+qLast {
		t.Fatalf("P1 reads Q's card = %d %s, want first, last, email, phone", code, raw)
	}
	noPrivatePhone(t, "P1 -> Q", raw)
	// Q reads P1, who never saved a profile: the names split from display_name,
	// no phone, and P1's private contact's number is not P1's.
	code, raw, out = c.do(t, q, http.MethodGet, memberCardPath(c.p1), nil, nil)
	if code != http.StatusOK || out["first_name"] != "Contacts" || out["last_name"] != "Rig" || out["phone"] != nil || out["email"] != c.email {
		t.Fatalf("Q reads P1's card = %d %s, want Contacts / Rig, email, phone null", code, raw)
	}
	noPrivatePhone(t, "Q -> P1", raw)
}

// C51: in a name-only workspace (t1) the card is the two names and nothing
// else: email and phone are null in the JSON itself, no '@' and no number in
// the body. The twin is P1's W2 session (not name-only), which reads all.
func TestMemberCardProfileNameOnly(t *testing.T) {
	c, q, qHum := profiledRig(t, func(o *hub.Options, w1, _ string) { o.MemberCardNameOnlyWorkspaces = []string{w1} })
	for _, k := range []struct {
		name string
		b    *http.Client
		id   string
	}{{"P1 -> Q", c.b1, qHum}, {"Q -> self", q, qHum}} {
		code, raw, out := c.do(t, k.b, http.MethodGet, memberCardPath(k.id), nil, nil)
		if code != http.StatusOK || out["first_name"] != qFirst || out["last_name"] != qLast {
			t.Fatalf("%s = %d %s, want 200 with the two names", k.name, code, raw)
		}
		for _, key := range []string{"email", "phone"} {
			if v, has := out[key]; !has || v != nil {
				t.Errorf("%s: %s = %v (present %v), want null", k.name, key, v, has)
			}
		}
		if strings.Contains(string(raw), "@") || strings.Contains(string(raw), "+358") || strings.Contains(string(raw), "4567") {
			t.Errorf("%s carries an address or the number: %s", k.name, raw)
		}
		noPrivatePhone(t, k.name, raw)
	}
}

// C52: another workspace's person reading Q is 404 and sees neither the
// names nor the number.
func TestMemberCardProfileOtherWorkspaceIs404(t *testing.T) {
	c, _, qHum := profiledRig(t)
	r, _ := c.other(t, "")
	code, raw, out := c.do(t, r, http.MethodGet, memberCardPath(qHum), nil, nil)
	if code != http.StatusNotFound || realmToken(out) != "not_found" || strings.Contains(string(raw), qPhone) || strings.Contains(string(raw), qLast) {
		t.Errorf("R -> Q = %d %s, want 404 not_found, no name, no number", code, raw)
	}
	code, raw, _ = c.do(t, c.b2, http.MethodGet, memberCardPath(qHum), nil, nil)
	if code != http.StatusNotFound || strings.Contains(string(raw), qPhone) {
		t.Errorf("P1 in W2 -> Q (W1 only) = %d %s, want 404", code, raw)
	}
}

// C53: the Settings side. GET profile is the person's own; bad input is a
// 400 that changes nothing; null clears the phone; a display_name saved
// alone splits back into the two names.
func TestProfilePreferences(t *testing.T) {
	c, q, qHum := profiledRig(t)
	code, raw, out := authDo(t, q, http.MethodGet, "profile", nil)
	if code != http.StatusOK || out["first_name"] != qFirst || out["last_name"] != qLast || out["phone"] != qPhone {
		t.Fatalf("GET profile = %d %s", code, raw)
	}
	for _, k := range []struct {
		body map[string]any
		tok  string
	}{
		{map[string]any{"phone": "040 123 4567"}, "invalid_phone"},
		{map[string]any{"phone": "+0401234567"}, "invalid_phone"},
		{map[string]any{"phone": "+358 40 abc"}, "invalid_phone"},
		{map[string]any{"first_name": "OnlyFirst"}, "invalid_name"},
		{map[string]any{"first_name": "", "last_name": "X"}, "invalid_name"},
		{map[string]any{"first_name": strings.Repeat("a", 101), "last_name": nil}, "invalid_name"},
	} {
		code, raw, out := authDo(t, q, http.MethodPut, "preferences", k.body)
		if code != http.StatusBadRequest || realmToken(out) != k.tok {
			t.Errorf("PUT %v = %d %s, want 400 %s", k.body, code, raw, k.tok)
		}
	}
	if code, raw, out := authDo(t, q, http.MethodPut, "preferences", map[string]any{"phone": nil, "first_name": "Solo", "last_name": nil}); code != http.StatusOK || out["phone"] != nil || out["display_name"] != "Solo" {
		t.Fatalf("clear phone, one name = %d %s", code, raw)
	}
	if code, raw, _ := authDo(t, q, http.MethodPut, "preferences", map[string]any{"display_name": "Mary Ann Smith"}); code != http.StatusOK {
		t.Fatalf("PUT display_name = %d %s", code, raw)
	}
	_, raw, out = c.do(t, c.b1, http.MethodGet, memberCardPath(qHum), nil, nil)
	if out["first_name"] != "Mary" || out["last_name"] != "Ann Smith" || out["phone"] != nil {
		t.Errorf("after display_name alone the card = %s, want Mary / Ann Smith, phone null", raw)
	}
}
