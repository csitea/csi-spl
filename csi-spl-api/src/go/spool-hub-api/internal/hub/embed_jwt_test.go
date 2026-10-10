package hub_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"
)

// specs/121 T205: the signed-in customer's JWT (embed_jwt.go). Each Done
// refusal (expired, wrong aud, wrong key, replayed) has its own test, and
// each test's CONTROL is the same JWT with only the refused part made right,
// accepted: the 401 is that part's, not a broken fixture's.

// embedKey is one per-embed key pair as T203 makes it; Kid its key id.
type embedKey struct {
	priv *ecdsa.PrivateKey
	Kid  string
}

func newEmbedKey(t *testing.T, kid string) embedKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return embedKey{k, kid}
}

// keyedEmbed is an enabled embed of a fresh workspace holding k's public half.
func keyedEmbed(t *testing.T, e *env, k embedKey) (string, string) {
	t.Helper()
	pg := pgOnly(t, e)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	der, err := x509.MarshalPKIXPublicKey(&k.priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pub := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	if _, err := pg.SetEmbedKey(context.Background(), tid, embed, pub, k.Kid); err != nil {
		t.Fatal(err)
	}
	return tid, embed
}

// signJWT is what the customer's server does: header and claims as given,
// signed ES256 with k (r || s, 32 bytes each).
func signJWT(t *testing.T, k embedKey, header, claims map[string]any) string {
	t.Helper()
	enc := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	signed := enc(header) + "." + enc(claims)
	sum := sha256.Sum256([]byte(signed))
	r, s, err := ecdsa.Sign(rand.Reader, k.priv, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signed + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// claimsFor are valid claims for sub on embed: issued now, 5 minutes to live.
func claimsFor(embed, sub string, iat time.Time) map[string]any {
	return map[string]any{"sub": sub, "aud": embed, "iat": iat.Unix(), "exp": iat.Add(5 * time.Minute).Unix()}
}

func es256(kid string) map[string]any {
	return map[string]any{"alg": "ES256", "typ": "JWT", "kid": kid}
}

type signInOut struct {
	Token     string `json:"token"`
	VisitorID string `json:"visitor_id"`
	Channel   string `json:"channel"`
}

// signInCall posts jwt to the sign-in route: the code, the answer and the
// raw body.
func signInCall(t *testing.T, e *env, tid, embed, jwt string) (int, signInOut, string) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"jwt": jwt})
	code, raw := embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/signin", "", string(body))
	var out signInOut
	_ = json.Unmarshal(raw, &out)
	return code, out, string(raw)
}

// accepted is a sign-in that must pass: 200 and a working visitor token.
func accepted(t *testing.T, e *env, tid, embed, jwt, what string) signInOut {
	t.Helper()
	code, out, raw := signInCall(t, e, tid, embed, jwt)
	if code != http.StatusOK || out.Token == "" || out.Channel == "" {
		t.Fatalf("%s: %d %s, want 200 and a token", what, code, raw)
	}
	readLines(t, e, tid, embed, out.Token)
	return out
}

// refused is a sign-in that must be a 401 embed_jwt naming why.
func refused(t *testing.T, e *env, tid, embed, jwt, why string) {
	t.Helper()
	code, _, raw := signInCall(t, e, tid, embed, jwt)
	if code != http.StatusUnauthorized || !strings.Contains(raw, "embed_jwt") || !strings.Contains(raw, why) {
		t.Errorf("%s: %d %s, want 401 embed_jwt %q", why, code, raw, why)
	}
}

