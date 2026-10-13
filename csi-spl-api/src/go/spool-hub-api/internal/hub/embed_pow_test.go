package hub_test

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math/bits"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// specs/121 T105: the embed's proof of work and honeypot (embed_pow.go).

// powZeroBits counts the leading zero bits of sha256(s): the iframe's side
// of the contract, written from the doc comment of embed_pow.go.
func powZeroBits(s string) int {
	sum := sha256.Sum256([]byte(s))
	n := 0
	for _, c := range sum {
		if c != 0 {
			return n + bits.LeadingZeros8(c)
		}
		n += 8
	}
	return n
}

// solvePow finds a nonce for challenge and body at want bits, as the
// iframe does.
func solvePow(t *testing.T, challenge, body string, want int) string {
	t.Helper()
	return solvePowFrom(t, challenge, body, want, 0)
}

// solvePowFrom is solvePow trying nonces from from on.
func solvePowFrom(t *testing.T, challenge, body string, want, from int) string {
	t.Helper()
	bodySum := sha256.Sum256([]byte(body))
	prefix := challenge + "." + hex.EncodeToString(bodySum[:]) + "."
	for i := from; i < 1<<26; i++ {
		if nonce := strconv.Itoa(i); powZeroBits(prefix+nonce) >= want {
			return nonce
		}
	}
	t.Fatal("no nonce found")
	return ""
}

// embedChallenge is GET .../challenge for tok.
type embedChallengeOut struct {
	Challenge string `json:"challenge"`
	Bits      int    `json:"bits"`
	Required  bool   `json:"required"`
}

func getChallenge(t *testing.T, e *env, tid, embed, tok string) embedChallengeOut {
	t.Helper()
	code, raw := embedCall(t, e, tid, http.MethodGet, "/v1/embed/"+embed+"/challenge", tok, "")
	var out embedChallengeOut
	if code != http.StatusOK || json.Unmarshal(raw, &out) != nil || out.Challenge == "" || out.Bits < 1 {
		t.Fatalf("challenge: %d %s", code, raw)
	}
	return out
}

// postJSON is a visitor post body with an optional proof.
func postJSON(body, challenge, nonce string) string {
	in := map[string]any{"body": body}
	if challenge != "" {
		in["pow"] = map[string]string{"challenge": challenge, "nonce": nonce}
	}
	raw, _ := json.Marshal(in)
	return string(raw)
}

// solvedPost is the JSON of a post of body carrying a fresh proof.
func solvedPost(t *testing.T, e *env, tid, embed, tok, body string) string {
	t.Helper()
	c := getChallenge(t, e, tid, embed, tok)
	return postJSON(body, c.Challenge, solvePow(t, c.Challenge, body, c.Bits))
}

