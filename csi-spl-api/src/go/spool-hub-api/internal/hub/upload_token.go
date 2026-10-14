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
// Only a WUI socket's token is signed. A box token stays in the map on
// purpose: the box's session probe (hubclient Probe, redeploy_test.go)
// reads a 401 door on its token as "my socket sits on a process that no
// longer serves REST" and redials; a token every process accepted would
// hide a redeploy strand. The WUI notices a retired revision through
// /v1/wui/revision instead, and only retries the upload on a door.

// uploadClaims is a signed upload token's payload.
type uploadClaims struct {
	Tenant  string `json:"t"`
	Box     string `json:"b"`
	Member  string `json:"m,omitempty"`
	Expires int64  `json:"e"` // unix nanoseconds
}

// signUploadToken returns the signed token for t.
func signUploadToken(key []byte, t uploadToken) string {
	raw, _ := json.Marshal(uploadClaims{Tenant: t.tenant, Box: t.box, Member: t.member, Expires: t.expires.UnixNano()}) //nolint:errchkjson // strings and an int
	payload := base64.RawURLEncoding.EncodeToString(raw)
	m := hmac.New(sha256.New, key)
	m.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// openUploadToken verifies the MAC before it decodes anything.
func openUploadToken(key []byte, tok string) (uploadToken, bool) {
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
	if err != nil || json.Unmarshal(raw, &c) != nil || c.Tenant == "" || c.Box != WUIBox {
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
		t, ok = openUploadToken(s.o.UploadTokenKey, tok)
	}
	if !ok {
		return uploadToken{}, "unknown_token"
	}
	if s.o.Now().After(t.expires) {
		return uploadToken{}, "expired_token"
	}
	return t, ""
}
