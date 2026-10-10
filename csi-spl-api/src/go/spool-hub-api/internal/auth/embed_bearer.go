package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
)

// The embed visitor's token (specs/121 4.1, T104): 256 random bits the hub
// hands the iframe once, which keeps it in its own localStorage and sends it
// as Authorization: Bearer on every visitor call. Never a cookie: a cookie
// set in a third-party iframe meets every browser's third-party-cookie rule,
// and a cookie would ride along on a member route the bearer never reaches.
// The hub stores only the token's sha256 (embed_visitors.token_hash).

// embedTokenBytes is the token's size: 256 bits.
const embedTokenBytes = 32

// ErrNoEmbedBearer: the request carries no well-formed visitor token.
var ErrNoEmbedBearer = errors.New("auth: no embed visitor bearer token")

// NewEmbedToken mints a visitor token: the string the visitor holds
// (unpadded base64url of 32 random bytes) and the sha256 the hub stores.
func NewEmbedToken() (token string, hash []byte, err error) {
	raw := make([]byte, embedTokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(raw)
	return base64.RawURLEncoding.EncodeToString(raw), sum[:], nil
}

// EmbedBearer is the stored hash of the visitor token r carries in its
// Authorization header, read from that header ONLY (no cookie, no query
// string, which would land in access logs). ErrNoEmbedBearer when the header
// is absent, not a Bearer, or not 32 bytes of unpadded base64url.
func EmbedBearer(r *http.Request) ([]byte, error) {
	scheme, tok, ok := strings.Cut(r.Header.Get("Authorization"), " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return nil, ErrNoEmbedBearer
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(tok))
	if err != nil || len(raw) != embedTokenBytes {
		return nil, ErrNoEmbedBearer
	}
	sum := sha256.Sum256(raw)
	return sum[:], nil
}
