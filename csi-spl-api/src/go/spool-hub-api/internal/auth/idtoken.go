package auth

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

// id_token verification (spec 018 FR-003): RS256 only, keys from the
// provider's JWKS. Standard library only: RS256 is PKCS#1 v1.5 over SHA-256.

var (
	errIDToken    = errors.New("auth: id_token rejected")
	errUnknownKid = errors.New("auth: id_token kid not in the JWKS")
)

// Keys under 2048 bits are refused. A JWKS body is capped at 1 MiB by
// readJSON (idp.go), like every IdP answer.
const jwksMinRSABits = 2048

// jwksCache holds one JWKS URL's RSA keys by kid. A known kid is served from
// the cache for ttl; an unknown kid (the provider rolled its keys) triggers a
// refetch, but at most one per minRefetch so forged kids cannot drive a fetch
// storm. A failed refetch keeps serving the keys it already has.
type jwksCache struct {
	url        string
	http       *http.Client
	ttl        time.Duration
	minRefetch time.Duration
	now        func() time.Time

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
	tried   time.Time
}

func newJWKSCache(url string, hc *http.Client, now func() time.Time) *jwksCache {
	if now == nil {
		now = time.Now
	}
	return &jwksCache{url: url, http: hc, ttl: 24 * time.Hour, minRefetch: time.Minute, now: now}
}

func (c *jwksCache) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	k, have := c.keys[kid]
	if have && now.Sub(c.fetched) < c.ttl {
		return k, nil
	}
	if !c.tried.IsZero() && now.Sub(c.tried) < c.minRefetch {
		if have {
			return k, nil
		}
		return nil, errUnknownKid
	}
	c.tried = now
	keys, err := fetchJWKS(ctx, c.http, c.url)
	if err != nil {
		if have {
			return k, nil
		}
		return nil, err
	}
	c.keys, c.fetched = keys, now
	if k, ok := keys[kid]; ok {
		return k, nil
	}
	return nil, errUnknownKid
}

func fetchJWKS(ctx context.Context, hc *http.Client, url string) (map[string]*rsa.PublicKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("jwks: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient(hc).Do(req)
	if err != nil {
		return nil, fmt.Errorf("jwks: %w", err)
	}
	var set struct {
		Keys []struct {
			Kty, Use, Kid, N, E string
		} `json:"keys"`
	}
	if err := readJSON(resp, &set); err != nil || resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks: status %d", resp.StatusCode)
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" || (k.Use != "" && k.Use != "sig") || k.Kid == "" {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil || len(e) == 0 || len(e) > 4 {
			continue
		}
		pub := &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
		if pub.N.BitLen() < jwksMinRSABits || pub.E < 3 {
			continue
		}
		keys[k.Kid] = pub
	}
	if len(keys) == 0 {
		return nil, errors.New("jwks: no usable RSA signing key")
	}
	return keys, nil
}

// verifyRS256 checks a compact JWS signed with RS256 by a key from keys and
// decodes its payload into claims. It checks nothing inside the claims: the
// caller owns iss/aud/exp/nonce.
func verifyRS256(ctx context.Context, keys *jwksCache, token string, claims any) error {
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return fmt.Errorf("%w: not a compact JWS", errIDToken)
	}
	rawHeader, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return fmt.Errorf("%w: header encoding", errIDToken)
	}
	var h struct{ Alg, Kid string }
	if json.Unmarshal(rawHeader, &h) != nil {
		return fmt.Errorf("%w: header json", errIDToken)
	}
	if h.Alg != "RS256" {
		return fmt.Errorf("%w: alg %q", errIDToken, h.Alg)
	}
	if h.Kid == "" {
		return fmt.Errorf("%w: no kid", errIDToken)
	}
	pub, err := keys.key(ctx, h.Kid)
	if err != nil {
		return fmt.Errorf("%w: %w", errIDToken, err)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return fmt.Errorf("%w: signature encoding", errIDToken)
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig) != nil {
		return fmt.Errorf("%w: bad signature", errIDToken)
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(payload, claims) != nil {
		return fmt.Errorf("%w: payload", errIDToken)
	}
	return nil
}
