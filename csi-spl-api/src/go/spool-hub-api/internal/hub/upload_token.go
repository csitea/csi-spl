package hub

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
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
//
// SPL-3262: a role=cli session's token is good on every revision. Such a
// session (`spool doctree`, the one-shot doc verbs) holds no socket for the
// probe to strand, and its REST goes to either revision while a deploy
// rolls: on prd 2026-10-24 the old revision 00934 still answered for 12 min
// after 00937 started (11:00:27Z..11:12:30Z), and a desk's repo-tree edit
// got 401 on 2 of 2 tries (cli_token_revision_test.go).

// uploadClaims is a signed upload token's payload.
type uploadClaims struct {
	Tenant  string `json:"t"`
	Box     string `json:"b"`
	Member  string `json:"m,omitempty"`
	Expires int64  `json:"e"`           // unix nanoseconds
	Rev     string `json:"r,omitempty"` // a box token's revision; "" on a WUI token
	AnyRev  bool   `json:"a,omitempty"` // a role=cli session's token: no revision (SPL-3262)
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
	return signClaims(key, uploadClaims{Tenant: t.tenant, Box: t.box, Member: t.member, Expires: t.expires.UnixNano(), Rev: tokenRev(t.box, rev)})
}

// signClaims is the signed token of c.
func signClaims(key []byte, c uploadClaims) string {
	raw, _ := json.Marshal(c) //nolint:errchkjson // strings, a bool and an int
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
	if err != nil || json.Unmarshal(raw, &c) != nil || c.Tenant == "" || c.Box == "" {
		return uploadToken{}, false
	}
	want := tokenRev(c.Box, rev)
	if c.AnyRev {
		want = ""
	}
	if c.Rev != want {
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

// sessionToken answers x's upload token. A role=box session's comes from
// slotToken, bound to this revision (SPL-1826); a role=cli session's is
// signed for any revision (SPL-3262), from the same slot, minted again in
// the second half of its life. Without a key both use the per-process map.
func (s *Server) sessionToken(x *session) (string, time.Time) {
	if x.role != wire.RoleCLI || len(s.o.UploadTokenKey) == 0 {
		return s.slotToken(&x.upload, x.tenant, x.box, "")
	}
	slot := &x.upload
	slot.mu.Lock()
	defer slot.mu.Unlock()
	if slot.tok != "" && slot.exp.Sub(s.o.Now()) > s.o.UploadTokenTTL/2 {
		return slot.tok, slot.exp
	}
	slot.exp = s.o.Now().Add(s.o.UploadTokenTTL)
	slot.tok = signClaims(s.o.UploadTokenKey, uploadClaims{Tenant: x.tenant, Box: x.box, Expires: slot.exp.UnixNano(), AnyRev: true})
	return slot.tok, slot.exp
}
