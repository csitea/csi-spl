package hub

import (
	"errors"
	"net"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Tenant resolution (specs/026 §2): the tenant of a request comes from WHO is
// calling. A human's is the session's active tenant; a box's is the tenant it
// names (TenantHeader), proven by its pin, the tenant root signature or an
// upload token. A Host of the tenant pattern (<tenant>.<fqdn>) is a legacy
// tenant host. It never grants a tenant: a non-member still cannot get in.
// When a credential already proves a tenant, the Host must EQUAL it (403
// tenant_mismatch). When a human session has no live `t`, the Host picks
// among several memberships that human already has. A member of two tenants,
// with a stale `t`, is placed in the tenant the Host names.

// TenantHeader names a box's tenant on the api host (specs/026 §4).
const TenantHeader = "X-Spool-Tenant"

// hostTenantID is the tenant a legacy tenant Host names, "" for the api host
// or any Host outside the pattern (the api labels are reserved tenant ids).
func (s *Server) hostTenantID(r *http.Request) string {
	host := strings.ToLower(r.Host)
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	id, ok := strings.CutSuffix(host, s.suffix)
	if !ok || !msg.ValidTenantID(id) {
		return ""
	}
	return id
}

// loadTenant answers the tenant row or writes 404 unknown_tenant.
func (s *Server) loadTenant(w http.ResponseWriter, r *http.Request, id string) (store.Tenant, bool) {
	t, err := s.o.Store.GetTenant(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no such tenant")
		return store.Tenant{}, false
	}
	if t.Suspended() { // spec 074: the operator workspace suspended (or archived) it
		writeErr(w, http.StatusForbidden, tokenWorkspaceSuspended, "this workspace is suspended by the operator")
		return store.Tenant{}, false
	}
	return t, true
}

// humanTenant resolves a browser request: the tenant and the member HUM-* id,
// or it writes the error. With the view door off (lde) a legacy tenant Host
// still names the tenant for an anonymous read and the human is attribution
// only ("" = anonymous); otherwise the session decides (auth.ActiveTenant).
func (s *Server) humanTenant(w http.ResponseWriter, r *http.Request) (store.Tenant, string, bool) {
	if messageRoute(r) {
		s.openMembersMemo(r.Context()) // perf E07: one role read per message write
	}
	host := s.hostTenantID(r)
	if s.o.ViewDoor == ViewDoorOff && host != "" {
		t, ok := s.loadTenant(w, r, host)
		if !ok {
			return t, "", false
		}
		hum, _ := s.memberID(r, t.ID)
		if !s.permit(w, r, t.ID, hum, rbac.TopicsRead) { // specs/025
			return store.Tenant{}, "", false
		}
		return t, hum, true
	}
	if s.o.Auth == nil {
		writeErr(w, http.StatusUnauthorized, "view_door", "a view token or a member session is required")
		return store.Tenant{}, "", false
	}
	sess, id, err := s.o.Auth.ActiveTenant(r, host)
	switch {
	case errors.Is(err, auth.ErrTenantMismatch):
		writeErr(w, http.StatusForbidden, "tenant_mismatch", "this host belongs to another tenant than the session")
		return store.Tenant{}, "", false
	case err != nil && s.doorDemoExpired(w, r): // specs/077 T009: the demo seat ended
		return store.Tenant{}, "", false
	case errors.Is(err, auth.ErrPageNotMember): // SPL-959: the tenant host's page, not a member
		writeErr(w, http.StatusForbidden, "not_member", "not a member of this tenant")
		return store.Tenant{}, "", false
	case errors.Is(err, auth.ErrTenantRequired):
		writeErr(w, http.StatusConflict, "tenant_required", "the session has several tenants; sign in with ?tenant=<id>")
		return store.Tenant{}, "", false
	case err != nil:
		writeErr(w, http.StatusUnauthorized, "view_door", "a view token or a member session is required")
		return store.Tenant{}, "", false
	}
	t, ok := s.loadTenant(w, r, id)
	if !ok {
		return t, "", false
	}
	hum := sess.HumanID
	if s.o.SessionID != nil { // test seam: the attributed human
		hum, _ = s.o.SessionID(r, t.ID)
	} else {
		// ActiveTenant just proved this session a member of t: memberID
		// answers it for the rest of the request without a second read.
		s.requestMemo(r.Context()).putSession(t.ID, hum)
	}
	if !s.permit(w, r, t.ID, hum, rbac.TopicsRead) { // specs/025: every browser door reads
		return store.Tenant{}, "", false
	}
	return t, hum, true
}

// memberID is the HUM-* of a member session of tenant, "" when none (the
// door-off attribution; SessionID is the test seam).
func (s *Server) memberID(r *http.Request, tenant string) (string, error) {
	if s.o.SessionID != nil {
		return s.o.SessionID(r, tenant)
	}
	mm := s.requestMemo(r.Context())
	if hum := mm.session(tenant); hum != "" {
		return hum, nil
	}
	hum, err := s.sessionFor(r, tenant)
	if err == nil {
		mm.putSession(tenant, hum)
	}
	return hum, err
}

// messageRoute reports a message write (PATCH|DELETE|POST|PUT
// /v1/messages/{msg_id}[/...]): none of them changes a role or a
// membership, so their request may memoise both (perf E07).
func messageRoute(r *http.Request) bool {
	method, path, ok := strings.Cut(r.Pattern, " ")
	return ok && method != http.MethodGet && method != http.MethodOptions &&
		strings.HasPrefix(path, "/v1/messages/{msg_id}")
}

// boxTenant resolves a box request that carries no upload token (the WS
// hello, pin, revoke): the tenant the box names in TenantHeader, else the
// legacy Host's. Both present and different = 403. The caller proves it
// (pin signature, root signature); naming a tenant grants nothing.
func (s *Server) boxTenant(w http.ResponseWriter, r *http.Request) (store.Tenant, bool) {
	host := s.hostTenantID(r)
	named := strings.ToLower(strings.TrimSpace(r.Header.Get(TenantHeader)))
	switch {
	case named != "" && !msg.ValidTenantID(named):
		writeErr(w, http.StatusBadRequest, "bad_tenant", TenantHeader+" is not a tenant id")
		return store.Tenant{}, false
	case named != "" && host != "" && named != host:
		writeErr(w, http.StatusForbidden, "tenant_mismatch", "this host belongs to another tenant than "+TenantHeader)
		return store.Tenant{}, false
	case named == "" && host == "":
		writeErr(w, http.StatusBadRequest, "tenant_required", "name the tenant in "+TenantHeader)
		return store.Tenant{}, false
	case named == "":
		named = host
	}
	return s.loadTenant(w, r, named)
}

// tokenTenant resolves a box REST call by its upload token: the tenant the
// token was minted in, and its box. No token = 401 door; a legacy Host of
// another tenant, or a TenantHeader naming another one = 403.
func (s *Server) tokenTenant(w http.ResponseWriter, r *http.Request) (store.Tenant, string, bool) {
	tenant, box, reason, ok := s.bearerAny(r)
	if !ok {
		// CLE-77795: name WHY in the log so a prd 401 on POST /v1/files is
		// diagnosable — unknown_token is the tell-tale of a hub restart that
		// wiped the per-process token map (the client still held a token the
		// new process never minted), expired_token is a plain TTL lapse, and
		// no_bearer is a call with no Authorization at all. The response body
		// stays "door" (the WUI keys the refresh-and-retry off it).
		s.o.Log.Warn().
			Str("request_id", w.Header().Get("X-Request-ID")).
			Str("method", r.Method).Str("path", r.URL.Path).Str("host", r.Host).
			Str("reason", reason).Msg("upload token refused")
		writeErr(w, http.StatusUnauthorized, "door", "a valid upload token is required")
		return store.Tenant{}, "", false
	}
	if !s.tenantConsistent(w, r, tenant) {
		return store.Tenant{}, "", false
	}
	t, ok := s.loadTenant(w, r, tenant)
	return t, box, ok
}

// tenantConsistent writes 403 when the Host or TenantHeader names another
// tenant than the credential proved.
func (s *Server) tenantConsistent(w http.ResponseWriter, r *http.Request, tenant string) bool {
	host := s.hostTenantID(r)
	named := strings.ToLower(strings.TrimSpace(r.Header.Get(TenantHeader)))
	if (host != "" && host != tenant) || (named != "" && named != tenant) {
		writeErr(w, http.StatusForbidden, "tenant_mismatch", "the credential belongs to another tenant")
		return false
	}
	return true
}

// bearerAny checks the WS-issued upload token (OQ-10) and returns its tenant
// and box, and — when it refuses — a reason code for the log (CLE-77795):
// no_bearer (no Authorization), unknown_token (not in the per-process map:
// a hub restart wiped it), expired_token (a plain TTL lapse).
func (s *Server) bearerAny(r *http.Request) (string, string, string, bool) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || tok == "" {
		return "", "", "no_bearer", false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tokens[tok]
	if !ok {
		return "", "", "unknown_token", false
	}
	if s.o.Now().After(t.expires) {
		return "", "", "expired_token", false
	}
	return t.tenant, t.box, "", true
}
