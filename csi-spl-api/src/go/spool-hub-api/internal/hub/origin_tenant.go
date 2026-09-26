package hub

import (
	"net/http"
	"net/url"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Tenant hosts of the WUI (SPL-959, owner option B 2026-09-26): every tenant
// but the apex one is served on https://<tenant>.<fqdn>, and the apex
// https://<fqdn> is the apex tenant (t1). The WUI calls the api host
// cross-origin, so the browser's Origin names the page's host. That page
// tenant is what the hub serves the request as. It is a selection, never a
// grant: the caller must still be a member (auth.ActiveTenant). Because it is
// taken per request, two tabs on two tenant hosts never cross, whatever the
// session cookie's `t` says.
//
// The pattern is SPOOL_HUB_TENANT_HOST_PATTERN ({tenant}.<env fqdn>), so dev
// and prd never match each other's hosts: a prd label cannot hold a dot, and
// "dev" is a reserved tenant id (msg.ValidTenantID).

// OriginTenant is the page tenant of a WUI request read from its Origin.
type OriginTenant struct {
	suffix     string // ".<fqdn>"
	apexHost   string // "<fqdn>"
	apexTenant string // "" = the apex keeps the session's tenant
}

// NewOriginTenant builds the resolver; nil when tenant hosts are off.
func NewOriginTenant(pattern, apexTenant string) *OriginTenant {
	suffix, ok := strings.CutPrefix(strings.ToLower(pattern), "{tenant}")
	if !ok || !strings.HasPrefix(suffix, ".") || len(suffix) < 2 {
		return nil
	}
	return &OriginTenant{suffix: suffix, apexHost: suffix[1:], apexTenant: apexTenant}
}

// host answers the host of an https origin with no port, path or userinfo.
func originHost(o string) (string, bool) {
	if o == "" {
		return "", false
	}
	u, err := url.Parse(o)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.Port() != "" || u.User != nil ||
		(u.Path != "" && u.Path != "/") || u.RawQuery != "" {
		return "", false
	}
	return strings.ToLower(u.Host), true
}

// Of answers the tenant an Origin names: the label of a tenant host, the apex
// tenant for the apex, else "".
func (ot *OriginTenant) Of(origin string) string {
	if ot == nil {
		return ""
	}
	host, ok := originHost(origin)
	if !ok {
		return ""
	}
	if host == ot.apexHost {
		return ot.apexTenant
	}
	id, ok := strings.CutSuffix(host, ot.suffix)
	if !ok || !msg.ValidTenantID(id) {
		return ""
	}
	return id
}

// Request is Of(the request's Origin); the auth.Options.PageTenant hook.
func (ot *OriginTenant) Request(r *http.Request) string {
	if ot == nil {
		return ""
	}
	return ot.Of(r.Header.Get("Origin"))
}

// TenantHost reports whether origin is a tenant host of this env (the CORS
// allow-list's pattern half; the apex stays an exact entry).
func (ot *OriginTenant) TenantHost(origin string) bool {
	if ot == nil {
		return false
	}
	host, ok := originHost(origin)
	if !ok || host == ot.apexHost {
		return false
	}
	id, ok := strings.CutSuffix(host, ot.suffix)
	return ok && msg.ValidTenantID(id)
}

// originAllowed: an exact SPOOL_HUB_VIEW_CORS_ORIGINS entry, or (tenant hosts
// on) a tenant host of this env.
func (s *Server) originAllowed(o string) bool {
	if o == "" {
		return false
	}
	for _, a := range s.o.ViewCORSOrigins {
		if o == a {
			return true
		}
	}
	return s.o.OriginTenant.TenantHost(o)
}
