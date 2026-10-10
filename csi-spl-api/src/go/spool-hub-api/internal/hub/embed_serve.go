package hub

import (
	"context"
	"io/fs"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The hub serves /embed/* (specs/121 section 5, T201), not Firebase: a static
// host cannot vary frame-ancestors per customer. Every response the hub sends
// refuses framing (frameGuard); only the chat page of a known, enabled embed
// may be framed, and only by that embed's allowed_origins. The loader script
// is fetched cross-origin by the customer's page, so it carries
// Cross-Origin-Resource-Policy: cross-origin; no /embed/* response carries
// Access-Control-Allow-Origin (the iframe calls the hub from our own origin).
const (
	embedLoaderFile = "v1/loader.js"
	embedChatFile   = "v1/chat"
	// embedLoaderAsset and embedChatAsset name the files inside the assets
	// (T202's embedassets).
	embedLoaderAsset = "loader.js"
	embedChatAsset   = "chat.html"
	frameNone        = "frame-ancestors 'none'"
)

// embedOrigin is the host part a CSP frame-ancestors source may carry: lower
// case labels (an optional leading "*." label), an optional port, nothing
// else. It keeps a stored value from adding a directive (";") or a source.
var embedOrigin = regexp.MustCompile(`^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$`)

// embedLookup reads one embed by its id: store.Postgres (rdb 0169). A store
// without it frames nothing.
type embedLookup interface {
	EmbedCustomer(ctx context.Context, embedID string) (store.EmbedCustomer, error)
}

// frameGuard refuses framing on every response: CSP frame-ancestors 'none'
// and X-Frame-Options: DENY, set before the handler runs. A handler that sets
// its own Content-Security-Policy replaces the first, and X-Frame-Options:
// DENY still refuses; only serveEmbed lifts both, for a framable chat page.
func frameGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", frameNone)
		h.Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

// routeEmbedServe mounts GET /embed/{path...} when cnf env.hub.embed.enabled
// is on; off, /embed/* is the mux's 404 under frameGuard. assets holds
// loader.js and chat.html (T202); nil answers 404 with the same headers.
func (s *Server) routeEmbedServe(mux *http.ServeMux, enabled bool, assets fs.FS) {
	if !enabled {
		return
	}
	mux.HandleFunc("GET /embed/{path...}", func(w http.ResponseWriter, r *http.Request) {
		s.serveEmbed(w, r, assets)
	})
}

func (s *Server) serveEmbed(w http.ResponseWriter, r *http.Request, assets fs.FS) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	switch r.PathValue("path") {
	case embedLoaderFile:
		h.Set("Cross-Origin-Resource-Policy", "cross-origin")
		h.Set("Cache-Control", "public, max-age=300")
		serveEmbedAsset(w, assets, embedLoaderAsset, "text/javascript; charset=utf-8")
	case embedChatFile:
		// The policy is per embed and its owner may change it: never cached.
		h.Set("Cache-Control", "no-store")
		if fa := s.embedFrameAncestors(r.Context(), r.URL.Query().Get("e")); fa != "" {
			h.Set("Content-Security-Policy", fa)
			h.Del("X-Frame-Options")
		}
		serveEmbedAsset(w, assets, embedChatAsset, "text/html; charset=utf-8")
	default:
		writeErr(w, http.StatusNotFound, "not_found", "no such embed file")
	}
}

// embedFrameAncestors is the frame-ancestors policy of embed id: those of
// its allowed_origins that are a valid origin. "" (keep 'none') for an
// unknown, disabled or unreadable embed, or one with no valid origin: it
// fails closed.
func (s *Server) embedFrameAncestors(ctx context.Context, id string) string {
	lk, ok := s.o.Store.(embedLookup)
	if id == "" || !ok {
		return ""
	}
	e, err := lk.EmbedCustomer(ctx, id)
	if err != nil || !e.Enabled {
		return ""
	}
	var srcs []string
	for _, o := range e.AllowedOrigins {
		if validFrameOrigin(o) {
			srcs = append(srcs, o)
		}
	}
	if len(srcs) == 0 {
		return ""
	}
	return "frame-ancestors " + strings.Join(srcs, " ")
}

// validFrameOrigin: https://<host>[:port], or http:// for localhost alone
// (a dev box); no path, query, fragment or user part.
func validFrameOrigin(o string) bool {
	u, err := url.Parse(o)
	if err != nil || o != u.Scheme+"://"+u.Host {
		return false
	}
	switch {
	case u.Scheme == "https":
	case u.Scheme == "http" && u.Hostname() == "localhost":
	default:
		return false
	}
	return embedOrigin.MatchString(u.Host)
}

func serveEmbedAsset(w http.ResponseWriter, assets fs.FS, name, ctype string) {
	var b []byte
	err := fs.ErrNotExist
	if assets != nil {
		b, err = fs.ReadFile(assets, name)
	}
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such embed file")
		return
	}
	w.Header().Set("Content-Type", ctype)
	w.WriteHeader(http.StatusOK)
	w.Write(b) //nolint:errcheck
}
