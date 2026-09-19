// Package fakeidp is a local stand-in for Google, Facebook and the generic OIDC
// providers (Microsoft, LinkedIn, xAI), serving the exact paths internal/auth
// calls (auth.Google*Path, auth.Facebook*Path, auth.OIDC*Path(p)). Point
// the hub at it with SPOOL_HUB_AUTH_IDP_BASE_URL (refused in prd). It checks
// what the real providers check: client id + secret, the registered redirect
// URI, a single-use code, the bearer token, Facebook's appsecret_proof.
//
// Every person has a picture (010 T044): userinfo / Graph me name
// <this origin>/avatar/<subject>.png, a small generated PNG, so the hub's
// server-side avatar fetch runs in lde and tests. Person.NoPicture drops it.
//
// The consent screen is skipped: the authorize endpoint redirects straight back
// with a code (or with error=access_denied after Set(p, true)).
package fakeidp

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// Client is one registered app at the fake provider.
type Client struct {
	ID, Secret, RedirectURI string
	// NoEmailVerifiedClaim mimics a provider whose userinfo has no
	// email_verified claim at all (Microsoft).
	NoEmailVerifiedClaim bool
}

// Person is who "signs in".
type Person struct {
	Subject       string
	Email         string
	EmailVerified bool
	Name          string
	NoPicture     bool // userinfo / Graph me carry no picture
}

// AvatarPath is where the fake serves a person's picture.
const AvatarPath = "/avatar/"

// Avatar is the PNG the fake serves for subject: 32x32, one colour from the
// subject's sha256, so each person's file_id differs and is stable.
func Avatar(subject string) []byte {
	sum := sha256.Sum256([]byte(subject))
	img := image.NewRGBA(image.Rect(0, 0, 32, 32))
	c := color.RGBA{sum[0], sum[1], sum[2], 0xff}
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			img.Set(x, y, c)
		}
	}
	var b bytes.Buffer
	png.Encode(&b, img) //nolint:errcheck
	return b.Bytes()
}

// pictureURL is the picture on the origin the caller reached the fake at.
func pictureURL(r *http.Request, p Person) string {
	if p.NoPicture {
		return ""
	}
	return "http://" + r.Host + AvatarPath + url.PathEscape(p.Subject) + ".png"
}

// IdP is the fake. Google/Facebook are fixed at New; change who signs in, or
// whether they deny consent, with Set between flows.
type IdP struct {
	Google, Facebook Client
	oidc             map[string]Client // generic OIDC provider slug -> app

	mu     sync.Mutex
	person Person
	deny   bool
	codes  map[string]string // code -> provider
	tokens map[string]string // access token -> provider
	n      int
}

// New returns a fake that knows the two client registrations.
func New(google, facebook Client, p Person) *IdP {
	return &IdP{Google: google, Facebook: facebook, person: p, oidc: map[string]Client{},
		codes: map[string]string{}, tokens: map[string]string{}}
}

// AddOIDC registers an app for a generic OIDC provider (microsoft, linkedin,
// xai) before Handler is called.
func (f *IdP) AddOIDC(provider string, c Client) *IdP {
	f.oidc[provider] = c
	return f
}

// Set changes the signing-in person and the consent answer for later flows.
func (f *IdP) Set(p Person, deny bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.person, f.deny = p, deny
}

func (f *IdP) current() (Person, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.person, f.deny
}

