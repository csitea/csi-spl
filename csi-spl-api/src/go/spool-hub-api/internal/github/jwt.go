package github

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
)

// errBadKey never quotes the key: a PEM that fails to parse is still a key.
var errBadKey = errors.New("github: the App key is not a PEM RSA private key")

// parseKey reads the PEM GitHub generates (PKCS#1) or a PKCS#8 one.
func parseKey(pemBytes []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errBadKey
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errBadKey
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		return nil, errBadKey
	}
	return rk, nil
}

// appJWT signs the App's RS256 JWT: issued 60 s in the past (GitHub's clock
// skew advice), valid 9 min (GitHub's maximum is 10).
func (c *Client) appJWT() (string, error) {
	now := c.now().Unix()
	head, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{"iat": now - 60, "exp": now + 9*60, "iss": c.appID})
	enc := base64.RawURLEncoding
	signing := enc.EncodeToString(head) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", fmt.Errorf("github: sign the App JWT: %w", err)
	}
	return signing + "." + enc.EncodeToString(sig), nil
}
