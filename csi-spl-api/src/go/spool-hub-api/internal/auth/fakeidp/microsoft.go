package fakeidp

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// MicrosoftKid is the kid of the fake's signing key in its JWKS.
const MicrosoftKid = "fake-ms-1"

// MicrosoftTamper corrupts the next id_tokens the fake issues (spec 018
// SC-002): edit the claims or the JOSE header, or break the signature.
type MicrosoftTamper struct {
	Claims       func(map[string]any)
	Header       func(map[string]any)
	BadSignature bool
}

type msFlow struct {
	nonce, challenge, tenant string
}

// AddMicrosoft registers the Microsoft app before Handler is called.
func (f *IdP) AddMicrosoft(c Client) *IdP {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	f.ms, f.msKey, f.msFlows = &c, key, map[string]msFlow{}
	return f
}

// SetMicrosoftTamper applies t to every later id_token (zero value = honest).
func (f *IdP) SetMicrosoftTamper(t MicrosoftTamper) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.msTamper = t
}

// MicrosoftJWKSFetches counts the JWKS requests served.
func (f *IdP) MicrosoftJWKSFetches() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.msJWKS
}

// MicrosoftOID is the GUID-shaped oid the fake gives subject.
func MicrosoftOID(subject string) string {
	s := sha256.Sum256([]byte(subject))
	return fmt.Sprintf("%x-%x-%x-%x-%x", s[0:4], s[4:6], s[6:8], s[8:10], s[10:16])
}

// MicrosoftTenantOf is the tid the fake puts in p's id_token.
func MicrosoftTenantOf(p Person) string {
	if p.MicrosoftTenantID != "" {
		return p.MicrosoftTenantID
	}
	return auth.MicrosoftConsumersTenantID
}

func (f *IdP) microsoftRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /{tenant}/oauth2/v2.0/authorize", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("client_id") != f.ms.ID || q.Get("redirect_uri") != f.ms.RedirectURI {
			http.Error(w, "AADSTS50011 redirect_uri_mismatch or unknown client", http.StatusBadRequest)
			return
		}
		if q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") == "" {
			http.Error(w, "AADSTS9002325 PKCE S256 required", http.StatusBadRequest)
			return
		}
		back := url.Values{"state": {q.Get("state")}}
		if _, deny := f.current(); deny {
			back.Set("error", "access_denied")
		} else {
			code := f.mint(f.codes, auth.ProviderMicrosoft, "code")
			f.mu.Lock()
			f.msFlows[code] = msFlow{nonce: q.Get("nonce"), challenge: q.Get("code_challenge"), tenant: r.PathValue("tenant")}
			f.mu.Unlock()
			back.Set("code", code)
		}
		http.Redirect(w, r, f.ms.RedirectURI+"?"+back.Encode(), http.StatusFound)
	})
	mux.HandleFunc("POST /{tenant}/oauth2/v2.0/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm() //nolint:errcheck
		v := r.PostForm
		f.mu.Lock()
		owner, ok := f.codes[v.Get("code")]
		flow := f.msFlows[v.Get("code")]
		delete(f.codes, v.Get("code")) // single use
		delete(f.msFlows, v.Get("code"))
		tamper := f.msTamper
		f.mu.Unlock()
		if !ok || owner != auth.ProviderMicrosoft || flow.tenant != r.PathValue("tenant") ||
			v.Get("client_id") != f.ms.ID || v.Get("client_secret") != f.ms.Secret || v.Get("redirect_uri") != f.ms.RedirectURI {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_grant", "error_codes": []int{70008}})
			return
		}
		if auth.PKCEChallenge(v.Get("code_verifier")) != flow.challenge {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_grant", "error_codes": []int{501481}})
			return
		}
		p, _ := f.current()
		tid := MicrosoftTenantOf(p)
		now := time.Now()
		claims := map[string]any{"ver": "2.0", "iss": "http://" + r.Host + "/" + tid + "/v2.0", "aud": f.ms.ID,
			"exp": now.Add(time.Hour).Unix(), "iat": now.Unix(), "nbf": now.Unix(), "nonce": flow.nonce,
			"tid": tid, "oid": MicrosoftOID(p.Subject), "sub": "pairwise-" + p.Subject, "name": p.Name,
			"preferred_username": p.Email}
		if p.Email != "" {
			claims["email"] = p.Email
		}
		if p.EmailDomainVerified {
			claims["xms_edov"] = true
		}
		header := map[string]any{"alg": "RS256", "typ": "JWT", "kid": MicrosoftKid}
		if tamper.Claims != nil {
			tamper.Claims(claims)
		}
		if tamper.Header != nil {
			tamper.Header(header)
		}
		writeJSON(w, http.StatusOK, map[string]any{"token_type": "Bearer", "expires_in": 3600,
			"access_token": f.mint(f.tokens, auth.ProviderMicrosoft, "at"),
			"id_token":     f.signRS256(header, claims, tamper.BadSignature)})
	})
	mux.HandleFunc("GET /{tenant}/discovery/v2.0/keys", func(w http.ResponseWriter, _ *http.Request) {
		f.mu.Lock()
		f.msJWKS++
		f.mu.Unlock()
		pub := f.msKey.PublicKey
		writeJSON(w, http.StatusOK, map[string]any{"keys": []map[string]string{{
			"kty": "RSA", "use": "sig", "kid": MicrosoftKid,
			"n": base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
		}}})
	})
}

func (f *IdP) signRS256(header, claims map[string]any, bad bool) string {
	h, _ := json.Marshal(header)
	c, _ := json.Marshal(claims)
	in := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(c)
	sum := sha256.Sum256([]byte(in))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.msKey, crypto.SHA256, sum[:])
	if err != nil {
		panic(err)
	}
	if bad {
		sig[len(sig)-1] ^= 0x01
	}
	return in + "." + base64.RawURLEncoding.EncodeToString(sig)
}
