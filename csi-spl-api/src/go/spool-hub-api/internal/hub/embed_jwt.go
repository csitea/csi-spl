package hub

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net/http"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The signed-in customer of an embed (specs/121 section 5, R3; T205). The
// customer's server signs a short JWT for its own signed-in user with the
// per-embed ES256 key the workspace owner made (T203: the hub keeps only the
// public half); the iframe hands it to
//
//	POST /v1/embed/{embed_id}/signin   {"jwt": "<compact JWS>"}
//
// and gets the same visitor token as an anonymous mint, but for (embed,
// sub)'s ONE channel_guest (store.SignInEmbedVisitor): the same user on any
// device finds the same channel. The JWT travels in the body, never in a
// query string (a URL lands in logs and Referer). Refused 401 embed_jwt: a
// JWT that is not ES256, not signed by the embed's current key, expired, not
// yet valid, alive longer than 5 minutes, not for this embed (aud), without
// a sub, or already used once (replay). Every refusal writes nothing but the
// replay mark. A banned address is refused 403 embed_banned, and one past
// its sign-ins of the hour or the day 429 embed_visitors, before the JWT is
// read (embedSignInGate, T105's bans and limits). Off (404, as an unknown path) while cnf env.hub.embed.enabled
// is off, and for an embed that is unknown, disabled or has no key.

const (
	// CodeEmbedJWT: the sign-in JWT is refused (401).
	CodeEmbedJWT = "embed_jwt"
	// embedJWTMaxLife is the longest exp - iat accepted (spec 5: 5 min).
	embedJWTMaxLife = 5 * time.Minute
	// embedJWTSkew is the clock skew allowed against exp, iat and nbf.
	embedJWTSkew = 30 * time.Second
	// embedJWTMaxBytes caps the compact JWT; embedSubMax caps sub.
	embedJWTMaxBytes = 4096
	embedSubMax      = 255
	// quotaEmbedJWT is the quota_counts kind of the replay mark: one row
	// per accepted JWT, window = its exp, limit 1 (rdb 0127, spec 6).
	quotaEmbedJWT = "embed_jwt"
)

// errEmbedJWT* say why a JWT is refused; the reason is the 401's detail.
var (
	errEmbedJWTForm    = errors.New("not a compact ES256 JWT")
	errEmbedJWTSig     = errors.New("not signed by this embed's key")
	errEmbedJWTExpired = errors.New("expired")
	errEmbedJWTEarly   = errors.New("not valid yet")
	errEmbedJWTLife    = errors.New("lives longer than 5 minutes (exp - iat)")
	errEmbedJWTAud     = errors.New("not for this embed (aud)")
	errEmbedJWTSub     = errors.New("no usable sub")
	errEmbedJWTReplay  = errors.New("already used")
)

func (s *Server) routeEmbedSignIn(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/embed/{embed_id}/signin", s.handleEmbedSignIn)
}

// embedClaims are the registered claims T205 reads; others are ignored.
type embedClaims struct {
	Sub string          `json:"sub"`
	Aud json.RawMessage `json:"aud"`
	Exp *json.Number    `json:"exp"`
	Iat *json.Number    `json:"iat"`
	Nbf *json.Number    `json:"nbf"`
}

// embedJWT is a verified sign-in JWT: its sub, its expiry and the digest of
// its signed part (the replay key).
type embedJWT struct {
	Sub    string
	Exp    time.Time
	Digest string
}

func b64(s string) ([]byte, error) { return base64.RawURLEncoding.DecodeString(s) }

// embedPublicKey parses the stored PEM public half as a P-256 key.
func embedPublicKey(pemKey string) (*ecdsa.PublicKey, error) {
	blk, _ := pem.Decode([]byte(pemKey))
	if blk == nil {
		return nil, errors.New("embed key: no PEM block")
	}
	k, err := x509.ParsePKIXPublicKey(blk.Bytes)
	if err != nil {
		return nil, err
	}
	pub, ok := k.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, errors.New("embed key: not a P-256 key")
	}
	return pub, nil
}