func (f *IdP) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET "+AvatarPath+"{file}", func(w http.ResponseWriter, r *http.Request) {
		sub, ok := strings.CutSuffix(r.PathValue("file"), ".png")
		if !ok || sub == "" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Write(Avatar(sub)) //nolint:errcheck
	})
	mux.HandleFunc("GET "+auth.GoogleAuthPath, func(w http.ResponseWriter, r *http.Request) {
		f.authorize(w, r, auth.ProviderGoogle, f.Google)
	})
	mux.HandleFunc("GET "+auth.FacebookDialogPath, func(w http.ResponseWriter, r *http.Request) {
		f.authorize(w, r, auth.ProviderFacebook, f.Facebook)
	})
	mux.HandleFunc("POST "+auth.GoogleTokenPath, func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm() //nolint:errcheck
		f.token(w, auth.ProviderGoogle, f.Google, r.PostForm)
	})
	mux.HandleFunc("GET "+auth.FacebookTokenPath, func(w http.ResponseWriter, r *http.Request) {
		f.token(w, auth.ProviderFacebook, f.Facebook, r.URL.Query())
	})
	mux.HandleFunc("GET "+auth.GoogleUserinfoPath, func(w http.ResponseWriter, r *http.Request) {
		tok := ""
		if h := r.Header.Get("Authorization"); len(h) > 7 && h[:7] == "Bearer " {
			tok = h[7:]
		}
		if !f.validToken(tok, auth.ProviderGoogle) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid_token"})
			return
		}
		p, _ := f.current()
		body := map[string]any{"sub": p.Subject, "email": p.Email,
			"email_verified": p.EmailVerified, "name": p.Name}
		if u := pictureURL(r, p); u != "" {
			body["picture"] = u
		}
		writeJSON(w, http.StatusOK, body)
	})
	mux.HandleFunc("GET "+auth.FacebookMePath, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		tok := q.Get("access_token")
		m := hmac.New(sha256.New, []byte(f.Facebook.Secret))
		m.Write([]byte(tok))
		if !f.validToken(tok, auth.ProviderFacebook) || q.Get("appsecret_proof") != hex.EncodeToString(m.Sum(nil)) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"message": "bad token or proof"}})
			return
		}
		p, _ := f.current()
		body := map[string]any{"id": p.Subject, "name": p.Name}
		if p.EmailVerified && p.Email != "" { // Graph omits unconfirmed email
			body["email"] = p.Email
		}
		if u := pictureURL(r, p); u != "" && strings.Contains(q.Get("fields"), "picture") {
			body["picture"] = map[string]any{"data": map[string]any{"url": u, "is_silhouette": false}}
		}
		writeJSON(w, http.StatusOK, body)
	})
	for prov, c := range f.oidc {
		prov, c := prov, c
		mux.HandleFunc("GET "+auth.OIDCAuthPath(prov), func(w http.ResponseWriter, r *http.Request) {
			f.authorize(w, r, prov, c)
		})
		mux.HandleFunc("POST "+auth.OIDCTokenPath(prov), func(w http.ResponseWriter, r *http.Request) {
			r.ParseForm() //nolint:errcheck
			f.token(w, prov, c, r.PostForm)
		})
		mux.HandleFunc("GET "+auth.OIDCUserinfoPath(prov), func(w http.ResponseWriter, r *http.Request) {
			tok := ""
			if h := r.Header.Get("Authorization"); len(h) > 7 && h[:7] == "Bearer " {
				tok = h[7:]
			}
			if !f.validToken(tok, prov) {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid_token"})
				return
			}
			p, _ := f.current()
			body := map[string]any{"sub": p.Subject, "email": p.Email, "name": p.Name}
			if u := pictureURL(r, p); u != "" {
				body["picture"] = u
			}
			if !c.NoEmailVerifiedClaim {
				body["email_verified"] = p.EmailVerified
			}
			writeJSON(w, http.StatusOK, body)
		})
	}
	return mux
}

func (f *IdP) authorize(w http.ResponseWriter, r *http.Request, prov string, c Client) {
	q := r.URL.Query()
	if q.Get("client_id") != c.ID || q.Get("redirect_uri") != c.RedirectURI {
		http.Error(w, "redirect_uri_mismatch or unknown client", http.StatusBadRequest)
		return
	}
	back := url.Values{"state": {q.Get("state")}}
	if _, deny := f.current(); deny {
		back.Set("error", "access_denied")
	} else {
		back.Set("code", f.mint(f.codes, prov, "code"))
	}
	http.Redirect(w, r, c.RedirectURI+"?"+back.Encode(), http.StatusFound)
}

func (f *IdP) token(w http.ResponseWriter, prov string, c Client, v url.Values) {
	f.mu.Lock()
	owner, ok := f.codes[v.Get("code")]
	delete(f.codes, v.Get("code")) // single use
	f.mu.Unlock()
	if !ok || owner != prov || v.Get("client_id") != c.ID || v.Get("client_secret") != c.Secret ||
		v.Get("redirect_uri") != c.RedirectURI {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_grant"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"access_token": f.mint(f.tokens, prov, "at"),
		"token_type": "Bearer", "expires_in": 3600})
}

func (f *IdP) mint(m map[string]string, prov, kind string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.n++
	v := fmt.Sprintf("%s-%s-%d", prov, kind, f.n)
	m[v] = prov
	return v
}

func (f *IdP) validToken(tok, prov string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return tok != "" && f.tokens[tok] == prov
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}