// TestEmbedFirstPostNeedsProof: a new visitor's first post without a proof
// is 428 embed_challenge with a challenge, and stores nothing; a wrong nonce,
// another visitor's challenge, a stale challenge and a proof of another body
// are 428 too; a filled honeypot is 403 even with a good proof. CONTROL: the
// same post with a good proof is 201, and the second post needs none
// (required false, no pow field: 201).
func TestEmbedFirstPostNeedsProof(t *testing.T) {
	// Each refused proof is a hit: thresholds high enough that no ban or
	// every-post challenge muddles this test (embed_abuse_test.go has those).
	e, pg := abuseEnv(t, hub.EmbedLimits{PowBits: 8, ChallengeAfterHits: 50, BanAfterHits: 60}, nil)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	tok, _ := mint(t, e, tid, embed)
	other, _ := mint(t, e, tid, embed)
	base := "/v1/embed/" + embed + "/messages"

	c := getChallenge(t, e, tid, embed, tok)
	if !c.Required || c.Bits != 8 || !strings.HasPrefix(c.Challenge, "v1.") {
		t.Fatalf("first challenge = %+v, want required at 8 bits", c)
	}
	code, raw := embedCall(t, e, tid, http.MethodPost, base, tok, `{"body":"hi"}`)
	var refusal struct {
		Error, Challenge string
		Bits             int
	}
	if code != http.StatusPreconditionRequired || json.Unmarshal(raw, &refusal) != nil ||
		refusal.Error != hub.TokenEmbedChallenge || refusal.Challenge == "" || refusal.Bits != 8 {
		t.Fatalf("no proof: %d %s, want 428 embed_challenge with a challenge", code, raw)
	}
	// good proves "hi" but not "other text": "another body" reuses it, and a
	// nonce proving both (1 in 2^8) let that case through, after which every
	// later case was a second post that needs no proof (SPL-1702).
	good := solvePow(t, c.Challenge, "hi", 8)
	for powZeroBits(c.Challenge+"."+hexSum("other text")+"."+good) >= 8 {
		n, _ := strconv.Atoi(good)
		good = solvePowFrom(t, c.Challenge, "hi", 8, n+1)
	}
	oc := getChallenge(t, e, tid, embed, other)
	bad := "x"
	for powZeroBits(c.Challenge+"."+hexSum("hi")+"."+bad) >= 8 {
		bad += "x"
	}
	for name, c := range map[string]struct {
		body string
		want int
	}{
		"wrong nonce":       {postJSON("hi", c.Challenge, bad), http.StatusPreconditionRequired},
		"another's":         {postJSON("hi", oc.Challenge, solvePow(t, oc.Challenge, "hi", 8)), http.StatusPreconditionRequired},
		"stale":             {postJSON("hi", "v1."+strings.Split(c.Challenge, ".")[1]+".1", "0"), http.StatusPreconditionRequired},
		"another body":      {postJSON("other text", c.Challenge, good), http.StatusPreconditionRequired},
		"honeypot":          {`{"body":"hi","website":"http://spam.example","pow":{"challenge":"` + c.Challenge + `","nonce":"` + good + `"}}`, http.StatusForbidden},
		"long nonce":        {postJSON("hi", c.Challenge, strings.Repeat("1", 65)), http.StatusPreconditionRequired},
		"pow without nonce": {postJSON("hi", c.Challenge, ""), http.StatusPreconditionRequired},
	} {
		if code, raw := embedCall(t, e, tid, http.MethodPost, base, tok, c.body); code != c.want {
			t.Errorf("%s: %d %s, want %d", name, code, raw, c.want)
		}
	}
	if v, m := embedCounts(t, pg, tid, embed); v != 2 || m != 0 {
		t.Fatalf("refused posts wrote: %d visitors, %d messages", v, m)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, tok, postJSON("hi", c.Challenge, good)); code != http.StatusCreated {
		t.Fatalf("CONTROL: a good proof: %d %s", code, raw)
	}
	if c := getChallenge(t, e, tid, embed, tok); c.Required {
		t.Errorf("after the first post: %+v, want not required", c)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, tok, `{"body":"second"}`); code != http.StatusCreated {
		t.Fatalf("CONTROL: second post, no proof: %d %s", code, raw)
	}
	if _, m := embedCounts(t, pg, tid, embed); m != 2 {
		t.Errorf("messages = %d, want 2", m)
	}
}

func hexSum(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// TestEmbedChallengeRouteOffIsNotFound: with the flag off the challenge
// route answers as an unknown path. CONTROL: on, it answers 401 without a
// token (it exists).
func TestEmbedChallengeRouteOffIsNotFound(t *testing.T) {
	off := embedEnv(t, false)
	tid, _ := off.tenant()
	unknownCode, unknown := embedCall(t, off, tid, http.MethodGet, "/v1/no-such-route", "", "")
	code, raw := embedCall(t, off, tid, http.MethodGet, "/v1/embed/e-some-embed/challenge", strings.Repeat("A", 43), "")
	if code != unknownCode || string(raw) != string(unknown) {
		t.Errorf("flag off: %d %q, want the unknown path's %d %q", code, raw, unknownCode, unknown)
	}
	on, pg := abuseEnv(t, hub.EmbedLimits{}, nil)
	tid2, _ := on.tenant()
	if code, raw := embedCall(t, on, tid2, http.MethodGet, "/v1/embed/"+seedEmbed(t, pg, tid2, true)+"/challenge", "", ""); code != http.StatusUnauthorized {
		t.Errorf("CONTROL: flag on, no token: %d %s, want 401", code, raw)
	}
}
