package hub

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The embed admin API (specs/121 T203, spec section 5): the workspace owner
// lists the workspace's embeds, creates one, sets its allowed_origins (they
// become its frame-ancestors, T201) and its switch, and makes its per-embed
// JWT key. The hub makes the key pair, stores only the PUBLIC half and
// returns the private half in that one response: it is never stored, logged
// or shown again (a lost key is replaced by making a new one, which revokes
// the old). Owner only: any other member gets 403. Behind cnf
// env.hub.embed.enabled: while it is off every route is 404 to the owner.
//
// The key is ES256 (P-256, PKCS#8 PEM): the customer's server signs a short
// JWT with it (T205), and every common JWT library speaks ES256.

// permTenantOwner names the gate in a 403 body; it is not an rbac permission.
const permTenantOwner = "tenant.owner"

// embedKeyAlg is the JWT alg the per-embed key signs with.
const embedKeyAlg = "ES256"

// embedMaxOrigins is rdb 0169's cardinality check, refused before the store.
const embedMaxOrigins = 32

// embedIDPattern is rdb 0169's embed_id check.
var embedIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{2,63}$`)

// embedBody is one embed as the admin API shows it: the public key only.
type embedBody struct {
	EmbedID        string    `json:"embed_id"`
	AllowedOrigins []string  `json:"allowed_origins"`
	Enabled        bool      `json:"enabled"`
	KeyID          string    `json:"key_id"`
	PublicKey      string    `json:"public_key"`
	KeyAlg         string    `json:"key_alg"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// embedKeyBody is the key route's one answer: the only body that ever
// carries the private key.
type embedKeyBody struct {
	embedBody
	PrivateKey string `json:"private_key"`
}

func toEmbedBody(e store.EmbedCustomer) embedBody {
	b := embedBody{EmbedID: e.EmbedID, AllowedOrigins: e.AllowedOrigins, Enabled: e.Enabled,
		KeyID: e.JWTKeyID, PublicKey: e.JWTPublicKey, CreatedAt: e.CreatedAt, UpdatedAt: e.UpdatedAt}
	if b.AllowedOrigins == nil {
		b.AllowedOrigins = []string{}
	}
	if b.PublicKey != "" {
		b.KeyAlg = embedKeyAlg
	}
	return b
}

// embedAdminActor resolves the caller: the member session, 403 unless the
// caller is the workspace owner (first, so a demo or member session is
// refused before anything is read: TestDemoRouteWalk), then 404 while the
// flag is off.
func (s *Server) embedAdminActor(w http.ResponseWriter, r *http.Request) (store.EmbedAdmin, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return nil, "", false
	}
	if hum == "" {
		writeForbidden(w, permTenantOwner, "the embed admin API needs a member session")
		return nil, "", false
	}
	if a, err := s.access(r.Context(), hum, t.ID); err != nil || !a.TenantOwner {
		writeForbidden(w, permTenantOwner, "only the workspace owner manages its embeds")
		return nil, "", false
	}
	if !s.o.EmbedEnabled {
		writeErr(w, http.StatusNotFound, "not_found", "the embed is not enabled on this hub")
		return nil, "", false
	}
	ea, ok := s.o.Store.(store.EmbedAdmin)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no embeds")
		return nil, "", false
	}
	return ea, t.ID, true
}

// normalizeOrigins checks each entry is one exact origin, https (http only
// for localhost), no path, query, credentials or wildcard, and returns them
// lower-cased, de-duplicated, in order.
func normalizeOrigins(in []string) ([]string, error) {
	if len(in) > embedMaxOrigins {
		return nil, errors.New("at most 32 allowed_origins")
	}
	out := make([]string, 0, len(in))
	for _, raw := range in {
		o, err := normalizeOrigin(raw)
		if err != nil {
			return nil, err
		}
		if !slices.Contains(out, o) {
			out = append(out, o)
		}
	}
	return out, nil
}

func normalizeOrigin(raw string) (string, error) {
	bad := errors.New("allowed_origins: " + quoteOrigin(raw) + " is not an origin like https://www.example.com")
	u, err := url.Parse(strings.TrimSuffix(strings.TrimSpace(raw), "/"))
	if err != nil || u.User != nil || u.Opaque != "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" ||
		u.Host == "" || strings.ContainsAny(u.Host, "*") || raw != strings.TrimSpace(raw) {
		return "", bad
	}
	host, scheme := strings.ToLower(u.Host), strings.ToLower(u.Scheme)
	local := u.Hostname() == "localhost" || net.ParseIP(u.Hostname()).IsLoopback()
	if scheme != "https" && !(scheme == "http" && local) {
		return "", errors.New("allowed_origins: " + quoteOrigin(raw) + " must be https")
	}
	return scheme + "://" + host, nil
}

// quoteOrigin keeps an origin readable in an error and cuts a long one.
func quoteOrigin(s string) string {
	if len(s) > 80 {
		s = s[:80] + "..."
	}
	return `"` + s + `"`
}

func writeEmbedStoreErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such embed in this workspace")
	case errors.Is(err, store.ErrEmbedExists):
		writeErr(w, http.StatusConflict, "embed_exists", "that embed id is taken")
	case errors.Is(err, store.ErrBadEmbed):
		writeErr(w, http.StatusBadRequest, "bad_embed", "the embed was refused by its checks")
	default:
		writeErr(w, http.StatusInternalServerError, "internal", "embeds unavailable")
	}
}