// verifyEmbedJWT checks raw against the embed's public key (and key id, when
// the header names one), its embed id and now. The header must say ES256
// exactly: "none", HS256 and the rest are refused before any key is used.
func verifyEmbedJWT(raw string, pub *ecdsa.PublicKey, keyID, embedID string, now time.Time) (embedJWT, error) {
	parts := strings.Split(raw, ".")
	if len(raw) > embedJWTMaxBytes || len(parts) != 3 {
		return embedJWT{}, errEmbedJWTForm
	}
	var hdr struct {
		Alg  string          `json:"alg"`
		Kid  *string         `json:"kid"`
		Crit json.RawMessage `json:"crit"`
	}
	hb, err := b64(parts[0])
	if err != nil || json.Unmarshal(hb, &hdr) != nil || hdr.Alg != embedKeyAlg || hdr.Crit != nil {
		return embedJWT{}, errEmbedJWTForm
	}
	sig, err := b64(parts[2])
	if err != nil || len(sig) != 64 {
		return embedJWT{}, errEmbedJWTForm
	}
	if hdr.Kid != nil && *hdr.Kid != keyID {
		return embedJWT{}, errEmbedJWTSig
	}
	signed := parts[0] + "." + parts[1]
	sum := sha256.Sum256([]byte(signed))
	if !ecdsa.Verify(pub, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return embedJWT{}, errEmbedJWTSig
	}
	c, err := embedJWTClaims(parts[1])
	if err != nil {
		return embedJWT{}, err
	}
	exp, err := checkEmbedJWTTimes(c, now)
	if err != nil {
		return embedJWT{}, err
	}
	if !audHas(c.Aud, embedID) {
		return embedJWT{}, errEmbedJWTAud
	}
	if !usableSub(c.Sub) {
		return embedJWT{}, errEmbedJWTSub
	}
	// The digest is of the signed part, not the signature: an ECDSA
	// signature has a second valid form (s -> n-s), the claims have one.
	return embedJWT{Sub: c.Sub, Exp: exp, Digest: hex.EncodeToString(sum[:])}, nil
}

func embedJWTClaims(part string) (embedClaims, error) {
	var c embedClaims
	pb, err := b64(part)
	if err != nil {
		return c, errEmbedJWTForm
	}
	d := json.NewDecoder(bytes.NewReader(pb))
	d.UseNumber()
	if d.Decode(&c) != nil {
		return c, errEmbedJWTForm
	}
	return c, nil
}

// checkEmbedJWTTimes: exp and iat are required, exp is not past, iat and nbf
// are not ahead (each within embedJWTSkew), and exp - iat <= 5 minutes.
func checkEmbedJWTTimes(c embedClaims, now time.Time) (time.Time, error) {
	exp, okE := unixClaim(c.Exp)
	iat, okI := unixClaim(c.Iat)
	if !okE || !okI {
		return time.Time{}, errEmbedJWTForm
	}
	switch {
	case !now.Before(exp.Add(embedJWTSkew)):
		return time.Time{}, errEmbedJWTExpired
	case iat.After(now.Add(embedJWTSkew)):
		return time.Time{}, errEmbedJWTEarly
	case exp.Sub(iat) > embedJWTMaxLife:
		return time.Time{}, errEmbedJWTLife
	}
	if c.Nbf != nil {
		nbf, ok := unixClaim(c.Nbf)
		if !ok {
			return time.Time{}, errEmbedJWTForm
		}
		if nbf.After(now.Add(embedJWTSkew)) {
			return time.Time{}, errEmbedJWTEarly
		}
	}
	return exp, nil
}

// unixClaim reads a NumericDate (whole seconds; a fraction is dropped).
func unixClaim(n *json.Number) (time.Time, bool) {
	if n == nil {
		return time.Time{}, false
	}
	f, err := n.Float64()
	if err != nil || f < 0 || f > 1e11 {
		return time.Time{}, false
	}
	return time.Unix(int64(f), 0).UTC(), true
}

