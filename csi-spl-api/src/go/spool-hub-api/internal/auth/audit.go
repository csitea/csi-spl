package auth

import (
	"context"
	"net"
	"net/http"
	"strings"
	"time"
)

// ActivityRecorder records an auth event about a member for the per-person
// Activity log (CLE-77799, owner topic 1fc29f99: "... when he has logged in,
// and logged out etc."). The hub wires it to the store; nil = auditing off.
//
// It is a primitives-only seam so the auth package keeps no dependency on the
// store package. kind is sign_in / sign_out; method is the sign-in method
// (password / google / facebook / microsoft / linkedin / xai / actas); ip is a
// /24-masked address and ua a coarse user agent (never a token, cookie,
// password, a full IP or a third party's email — owner privacy rule).
type ActivityRecorder interface {
	RecordAuthEvent(ctx context.Context, tenant, humanID, kind, method, ip, ua string, at time.Time) error
}

// recordAuth appends one auth event, best-effort: a failure is logged and
// swallowed so it NEVER fails the sign-in / sign-out it audits. It is skipped
// when auditing is off or the tenant / human is unknown (a sign-in that has not
// yet resolved a single workspace carries no per-workspace attribution).
func (h *Handler) recordAuth(r *http.Request, tenant, humanID, kind, method string) {
	if h.audit == nil || tenant == "" || humanID == "" {
		return
	}
	ip := maskIP(clientIP(r, h.hops))
	ua := coarseUA(r.UserAgent())
	if err := h.audit.RecordAuthEvent(r.Context(), tenant, humanID, kind, method, ip, ua, h.now().UTC()); err != nil {
		h.log.Warn().Err(err).Str("tenant", tenant).Str("kind", kind).Msg("auth activity not recorded")
	}
}

// maskIP masks a client IP for the audit log: IPv4 to /24 (last octet zeroed),
// IPv6 to /48. Owner rule: never store a full IP. "" or an unparseable value
// stays "".
func maskIP(ip string) string {
	s := strings.TrimSpace(ip)
	if s == "" {
		return ""
	}
	p := net.ParseIP(s)
	if p == nil {
		return ""
	}
	if v4 := p.To4(); v4 != nil {
		return net.IPv4(v4[0], v4[1], v4[2], 0).String() + "/24"
	}
	return p.Mask(net.CIDRMask(48, 128)).String() + "/48"
}

// coarseUA reduces a User-Agent to a "<browser> on <OS>" pair, so the audit
// shows "Chrome on Windows" without storing a fingerprintable string. "" stays
// "". Order matters: Edge/Opera masquerade as Chrome, Chrome as Safari.
func coarseUA(ua string) string {
	if strings.TrimSpace(ua) == "" {
		return ""
	}
	browser := "Other"
	switch {
	case strings.Contains(ua, "Edg/"):
		browser = "Edge"
	case strings.Contains(ua, "OPR/") || strings.Contains(ua, "Opera"):
		browser = "Opera"
	case strings.Contains(ua, "Firefox/"):
		browser = "Firefox"
	case strings.Contains(ua, "Chrome/") || strings.Contains(ua, "Chromium/"):
		browser = "Chrome"
	case strings.Contains(ua, "Safari/"):
		browser = "Safari"
	}
	os := "Other"
	switch {
	case strings.Contains(ua, "Windows"):
		os = "Windows"
	case strings.Contains(ua, "Android"):
		os = "Android"
	case strings.Contains(ua, "iPhone"), strings.Contains(ua, "iPad"):
		os = "iOS"
	case strings.Contains(ua, "Mac OS X"), strings.Contains(ua, "Macintosh"):
		os = "macOS"
	case strings.Contains(ua, "Linux"):
		os = "Linux"
	}
	return browser + " on " + os
}