// GET /v1/tenant/embeds
func (s *Server) handleListEmbeds(w http.ResponseWriter, r *http.Request) {
	ea, tenant, ok := s.embedAdminActor(w, r)
	if !ok {
		return
	}
	list, err := ea.EmbedCustomers(r.Context(), tenant)
	if err != nil {
		writeEmbedStoreErr(w, err)
		return
	}
	out := make([]embedBody, 0, len(list))
	for _, e := range list {
		out = append(out, toEmbedBody(e))
	}
	writeJSON(w, http.StatusOK, map[string]any{"embeds": out})
}

// POST /v1/tenant/embeds {embed_id, allowed_origins}: a new embed, disabled
// and keyless.
func (s *Server) handleCreateEmbed(w http.ResponseWriter, r *http.Request) {
	ea, tenant, ok := s.embedAdminActor(w, r)
	if !ok {
		return
	}
	var body struct {
		EmbedID        string   `json:"embed_id"`
		AllowedOrigins []string `json:"allowed_origins"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if !embedIDPattern.MatchString(body.EmbedID) {
		writeErr(w, http.StatusBadRequest, "bad_embed", "embed_id: 3..64 of a-z, 0-9 and '-', not starting with '-'")
		return
	}
	origins, err := normalizeOrigins(body.AllowedOrigins)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_origin", err.Error())
		return
	}
	e, err := ea.CreateEmbedCustomer(r.Context(), tenant, body.EmbedID, origins)
	if err != nil {
		writeEmbedStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toEmbedBody(e))
}

// PATCH /v1/tenant/embeds/{embed_id} {allowed_origins?, enabled?}
func (s *Server) handlePatchEmbed(w http.ResponseWriter, r *http.Request) {
	ea, tenant, ok := s.embedAdminActor(w, r)
	if !ok {
		return
	}
	var body struct {
		AllowedOrigins *[]string `json:"allowed_origins"`
		Enabled        *bool     `json:"enabled"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if body.AllowedOrigins == nil && body.Enabled == nil {
		writeErr(w, http.StatusBadRequest, "bad_embed", "allowed_origins or enabled is required")
		return
	}
	var origins []string
	if body.AllowedOrigins != nil {
		var err error
		if origins, err = normalizeOrigins(*body.AllowedOrigins); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_origin", err.Error())
			return
		}
	}
	e, err := ea.UpdateEmbedCustomer(r.Context(), tenant, r.PathValue("embed_id"), origins, body.Enabled)
	if err != nil {
		writeEmbedStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toEmbedBody(e))
}

// newEmbedKey makes an ES256 key pair: the public half as a PKIX PEM, the
// private half as a PKCS#8 PEM, and a fresh key id.
func newEmbedKey() (pubPEM, privPEM, keyID string, err error) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", "", err
	}
	pub, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		return "", "", "", err
	}
	priv, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		return "", "", "", err
	}
	id := make([]byte, 8)
	if _, err := rand.Read(id); err != nil {
		return "", "", "", err
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pub})),
		string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: priv})),
		"k-" + hex.EncodeToString(id), nil
}

// POST /v1/tenant/embeds/{embed_id}/key: a new key pair. The public half
// replaces the stored one (a JWT signed with the old key stops verifying);
// the private half is in this response only. No error path carries the key
// or a store error text: nothing here can put it in a log.
func (s *Server) handleNewEmbedKey(w http.ResponseWriter, r *http.Request) {
	ea, tenant, ok := s.embedAdminActor(w, r)
	if !ok {
		return
	}
	pub, priv, kid, err := newEmbedKey()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "could not make a key")
		return
	}
	e, err := ea.SetEmbedKey(r.Context(), tenant, r.PathValue("embed_id"), pub, kid)
	if err != nil {
		writeEmbedStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, embedKeyBody{embedBody: toEmbedBody(e), PrivateKey: priv})
}

func (s *Server) embedAdminPreflight(methods string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.allowOrigin(w, r) {
			h := w.Header()
			h.Set("Access-Control-Allow-Methods", methods)
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
			h.Set("Access-Control-Max-Age", corsMaxAge)
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// routeEmbedAdmin registers the embed admin API.
func (s *Server) routeEmbedAdmin(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/embeds", s.handleListEmbeds)
	mux.HandleFunc("POST /v1/tenant/embeds", s.handleCreateEmbed)
	mux.HandleFunc("PATCH /v1/tenant/embeds/{embed_id}", s.handlePatchEmbed)
	mux.HandleFunc("POST /v1/tenant/embeds/{embed_id}/key", s.handleNewEmbedKey)
	mux.HandleFunc("OPTIONS /v1/tenant/embeds", s.embedAdminPreflight("GET, POST"))
	mux.HandleFunc("OPTIONS /v1/tenant/embeds/{embed_id}", s.embedAdminPreflight("PATCH"))
	mux.HandleFunc("OPTIONS /v1/tenant/embeds/{embed_id}/key", s.embedAdminPreflight("POST"))
}