// audHas: aud is the embed id, or an array holding it (RFC 7519 4.1.3).
func audHas(raw json.RawMessage, embedID string) bool {
	var one string
	if json.Unmarshal(raw, &one) == nil {
		return one == embedID
	}
	var many []string
	if json.Unmarshal(raw, &many) != nil {
		return false
	}
	for _, a := range many {
		if a == embedID {
			return true
		}
	}
	return false
}

// usableSub: 1..255 bytes of valid UTF-8, no control character.
func usableSub(sub string) bool {
	if sub == "" || len(sub) > embedSubMax || !utf8.ValidString(sub) {
		return false
	}
	return strings.IndexFunc(sub, unicode.IsControl) < 0
}

// embedSignInTarget is the URL's embed when it can take a signed-in user
// (enabled, with a key), with the stores the sign-in needs; nil after a 404
// (as an unknown path) or a 500.
func (s *Server) embedSignInTarget(w http.ResponseWriter, r *http.Request) (*store.EmbedCustomer, store.EmbedSignIn, store.QuotaCounter) {
	es := s.embedStore(w, r)
	if es == nil {
		return nil, nil, nil
	}
	si, okS := s.o.Store.(store.EmbedSignIn)
	qc, okQ := s.o.Store.(store.QuotaCounter)
	if !okS || !okQ {
		http.NotFound(w, r)
		return nil, nil, nil
	}
	ec, err := es.EmbedCustomer(r.Context(), r.PathValue("embed_id"))
	switch {
	case err != nil && !errors.Is(err, store.ErrNotFound):
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed not read", err)
		return nil, nil, nil
	case err != nil || !ec.Enabled || ec.JWTPublicKey == "":
		http.NotFound(w, r)
		return nil, nil, nil
	}
	return &ec, si, qc
}

// handleEmbedSignIn verifies the customer's JWT, marks it used, then signs
// (embed, sub)'s visitor in with a fresh token: in this response only.
func (s *Server) handleEmbedSignIn(w http.ResponseWriter, r *http.Request) {
	ec, si, qc := s.embedSignInTarget(w, r)
	if ec == nil {
		return
	}
	var in struct {
		JWT string `json:"jwt"`
	}
	if !readJSONStrict(w, r, &in, embedJWTMaxBytes+256, "invalid JSON body (only jwt)") {
		return
	}
	if !s.embedSignInGate(w, r, ec.TenantID) {
		return
	}
	refuse := func(why error) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="embed", error="invalid_token"`)
		writeErr(w, http.StatusUnauthorized, CodeEmbedJWT, "sign-in JWT refused: "+why.Error())
	}
	pub, err := embedPublicKey(ec.JWTPublicKey)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed key unreadable", err)
		return
	}
	now := s.o.Now().UTC()
	tok, err := verifyEmbedJWT(in.JWT, pub, ec.JWTKeyID, ec.EmbedID, now)
	if err != nil {
		refuse(err)
		return
	}
	_, fresh, err := qc.TakeQuota(r.Context(), ec.TenantID, "jwt:"+tok.Digest, quotaEmbedJWT, tok.Exp, 1)
	switch {
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "replay mark not stored", err)
		return
	case !fresh:
		refuse(errEmbedJWTReplay)
		return
	}
	s.signInEmbedVisitor(w, r, si, ec, tok.Sub, now)
}

func (s *Server) signInEmbedVisitor(w http.ResponseWriter, r *http.Request, si store.EmbedSignIn, ec *store.EmbedCustomer, sub string, now time.Time) {
	bearer, hash, err := auth.NewEmbedToken()
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "token not minted", err)
		return
	}
	v, err := si.SignInEmbedVisitor(r.Context(), store.EmbedVisitorMint{TenantID: ec.TenantID, EmbedID: ec.EmbedID,
		TokenHash: hash, Life: s.embedLife()}, sub, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		http.NotFound(w, r)
		return
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "visitor not signed in", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": bearer, "visitor_id": v.VisitorID,
		"channel": v.ChannelID, "expires_at": rfc(v.ExpiresAt)})
}