// TestEmbedSignInOneChannelPerSub (happy path): a valid JWT signs its sub in
// with a visitor token that reads its channel; a later JWT for the same sub
// is the same visitor and channel; another sub is another channel.
func TestEmbedSignInOneChannelPerSub(t *testing.T) {
	e := embedEnv(t, true)
	k := newEmbedKey(t, "k-happy")
	tid, embed := keyedEmbed(t, e, k)
	now := time.Now()
	first := accepted(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", now)), "first sign-in")
	again := accepted(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", now.Add(-time.Second))), "second sign-in")
	if again.VisitorID != first.VisitorID || again.Channel != first.Channel {
		t.Errorf("one sub, two visitors: %+v vs %+v", again, first)
	}
	other := accepted(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-2", now)), "another sub")
	if other.Channel == first.Channel || other.VisitorID == first.VisitorID {
		t.Errorf("CONTROL: another sub shares the channel: %+v", other)
	}
}

// TestEmbedSignInRefusesExpired: a JWT whose exp has passed is refused.
func TestEmbedSignInRefusesExpired(t *testing.T) {
	e := embedEnv(t, true)
	k := newEmbedKey(t, "k-exp")
	tid, embed := keyedEmbed(t, e, k)
	old := time.Now().Add(-10 * time.Minute)
	refused(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", old)), "expired")
	accepted(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", time.Now())), "CONTROL: the same JWT issued now")
}

// TestEmbedSignInRefusesWrongAud: a JWT for another embed, even of the same
// workspace and signed by this embed's key, is refused.
func TestEmbedSignInRefusesWrongAud(t *testing.T) {
	e := embedEnv(t, true)
	k := newEmbedKey(t, "k-aud")
	tid, embed := keyedEmbed(t, e, k)
	otherEmbed := seedEmbed(t, pgOnly(t, e), tid, true)
	now := time.Now()
	for _, aud := range []any{otherEmbed, []string{otherEmbed}, ""} {
		c := claimsFor(embed, "user-1", now)
		c["aud"] = aud
		refused(t, e, tid, embed, signJWT(t, k, es256(k.Kid), c), "aud")
	}
	c := claimsFor(embed, "user-1", now)
	c["aud"] = []string{otherEmbed, embed}
	accepted(t, e, tid, embed, signJWT(t, k, es256(k.Kid), c), "CONTROL: aud lists this embed")
}

// TestEmbedSignInRefusesWrongKey: a JWT signed by another key (another
// embed's, or this embed's revoked one) is refused, as is a header naming
// another key id, and a JWT that is not ES256 (none, HS256).
func TestEmbedSignInRefusesWrongKey(t *testing.T) {
	e := embedEnv(t, true)
	k := newEmbedKey(t, "k-right")
	tid, embed := keyedEmbed(t, e, k)
	now := time.Now()
	wrong := newEmbedKey(t, k.Kid) // same key id, other key
	refused(t, e, tid, embed, signJWT(t, wrong, es256(k.Kid), claimsFor(embed, "user-1", now)), "not signed by this embed's key")
	refused(t, e, tid, embed, signJWT(t, k, es256("k-old"), claimsFor(embed, "user-1", now)), "not signed by this embed's key")
	good := signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", now))
	p := strings.Split(good, ".")
	for alg, jwt := range map[string]string{
		"none":  base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`)) + "." + p[1] + ".",
		"HS256": base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256"}`)) + "." + p[1] + "." + p[2],
	} {
		t.Run(alg, func(t *testing.T) { refused(t, e, tid, embed, jwt, "not a compact ES256 JWT") })
	}
	accepted(t, e, tid, embed, good, "CONTROL: the same claims signed by the embed's key")
}

// TestEmbedSignInRefusesReplay: a JWT is good once; the same JWT again, or
// with its signature in ECDSA's other valid form, is refused and makes no
// second token.
func TestEmbedSignInRefusesReplay(t *testing.T) {
	e := embedEnv(t, true)
	k := newEmbedKey(t, "k-replay")
	tid, embed := keyedEmbed(t, e, k)
	jwt := signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", time.Now()))
	accepted(t, e, tid, embed, jwt, "CONTROL: its first use")
	refused(t, e, tid, embed, jwt, "already used")
	p := strings.Split(jwt, ".")
	sig, _ := base64.RawURLEncoding.DecodeString(p[2])
	n := elliptic.P256().Params().N
	s := new(big.Int).SetBytes(sig[32:])
	s.Sub(n, s)
	s.FillBytes(sig[32:])
	refused(t, e, tid, embed, p[0]+"."+p[1]+"."+base64.RawURLEncoding.EncodeToString(sig), "already used")
}

// TestEmbedSignInClaimsAndDoors: a JWT living longer than 5 minutes, issued
// in the future or naming no sub is refused; an embed without a key, a
// disabled one and the flag off answer 404 as an unknown path.
func TestEmbedSignInClaimsAndDoors(t *testing.T) {
	e := embedEnv(t, true)
	k := newEmbedKey(t, "k-claims")
	tid, embed := keyedEmbed(t, e, k)
	now := time.Now()
	long := claimsFor(embed, "user-1", now)
	long["exp"] = now.Add(time.Hour).Unix()
	refused(t, e, tid, embed, signJWT(t, k, es256(k.Kid), long), "longer than 5 minutes")
	refused(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", now.Add(time.Hour))), "not valid yet")
	refused(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "", now)), "no usable sub")

	jwt := signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", now))
	keyless := seedEmbed(t, pgOnly(t, e), tid, true)
	if code, _, raw := signInCall(t, e, tid, keyless, jwt); code != http.StatusNotFound {
		t.Errorf("an embed with no key: %d %s, want 404", code, raw)
	}
	off := embedEnv(t, false)
	if code, _, raw := signInCall(t, off, tid, embed, jwt); code != http.StatusNotFound {
		t.Errorf("flag off: %d %s, want 404", code, raw)
	}
	accepted(t, e, tid, embed, jwt, "CONTROL: the same JWT on the keyed embed, flag on")
}
