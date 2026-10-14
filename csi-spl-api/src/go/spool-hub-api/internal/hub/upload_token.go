package hub

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"
)

// SPL-1815: the upload token is checked on whichever instance the POST
// lands on. Since the hub runs up to two instances (cnf max_instances 2,
// f4bcab00f), a token kept only in the minting process's map was refused
// 401 door whenever the upload went to the other one: the WUI's socket and
// views ride the session-affinity cookie, the upload is sent without
// credentials and is routed freely. On prd 2026-10-14 07:46..07:48Z the
// owner's phone got 401 on all 20 POST /v1/files, each on the instance that
// held none of its sockets.
//
// With Options.UploadTokenKey set, a token is `<b64url(json)>.<b64url(mac)>`
// (the session cookie's shape), signed with a key every instance derives
// from the same SPOOL_HUB_AUTH_SESSION_KEY, so any instance verifies it.
// Without a key (lde with auth off, tests) the per-process map stays.
//
// A WUI socket's token is valid on every instance. The WUI notices a
// retired revision through /v1/wui/revision, and only retries the upload
// on a door.
//
// SPL-1826: a box token is signed too, but bound to the minting revision
// (Options.Revision, Cloud Run's $K_REVISION): every live instance of that
// revision accepts it, any other revision refuses it 401 door. The box's
// session probe (hubclient Probe, redeploy_test.go) reads that door as "my
// socket sits on a revision that no longer serves REST" and redials. Kept
// in the map it was refused by the SIBLING instance too, since the box
// carries no affinity cookie and its REST goes to either one: measured with
// two processes of one revision (box_token_instances_test.go, n = 15 each),
// every pin sync on dial, probe and put-file there got the false door, and
// the probe redialled the session onto a dial that failed the same way.

// uploadClaims is a signed upload token's payload.
type uploadClaims struct {
	Tenant  string `json:"t"`
	Box     string `json:"b"`
	Member  string `json:"m,omitempty"`
	Expires int64  `json:"e"`           // unix nanoseconds
	Rev     string `json:"r,omitempty"` // a box token's revision; "" on a WUI token
}

// tokenRev is the revision a token of box is bound to: none for the WUI.
func tokenRev(box, rev string) string {
	if box == WUIBox {
		return ""
	}
	return rev
}

// signUploadToken returns the signed token for t, minted on revision rev.
func signUploadToken(key []byte, rev string, t uploadToken) string {
	c := uploadClaims{Tenant: t.tenant, Box: t.box, Member: t.member, Expires: t.expires.UnixNano(), Rev: tokenRev(t.box, rev)}
	raw, _ := json.Marshal(c) //nolint:errchkjson // strings and an int
	payload := base64.RawURLEncoding.EncodeToString(raw)
	m := hmac.New(sha256.New, key)
	m.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// openUploadToken verifies the MAC before it decodes anything; a box token
// only on the revision rev that minted it.
func openUploadToken(key []byte, rev, tok string) (uploadToken, bool) {
	payload, sig, ok := strings.Cut(tok, ".")
	if !ok || payload == "" || sig == "" || len(key) == 0 {
		return uploadToken{}, false
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte(payload))
	got, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil || !hmac.Equal(got, m.Sum(nil)) {
		return uploadToken{}, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	var c uploadClaims
	if err != nil || json.Unmarshal(raw, &c) != nil || c.Tenant == "" || c.Box == "" || c.Rev != tokenRev(c.Box, rev) {
		return uploadToken{}, false
	}
	return uploadToken{tenant: c.Tenant, box: c.Box, member: c.Member, expires: time.Unix(0, c.Expires)}, true
}

// uploadTokenOf resolves tok: the per-process map first, then the
// signature. reason is "" when tok is known and live, else unknown_token
// or expired_token (CLE-77795 log codes).
func (s *Server) uploadTokenOf(tok string) (uploadToken, string) {
	s.mu.Lock()
	t, ok := s.tokens[tok]
	s.mu.Unlock()
	if !ok {
		t, ok = openUploadToken(s.o.UploadTokenKey, s.o.Revision, tok)
	}
	if !ok {
		return uploadToken{}, "unknown_token"
	}
	if s.o.Now().After(t.expires) {
		return uploadToken{}, "expired_token"
	}
	return t, ""
}
